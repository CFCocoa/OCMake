# One asset-selection case, run as a subprocess so expected failures are observable.
# Usage: cmake -DOCMAKE_ROOT=... -DCASE=<name> -P resolve_case.cmake

cmake_minimum_required(VERSION 3.25)
set(OC_CACHE_DIR "${CMAKE_CURRENT_BINARY_DIR}/unused-cache")
include(${OCMAKE_ROOT}/cmake/OCUtil.cmake)
include(${OCMAKE_ROOT}/cmake/OCResolve.cmake)

# Real shapes observed on GitHub while designing PLAN.md §3.4.
set(NOOTED [=[{"tag_name":"v0.8.10","assets":[
 {"name":"NootedRed-0.8.10-DEBUG.zip","browser_download_url":"https://x/DEBUG"},
 {"name":"NootedRed-0.8.10-RELEASE.zip","browser_download_url":"https://x/RELEASE"},
 {"name":"NootedRed-0.8.10-RESEARCH_RELEASE.zip","browser_download_url":"https://x/RESEARCH"}]}]=])

# Same assets, RESEARCH_RELEASE listed first. Asset order is upload order, so this is a
# perfectly possible response -- and with an unanchored pattern it is the one that breaks.
set(NOOTED_RESEARCH_FIRST [=[{"tag_name":"v0.8.10","assets":[
 {"name":"NootedRed-0.8.10-RESEARCH_RELEASE.zip","browser_download_url":"https://x/RESEARCH"},
 {"name":"NootedRed-0.8.10-RELEASE.zip","browser_download_url":"https://x/RELEASE"},
 {"name":"NootedRed-0.8.10-DEBUG.zip","browser_download_url":"https://x/DEBUG"}]}]=])

set(RELEASE_ONLY [=[{"tag_name":"1.0.0","assets":[
 {"name":"Thing-1.0.0-RELEASE.zip","browser_download_url":"https://x/RELEASE"}]}]=])

set(SOLE [=[{"tag_name":"1.0.0","assets":[
 {"name":"Thing.kext.zip","browser_download_url":"https://x/SOLE"}]}]=])

set(ITLWM [=[{"tag_name":"v2.3.0","assets":[
 {"name":"AirportItlwm_v2.3.0_stable_BigSur.kext.zip","browser_download_url":"https://x/BigSur"},
 {"name":"AirportItlwm_v2.3.0_stable_Sonoma14.0.kext.zip","browser_download_url":"https://x/S140"},
 {"name":"AirportItlwm_v2.3.0_stable_Sonoma14.4.kext.zip","browser_download_url":"https://x/S144"},
 {"name":"itlwm_v2.3.0_stable.kext.zip","browser_download_url":"https://x/itlwm"}]}]=])

if(CASE STREQUAL "glob_to_regex")
  _oc_glob_to_regex("AirportItlwm_*_Sonoma14.4.kext.zip" rx)
  message(STATUS "REGEX ${rx}")
  # The '.' before kext must be literal: a regex '.' would also match "Sonoma14X4".
  if("AirportItlwm_v1_Sonoma14X4.kext.zip" MATCHES "${rx}")
    message(FATAL_ERROR "glob '.' was not escaped")
  endif()
  if(NOT "AirportItlwm_v2.3.0_stable_Sonoma14.4.kext.zip" MATCHES "${rx}")
    message(FATAL_ERROR "glob failed to match its own asset")
  endif()
  return()
endif()

if(CASE STREQUAL "nooted_release")
  _oc_pick_asset("${NOOTED}" "RELEASE" "" n u b)
elseif(CASE STREQUAL "nooted_debug")
  _oc_pick_asset("${NOOTED}" "DEBUG" "" n u b)
elseif(CASE STREQUAL "nooted_research_first")
  _oc_pick_asset("${NOOTED_RESEARCH_FIRST}" "RELEASE" "" n u b)
elseif(CASE STREQUAL "debug_fallback")
  _oc_pick_asset("${RELEASE_ONLY}" "DEBUG" "" n u b)
elseif(CASE STREQUAL "sole_asset")
  _oc_pick_asset("${SOLE}" "DEBUG" "" n u b)
elseif(CASE STREQUAL "ambiguous")
  _oc_pick_asset("${ITLWM}" "RELEASE" "" n u b)
elseif(CASE STREQUAL "glob_pick")
  _oc_pick_asset("${ITLWM}" "RELEASE" "AirportItlwm_*_Sonoma14.4.kext.zip" n u b)
elseif(CASE STREQUAL "glob_nomatch")
  _oc_pick_asset("${ITLWM}" "RELEASE" "*Ventura*" n u b)
else()
  message(FATAL_ERROR "unknown CASE '${CASE}'")
endif()

message(STATUS "RESULT ${n}|${u}|${b}")
