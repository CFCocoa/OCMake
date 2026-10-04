# End-to-end test: resolution, lockfile, build, install and rebuild of examples/minimal.
#
# The example is copied into the work directory first, so the tests that tamper with the
# lockfile never touch the source tree. Needs network on a cold cache.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)

set(SRC "${WORK}/src")
set(BUILD "${WORK}/build")
set(PREFIX "${WORK}/prefix")
set(LOCK "${SRC}/ocmake.lock")
file(REMOVE_RECURSE "${WORK}")
file(COPY "${EXAMPLE}/" DESTINATION "${SRC}")

set(gen "")
if(GENERATOR)
  set(gen -G "${GENERATOR}")
endif()
set(cfg "${CMAKE_COMMAND}" -S "${SRC}" -B "${BUILD}" ${gen} -DOCMAKE_ROOT=${OCMAKE_ROOT} -DCMAKE_BUILD_TYPE=Release)

step("cold configure resolves and writes a lockfile")
file(REMOVE "${LOCK}")
run("cold configure" ${cfg})
assert_exists("${LOCK}" "lockfile written")
file(READ "${LOCK}" lock)
if(NOT lock MATCHES "OpenCore-1\\.0\\.7-RELEASE\\.zip")
  message(FATAL_ERROR "FAIL: lock should record the resolved asset URL:\n${lock}")
endif()
# NB: CMake's regex engine has no {n} repetition, so check the length separately.
if(NOT lock MATCHES "SHA256 \"([0-9a-f]+)\"")
  message(FATAL_ERROR "FAIL: lock should record a sha256:\n${lock}")
endif()
string(LENGTH "${CMAKE_MATCH_1}" shalen)
if(NOT shalen EQUAL 64)
  message(FATAL_ERROR "FAIL: sha256 should be 64 hex chars, got ${shalen}")
endif()

step("re-configure leaves the lockfile byte-identical")
run("reconfigure" ${cfg})
file(READ "${LOCK}" lock2)
if(NOT lock STREQUAL lock2)
  message(FATAL_ERROR "FAIL: lockfile is not stable across configures")
endif()

step("a warm lock + cache configures with OC_OFFLINE=ON")
# The claim from PLAN.md §7: once the lock is committed, builds make no API calls at all.
file(REMOVE_RECURSE "${BUILD}")
run("offline configure" ${cfg} -DOC_OFFLINE=ON)

step("a tampered lock hash is rejected, not silently accepted")
file(READ "${LOCK}" good)
string(REGEX REPLACE "SHA256 \"[0-9a-f]+\""
       "SHA256 \"0000000000000000000000000000000000000000000000000000000000000000\""
       tampered "${good}")
file(WRITE "${LOCK}" "${tampered}")
file(REMOVE_RECURSE "${BUILD}")
run_expect_fail("tampered lock" ${cfg} -DOC_OFFLINE=ON)
# The diagnostic must name the real problem: the archive is cached, its hash disagrees.
assert_matches("${LAST_ERROR}" "does not match the expected hash" "tampered lock diagnostic")
file(WRITE "${LOCK}" "${good}")

step("build")
file(REMOVE_RECURSE "${BUILD}")
run("configure" ${cfg})
run("build" "${CMAKE_COMMAND}" --build "${BUILD}")

set(EFI "${BUILD}/EFI")
assert_exists("${EFI}/BOOT/BOOTx64.efi" "bootstrap staged")
assert_exists("${EFI}/OC/OpenCore.efi" "OpenCore staged")
assert_exists("${EFI}/BOOT/.contentFlavour" "BOOT content flavour preserved")
assert_exists("${EFI}/OC/.contentFlavour" "OC content flavour preserved")

file(SIZE "${EFI}/OC/OpenCore.efi" sz)
if(sz LESS 100000)
  message(FATAL_ERROR "FAIL: OpenCore.efi is only ${sz} bytes -- staged the wrong file?")
endif()

step("install")
run("install" "${CMAKE_COMMAND}" --install "${BUILD}" --prefix "${PREFIX}")
assert_exists("${PREFIX}/EFI/OC/OpenCore.efi" "installed under <prefix>/EFI")
assert_same_file("${PREFIX}/EFI/OC/OpenCore.efi" "${EFI}/OC/OpenCore.efi" "install is byte-identical")

step("rebuild restores a deleted file")
file(REMOVE "${EFI}/OC/OpenCore.efi")
run("rebuild" "${CMAKE_COMMAND}" --build "${BUILD}")
assert_exists("${EFI}/OC/OpenCore.efi" "deleted output restored by rebuild")

step("no-op rebuild does no work")
# Guards the timestamp handling in OCStage: file(COPY) preserves source mtimes, which
# would make every staged file look older than the generated manifest and restage the
# whole tree on every build. If that regresses, the stage comment reappears here.
run("no-op rebuild" "${CMAKE_COMMAND}" --build "${BUILD}")
if(LAST_OUTPUT MATCHES "Staging EFI")
  message(FATAL_ERROR "FAIL: nothing changed but the EFI was restaged:\n${LAST_OUTPUT}")
endif()

message(STATUS "example.minimal: PASS")
