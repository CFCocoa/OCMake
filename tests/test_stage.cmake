# Unit test for cmake/OCStage.cmake. No network.
#
# Covers the properties the staging step exists to guarantee: rename-on-copy for both
# files and directories, junk exclusion, dotfile preservation, wipe-and-rebuild so
# removals propagate, and a hard error on a missing source.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)

set(SRC "${WORK}/src")
set(EFI "${WORK}/EFI")
set(STAGE "${OCMAKE_ROOT}/cmake/OCStage.cmake")

file(REMOVE_RECURSE "${WORK}")
file(MAKE_DIRECTORY "${SRC}")

step("build fixture")
file(WRITE "${SRC}/OpenCore.efi" "fake-opencore-binary")
file(WRITE "${SRC}/contentFlavour" "Auto")
file(MAKE_DIRECTORY "${SRC}/Some.kext/Contents/MacOS")
file(WRITE "${SRC}/Some.kext/Contents/Info.plist" "<plist/>")
file(WRITE "${SRC}/Some.kext/Contents/MacOS/Some" "macho")
file(WRITE "${SRC}/Some.kext/.DS_Store" "junk")
file(WRITE "${SRC}/Some.kext/Contents/.DS_Store" "junk")

file(WRITE "${WORK}/manifest.cmake" "
oc_stage_copy(\"${SRC}/OpenCore.efi\" \"OC/OpenCore.efi\")
oc_stage_copy(\"${SRC}/contentFlavour\" \"BOOT/.contentFlavour\")
oc_stage_copy(\"${SRC}/Some.kext\" \"OC/Kexts/Renamed.kext\")
")

step("stage")
run("stage" "${CMAKE_COMMAND}" -DOC_MANIFEST=${WORK}/manifest.cmake -DOC_EFI_DIR=${EFI} -P "${STAGE}")

assert_exists("${EFI}/OC/OpenCore.efi" "file copy")
assert_same_file("${EFI}/OC/OpenCore.efi" "${SRC}/OpenCore.efi" "file copy is byte-identical")
assert_exists("${EFI}/BOOT/.contentFlavour" "dotfile copy with rename")
assert_exists("${EFI}/OC/Kexts/Renamed.kext/Contents/Info.plist" "directory copy with rename")
assert_exists("${EFI}/OC/Kexts/Renamed.kext/Contents/MacOS/Some" "nested directory copy")
assert_missing("${EFI}/OC/Kexts/Renamed.kext/.DS_Store" ".DS_Store excluded at top level")
assert_missing("${EFI}/OC/Kexts/Renamed.kext/Contents/.DS_Store" ".DS_Store excluded when nested")

step("directory copies do not inherit ancient source timestamps")
# file(COPY) preserves source mtimes. Kexts come from a release zip whose files carry
# the upstream build date, so without an explicit touch every staged kext would read as
# older than the generated manifest and the whole tree would restage on every build.
# Phase 0 stages no directories, so this is the only place the guard is exercised.
find_program(PY NAMES python3 python)
if(PY)
  file(GLOB_RECURSE srcfiles LIST_DIRECTORIES false "${SRC}/Some.kext/*")
  execute_process(COMMAND "${PY}" -c
    "import os,sys
for p in sys.argv[1:]: os.utime(p,(1577836800,1577836800))"
    ${srcfiles} RESULT_VARIABLE rc)
  if(rc EQUAL 0)
    run("re-stage after ageing sources" "${CMAKE_COMMAND}"
        -DOC_MANIFEST=${WORK}/manifest.cmake -DOC_EFI_DIR=${EFI} -P "${STAGE}")
    file(TIMESTAMP "${EFI}/OC/Kexts/Renamed.kext/Contents/Info.plist" year "%Y")
    if(year STREQUAL "2020")
      message(FATAL_ERROR
        "FAIL: staged file kept the 2020 source timestamp; OCStage must touch after file(COPY)")
    endif()
  endif()
else()
  message(STATUS "  .. (skipped: no python found to age timestamps)")
endif()

step("re-stage wipes stale files")
file(WRITE "${EFI}/OC/Kexts/Removed.kext" "should not survive")
file(WRITE "${EFI}/OC/stray.txt" "should not survive")
run("re-stage" "${CMAKE_COMMAND}" -DOC_MANIFEST=${WORK}/manifest.cmake -DOC_EFI_DIR=${EFI} -P "${STAGE}")
assert_missing("${EFI}/OC/Kexts/Removed.kext" "stale kext removed by wipe-and-rebuild")
assert_missing("${EFI}/OC/stray.txt" "stray file removed by wipe-and-rebuild")
assert_exists("${EFI}/OC/OpenCore.efi" "declared content still present after re-stage")

step("missing source is a hard error")
file(WRITE "${WORK}/bad.cmake" "oc_stage_copy(\"${SRC}/does-not-exist\" \"OC/Nope.efi\")\n")
run_expect_fail("missing source" "${CMAKE_COMMAND}" -DOC_MANIFEST=${WORK}/bad.cmake -DOC_EFI_DIR=${EFI} -P "${STAGE}")
if(NOT LAST_ERROR MATCHES "missing source")
  message(FATAL_ERROR "FAIL: error message should name the missing source, got:\n${LAST_ERROR}")
endif()

message(STATUS "stage: PASS")
