//
// Created by Ye Jie on 2/23/20.
//
#include <cstdio>
#include <cstdlib>
#include <string>
#include <time.h>
#include <sys/time.h>
#include <vector>
#include <sstream>
#include "crc16_slottable.h"
#include "mpi.h"
#include "sw/redis++/redis++.h"

using namespace sw::redis;

#define KILO        1024
#define MEGA        (1024 * 1024)
#define CLUSTER_SLOTS 16384

#define SMALL_IO_SIZE KILO
#define LARGE_IO_SIZE (16 * MEGA)

#define SMALL_REQ_NUMS 98304 // 96MB/1KB
#define LARGE_REQ_NUMS 6 // 96MB/16MB

// The number of metadata requests on each client
#define MDM_REQ_NUMS 25000

#define PIPELINES 1

long long mstime(void){
    struct timeval tv;
    long long mst;

    gettimeofday(&tv, NULL);
    mst = ((long long)tv.tv_sec) * 1000;
    mst += tv.tv_usec/1000;
    return mst;
}

typedef enum EIO_PATTERN{
    METADATA = 0,
    SEQUENTIAL = 1,
    RANDOM = 2
}IOPattern;

typedef enum EIO_TYPE{
    SMALL_IO = 0,
    LARGE_IO = 1
}IOType;

typedef enum EIO_OPERATION{
    WRITE = 0,
    READ = 1
}IOOperation;

void write_redis(RedisCluster &redisCluster, char *key_str, char *value, int test_size){
    try{
        const StringView strKey(key_str);
        const StringView strValue(value, test_size - strKey.size());
        bool result = redisCluster.set(strKey, strValue);
        if (!result)
        {
            printf("Something is wrong with write command.key: %s\n", key_str);
        }
    } catch (const Error &err) {
        printf("Exception: Something is wrong with write command.key: %s\n", key_str);
    };
}

int read_redis(RedisCluster &redisCluster, char *key_str, int test_size){
    try{
        const StringView strKey(key_str);
        auto resp = redisCluster.get(strKey);
        if(!resp || (*resp).length() != test_size - strKey.size())
        {
            printf("Something is wrong with read command.key: %s\n", key_str);
        }
        else
        {
            return 1;
        }
    } catch (const Error &err) {
        printf("Exception: Something is wrong with read command.key:%s\n", key_str);
    };
    return 0;
}

void write_redis_with_pipe(int rank, RedisCluster &redisCluster, char* key_space, char* value, int test_size,
                           const StringView &sslot_tag, int pipelines, int seq){
    try{
        auto pipe = redisCluster.pipeline(sslot_tag);
        for (int j = 0; j < pipelines; ++j) {
            sprintf(key_space, "%s{%s}_%d_%d", "test", sslot_tag.data(), rank, (seq + j));
            const StringView strKey(key_space);
            const StringView strValue(value, test_size);
            pipe.set(strKey, strValue);
        }
        pipe.exec();
    } catch (const Error &err) {
        printf("Exception: write commands with pipes failed\n");
    }
}

void read_redis_with_pipe(int rank, RedisCluster &redisCluster, char *key_space, const StringView &sslot_tag, int test_size, int pipelines, int seq){
    try {
        auto pipe = redisCluster.pipeline(sslot_tag);
        for (int j = 0; j < pipelines; ++j) {
            sprintf(key_space, "%s{%s}_%d_%d", "test", sslot_tag.data(), rank, (seq + j));
            const StringView strKey(key_space);
            pipe.get(strKey);
        }
        auto replies = pipe.exec();
    } catch (const Error &err) {
        printf("Exception: write commands with pipes failed\n");
    }
}

void create_key(RedisCluster &redisCluster, const StringView &strKey){
    try{
        const StringView strValue;
        bool result = redisCluster.set(strKey, strValue);
        if (!result)
        {
            printf("Create key failed. key: %s\n", strKey.data());
        }
    }catch (const Error &err) {
        printf("Exception: Create key failed. key: %s\n", strKey.data());
    };
}

void delete_key(RedisCluster &redisCluster, const StringView &strKey){
    try{
        redisCluster.del(strKey);
    }catch (const Error &err) {
        printf("Exception: Del key failed. key: %s\n", strKey.data());
    };
}

void create_key_with_pipes(int rank, RedisCluster &redisCluster, char* key_space, const StringView &sslot_tag, int pipelines, int seq){
    try {
        const StringView strValue;
        auto pipe = redisCluster.pipeline(sslot_tag);
        for (int j = 0; j < pipelines; ++j) {
            sprintf(key_space, "%s{%s}_%d_%d", "test", sslot_tag.data(), rank, (seq + j));
            const StringView strKey(key_space);
            pipe.set(strKey, strValue);
        }
        pipe.exec();
    } catch (const Error &err) {
        printf("Exception: create key with pipes failed.\n");
    }

}

