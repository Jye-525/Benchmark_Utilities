#!/bin/bash

CWD="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
LOCAL_DIR=/mnt/hdd/jye20/redis_cluster
REDIS_DIR=/home/jye20/pkg_install/redis-6.0.9/bin
REDIS_VER=`${REDIS_DIR}/redis-server -v | awk '{print $3}' | cut -d'=' -f2`
CONF_FILE=redis.conf
#HOSTNAME_POSTFIX=-40g
HOSTNAME_POSTFIX=""
SERVERS=`cat ${CWD}/servers | awk '{print $1}'`
PORT_BASE=6379
REDIS_CONFS_DIR=/home/jye20/redis_test/redis_confs
