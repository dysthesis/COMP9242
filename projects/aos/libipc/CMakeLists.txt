cmake_minimum_required(VERSION 3.7.2)

project(libipc C)

add_library(ipc EXCLUDE_FROM_ALL src/ipc.c src/shmem.c)
target_include_directories(
  ipc
  PUBLIC  include
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../sos/src
)
target_link_libraries(ipc PUBLIC muslc sel4cspace)
