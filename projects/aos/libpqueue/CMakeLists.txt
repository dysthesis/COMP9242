#
# Priority queue library used by AOS components.
#
cmake_minimum_required(VERSION 3.7.2)

project(libpqueue C)

add_library(pqueue EXCLUDE_FROM_ALL src/pqueue.c)
target_include_directories(pqueue PUBLIC src)
target_link_libraries(pqueue PUBLIC muslc)
