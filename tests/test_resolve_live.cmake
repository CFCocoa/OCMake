# Live API tests: resolution only, no downloads. Five requests, served from the
# OC_API_TTL cache on repeat runs.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)
include(${OCMAKE_ROOT}/cmake/OCUtil.cmake)
_oc_init_cache_dir()
include(${OCMAKE_ROOT}/cmake/OCResolve.cmake)

step("a version without the tag's v prefix still resolves")
# The disagreement found while writing PLAN.md §3.4: users write VERSION 0.8.10, the tag
# is v0.8.10, and the asset is NootedRed-0.8.10-RELEASE.zip. All three differ.
_oc_gh_release("ChefKissInc/NootedRed" "0.8.10" json)
string(JSON tag GET "${json}" tag_name)
if(NOT tag STREQUAL "v0.8.10")
  message(FATAL_ERROR "FAIL: expected tag v0.8.10, got '${tag}'")
endif()

step("the asset name is read from the release, never built from the tag")
_oc_pick_asset("${json}" "RELEASE" "" name url build)
if(NOT name STREQUAL "NootedRed-0.8.10-RELEASE.zip")
  message(FATAL_ERROR "FAIL: expected NootedRed-0.8.10-RELEASE.zip, got '${name}'")
endif()
if(NOT url MATCHES "^https://")
  message(FATAL_ERROR "FAIL: asset url looks wrong: '${url}'")
endif()

step("latest resolves and reports a concrete tag")
_oc_gh_release("acidanthera/Lilu" "latest" ljson)
string(JSON ltag GET "${ljson}" tag_name)
if(NOT ltag MATCHES "^[0-9]")
  message(FATAL_ERROR "FAIL: unexpected Lilu tag '${ltag}'")
endif()
message(STATUS "  .. Lilu latest = ${ltag}")

step("a branch resolves to the commit that pins it")
# OcBinaryData's payload is in its tree, not in its releases -- those are unrelated QEMU
# CI artefacts. Resolving master to a commit is what turns a moving branch into the
# immutable raw URL whose hash the lockfile can meaningfully record.
_oc_gh_commit("acidanthera/OcBinaryData" "master" sha)
if(NOT sha MATCHES "^[0-9a-f][0-9a-f]+$")
  message(FATAL_ERROR "FAIL: expected a commit sha, got '${sha}'")
endif()
string(LENGTH "${sha}" shalen)
if(NOT shalen EQUAL 40)
  message(FATAL_ERROR "FAIL: commit sha should be 40 hex chars, got ${shalen}: ${sha}")
endif()
message(STATUS "  .. OcBinaryData master = ${sha}")

step("a renamed repository still resolves, because file(DOWNLOAD) follows the redirect")
# GitHub answers the old path with 301 {"message": "Moved Permanently"}. Worth pinning:
# the obvious reading of that body is that OCMake must handle renames itself, and it was
# briefly recorded as a gap on exactly that reasoning -- before anyone checked that CMake
# already follows it.
_oc_http_json("https://api.github.com/repos/1Revenger1/ECEnabler/releases/latest" moved code)
if(NOT code EQUAL 200)
  message(FATAL_ERROR "FAIL: a renamed repo should resolve, got HTTP ${code}")
endif()
string(JSON movedtag GET "${moved}" tag_name)
message(STATUS "  .. ECEnabler (renamed upstream) = ${movedtag}")

step("Dortania publishes a build for a project we know")
_oc_dortania_build("Lilu" "RELEASE" dver durl dsha dbuild)
if(NOT durl MATCHES "^https://github.com/dortania/build-repo/releases/download/")
  message(FATAL_ERROR "FAIL: unexpected Dortania link: ${durl}")
endif()
string(LENGTH "${dsha}" dshalen)
if(NOT dshalen EQUAL 64)
  message(FATAL_ERROR "FAIL: Dortania should publish a sha256, got '${dsha}'")
endif()
message(STATUS "  .. Dortania Lilu = ${dver}")

message(STATUS "resolve.live: PASS")
