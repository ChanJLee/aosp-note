#!/bin/bash

source env.sh

docker run -d \
  --name=os-make \
  --mount 'type=volume,source=How-to-Make-a-Computer-Operating-System/src,target=/mirror' \
  ${IMAGE_NAME}