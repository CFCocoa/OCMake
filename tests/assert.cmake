# Tiny assertion helpers shared by the test scripts.

function(assert_exists path why)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "FAIL (${why}): expected to exist:\n  ${path}")
  endif()
endfunction()

function(assert_missing path why)
  if(EXISTS "${path}")
    message(FATAL_ERROR "FAIL (${why}): expected NOT to exist:\n  ${path}")
  endif()
endfunction()

function(assert_same_file a b why)
  file(SHA256 "${a}" ha)
  file(SHA256 "${b}" hb)
  if(NOT ha STREQUAL hb)
    message(FATAL_ERROR "FAIL (${why}): contents differ:\n  ${a}\n  ${b}")
  endif()
endfunction()

# run(<why> COMMAND...) -- fails the test if the command exits non-zero.
function(run why)
  execute_process(COMMAND ${ARGN} RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT rc EQUAL 0)
    message(FATAL_ERROR "FAIL (${why}): command failed with ${rc}\n  ${ARGN}\n--- stdout ---\n${out}\n--- stderr ---\n${err}")
  endif()
  set(LAST_OUTPUT "${out}${err}" PARENT_SCOPE)
endfunction()

# run_expect_fail(<why> COMMAND...) -- fails the test if the command *succeeds*.
# Captures both streams: compilers do not agree on where diagnostics go (iasl prints
# its errors to stdout), so LAST_ERROR carries stderr+stdout and LAST_OUTPUT stdout.
function(run_expect_fail why)
  execute_process(COMMAND ${ARGN} RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(rc EQUAL 0)
    message(FATAL_ERROR "FAIL (${why}): command unexpectedly succeeded:\n  ${ARGN}\n${out}${err}")
  endif()
  set(LAST_ERROR "${err}${out}" PARENT_SCOPE)
  set(LAST_OUTPUT "${out}" PARENT_SCOPE)
endfunction()

# CMake wraps message() output at arbitrary column widths, so any assertion on an error
# string must normalise whitespace first or it will break on a line boundary.
function(assert_matches text pattern why)
  string(REGEX REPLACE "[ \t\r\n]+" " " flat "${text}")
  if(NOT flat MATCHES "${pattern}")
    message(FATAL_ERROR "FAIL (${why}): expected to match '${pattern}':\n${text}")
  endif()
endfunction()

function(assert_not_matches text pattern why)
  string(REGEX REPLACE "[ \t\r\n]+" " " flat "${text}")
  if(flat MATCHES "${pattern}")
    message(FATAL_ERROR "FAIL (${why}): expected NOT to match '${pattern}':\n${text}")
  endif()
endfunction()

function(step msg)
  message(STATUS "  .. ${msg}")
endfunction()
