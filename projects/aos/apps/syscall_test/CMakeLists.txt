cmake_minimum_required(VERSION 3.7.2)

project(syscall_test C)

set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -u __vsyscall_ptr")

add_executable(syscall_test EXCLUDE_FROM_ALL src/syscall_test.c)
target_include_directories(syscall_test PRIVATE include)
target_link_libraries(syscall_test sel4runtime muslc sel4 sosapi)

# warn about everything
add_compile_options(-Wall -Werror -W -Wextra)

add_app(syscall_test)
