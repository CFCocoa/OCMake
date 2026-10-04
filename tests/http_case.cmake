# One _oc_http_json() case against the stub server, run as a subprocess so that
# FATAL_ERROR paths are observable.
# Usage: cmake -DOCMAKE_ROOT=.. -DPORT=n -DCACHE=dir -DCASE=name -P http_case.cmake

cmake_minimum_required(VERSION 3.25)
set(OC_CACHE_DIR "${CACHE}")
include(${OCMAKE_ROOT}/cmake/OCUtil.cmake)
include(${OCMAKE_ROOT}/cmake/OCResolve.cmake)

# The developer's real token must not change which branch we are testing.
unset(ENV{GITHUB_TOKEN})
unset(ENV{GH_TOKEN})
if(TOKEN)
  set(ENV{GITHUB_TOKEN} "${TOKEN}")
endif()

set(base "http://127.0.0.1:${PORT}")

if(CASE STREQUAL "ok")
  _oc_http_json("${base}/release" j code)
  string(JSON tag GET "${j}" tag_name)
  message(STATUS "RESULT code=${code} tag=${tag}")
elseif(CASE STREQUAL "cached")
  # Two calls, one URL: the second must be served from the TTL cache. Its own path, so
  # the server's request counter is not polluted by the other cases.
  _oc_http_json("${base}/release-ttl" j1 c1)
  _oc_http_json("${base}/release-ttl" j2 c2)
  message(STATUS "RESULT code=${c1}${c2}")
elseif(CASE STREQUAL "auth")
  _oc_http_json("${base}/release" j code)
  string(JSON seen GET "${j}" seen_auth)
  message(STATUS "RESULT ${seen}")
elseif(CASE STREQUAL "404")
  _oc_http_json("${base}/status/404" j code)
  message(STATUS "RESULT code=${code}")
elseif(CASE STREQUAL "403" OR CASE STREQUAL "429" OR CASE STREQUAL "401")
  _oc_http_json("${base}/status/${CASE}" j code)
  message(STATUS "RESULT unexpectedly succeeded with code=${code}")
else()
  message(FATAL_ERROR "unknown CASE '${CASE}'")
endif()
