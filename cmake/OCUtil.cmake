# Shared helpers: logging, build-type mapping, and the per-EFI data model (PLAN.md §3.7).

# Both take any number of fragments and concatenate them, because a message long enough to
# wrap in the source is exactly the kind that gets split across two string literals -- and
# taking only the first silently dropped the second. That is how the `-UOC_BUILD` hint
# went unprinted from Phase 4 until Phase 7: its test asserted on the surviving half.
function(_oc_info msg)
  string(JOIN "" text "${msg}" ${ARGN})
  message(STATUS "OCMake: ${text}")
endfunction()

function(_oc_warn msg)
  string(JOIN "" text "${msg}" ${ARGN})
  message(WARNING "OCMake: ${text}")
endfunction()

# Declares one of the built-in defaults listed in OCMake.cmake. Setting it before
# include(OCMake.cmake), after it, or with -D on the command line all leave the variable
# DEFINED, so the value here applies only when nobody else has chosen one.
#
# Deliberately not a cache entry: the defaults are read from OCMake.cmake, and a cached
# copy of one would go stale in every existing build directory the moment it changed --
# the same trap that made a derived OC_BUILD impossible to switch.
macro(_oc_default var)
  if(NOT DEFINED ${var})
    set(${var} ${ARGN})
  endif()
endmacro()

# CMAKE_BUILD_TYPE -> OC_BUILD (RELEASE/DEBUG). -DOC_BUILD=... wins; per-item BUILD wins
# over that.
#
# The effective value is deliberately NOT cached. Caching the *derived* value made it
# indistinguishable from a user override on the next configure, so once a build directory
# had been configured Release it stayed Release for ever -- switching CMAKE_BUILD_TYPE
# silently produced the wrong variant, and only deleting the build directory helped.
#
# So the cache entry holds the user's override (empty = follow CMAKE_BUILD_TYPE), and the
# effective value is a normal variable shadowing it, recomputed on every configure.
function(_oc_init_build_type)
  set(OC_BUILD "" CACHE STRING
      "OpenCore build variant: RELEASE, DEBUG, or empty to follow CMAKE_BUILD_TYPE")
  set_property(CACHE OC_BUILD PROPERTY STRINGS "" RELEASE DEBUG)

  set(overridden FALSE)
  if(NOT "${OC_BUILD}" STREQUAL "")
    string(TOUPPER "${OC_BUILD}" b)
    set(overridden TRUE)
  elseif(CMAKE_BUILD_TYPE)
    string(TOUPPER "${CMAKE_BUILD_TYPE}" ct)
    if(ct STREQUAL "DEBUG" OR ct STREQUAL "RELWITHDEBINFO")
      set(b "DEBUG")
    else()
      set(b "RELEASE")
    endif()
  else()
    set(b "RELEASE")
  endif()
  if(NOT b STREQUAL "RELEASE" AND NOT b STREQUAL "DEBUG")
    message(FATAL_ERROR "OCMake: OC_BUILD must be RELEASE or DEBUG, got '${b}'")
  endif()

  if(overridden AND CMAKE_BUILD_TYPE)
    string(TOUPPER "${CMAKE_BUILD_TYPE}" ct)
    if(NOT ct STREQUAL b)
      _oc_info("build variant: ${b} (OC_BUILD overrides CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}; "
               "clear it with -UOC_BUILD)")
      set(OC_BUILD "${b}" PARENT_SCOPE)
      return()
    endif()
  endif()
  _oc_info("build variant: ${b}")
  set(OC_BUILD "${b}" PARENT_SCOPE)
endfunction()

function(_oc_init_cache_dir)
  if(DEFINED OC_CACHE_DIR AND NOT OC_CACHE_DIR STREQUAL "")
    return()
  endif()
  if(WIN32 AND DEFINED ENV{LOCALAPPDATA})
    set(d "$ENV{LOCALAPPDATA}/ocmake")
  elseif(DEFINED ENV{XDG_CACHE_HOME})
    set(d "$ENV{XDG_CACHE_HOME}/ocmake")
  elseif(DEFINED ENV{HOME})
    set(d "$ENV{HOME}/.cache/ocmake")
  else()
    set(d "${CMAKE_BINARY_DIR}/_oc/cache")
  endif()
  set(OC_CACHE_DIR "${d}" CACHE PATH "Shared download cache for OCMake")
