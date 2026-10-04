# The presets template: it parses with the real CMake, and the copies shipped in the
# examples have not drifted from it. No network -- --list-presets does not configure.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)

set(TEMPLATE "${OCMAKE_ROOT}/presets/CMakePresets.json")
assert_exists("${TEMPLATE}" "presets template")

step("every example ships the template verbatim")
file(GLOB examples LIST_DIRECTORIES true "${OCMAKE_ROOT}/examples/*")
set(checked 0)
foreach(dir IN LISTS examples)
  if(IS_DIRECTORY "${dir}" AND EXISTS "${dir}/CMakeLists.txt")
    assert_exists("${dir}/CMakePresets.json" "presets in ${dir}")
    assert_same_file("${dir}/CMakePresets.json" "${TEMPLATE}" "presets copy is current")
    math(EXPR checked "${checked}+1")
  endif()
endforeach()
if(checked EQUAL 0)
  message(FATAL_ERROR "FAIL: no examples were checked")
endif()

step("CMake parses the presets and lists all four")
run("list-presets" "${CMAKE_COMMAND}" --list-presets -S "${OCMAKE_ROOT}/examples/minimal")
foreach(name release debug offline update)
  assert_matches("${LAST_OUTPUT}" "\"${name}\"" "preset ${name} listed")
endforeach()

step("workflow presets are listed too")
run("list-workflow" "${CMAKE_COMMAND}" --list-presets=workflow -S "${OCMAKE_ROOT}/examples/minimal")
assert_matches("${LAST_OUTPUT}" "\"release\"" "release workflow listed")

message(STATUS "presets: PASS")