void delete_key_with_pipes(int rank, RedisCluster &redisCluster, char* key_space, const StringView &sslot_tag, int pipelines, int seq){
    try{
        auto pipe = redisCluster.pipeline(sslot_tag);
        for (int j = 0; j < pipelines; ++j) {
            sprintf(key_space, "%s{%s}_%d_%d", "test", sslot_tag.data(), rank, (seq + j));
            const StringView strKey(key_space);
            pipe.del(strKey);
        }
        pipe.exec();
    } catch (const Error &err) {
        printf("Exception: delete key with pipes failed.\n");
    }
}

double metadata_test(int rank, ConnectionOptions &connectionOptions, char* key_space, int numbers, int pipelines, const std::vector<int> &slot_nums, int slottag_nums){
    // create keys & delete keys
    double mdm_start = MPI_Wtime();
    auto redis_cluster = RedisCluster(connectionOptions);
    if (pipelines == 1)
    {
        int idx = rank % slottag_nums;
        const char* slot_tag = crc16_slot_table[slot_nums[idx]];
        for (int i = 0; i < numbers; ++i) {
            sprintf(key_space, "%s{%s}_%d_%d", "test", slot_tag, rank, i);
            const StringView strKey(key_space);
            // create key
            create_key(redis_cluster, strKey);
            // delete key
            delete_key(redis_cluster, strKey);
        }
    }
    else
    {
        // get the slottag
        int idx = rank % slottag_nums;
        const StringView sslot_tag(crc16_slot_table[slot_nums[idx]]);

        int seq = 0;
        int cyc_nums = numbers / pipelines;
        int remainder = numbers - cyc_nums * pipelines;
        for (int i = 0; i < cyc_nums; ++i) {
            // create key with pipeline
            create_key_with_pipes(rank, redis_cluster, key_space, sslot_tag, pipelines, seq);
            // delete key with pipeline
            delete_key_with_pipes(rank, redis_cluster, key_space, sslot_tag, pipelines, seq);
            seq += pipelines;
        }
        if (remainder != 0){
            create_key_with_pipes(rank, redis_cluster, key_space, sslot_tag, remainder, seq);
            delete_key_with_pipes(rank, redis_cluster, key_space, sslot_tag, remainder, seq);
        }
    }
    double mdm_end = MPI_Wtime();
    return mdm_end - mdm_start;
}

void sequential_rw_test(int rank, RedisCluster &redisCluster, char* key_space, char* value, int test_size,
                        int numbers, int pipelines, const std::vector<int> &slot_nums, int slottag_nums, IOOperation io_operation){
    if (pipelines == 1){
        int idx = rank % slottag_nums;
        const char* slot_tag = crc16_slot_table[slot_nums[idx]];
        for (int i = 0; i < numbers; ++i) {
            sprintf(key_space, "%s{%s}_%d_%d", "test", slot_tag, rank, i);
            if (io_operation == WRITE){
                write_redis(redisCluster,key_space,value,test_size);
            }
            else {
                read_redis(redisCluster, key_space, test_size);
            }
        }
    }
    else {
        // get the slottag
        int idx = rank % slottag_nums;
        const StringView sslot_tag(crc16_slot_table[slot_nums[idx]]);

        int seq = 0;
        int cyc_nums = numbers / pipelines;
        int remainder = numbers - cyc_nums * pipelines;
        for (int i = 0; i < cyc_nums; ++i) {
            // create key with pipeline
            if (io_operation == WRITE){
                write_redis_with_pipe(rank, redisCluster, key_space, value, test_size, sslot_tag, pipelines, seq);
            }
            else {
                read_redis_with_pipe(rank, redisCluster, key_space, sslot_tag, test_size, pipelines, seq);
            }
            seq += pipelines;
        }
        if (remainder != 0){
            if (io_operation == WRITE){
                write_redis_with_pipe(rank, redisCluster, key_space, value, test_size, sslot_tag, remainder, seq);
            }
            else{
                read_redis_with_pipe(rank, redisCluster, key_space, sslot_tag, test_size, remainder, seq);
            }
        }
    }
}

