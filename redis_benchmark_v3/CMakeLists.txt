cmake_minimum_required(VERSION 3.10)
project(redis_bench_v3)

set(CMAKE_CXX_STANDARD 17)
set(LIBS -lpthread  -lhiredis -lredis++ -lmpi)

add_executable(redis_cluster_bench redis_cluster_bench_setrange.cpp)
target_link_libraries(redis_cluster_bench ${LIBS})