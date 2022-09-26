# rm - polysemy

Running:

cd rm-polysemy/
docker build -t rm-jupyter .
docker run -p 8888:8888 -v ~/jupyter_src:/home/mamba/jupyter_src rm-jupyter

Debugging container as root (eg, for container 71fa4a7ae067):
docker exec -u root -it 71fa4a7ae067 /bin/bash

TODO: make it easier to add python packages to the kernel without rebuilding *everything* by adding a second package stage at the end
Currently fixed up the container to be able to handle postgreSQL with the following:
apt-get update
apt-get -y install libpq-dev gcc
pip install psycopg2