void random_rw_test(int rank, RedisCluster &redisCluster, char* key_space, char* value, int test_size,
                    int numbers, int pipelines, const std::vector<int> &slot_nums, int slottag_nums, IOOperation io_operation){
    if (pipelines == 1){
        int idx = rank % slottag_nums;
        const char* slot_tag = crc16_slot_table[slot_nums[idx]];
        for (int i = 0; i < numbers; ++i) {
            int req_seq = rand() % numbers;
            sprintf(key_space, "%s{%s}_%d_%d", "test", slot_tag, rank, req_seq);
            if (io_operation == WRITE){
                write_redis(redisCluster,key_space,value,test_size);
            }
            else {
                read_redis(redisCluster, key_space, test_size);
            }
        }
    }
    else {
        int idx = rank % slottag_nums;
        const StringView sslot_tag(crc16_slot_table[slot_nums[idx]]);

        int seq = 0;
        int cyc_nums = numbers / pipelines;
        int remainder = numbers - cyc_nums * pipelines;
        int slot_nums_size = slot_nums.size();
        for (int i = 0; i < cyc_nums; ++i) {
            // create key with pipeline
            seq = (rand() % cyc_nums) * pipelines;
            if (io_operation == WRITE) {
                write_redis_with_pipe(rank, redisCluster, key_space, value, test_size, sslot_tag, pipelines, seq);
            }
            else {
                read_redis_with_pipe(rank, redisCluster, key_space, sslot_tag, test_size, pipelines, seq);
            }
            seq += pipelines;
        }
        if (remainder != 0){
            seq = cyc_nums * pipelines;
            if (io_operation == WRITE) {
                write_redis_with_pipe(rank, redisCluster, key_space, value, test_size, sslot_tag, remainder, seq);
            }
            else {
                read_redis_with_pipe(rank, redisCluster, key_space, sslot_tag, test_size, remainder, seq);
            }
        }
    }
}

double sequential_test(int rank, ConnectionOptions &connectionOptions, char* key_space, char* value, IOType io_type, IOOperation io_operation, const std::vector<int> &slot_nums, int slottag_nums){
    // sequential test
    double  start_time = MPI_Wtime();
    auto redisCluster = RedisCluster(connectionOptions);
    if (io_type == SMALL_IO){
        sequential_rw_test(rank, redisCluster, key_space, value, SMALL_IO_SIZE, SMALL_REQ_NUMS, PIPELINES, slot_nums, slottag_nums, io_operation);
    }
    else {// Large IO
        sequential_rw_test(rank, redisCluster, key_space, value, LARGE_IO_SIZE, LARGE_REQ_NUMS, PIPELINES, slot_nums, slottag_nums, io_operation);
    }
    double end_time = MPI_Wtime();
    return end_time - start_time;
}

double random_test(int rank, ConnectionOptions &connectionOptions, char* key_space, char* value, IOType io_type, IOOperation io_operation, const std::vector<int> &slot_nums, int slottag_nums){
    // random test
    double start_time = MPI_Wtime();
    auto redisCluster = RedisCluster(connectionOptions);
    if (io_type == SMALL_IO) {
        random_rw_test(rank, redisCluster, key_space, value, SMALL_IO_SIZE, SMALL_REQ_NUMS, PIPELINES, slot_nums, slottag_nums, io_operation);
    }
    else { // large IO
        random_rw_test(rank, redisCluster, key_space, value, LARGE_IO_SIZE, LARGE_REQ_NUMS, PIPELINES, slot_nums, slottag_nums, io_operation);
    }
    double end_time = MPI_Wtime();
    return end_time - start_time;
}

