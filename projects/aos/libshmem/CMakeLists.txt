cmake_minimum_required(VERSION 3.7.2)

project(libshmem C)

add_library(shmem EXCLUDE_FROM_ALL src/shmem.c)
target_include_directories(shmem PUBLIC include)
target_link_libraries(shmem PUBLIC muslc)
