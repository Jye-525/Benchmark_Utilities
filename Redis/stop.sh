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

echo -e "${GREEN}Stopping Redis ...${NC}"
mpssh -f ${CWD}/servers 'killall -9 redis-server' > /dev/null

echo -e "${GREEN}Double checking redis-server process ...${NC}"
mpssh -f ${CWD}/servers "pgrep -la redis-server" | sort

echo -e "${GREEN}Redis is stopped${NC}"