std::vector<std::string> split(const std::string& s, char delimiter)
{
    std::vector<std::string> tokens;
    std::string token;
    std::istringstream tokenStream(s);
    while (std::getline(tokenStream, token, delimiter))
    {
        tokens.push_back(token);
    }
    return tokens;
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(stderr, "Usage: %s redis_end_points io_pattern(0-metadata 1-sequential 2-random) io_type(0-small io 1-large io) io_operation(0-write 1-read)\n", argv[0]);
        fprintf(stderr, "e.g: %s \"127.0.0.1:6379,127.0.0.1:6380,127.0.0.1:6381\" 0 0 0\n", argv[0]);
        exit(-1);
    }

    int rank, nprocs;
    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &nprocs);

    // Initialize the parameters;
    /* Get masters ip and ports*/
    std::string redis_endpoints(argv[1]);
    auto end_points_arr = split(redis_endpoints,',');
    int cluster_nodes = end_points_arr.size();

    IOPattern io_pattern = static_cast<IOPattern>(atoi(argv[2]));
    IOType  io_type = static_cast<IOType>(atoi(argv[3]));
    IOOperation io_operation = static_cast<IOOperation>(atoi(argv[4]));

    char* value = nullptr;
    if (io_pattern != METADATA){
        if (io_type == SMALL_IO){
            value = (char*)malloc(sizeof(char) * (SMALL_IO_SIZE + 1));
            memset(value, 'a', SMALL_IO_SIZE);
        }
        else
        {
            value = (char*)malloc(sizeof(char) * (LARGE_IO_SIZE + 1));
            memset(value, 'b', LARGE_IO_SIZE);
        }
    }
    char key_base[512], temp[512];

    srand(1);
    /* generate all the slots tags*/
    std::vector<int> slots_nums;
    int slots_one_node = CLUSTER_SLOTS / cluster_nodes;
    for (int i = 0; i < cluster_nodes; ++i) {
        int start = i * slots_one_node;
        int end = (i + 1) * slots_one_node;
        int slottag = (rand() % (end - start)) + start;
        slots_nums.push_back(slottag);
    }
    int slottag_nums = slots_nums.size();

    char output_buffer[512];
    char file_name[100];
    sprintf(file_name, "./results/%s_%d", "benchresult", rank);
    FILE* fp = fopen(file_name, "a");

    /* Connect to Redis server. Make different rank go to different redis instance.*/
    auto index = rank % end_points_arr.size();
    auto ip_and_port = split(end_points_arr[index], ':');
    std::string redis_ip = ip_and_port[0];
    int redis_port = atoi(ip_and_port[1].c_str());
    ConnectionOptions connectionOptions;
    connectionOptions.host = redis_ip; // redis_cluster ip
    connectionOptions.port = redis_port; // redis_cluster port

    double duration = 0;
    if (io_pattern == METADATA){
        duration = metadata_test(rank, connectionOptions, key_base, MDM_REQ_NUMS, PIPELINES, slots_nums, slottag_nums);
        sprintf(output_buffer, "%ld requests cost %0.3lf seconds\npipelines: %d\n",
                MDM_REQ_NUMS, duration, PIPELINES);
        fprintf(fp, "-----------metadata measurement results----------\n%s", output_buffer);
    }
    else if (io_pattern == SEQUENTIAL){
        duration = sequential_test(rank, connectionOptions, key_base, value, io_type, io_operation, slots_nums, slottag_nums);
        if (io_type == SMALL_IO){
            sprintf(output_buffer, "%ld requests cost %0.3lf seconds\npipelines: %d\n"
                                   "data size: %ld kB\nthroughput: %0.3lf requests per second\naverage latency: %0.3f ms\n",
                    SMALL_REQ_NUMS, duration, PIPELINES, SMALL_IO_SIZE / KILO, (SMALL_REQ_NUMS / duration), (duration / SMALL_REQ_NUMS) * 1000);
            if (io_operation == WRITE){ // small sequential write
                fprintf(fp, "-----------sequential small IO write measurement results----------\n%s", output_buffer);
            }
            else { // small sequential read
                fprintf(fp, "-----------sequential small IO read measurement results----------\n%s", output_buffer);
            }
        }
        else {
            sprintf(output_buffer, "%ld requests cost %0.3lf seconds\npipelines: %d\n"
                                   "data size: %ld kB\nthroughput: %0.3lf requests per second\naverage latency: %0.3f ms\n",
                    LARGE_REQ_NUMS, duration, PIPELINES, LARGE_IO_SIZE / KILO, (LARGE_REQ_NUMS / duration), (duration / LARGE_REQ_NUMS) * 1000);
            if (io_operation == WRITE) { // large sequential write
                fprintf(fp, "-----------sequential large IO write measurement results----------\n%s", output_buffer);
            }
            else { // large sequential read
                fprintf(fp, "-----------sequential large IO read measurement results----------\n%s", output_buffer);
            }
        }
    }
    else if (io_pattern == RANDOM){
        duration = random_test(rank, connectionOptions, key_base, value, io_type, io_operation, slots_nums, slottag_nums);
        if (io_type == SMALL_IO){
            sprintf(output_buffer, "%ld requests cost %0.3lf seconds\npipelines: %d\n"
                                   "data size: %ld kB\nthroughput: %0.3lf requests per second\naverage latency: %0.3f ms\n",
                    SMALL_REQ_NUMS, duration, PIPELINES, SMALL_IO_SIZE / KILO, (SMALL_REQ_NUMS / duration), (duration / SMALL_REQ_NUMS) * 1000);
            if (io_operation == WRITE){ // small sequential write
                fprintf(fp, "-----------random small IO write measurement results----------\n%s", output_buffer);
            }
            else { // small sequential read
                fprintf(fp, "-----------random small IO read measurement results----------\n%s", output_buffer);
            }
        }
        else {
            sprintf(output_buffer, "%ld requests cost %0.3lf seconds\npipelines: %d\n"
                                   "data size: %ld kB\nthroughput: %0.3lf requests per second\naverage latency: %0.3f ms\n",
                    LARGE_REQ_NUMS, duration, PIPELINES, LARGE_IO_SIZE / KILO, (LARGE_REQ_NUMS / duration), (duration / LARGE_REQ_NUMS) * 1000);
            if (io_operation == WRITE) { // large sequential write
                fprintf(fp, "-----------random large IO write measurement results----------\n%s", output_buffer);
            }
            else { // large sequential read
                fprintf(fp, "-----------random large IO read measurement results----------\n%s", output_buffer);
            }
        }
    }
    fclose(fp);

    MPI_Finalize();
    return 0;
}

