#
# Copyright 2019, Data61
# Commonwealth Scientific and Industrial Research Organisation (CSIRO)
# ABN 41 687 119 230.
#
# This software may be distributed and modified according to the terms of
# the GNU General Public License version 2. Note that NO WARRANTY is provided.
# See "LICENSE_GPLv2.txt" for details.
#
# @TAG(DATA61_GPL)
#

find_program(ZIG NAMES zig)
if(NOT ZIG)
    # if zig isn't installed, assume we are running in CSE build environment
    # unzip the zig compiler that is in the project root folder and use that one
    # NOTE the packaged compiler targets CSE machines and may not be compatible with your machine
    execute_process(COMMAND
        tar
        -xf "${CMAKE_SOURCE_DIR}/zig-x86_64-linux-0.15.1.tar.xz"
        -C "${CMAKE_BINARY_DIR}"
    )
    set(ZIG "${CMAKE_BINARY_DIR}/zig-x86_64-linux-0.15.1/zig")
endif()

set(ZIG_LIBS
    # this is the list of libraries zig will produce for cmake
    # be sure to keep this list updated!
    ziglib_sos
    ziglib_sosapi
    ziglib_ipc
)
set(ZIG_APPS
    # this is the list of executable apps zig will produce
    # be sure to keep this list updated!
)

set(ZIG_LIB_PATHS)
foreach(lib ${ZIG_LIBS})
    # map each zig library to its path
    # we expect them to be emitted at `build/zig-out/lib`
    # we expect them to be named `lib<name>.a`
    list(APPEND ZIG_LIB_PATHS "${CMAKE_BINARY_DIR}/zig-out/lib/lib${lib}.a")
endforeach()
set(ZIG_APP_PATHS)
foreach(app ${ZIG_APPS})
    # map each zig app to its path
    # we expect them to be emitted at `build/apps`
    list(APPEND ZIG_APP_PATHS "${CMAKE_BINARY_DIR}/apps/${app}")
endforeach()

add_custom_command(
    # run `zig build`
    COMMAND "${ZIG}" build
        # tell zig where to put its outut
        --prefix "${CMAKE_BINARY_DIR}"
        --prefix-lib-dir "${CMAKE_BINARY_DIR}/zig-out/lib"
        # zig wants the following cmake projects
        # update this list as needed
        -Dsel4=$<TARGET_FILE:sel4>
        -Dmuslc=$<TARGET_FILE:muslc_imported>
        -Dutils=$<TARGET_FILE:utils>
        -Daos=$<TARGET_FILE:aos>
    # show zig's output
    USES_TERMINAL
    # where to run zig
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}" 
    # ask cmake to run zig after these projects
    DEPENDS sel4 muslc utils aos
    # tell cmake what zig will produce
    # a nonexistent target is added to make zig always runs (unsure whether this is needed tho)
    OUTPUT "__always_run_zig__" ${ZIG_LIB_PATHS} ${ZIG_APP_PATHS}
)
# tell cmake that the nonexistent target is wanted
add_custom_target(__zig_build__ ALL DEPENDS "__always_run_zig__")
# tell cmake of zig's libraries so projects it can link against them, i.e.,
# `target_link_libraries(my_project ziglib_sos)`
foreach(lib ${ZIG_LIBS})
    add_library(${lib} STATIC IMPORTED)
    set_target_properties(${lib} PROPERTIES IMPORTED_LOCATION "${CMAKE_BINARY_DIR}/zig-out/lib/lib${lib}.a")
endforeach()
# add zig's apps to the global list of apps `apps_property`
# not sure why this is done.. just copying cmake `add_app`
set_property(GLOBAL APPEND PROPERTY apps_property ${ZIG_APP_PATHS})

cmake_minimum_required(VERSION 3.7.2)

# add apps
add_subdirectory(apps/console_test)
add_subdirectory(apps/syscall_test)
add_subdirectory(apps/sosh)
# add any additional apps here

# add sos itself, this is your OS
# and root task
add_subdirectory(sos)

# add libraries
add_subdirectory(libaos)
add_subdirectory(libpqueue)
add_subdirectory(libclock)
add_subdirectory(libco)
add_subdirectory(libethernet)
add_subdirectory(libsel4cspace)
add_subdirectory(libnetworkconsole)
add_subdirectory(libsosapi)
add_subdirectory(libipc)
# add any additional libs here

# enable our networking libs
set(LibPicotcp ON CACHE BOOL "" FORCE)
set(LibPicotcpBsd ON CACHE BOOL "" FORCE)
set(LibNfs ON CACHE BOOL "" FORCE)
