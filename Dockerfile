FROM ubuntu:20.04

# inpiration 1: https://github.com/jupyter/docker-stacks/blob/master/pyspark-notebook/Dockerfile
# inspiration 2: https://github.com/myzhang1029/toyplot_notebook/blob/2a98b8903f752a3ad6cf6f86f875e86150504ad8/Dockerfile
# build image with "docker build -t rm-jupyter ."
# run with "docker run -p 8888:8888 -v ~/jupyter_src:/home/mamba/jupyter_src rm-jupyter"
#   above assumes a folder named ~/jupyter_src for jupyter source in $HOME
#   and an image built to image name rm-jupyter
# connect on the Host PC at using the 127.0.0.1 URL provided by Jupyter

# Fix DL4006, also source micromamba bashrc changes
# SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# configure notebook user
ARG NB_USER="mamba"
ARG NB_UID="1000"
ARG NB_GID="100"

# Install packages as root
USER root

# Install all OS dependencies for fully functional notebook server
RUN apt-get update -y && \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    --no-install-recommends \
    # base-notebook
    tini \
    wget \
    ca-certificates \
    locales \
    fonts-liberation \
    # minimal-notebook
    build-essential \
    vim-tiny \
    git \
    inkscape \
    libsm6 \
    libxext-dev \
    libxrender1 \
    lmodern \
    netcat \
    openssh-client \
    # ---- nbconvert dependencies ----
    texlive-xetex \
    texlive-fonts-recommended \
    texlive-plain-generic \
    # ----
    tzdata \
    unzip \
    # scipy-notebook
    ffmpeg dvipng cm-super \
    # additional
    cmake \
    pkg-config && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Spark dependencies
# Default values can be overridden at build time
# (ARGS are in lower case to distinguish them from ENV)
ARG spark_version="3.1.2"
ARG hadoop_version="3.2"
ARG spark_checksum="2385CB772F21B014CE2ABD6B8F5E815721580D6E8BC42A26D70BBCDDA8D303D886A6F12B36D40F6971B5547B70FAE62B5A96146F0421CB93D4E51491308EF5D5"
ARG openjdk_version="11"

ENV APACHE_SPARK_VERSION="${spark_version}" \
    HADOOP_VERSION="${hadoop_version}"

RUN apt-get update --yes && \
    apt-get install --yes --no-install-recommends \
    "openjdk-${openjdk_version}-jre-headless" \
    ca-certificates-java && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Spark installation
WORKDIR /tmp
RUN wget -q "https://archive.apache.org/dist/spark/spark-${APACHE_SPARK_VERSION}/spark-${APACHE_SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz" && \
    echo "${spark_checksum} *spark-${APACHE_SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz" | sha512sum -c - && \
    tar xzf "spark-${APACHE_SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz" -C /usr/local --owner root --group root --no-same-owner && \
    rm "spark-${APACHE_SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz"

WORKDIR /usr/local

# Configure Spark
ENV SPARK_HOME=/usr/local/spark
ENV SPARK_OPTS="--driver-java-options=-Xms1024M --driver-java-options=-Xmx4096M --driver-java-options=-Dlog4j.logLevel=info" \
    PATH="${PATH}:${SPARK_HOME}/bin"

RUN ln -s "spark-${APACHE_SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}" spark 

# Fix Spark installation for Java 11 and Apache Arrow library
# see: https://github.com/apache/spark/pull/27356, https://spark.apache.org/docs/latest/#downloading
RUN cp -p "${SPARK_HOME}/conf/spark-defaults.conf.template" "${SPARK_HOME}/conf/spark-defaults.conf" && \
    echo 'spark.driver.extraJavaOptions -Dio.netty.tryReflectionSetAccessible=true' >> "${SPARK_HOME}/conf/spark-defaults.conf" && \
    echo 'spark.executor.extraJavaOptions -Dio.netty.tryReflectionSetAccessible=true' >> "${SPARK_HOME}/conf/spark-defaults.conf"

# Install Micromamba
# No need to keep the image small as micromamba does. Jupyter requires
# those packages anyways
ARG TARGETARCH
RUN [ "${TARGETARCH}" = 'arm64' ] && export ARCH='aarch64' || export ARCH='64' && \
    wget -qO - "https://micromamba.snakepit.net/api/micromamba/linux-${ARCH}/latest" | \
    tar -xj -C / bin/micromamba

