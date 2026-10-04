# GitHub API error handling, driven against tests/stub_api.py.
#
# 401/403/429 cannot be provoked on demand against real GitHub without burning the rate
# limit, so they are served locally instead. Run via stub_api.py, which supplies PORT.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)

set(CASE_SCRIPT "${CMAKE_CURRENT_LIST_DIR}/http_case.cmake")
set(CACHE_DIR "${WORK}/cache")
file(REMOVE_RECURSE "${WORK}")
file(MAKE_DIRECTORY "${CACHE_DIR}")

function(case_run name)
  run("${name}" "${CMAKE_COMMAND}" -DOCMAKE_ROOT=${OCMAKE_ROOT} -DPORT=${PORT}
      -DCACHE=${CACHE_DIR} -DCASE=${name} ${ARGN} -P "${CASE_SCRIPT}")
  set(LAST_OUTPUT "${LAST_OUTPUT}" PARENT_SCOPE)
endfunction()

function(case_fail name)
  run_expect_fail("${name}" "${CMAKE_COMMAND}" -DOCMAKE_ROOT=${OCMAKE_ROOT} -DPORT=${PORT}
      -DCACHE=${CACHE_DIR} -DCASE=${name} ${ARGN} -P "${CASE_SCRIPT}")
  set(LAST_ERROR "${LAST_ERROR}" PARENT_SCOPE)
endfunction()

step("200 returns parsed JSON")
case_run(ok)
assert_matches("${LAST_OUTPUT}" "RESULT code=200 tag=v1\\.2\\.3" "200 parsed")

step("404 is returned to the caller, not fatal")
# _oc_gh_release relies on this to retry the v-prefixed tag.
case_run(404)
assert_matches("${LAST_OUTPUT}" "RESULT code=404" "404 is soft")

step("403 without a token explains the unauthenticated limit")
case_fail(403)
assert_matches("${LAST_ERROR}" "HTTP 403" "403 names the status")
assert_matches("${LAST_ERROR}" "60 requests/hour" "403 explains the limit")
assert_matches("${LAST_ERROR}" "GITHUB_TOKEN" "403 suggests a token")
assert_matches("${LAST_ERROR}" "ocmake.lock" "403 points at the lockfile")

step("403 with a token blames the token instead")
case_fail(403 -DTOKEN=stub-token-value)
assert_matches("${LAST_ERROR}" "may lack access or be expired" "403 with token")

step("429 is treated as rate limiting")
case_fail(429)
assert_matches("${LAST_ERROR}" "HTTP 429" "429 names the status")

step("401 reports a rejected token")
case_fail(401 -DTOKEN=stub-token-value)
assert_matches("${LAST_ERROR}" "rejected the token" "401 wording")

step("the token never appears in an error message")
# file(DOWNLOAD)'s LOG contains the Authorization header, so it must never be surfaced.
if(LAST_ERROR MATCHES "stub-token-value")
  message(FATAL_ERROR "FAIL: the token leaked into an error message:\n${LAST_ERROR}")
endif()

step("the Authorization header is actually sent")
# Fresh cache: the TTL cache is keyed by URL alone, so an earlier tokenless 200 for this
# same URL would otherwise be replayed and the header never sent.
file(REMOVE_RECURSE "${CACHE_DIR}")
file(MAKE_DIRECTORY "${CACHE_DIR}")
case_run(auth -DTOKEN=stub-token-value)
assert_matches("${LAST_OUTPUT}" "RESULT Bearer stub-token-value" "token sent as Bearer")

step("a repeat request inside OC_API_TTL is served from cache")
file(REMOVE_RECURSE "${CACHE_DIR}")
file(MAKE_DIRECTORY "${CACHE_DIR}")
case_run(cached)
file(DOWNLOAD "http://127.0.0.1:${PORT}/hits/release-ttl" "${WORK}/hits.json")
file(READ "${WORK}/hits.json" hits)
string(JSON n GET "${hits}" count)
if(NOT n EQUAL 1)
  message(FATAL_ERROR "FAIL: two calls to one URL hit the server ${n} times; TTL cache is not working")
endif()

message(STATUS "http: PASS")
