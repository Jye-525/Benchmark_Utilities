#!/bin/bash
#environment variables
REDIS_CONFS_DIR=/home/jye20/redis_test/redis_confs
REDIS_CONFS_LISTS=/home/jye20/redis_test/redis_confs_lists

# redis config variables
RDB_COMPRESSION_OPS=("yes" "no")
IO_THREADS_VALS=(1 4)
HZ_VALS=(10 50)
RDB_SAVE_INCREMENTAL_FSYNC_OPS=("yes" "no")
SAVE_PARAS_LISTS=("15 1,5 10,1 10000" "900 1,300 10,60 10000")

#create and clean redis confs dir
if [ ! -d ${REDIS_CONFS_DIR} ]; then
    mkdir -p ${REDIS_CONFS_DIR}
fi
#clean DEPLOYMENT_CONF_DIR
rm -f ${REDIS_CONFS_DIR}/*
rm -f ${REDIS_CONFS_LISTS}

write_basic_redis_conf_items(){
  redis_conf_file=$1
  echo "port 6379" >> ${redis_conf_file}
  echo "protected-mode no" >> ${redis_conf_file}
  echo "daemonize yes" >> ${redis_conf_file}
  echo "loglevel notice" >> ${redis_conf_file}
  echo "logfile redis.log" >> ${redis_conf_file}
  echo "cluster-enabled yes" >> ${redis_conf_file}
  echo "cluster-config-file nodes.conf" >> ${redis_conf_file}
  echo "cluster-node-timeout 15000" >> ${redis_conf_file}
}

echo "Begin to generate redis config files...."
# iterate different configuration Items and generate redis configuration files
seq=0
for hz in "${HZ_VALS[@]}"
do
  for rdb_save_incremental in "${RDB_SAVE_INCREMENTAL_FSYNC_OPS[@]}"
  do
    for rdbcompression in "${RDB_COMPRESSION_OPS[@]}"
    do
      for io_threads in "${IO_THREADS_VALS[@]}"
      do
        for save_paras in "${SAVE_PARAS_LISTS[@]}"
        do
          seq=$((seq + 1))
          redis_conf_file=${REDIS_CONFS_DIR}/redis_${seq}.conf
          if [ -f ${redis_conf_file} ]; then
            echo "" > ${redis_conf_file}
          fi
          #write the basic config items to redis conf file
          write_basic_redis_conf_items ${redis_conf_file}
          #write other config items
          echo "rdbcompression ${rdbcompression}" >> ${redis_conf_file}
          echo "rdb-save-incremental-fsync ${rdb_save_incremental}" >> ${redis_conf_file}
          echo "io-threads ${io_threads}" >> ${redis_conf_file}
          echo "io-threads-do-reads yes" >> ${redis_conf_file}
          echo "hz ${hz}" >> ${redis_conf_file}
          save_lists=(`echo ${save_paras} |tr ' ' '&'| tr ',' ' '`)
          for save in "${save_lists[@]}"
          do
            save=`echo ${save} |tr '&' ' '`
            echo "save ${save}" >> ${redis_conf_file}
          done

          # append the config path to redis_conf_lists file
          echo ${redis_conf_file} >> ${REDIS_CONFS_LISTS}
        done
      done
    done
  done
done
echo "End to generate redis conf files....."
