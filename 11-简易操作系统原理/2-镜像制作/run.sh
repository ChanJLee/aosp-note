#!/bin/bash

source env.sh

docker container ls -a | grep os-make | awk '{print $1}' | xargs docker container rm -f

src=`pwd`/src

docker run -it \
  --name=os-make \
  --mount "type=bind,src=${src},dst=/mirror" \
  ${IMAGE_NAME} \
  bash -c "cd /mirror && ls -l && make all && make run"