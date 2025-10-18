cmake_minimum_required(VERSION 3.7.2)

project(vm_test C)

set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -u __vsyscall_ptr")

add_executable(vm_test EXCLUDE_FROM_ALL src/vm_test.c)
target_link_libraries(vm_test sel4runtime muslc sel4 sosapi)

add_compile_options(-Wall -Werror -Wextra)

add_app(vm_test)
