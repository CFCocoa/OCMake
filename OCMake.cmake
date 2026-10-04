# OCMake — declarative OpenCore EFI assembly in CMake.
#
# Usage:
#   include(FetchContent)
#   FetchContent_Declare(OCMake GIT_REPOSITORY ... GIT_TAG ...)
#   FetchContent_MakeAvailable(OCMake)
#   include(${ocmake_SOURCE_DIR}/OCMake.cmake)
#
# See PLAN.md for the design. Phase 0 implements: oc_opencore(), oc_efi(),
# staging, and install rules.

cmake_minimum_required(VERSION 3.25)

if(DEFINED OCMAKE_VERSION)
  return()  # already included
endif()
set(OCMAKE_VERSION "0.1.0")
set(OCMAKE_DIR "${CMAKE_CURRENT_LIST_DIR}" CACHE INTERNAL "OCMake module root")

include("${OCMAKE_DIR}/cmake/OCUtil.cmake")
include("${OCMAKE_DIR}/cmake/OCPython.cmake")
include("${OCMAKE_DIR}/cmake/OCLock.cmake")
include("${OCMAKE_DIR}/cmake/OCFetch.cmake")
include("${OCMAKE_DIR}/cmake/OCResolve.cmake")
include("${OCMAKE_DIR}/cmake/OCOpenCore.cmake")
include("${OCMAKE_DIR}/cmake/OCKext.cmake")
include("${OCMAKE_DIR}/cmake/OCACPI.cmake")
include("${OCMAKE_DIR}/cmake/OCResources.cmake")
include("${OCMAKE_DIR}/cmake/OCConfig.cmake")
include("${OCMAKE_DIR}/cmake/OCVault.cmake")
include("${OCMAKE_DIR}/cmake/OCValidate.cmake")
include("${OCMAKE_DIR}/cmake/OCInstall.cmake")
include("${OCMAKE_DIR}/cmake/OCEFI.cmake")

_oc_init_build_type()
_oc_init_cache_dir()

# --- built-in defaults ---------------------------------------------------------------
# Conventions that nearly every EFI repeats, applied so that no CMakeLists.txt has to
# spell them out. Each variable is named after the function it feeds and holds exactly
# what that function would have been called with, so this block is also the reference for
# what OCMake does on its own.
#
# An explicit declaration always wins. The file defaults fill in only when the project
# declares none of its own; the Debug ops are seeded ahead of every project declaration,
# so a later oc_config_set() or oc_boot_args() on the same key overrides rather than
# fights. Nothing fires unless the file it names exists.
#
# Change one by setting it with -D on the command line, or anywhere ahead of the first
# oc_* declaration -- before or after include(OCMake.cmake), both work. Empty a variable
# to drop that default; turn the lot off with -DOC_DEFAULTS=OFF.

option(OC_DEFAULTS "Apply OCMake's built-in defaults (see OCMake.cmake)" ON)

# --- install and packaging knobs -------------------------------------------------------
# install-esp never mounts anything: mounting an ESP needs root everywhere, and a build
# target that silently asks for a password is worse than one that prints the command. Set
# OC_ESP to skip detection entirely -- which is also how you install to a USB stick.
set(OC_ESP "" CACHE PATH "ESP mount point; empty auto-detects the boot disk's")
option(OC_ESP_BACKUP "Archive the ESP's current EFI before install-esp replaces it" ON)
set(OC_ESP_BACKUP_DIR "" CACHE PATH "Where install-esp puts that archive (default: <build>/esp-backup)")
option(OC_PACKAGE "Register a CPack ZIP of the staged EFI" ON)

# oc_config(<file>), relative to the CMakeLists.txt that declares the EFI.
_oc_default(OC_DEFAULT_CONFIG "config.plist")

# oc_secrets(<file>) -- machine identifiers, kept out of the repo so config.plist stays
# shareable. A committed <file>.example next to it is how a project says it uses secrets:
# with the template present but the file missing, that is an error naming the template;
# with neither present, the project simply has no secrets.
_oc_default(OC_DEFAULT_SECRETS "secrets.plist")

# oc_config_set(<keypath> <TYPE> <value>), on DEBUG builds only. One entry per
# declaration, split like a command line so a value containing spaces can be quoted.
# Target 67 = 0x43: enable logging, mirror it to the console, and write log files to the
# ESP. There is no RELEASE counterpart, and none is needed: every build re-derives
# config.plist from the hand-written base, so a Release build just never applies these.
_oc_default(OC_DEFAULT_DEBUG_SET
    "Misc/Debug/Target     INTEGER 67"
    "Misc/Debug/AppleDebug BOOL    ON")

# oc_boot_args(APPEND <args>), on DEBUG builds only: verbose boot, kernel debug flags,
# and unstripped symbols in panic logs.
_oc_default(OC_DEFAULT_DEBUG_BOOT_ARGS -v debug=0x100 keepsyms=1)

# Python drives the config.plist step (plistlib + OCSnapshot). Only required once a
# project calls oc_config(), but locating it here keeps the failure at configure time.
find_package(Python3 3.9 COMPONENTS Interpreter QUIET)

# Validation is registered as ctest tests by oc_efi()'s deferred finalize, but
# enable_testing() has to run while the directory is still being processed -- called from
# the deferred call it is too late and CTestTestfile.cmake is never written.
enable_testing()
