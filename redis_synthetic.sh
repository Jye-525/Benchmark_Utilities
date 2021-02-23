#!/bin/bash
# env_parameters
REDIS_BIN_DIR=/home/jye20/pkg_install/redis-6.0.9/bin
REDIS_CLUSTER_INSTALL_DIR=/mnt/ssd/jye20/redis_cluster
REDIS_SERVER_HOSTS=/home/jye20/redis_test/Redis/servers
REDIS_DEPLOYMENT_SCRIPTS_DIR=/home/jye20/redis_test/Redis

REDIS_CONFS_DIR=/home/jye20/redis_test/redis_confs
REDIS_CONFS_LIST=/home/jye20/redis_test/redis_confs_lists

CLIENT_HOSTS=/home/jye20/redis_test/clients
BENCHMARK_EXEC_NAME=/home/jye20/redis_test/redis_cluster_bench

TESTING_RESULTS_DIR=/home/jye20/redis_test/results

#IFACE=enp47s0
#IFACE=""

# workload variables
# The default value of clients are 1 4 8 16
N_CLIETS=(16)
# The default value of clients are 4 8 16
N_SERVERS=(16)

# device type values: nvme,ssd,hdd
#DEVICE_TYPES=("nvme" "ssd" "hdd")
#DEVICE_TYPES=("nvme")
DEVICE_TYPES=("hdd" "ssd" "nvme")

ppn_nums=40

stop_and_cleanup_redis()
{
  echo "Begin to stop and clean Redis Cluster....."
  # stop redis_cluster
  cd ${REDIS_DEPLOYMENT_SCRIPTS_DIR}
  ./clean.sh ${REDIS_CLUSTER_INSTALL_DIR}
  cd -
  echo "End to stop and clean Redis Cluster....."
}

clear_redis_data()
{
  echo "Begin to clear Redis dataset in Cluster...."
  cd ${REDIS_DEPLOYMENT_SCRIPTS_DIR}
  ./flushall.sh
  cd -
  echo "End to clear Redis dataset in Cluster..."
}

deploy_and_start_redis_cluster()
{
  echo "Begin to deploy and start Redis Cluster....."
  # copy config file to redis repo
  conf_file_seq=$1
  cd ${REDIS_DEPLOYMENT_SCRIPTS_DIR}
  ./start.sh ${REDIS_CLUSTER_INSTALL_DIR} ${conf_file_seq}
  cd -
  echo "End to deploy and start Redis Cluster....."
}