# configure shell and env variables for jupyter (notebook server) and micromamba (faster, better solver microconda) to handle Python environments
ENV SHELL=/bin/bash \
    NB_USER="${NB_USER}" \
    NB_UID=${NB_UID} \
    NB_GID=${NB_GID} \
    ENV_NAME="base" \
    MAMBA_ROOT_PREFIX="/opt/conda" \
    LC_ALL="en_US.UTF-8" \
    LANG="en_US.UTF-8" \
    LANGUAGE="en_US.UTF-8"
ENV HOME="/home/${NB_USER}"
ENV PATH="${MAMBA_ROOT_PREFIX}/bin:${HOME}/.cargo/bin:${PATH}"

# Make sure when users use the terminal, the locales are reasonable
RUN sed -i.bak -e 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && \
    locale-gen && \
    update-locale && \
    dpkg-reconfigure --frontend noninteractive locales

# Copy a script that we will use to correct permissions after running certain commands
COPY fix-permissions /usr/local/bin/fix-permissions
RUN chmod a+rx /usr/local/bin/fix-permissions

# Enable prompt color in the skeleton .bashrc before creating the default NB_USER
RUN sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' /etc/skel/.bashrc

# Create NB_USER with name ${NB_USER} user with UID=${NB_UID} and in the 'users' group
# and make sure these dirs are writable by the `users` group.
# Then initialize micromamba
RUN useradd -l -m -s /bin/bash -N -u "${NB_UID}" "${NB_USER}" && \
    mkdir -p "${HOME}" && \
    /bin/micromamba shell init -s bash -p "${MAMBA_ROOT_PREFIX}" && \
    echo "micromamba activate ${ENV_NAME}" >> "${HOME}/.bashrc" && \
    chown "${NB_USER}:${NB_GID}" "${MAMBA_ROOT_PREFIX}" && \
    chmod g+w /etc/passwd && \
    fix-permissions "${HOME}" && \
    fix-permissions "${MAMBA_ROOT_PREFIX}"

# Use notebook user for future commands
USER ${NB_UID}

# use micromamba to install python packages
# 3.8 (newest Python supported by Tensorflow), Jupyter, and Pyarrow (note: pyarrow permissions fixes removed)
RUN micromamba install -y -n base -c conda-forge \
        altair \
        beautifulsoup4 \
        bokeh \
        bottleneck \
        cloudpickle \
        cython \
        dask \
        dill \
        h5py \
        ipython \
        ipympl \
        ipywidgets \
        jupyterhub \
        jupyterlab \
        # Git plugin
        jupyterlab-git \
        # Needed for math rendering
        jupyterlab-mathjax3 \
        matplotlib-base \
        notebook \
        numba \
        numexpr \
        pandas \
        patsy \
        protobuf \
        pyopenssl \
        pytables \
        python=3.8 \
        requests \
        scikit-image \
        scikit-learn \
        scipy \
        seaborn \
        sqlalchemy \
        statsmodels \
        sympy \
        toyplot \
        widgetsnbextension \
        # C++ kernel
        xeus-cling \
        xlrd \
        'pyarrow=4.0.*' \
        pyspark \
        psycopg2

# Install Tensorflow for if target architecture is not ARM
# ARM64 does not have Tensorflow in conda-forge yet
RUN [ "${TARGETARCH}" = 'arm64' ] || \
    micromamba install -y -n base -c conda-forge tensorflow
RUN micromamba clean --all --yes

# Install Rust
RUN wget -qO- https://sh.rustup.rs | sh -s -- -y
RUN rustup component add rust-src
# Install Rust kernel
RUN cargo install evcxr_jupyter
RUN evcxr_jupyter --install

# start up Jupyterlab
EXPOSE 8888
ENTRYPOINT ["tini", "-g", "--"]
CMD ["jupyter", "lab", "--ip='0.0.0.0'", "--port=8888", "--no-browser", "--allow-root"]
COPY jupyter_server_config.py /etc/jupyter/
WORKDIR "${HOME}"

# Debug command to make this docker image's containers wait forever but terminate quickly
# https://stackoverflow.com/a/35770783/1409028
# CMD exec /bin/bash -c "trap : TERM INT; sleep 9999999 & wait"
