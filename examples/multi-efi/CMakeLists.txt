# Two machines, one repository -- NOT validated hardware configurations.
#
# Neither of these has booted anything; they exist to show the *shape* of a repo that
# builds more than one EFI. examples/b760i-aorus-pro is the validated one.
#
# One directory per machine, which is how a CMake project with two of anything is usually
# laid out. Each subdirectory names the EFI it is describing and then just declares -- no
# EFI keyword on every line, because add_subdirectory() gives each one its own scope.

cmake_minimum_required(VERSION 3.25...4.4)
project(multi-efi NONE)

if(NOT DEFINED OCMAKE_ROOT)
  set(OCMAKE_ROOT ${CMAKE_CURRENT_LIST_DIR}/../..)
endif()
include(${OCMAKE_ROOT}/OCMake.cmake)

add_subdirectory(desktop)
add_subdirectory(laptop)