create_and_clear_results_dir()
{
  # create and clear the results directory
  if [ ! -d ${TESTING_RESULTS_DIR} ]; then
    mkdir -p ${TESTING_RESULTS_DIR}
  fi
  # clear testing results directory
  rm -rf ${TESTING_RESULTS_DIR}/*
}

clear_system_cache()
{
  mpssh -f ${REDIS_SERVER_HOSTS} "sudo fm" > /dev/null 2>&1
  mpssh -f ${CLIENT_HOSTS} "sudo fm" > /dev/null 2>&1
}

metadata_test()
{
   # clear system cache
   clear_system_cache
   sleep 1
   echo "Phase1: metadata test..."
   mpiexec -f ${CLIENT_HOSTS} -ppn ${ppn_nums} -prepend-rank ${BENCHMARK_EXEC_NAME} ${redis_endpoints} 0 0 0
}

write_test()
{
  seq=$1
  io_pattern=$2
  io_type=$3
  # clear redis dataset
  clear_redis_data
  sleep 2
  # clear system cache
  clear_system_cache
  sleep 1
  # execute write test
  if [ ${io_pattern} == "sequential" ]; then
    if [ ${io_type} == "small" ]; then
      echo "Phase${seq}: sequential small io write  test..."
	  mpiexec -f ${CLIENT_HOSTS} -ppn ${ppn_nums} -prepend-rank ${BENCHMARK_EXEC_NAME} ${redis_endpoints} 1 0 0
	else
      echo "Phase${seq}: sequential large io write test..."
      mpiexec -f ${CLIENT_HOSTS} -ppn ${ppn_nums} -prepend-rank ${BENCHMARK_EXEC_NAME} ${redis_endpoints} 1 1 0
    fi
  else
    if [ ${io_type} == "small" ]; then
      echo "Phase${seq}: random small io write test..."
      mpiexec -f ${CLIENT_HOSTS} -ppn ${ppn_nums} -prepend-rank ${BENCHMARK_EXEC_NAME} ${redis_endpoints} 2 0 0
    else
      echo "Phase${seq}: random large io write test..."
      mpiexec -f ${CLIENT_HOSTS} -ppn ${ppn_nums} -prepend-rank ${BENCHMARK_EXEC_NAME} ${redis_endpoints} 2 1 0
    fi
  fi
}

read_test()
{
  seq=$1
  io_pattern=$2
  io_type=$3
  # clear system cache
  clear_system_cache
  sleep 1
  # execute read test
  if [ ${io_pattern} == "sequential" ]; then
    if [ ${io_type} == "small" ]; then
      echo "Phase${seq}: sequential small io read  test..."
      mpiexec -f ${CLIENT_HOSTS} -ppn ${ppn_nums} -prepend-rank ${BENCHMARK_EXEC_NAME} ${redis_endpoints} 1 0 1
    else
      echo "Phase${seq}: sequential large io read test..."
      mpiexec -f ${CLIENT_HOSTS} -ppn ${ppn_nums} -prepend-rank ${BENCHMARK_EXEC_NAME} ${redis_endpoints} 1 1 1
    fi
  else
    if [ ${io_type} == "small" ]; then
      echo "Phase${seq}: random small io read test..."
      mpiexec -f ${CLIENT_HOSTS} -ppn ${ppn_nums} -prepend-rank ${BENCHMARK_EXEC_NAME} ${redis_endpoints} 2 0 1
    else
      echo "Phase${seq}: random large io read test..."
      mpiexec -f ${CLIENT_HOSTS} -ppn ${ppn_nums} -prepend-rank ${BENCHMARK_EXEC_NAME} ${redis_endpoints} 2 1 1
    fi
  fi
}

# get all the redis servers' ip and port
get_endpoints(){
	REDIS_SERVERS=(`cat ${REDIS_SERVER_HOSTS}`)
	REDIS_SERVERS_NUMS=${#REDIS_SERVERS[@]}
	idx_count=0
	base_port=6379
	redis_endpoints=""
	for redis_server in ${REDIS_SERVERS[@]}
	do
  		redis_ip=$(getent ahosts $redis_server | grep STREAM | awk '{print $1}')
  		((redis_port=$base_port+$idx_count))
  		((idx_count=idx_count+1))
  		if [ ${idx_count} -lt ${REDIS_SERVERS_NUMS} ]; then
     		redis_endpoints="${redis_endpoints}${redis_ip}:${redis_port},"
  		else
     		redis_endpoints="${redis_endpoints}${redis_ip}:${redis_port}"
  		fi
	done
	echo ${redis_endpoints}
}


# Start the synthetic tests
for n_server in "${N_SERVERS[@]}"
do
  # set server files
  cp ${REDIS_SERVER_HOSTS}"_"${n_server} ${REDIS_SERVER_HOSTS}
  redis_endpoints=`get_endpoints`
  echo "redis endpoints: "${redis_endpoints}
  for n_client in "${N_CLIETS[@]}"
  do
  	# set client files
	echo "current client numbers:"${n_client}
	cp ${CLIENT_HOSTS}"_"${n_client} ${CLIENT_HOSTS}
	#list=`cat ${CLIENT_HOSTS}`
	#echo ${list}
    for device in "${DEVICE_TYPES[@]}"
    do
      if [ ${device} == "nvme" ]; then
         REDIS_CLUSTER_INSTALL_DIR=/dev/shm/jye20/redis_cluster
      elif [ ${device} == "ssd" ]; then
         REDIS_CLUSTER_INSTALL_DIR=/mnt/ssd/jye20/redis_cluster
      elif [ ${device} == "hdd" ]; then
         REDIS_CLUSTER_INSTALL_DIR=/mnt/hdd/jye20/redis_cluster
      fi

      # get the redis config lists
      redis_conf_seq=0
      redis_confs=`cat ${REDIS_CONFS_LIST}`
      for redis_conf in ${redis_confs}
      do
        redis_conf_seq=`echo ${redis_conf}|awk -F'_' '{print$4}'|awk -F'.' '{print$1}'`
		#echo ${redis_conf_seq}
        # stop and cleanup redis cluster
        stop_and_cleanup_redis
        sleep 5
        #deploy and start redis cluster
        deploy_and_start_redis_cluster ${redis_conf_seq}
        #deploy_and_start_redis_cluster 5
		sleep 5

        # create and clear the results directory
        create_and_clear_results_dir

        echo "Begin to synthetic benchmark Redis Cluster....${test_seq}"
        # phase1: metadata test
        metadata_test
        # phase2: sequential small io write
        write_test 2 "sequential" "small"
        #phase3: sequential small io read
        read_test 3 "sequential" "small"
        #phase4: random small io read
        read_test 4 "random" "small"
        #phase5: random small io write
        write_test 5 "random" "small"
        #phase6: sequential large io write
        write_test 6 "sequential" "large"
        #phase7: sequential large io read
        read_test 7 "sequential" "large"
        #phase8: random large io read
        read_test 8 "random" "large"
        #phase9: random large io write
        write_test 9 "random" "large"
        echo "End to synthetic benchmark Redis Cluster....${test_seq}"
        ##sleep 5 sec
        sleep 5
        # mv the running result to a new diretory
        echo "Begin to save the running result to new directory...."
        new_results_dir=${TESTING_RESULTS_DIR}"_"${n_server}"s"${n_client}"c_"${device}"_"${redis_conf_seq}
        mv ${TESTING_RESULTS_DIR} ${new_results_dir}
        echo "End to save the running result...."

        # stop & clean redis cluster
        stop_and_cleanup_redis
        sleep 5
      done
    done
  done
done
