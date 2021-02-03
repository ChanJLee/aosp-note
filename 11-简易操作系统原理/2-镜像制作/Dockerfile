FROM chrismacp/ubuntu-10.04

RUN sed -i 's/archive/old-releases/' /etc/apt/sources.list
# COPY sources.list /etc/apt/sources.list.d/old.sources.list

RUN echo "y" | apt-get update
RUN echo "y" | apt-get upgrade
RUN apt-get install nasm make build-essential grub zip -y --force-yes
RUN apt-get install qemu -y --force-yes --fix-missing