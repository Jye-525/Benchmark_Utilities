#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

CWD="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

if [ -f ${CWD}/env_ares.sh ]
then
  source ${CWD}/env_ares.sh
else
  echo "env_ares.sh does not exist, quiting ..."
  exit
fi

if [ $# -eq 2 ];then
  LOCAL_DIR=$1
  REDIS_CONF_NUM=$2
fi

echo "Redis install dir is ${LOCAL_DIR}, config number is ${REDIS_CONF_NUM}..."

function version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

n_server=`cat ${CWD}/servers | wc -l`
if [ $((n_server%2)) -ne 0 ]
then
  echo "Even number of servers are required, exiting ..."
  exit
fi

#if [[ `grep -- "${HOSTNAME_POSTFIX}" ${CWD}/servers | wc -l` == ${n_server} ]]
#then
#  echo -e "${CYAN}Hostname with ${HOSTNAME_POSTFIX} provided, use it directly ...${NC}"
#  HOSTNAME_POSTFIX=""
#elif [[ `grep -- "${HOSTNAME_POSTFIX}" ${CWD}/servers | wc -l` != 0 ]]
#then
#  echo "Mixed hostname format is not supported, exiting ..."
#  exit
#else
#  echo -e "${CYAN}Hostname without postfix provided, adding ${HOSTNAME_POSTFIX} ...${NC}"
#  sed -e "s/$/${HOSTNAME_POSTFIX}/" -i ${CWD}/servers
#fi

# Prepare configuration for each server
echo -e "${GREEN}Preparing Redis cluster configuration files ...${NC}"
i=0
for server in ${SERVERS[@]}
do
  server_ip=$(getent ahosts $server$HOSTNAME_POSTFIX | grep STREAM | awk '{print $1}')
  ((port=$PORT_BASE+$i))
  mkdir -p ${CWD}/$port
  cp ${REDIS_CONFS_DIR}/redis_${REDIS_CONF_NUM}.conf $port/$CONF_FILE
  sed -e "s/port 6379/port ${port}/g" -i $port/$CONF_FILE
  ((i=i+1))
done

# Copy configuration files to local directories on all servers
echo -e "${GREEN}Copying Redis cluster configuration files ...${NC}"
i=0
for server in ${SERVERS[@]}
do
  ((port=$PORT_BASE+$i))
  echo Copying configuration directory $port to $server ...
  ssh $server mkdir -p $LOCAL_DIR
  rsync -qraz ${CWD}/$port $server:$LOCAL_DIR/
  ((i=i+1))
done
wait

# Start server
echo -e "${GREEN}Starting Redis ...${NC}"
i=0
for server in ${SERVERS[@]}
do
  ((port=$PORT_BASE+$i))
  echo Starting redis on $server:$port ...
  ssh $server "sh -c \"cd $LOCAL_DIR/$port; $REDIS_DIR/redis-server ./$CONF_FILE > /dev/null 2>&1 &\""
  ((i=i+1))
done
wait

# Verify server
echo -e "${GREEN}Verifying Redis cluster servers ...${NC}"
mpssh -f ${CWD}/servers 'pgrep -l redis-server'

# Connect servers
# for Redis 5 the command should be like redis-cli --cluster create 127.0.0.1:7000 127.0.0.1:7001 --cluster-replicas 1
# for Redis 3 and 4, the command looks like ./redis-trib.rb create --replicas 1 127.0.0.1:7000 127.0.0.1:7001
echo -e "${GREEN}Connecting Redis cluster servers ...${NC}"
i=0
echo "Using redis-cli ..."
cmd="$REDIS_DIR/redis-cli --cluster create "
for server in ${SERVERS[@]}
do
  server_ip=$(getent ahosts $server$HOSTNAME_POSTFIX | grep STREAM | awk '{print $1}')
  ((port=$PORT_BASE+$i))
  cmd="${cmd}${server_ip}:${port} "
  ((i=i+1))
done
cmd="${cmd}--cluster-replicas 0"
echo yes | $cmd

# Check cluster nodes
echo -e "${GREEN}Checking Redis cluster nodes ...${NC}"
first_server=`head -1 ${CWD}/servers`
cmd="$REDIS_DIR/redis-cli -c -h ${first_server}${HOSTNAME_POSTFIX} -p ${PORT_BASE} cluster nodes"
$cmd | sort -k9 -n
echo -e "${GREEN}Redis is started${NC}"