endfunction()

# --- the data model -----------------------------------------------------------
# Every EFI is an INTERFACE library used as a typed property bag. Arbitrary
# properties on INTERFACE libraries require CMake 3.19+, comfortably under our floor.

# Resolve which EFI a declaration belongs to:
#   explicit EFI argument  >  OC_EFI variable (block()/subdirectory scope)  >  PROJECT_NAME
function(_oc_target out explicit)
  if(NOT explicit STREQUAL "")
    set(n "${explicit}")
  elseif(DEFINED OC_EFI AND NOT OC_EFI STREQUAL "")
    set(n "${OC_EFI}")
  else()
    set(n "${PROJECT_NAME}")
  endif()
  if(n STREQUAL "")
    message(FATAL_ERROR "OCMake: cannot determine target EFI; call project() first or pass EFI <name>")
  endif()
  if(NOT TARGET oc_${n})
    _oc_create_efi("${n}")
  endif()
  set(${out} "oc_${n}" PARENT_SCOPE)
endfunction()

function(_oc_create_efi n)
  add_library(oc_${n} INTERFACE)
  set_property(TARGET oc_${n} PROPERTY OC_NAME "${n}")
  set_property(TARGET oc_${n} PROPERTY OC_IS_EFI TRUE)
  set_property(TARGET oc_${n} PROPERTY OC_DECL_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
  # The default (implicitly named) EFI gets build/EFI; additional named ones get
  # build/<name>/EFI. Stated rather than magic: adding a second EFI never moves the first.
  if(n STREQUAL "${PROJECT_NAME}")
    set(dir "${CMAKE_BINARY_DIR}/EFI")
  else()
    set(dir "${CMAKE_BINARY_DIR}/${n}/EFI")
  endif()
  set_property(TARGET oc_${n} PROPERTY OC_OUTPUT_DIR "${dir}")
  set_property(GLOBAL APPEND PROPERTY OC_EFIS "${n}")
  _oc_schedule_finalize()
  _oc_info("EFI '${n}' -> ${dir}")
  # Before anything the project declares, so a later declaration on the same key wins.
  _oc_default_ops("${n}")
endfunction()

# Finalization is deferred to end-of-directory, so there is no "declared after the
# last oc_efi()" hole to fall into. NOTE: cmake_language(DEFER CALL f "${x}") evaluates
# its arguments when the deferred call *executes*, by which time a function-local ${x}
# is gone -- so we defer one no-argument finalizer over a global registry instead.
function(_oc_schedule_finalize)
  get_property(sched GLOBAL PROPERTY OC_FINALIZE_SCHEDULED)
  if(NOT sched)
    set_property(GLOBAL PROPERTY OC_FINALIZE_SCHEDULED TRUE)
    cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _oc_finalize_all)
  endif()
endfunction()

# --- provenance ---------------------------------------------------------------
# Where each staged file came from, so the BOM can cite it. Recorded at declaration
# time: the staged tree alone cannot say that IntelBTPatcher.kext arrived in the
# IntelBluetoothFirmware release.
function(_oc_provenance t kind item)
  cmake_parse_arguments(P "" "ORIGIN;REPO;VERSION;URL;SOURCE" "" ${ARGN})
  string(REGEX REPLACE "[^A-Za-z0-9]" "_" tok "${kind}_${item}")
  set_property(TARGET ${t} APPEND PROPERTY OC_PROV_${kind} "${item}")
  foreach(f ORIGIN REPO VERSION URL SOURCE)
    if(NOT "${P_${f}}" STREQUAL "")
      set_property(TARGET ${t} PROPERTY OC_PROV_${tok}_${f} "${P_${f}}")
    endif()
  endforeach()
endfunction()

# Paths are reported relative to the project, so a BOM is not machine-specific.
function(_oc_relpath path out)
  file(RELATIVE_PATH rel "${CMAKE_SOURCE_DIR}" "${path}")
  if(rel MATCHES "^\\.\\.")
    set(rel "${path}")
  endif()
  set(${out} "${rel}" PARENT_SCOPE)
endfunction()
