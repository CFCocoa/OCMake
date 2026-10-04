# Several oc_efi() scopes in one project: separate trees, separate targets, and the two
# places where "one EFI" was baked in. No network -- the fixture's archives are local.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)

set(FX "${WORK}/fx")
set(PRJ "${WORK}/prj")
set(BUILD "${PRJ}/b")
file(REMOVE_RECURSE "${WORK}")

step("generate fixture")
run("fixture" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/make_fixture.py" "${FX}" "${OCMAKE_ROOT}")

set(gen "")
if(GENERATOR)
  set(gen -G "${GENERATOR}")
endif()

file(MAKE_DIRECTORY "${PRJ}")
file(WRITE "${PRJ}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.25...4.4)
project(twin NONE)
include(${OCMAKE_ROOT}/OCMake.cmake)
set(OC_DEFAULT_CONFIG \"\")

oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\" EFI desktop)
oc_driver(OpenRuntime EFI desktop)

oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\" EFI laptop)
oc_driver(OpenCanopy EFI laptop)

oc_efi(desktop)
oc_efi(laptop)
")

step("each EFI gets its own tree, and the shared package is fetched once")
run("configure" "${CMAKE_COMMAND}" -S "${PRJ}" -B "${BUILD}" ${gen})
# One extraction line, not two: both EFIs pin the same OpenCore, so the lock and cache
# collapse them into a single fetch.
string(REGEX MATCHALL "extracted opencore" extractions "${LAST_OUTPUT}")
list(LENGTH extractions nextract)
if(nextract GREATER 1)
  message(FATAL_ERROR "FAIL: the shared package was fetched ${nextract} times:\n${LAST_OUTPUT}")
endif()
run("build" "${CMAKE_COMMAND}" --build "${BUILD}")
assert_exists("${BUILD}/desktop/EFI/OC/Drivers/OpenRuntime.efi" "desktop tree")
assert_exists("${BUILD}/laptop/EFI/OC/Drivers/OpenCanopy.efi" "laptop tree")
assert_missing("${BUILD}/desktop/EFI/OC/Drivers/OpenCanopy.efi" "and they do not bleed into each other")

step("installing them together is refused rather than silently mixed")
# Every EFI installs to <prefix>/EFI, because that is the only layout firmware looks for.
# Without the guard the second overwrote the first and the USB stick got a hybrid.
run_expect_fail("install all" "${CMAKE_COMMAND}" --install "${BUILD}" --prefix "${WORK}/pfx")
assert_matches("${LAST_ERROR}" "builds 2 EFIs" "the count is named")
assert_matches("${LAST_ERROR}" "--component" "and the way out is given")
assert_missing("${WORK}/pfx/EFI" "nothing was copied before it refused")

step("one component at a time installs exactly that EFI")
run("install one" "${CMAKE_COMMAND}" --install "${BUILD}" --component laptop --prefix "${WORK}/pfx")
assert_exists("${WORK}/pfx/EFI/OC/Drivers/OpenCanopy.efi" "the chosen EFI")
assert_missing("${WORK}/pfx/EFI/OC/Drivers/OpenRuntime.efi" "and only that one")

step("no bare aliases and no cpack target, because neither could mean one thing")
assert_matches("${LAST_OUTPUT}" "." "install produced output")
run("targets" "${CMAKE_COMMAND}" --build "${BUILD}" --target help)
assert_matches("${LAST_OUTPUT}" "efi-desktop" "per-EFI targets exist")
assert_matches("${LAST_OUTPUT}" "efi-laptop" "per-EFI targets exist")
assert_not_matches("${LAST_OUTPUT}" "\\.\\.\\. outdated$" "no bare outdated")
assert_missing("${BUILD}/CPackConfig.cmake" "no cpack config: both would pack to one root")

step("oc_efi(<name>) names the EFI the declarations after it belong to")
# Rather than set(OC_EFI ...). A function can reject what it does not understand; a
# misspelled variable is simply unread, the PROJECT_NAME fallback takes over, and the
# declarations land on an EFI nobody named -- silently, and it still builds.
set(SCOPED2 "${WORK}/scoped2")
file(MAKE_DIRECTORY "${SCOPED2}")
file(WRITE "${SCOPED2}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.25...4.4)
project(rigs NONE)
include(${OCMAKE_ROOT}/OCMake.cmake)
set(OC_DEFAULT_CONFIG \"\")
oc_efi(one)
oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\")
oc_driver(OpenCanopy)
oc_efi(two)
oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\")
oc_driver(OpenRuntime)
")
run("configure scopes" "${CMAKE_COMMAND}" -S "${SCOPED2}" -B "${SCOPED2}/b" ${gen})
set(SCOPE_CONFIGURE "${LAST_OUTPUT}")
run("build scopes" "${CMAKE_COMMAND}" --build "${SCOPED2}/b")
assert_exists("${SCOPED2}/b/one/EFI/OC/Drivers/OpenCanopy.efi" "the first scope collected its own")
assert_missing("${SCOPED2}/b/one/EFI/OC/Drivers/OpenRuntime.efi" "and only its own")
assert_exists("${SCOPED2}/b/two/EFI/OC/Drivers/OpenRuntime.efi" "the second scope likewise")

step("a project with several EFIs says what each one ended up with")
# Which EFI a declaration belongs to is valid CMake either way, so a misplaced one cannot
# be caught -- it can only be shown, at configure time rather than in a BOM after a build.
assert_matches("${SCOPE_CONFIGURE}" "2 EFIs: one .1 driver., two .1 driver."
               "the summary is printed at configure time")

step("oc_efi() rejects arguments it does not understand")
# The whole reason for preferring a call over a bare variable.
function(bad_efi name body)
  set(dir "${WORK}/badefi-${name}")
  file(REMOVE_RECURSE "${dir}")
  file(MAKE_DIRECTORY "${dir}")
  file(WRITE "${dir}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.25...4.4)
project(x NONE)
include(${OCMAKE_ROOT}/OCMake.cmake)
${body}
")
  run_expect_fail("${name}" "${CMAKE_COMMAND}" -S "${dir}" -B "${dir}/b" ${gen})
  set(LAST_ERROR "${LAST_ERROR}" PARENT_SCOPE)
endfunction()
bad_efi(twonames "oc_efi(a b)")
assert_matches("${LAST_ERROR}" "takes one name" "two names is an error")
bad_efi(oldkeyword "oc_efi(NAME desktop)")
assert_matches("${LAST_ERROR}" "takes one name" "so is the keyword form it replaced")
bad_efi(novalue "oc_efi(desktop OUTPUT_DIR)")
assert_matches("${LAST_ERROR}" "OUTPUT_DIR needs a value" "and a keyword with no value")

step("an EFI declared in a subdirectory builds, including its compiled SSDTs")
# add_custom_command(OUTPUT) is visible only to targets in the directory that created it,
# and the targets come from the deferred finalize at the top level. oc_ssdt() used to create
# its iasl rule where it stood, so a project laid out as one CMakeLists per machine -- the
# idiomatic shape -- produced .aml rules nothing could reach: "No rule to make target".
set(SUB "${WORK}/sub")
file(MAKE_DIRECTORY "${SUB}/box")
file(WRITE "${SUB}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.25...4.4)
project(sub NONE)
include(${OCMAKE_ROOT}/OCMake.cmake)
add_subdirectory(box)
")
file(WRITE "${SUB}/box/CMakeLists.txt"
"set(OC_EFI box)
oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\")
oc_config(${FX}/base.plist)
oc_ssdt(acpi/SSDT-SUB.dsl)
oc_efi()
")
file(MAKE_DIRECTORY "${SUB}/box/acpi")
file(WRITE "${SUB}/box/acpi/SSDT-SUB.dsl"
"DefinitionBlock (\"\", \"SSDT\", 2, \"OCMK\", \"SUB\", 0x00000000)\n{\n}\n")
run("configure subdir" "${CMAKE_COMMAND}" -S "${SUB}" -B "${SUB}/b" ${gen})
run("build subdir" "${CMAKE_COMMAND}" --build "${SUB}/b")
assert_exists("${SUB}/b/box/EFI/OC/ACPI/SSDT-SUB.aml" "the subdirectory's SSDT compiled and staged")

step("two EFIs in one directory cannot quietly share a default config.plist")
# Both would fall back to ./config.plist and then share one machine's settings while
# appearing to have their own -- silent, and never what anyone means.
set(SHARED "${WORK}/shared")
file(MAKE_DIRECTORY "${SHARED}")
file(WRITE "${SHARED}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.25...4.4)
project(shared NONE)
include(${OCMAKE_ROOT}/OCMake.cmake)
oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\" EFI a)
oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\" EFI b)
oc_efi(a)
oc_efi(b)
")
run_expect_fail("shared default" "${CMAKE_COMMAND}" -S "${SHARED}" -B "${SHARED}/b" ${gen})
assert_matches("${LAST_ERROR}" "already uses" "the collision is named")
assert_matches("${LAST_ERROR}" "oc_config.b/config.plist EFI b." "and the fix is shown")

step("but naming one explicitly for each is fine")
# And so is pointing both at the same base on purpose: that is a decision, not an accident.
file(COPY_FILE "${FX}/base.plist" "${SHARED}/a.plist")
file(COPY_FILE "${FX}/base.plist" "${SHARED}/b.plist")
file(READ "${SHARED}/CMakeLists.txt" scml)
string(REPLACE "oc_efi(a)"
       "oc_config(a.plist EFI a)\noc_config(b.plist EFI b)\noc_efi(a)" scml "${scml}")
file(WRITE "${SHARED}/CMakeLists.txt" "${scml}")
run("named bases" "${CMAKE_COMMAND}" -S "${SHARED}" -B "${SHARED}/b" ${gen})

message(STATUS "multi: PASS")
