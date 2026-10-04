# Asset-selection tests. No network: every case runs against captured GitHub JSON.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)

set(CASE_SCRIPT "${CMAKE_CURRENT_LIST_DIR}/resolve_case.cmake")

function(expect case name url build)
  run("${case}" "${CMAKE_COMMAND}" -DOCMAKE_ROOT=${OCMAKE_ROOT} -DCASE=${case} -P "${CASE_SCRIPT}")
  if(NOT LAST_OUTPUT MATCHES "RESULT ([^|]*)\\|([^|]*)\\|([^\n]*)")
    message(FATAL_ERROR "FAIL (${case}): no RESULT line:\n${LAST_OUTPUT}")
  endif()
  string(STRIP "${CMAKE_MATCH_3}" got_build)
  if(NOT CMAKE_MATCH_1 STREQUAL "${name}")
    message(FATAL_ERROR "FAIL (${case}): asset\n  expected ${name}\n  got      ${CMAKE_MATCH_1}")
  endif()
  if(NOT CMAKE_MATCH_2 STREQUAL "${url}")
    message(FATAL_ERROR "FAIL (${case}): url\n  expected ${url}\n  got      ${CMAKE_MATCH_2}")
  endif()
  if(NOT got_build STREQUAL "${build}")
    message(FATAL_ERROR "FAIL (${case}): build\n  expected ${build}\n  got      ${got_build}")
  endif()
endfunction()

step("glob to regex escapes literals")
run("glob_to_regex" "${CMAKE_COMMAND}" -DOCMAKE_ROOT=${OCMAKE_ROOT} -DCASE=glob_to_regex -P "${CASE_SCRIPT}")

step("RELEASE must not match RESEARCH_RELEASE")
# The trap from PLAN.md §3.4: an unanchored RELEASE\.zip$ also matches NootedRed's
# RESEARCH_RELEASE.zip, silently shipping a different build.
expect(nooted_release "NootedRed-0.8.10-RELEASE.zip" "https://x/RELEASE" "RELEASE")
# Ordering matters: with RELEASE listed first, an unanchored pattern still lands on the
# right asset by luck. This case puts RESEARCH_RELEASE first so only the anchor saves it.
expect(nooted_research_first "NootedRed-0.8.10-RELEASE.zip" "https://x/RELEASE" "RELEASE")

step("DEBUG selects the debug asset")
expect(nooted_debug "NootedRed-0.8.10-DEBUG.zip" "https://x/DEBUG" "DEBUG")

step("missing debug asset falls back to release")
expect(debug_fallback "Thing-1.0.0-RELEASE.zip" "https://x/RELEASE" "RELEASE")

step("a sole asset is used whatever the build")
expect(sole_asset "Thing.kext.zip" "https://x/SOLE" "DEBUG")

step("ASSET glob selects among per-OS assets")
expect(glob_pick "AirportItlwm_v2.3.0_stable_Sonoma14.4.kext.zip" "https://x/S144" "RELEASE")

step("ambiguous release errors and lists the assets")
run_expect_fail("ambiguous" "${CMAKE_COMMAND}" -DOCMAKE_ROOT=${OCMAKE_ROOT} -DCASE=ambiguous -P "${CASE_SCRIPT}")
foreach(want "ASSET" "AirportItlwm_v2.3.0_stable_BigSur.kext.zip" "itlwm_v2.3.0_stable.kext.zip")
  assert_matches("${LAST_ERROR}" "${want}" "ambiguity error lists assets")
endforeach()

step("a glob matching nothing errors")
run_expect_fail("glob_nomatch" "${CMAKE_COMMAND}" -DOCMAKE_ROOT=${OCMAKE_ROOT} -DCASE=glob_nomatch -P "${CASE_SCRIPT}")

message(STATUS "resolve: PASS")
