# OCMake test suite. `stage` needs no network; `example.minimal` downloads OpenCore once
# into the shared cache (OC_CACHE_DIR).

add_test(NAME stage COMMAND ${CMAKE_COMMAND}
  -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
  -DWORK=${CMAKE_CURRENT_BINARY_DIR}/stage
  -P ${CMAKE_CURRENT_SOURCE_DIR}/test_stage.cmake)

add_test(NAME resolve COMMAND ${CMAKE_COMMAND}
  -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
  -P ${CMAKE_CURRENT_SOURCE_DIR}/test_resolve.cmake)

add_test(NAME presets COMMAND ${CMAKE_COMMAND}
  -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
  -P ${CMAKE_CURRENT_SOURCE_DIR}/test_presets.cmake)

# Error paths that cannot be provoked against real GitHub, served by a local stub.
find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_Interpreter_FOUND)
  add_test(NAME http COMMAND ${Python3_EXECUTABLE}
    ${CMAKE_CURRENT_SOURCE_DIR}/stub_api.py
    ${CMAKE_COMMAND}
      -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
      -DWORK=${CMAKE_CURRENT_BINARY_DIR}/http
      -DPORT={PORT}
      -P ${CMAKE_CURRENT_SOURCE_DIR}/test_http.cmake)
  set_tests_properties(http PROPERTIES TIMEOUT 120)
endif()

if(Python3_Interpreter_FOUND)
  add_test(NAME phase2 COMMAND ${CMAKE_COMMAND}
    -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
    -DWORK=${CMAKE_CURRENT_BINARY_DIR}/phase2
    -DPYTHON=${Python3_EXECUTABLE}
    -DGENERATOR=${CMAKE_GENERATOR}
    -P ${CMAKE_CURRENT_SOURCE_DIR}/test_phase2.cmake)
  set_tests_properties(phase2 PROPERTIES TIMEOUT 300)
endif()

if(Python3_Interpreter_FOUND)
  add_test(NAME config COMMAND ${CMAKE_COMMAND}
    -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
    -DWORK=${CMAKE_CURRENT_BINARY_DIR}/config
    -DPYTHON=${Python3_EXECUTABLE}
    -DGENERATOR=${CMAKE_GENERATOR}
    -P ${CMAKE_CURRENT_SOURCE_DIR}/test_config.cmake)
  set_tests_properties(config PROPERTIES TIMEOUT 300)
endif()

if(Python3_Interpreter_FOUND)
  add_test(NAME defaults COMMAND ${CMAKE_COMMAND}
    -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
    -DWORK=${CMAKE_CURRENT_BINARY_DIR}/defaults
    -DPYTHON=${Python3_EXECUTABLE}
    -DGENERATOR=${CMAKE_GENERATOR}
    -P ${CMAKE_CURRENT_SOURCE_DIR}/test_defaults.cmake)
  set_tests_properties(defaults PROPERTIES TIMEOUT 300)
endif()

if(Python3_Interpreter_FOUND)
  add_test(NAME multi COMMAND ${CMAKE_COMMAND}
    -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
    -DWORK=${CMAKE_CURRENT_BINARY_DIR}/multi
    -DPYTHON=${Python3_EXECUTABLE}
    -DGENERATOR=${CMAKE_GENERATOR}
    -P ${CMAKE_CURRENT_SOURCE_DIR}/test_multi.cmake)
  set_tests_properties(multi PROPERTIES TIMEOUT 300)
endif()

if(Python3_Interpreter_FOUND)
  add_test(NAME validate COMMAND ${CMAKE_COMMAND}
    -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
    -DWORK=${CMAKE_CURRENT_BINARY_DIR}/validate
    -DPYTHON=${Python3_EXECUTABLE}
    -DGENERATOR=${CMAKE_GENERATOR}
    -P ${CMAKE_CURRENT_SOURCE_DIR}/test_validate.cmake)
  set_tests_properties(validate PROPERTIES TIMEOUT 300)
endif()

if(Python3_Interpreter_FOUND)
  add_test(NAME install COMMAND ${CMAKE_COMMAND}
    -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
    -DWORK=${CMAKE_CURRENT_BINARY_DIR}/install
    -DPYTHON=${Python3_EXECUTABLE}
    -DGENERATOR=${CMAKE_GENERATOR}
    -P ${CMAKE_CURRENT_SOURCE_DIR}/test_install.cmake)
  set_tests_properties(install PROPERTIES TIMEOUT 300)
endif()

# ACPI needs iasl. It is auto-fetched on macOS (once, into OC_CACHE_DIR); elsewhere the
# test is only registered when a system iasl is present.
find_program(IASL NAMES iasl HINTS /opt/homebrew/bin /usr/local/bin /usr/bin)
if(Python3_Interpreter_FOUND AND (IASL OR APPLE))
  add_test(NAME acpi COMMAND ${CMAKE_COMMAND}
    -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
    -DWORK=${CMAKE_CURRENT_BINARY_DIR}/acpi
    -DPYTHON=${Python3_EXECUTABLE}
    -DGENERATOR=${CMAKE_GENERATOR}
    -P ${CMAKE_CURRENT_SOURCE_DIR}/test_acpi.cmake)
  set_tests_properties(acpi PROPERTIES TIMEOUT 300)
endif()

# Needs network. Exclude with: ctest -E live
add_test(NAME resolve.live COMMAND ${CMAKE_COMMAND}
  -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
  -P ${CMAKE_CURRENT_SOURCE_DIR}/test_resolve_live.cmake)
# A GitHub rate limit is an environment condition, not a regression: skip rather than
# fail. (The 403 path itself is covered deterministically by the `http` test.)
set_tests_properties(resolve.live PROPERTIES
  TIMEOUT 120
  SKIP_REGULAR_EXPRESSION "GitHub API refused the request")

add_test(NAME example.minimal COMMAND ${CMAKE_COMMAND}
  -DOCMAKE_ROOT=${CMAKE_SOURCE_DIR}
  -DEXAMPLE=${CMAKE_SOURCE_DIR}/examples/minimal
  -DWORK=${CMAKE_CURRENT_BINARY_DIR}/minimal
  -DGENERATOR=${CMAKE_GENERATOR}
  -P ${CMAKE_CURRENT_SOURCE_DIR}/test_example.cmake)
# Its first step deliberately deletes the lockfile to exercise a cold resolve, so it needs
# the API. As with resolve.live, a rate limit is an environment condition, not a regression.
set_tests_properties(example.minimal PROPERTIES
  TIMEOUT 300
  SKIP_REGULAR_EXPRESSION "GitHub API refused the request")
