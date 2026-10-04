# Smallest possible OCMake project: fetch OpenCore and stage a bare EFI tree.
#
# Phase 0 stages only the OpenCore binaries. config.plist, kexts, ACPI and drivers
# arrive in later phases -- this tree is not bootable yet.

cmake_minimum_required(VERSION 3.25...4.4)
project(minimal NONE)

# In-tree usage. Real projects use FetchContent:
#   FetchContent_Declare(OCMake GIT_REPOSITORY https://github.com/<you>/OCMake GIT_TAG v0.1.0)
#   FetchContent_MakeAvailable(OCMake)
#   include(${ocmake_SOURCE_DIR}/OCMake.cmake)
if(NOT DEFINED OCMAKE_ROOT)
  set(OCMAKE_ROOT ${CMAKE_CURRENT_LIST_DIR}/../..)
endif()
include(${OCMAKE_ROOT}/OCMake.cmake)

# Deliberately no config.plist. Any other project would let OCMake create one from the
# OpenCore package's Docs/Sample.plist on the first configure; clearing the default opts
# out, which is what keeps this example a bare OpenCore tree.
set(OC_DEFAULT_CONFIG "")

# The URL and hash are resolved from the GitHub release and recorded in ocmake.lock,
# which is committed. Warm builds make no API calls at all.
oc_opencore(VERSION 1.0.7)

oc_efi()
