FROM ubuntu:10.04

RUN apt-get update
RUN apt-get install nasm make build-essential grub zip git -y --force-yes
RUN apt-get install qemu -y --force-yes --fix-missing

RUN git clone https://github.com/SamyPesse/How-to-Make-a-Computer-Operating-System.git
RUN cd How-to-Make-a-Computer-Operating-System/src
RUN make all
RUN make run