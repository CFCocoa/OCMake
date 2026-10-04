# ACPI: compiled SSDTs and prebuilt tables.
#
# Reuses make_fixture.py's fake OpenCore package, then declares ACPI on top of it.
# Needs iasl; the suite only registers this test when one is available or fetchable.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)

set(FX "${WORK}/fx")
set(BUILD "${WORK}/build")
set(EFI "${BUILD}/EFI")
file(REMOVE_RECURSE "${WORK}")

step("generate fixture")
run("fixture" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/make_fixture.py" "${FX}" "${OCMAKE_ROOT}")
file(MAKE_DIRECTORY "${FX}/acpi")

file(WRITE "${FX}/acpi/SSDT-TEST.dsl"
"DefinitionBlock (\"\", \"SSDT\", 2, \"OCM\", \"TEST\", 0x00000000)
{
    External (_SB_, DeviceObj)
    Scope (\\_SB)
    {
        Device (TST0)
        {
            Name (_HID, \"TEST0000\")
        }
    }
}
")
# A prebuilt table: a real ACPI header so it is a plausible .aml, staged verbatim.
file(WRITE "${FX}/acpi/SSDT-PREBUILT.aml" "SSDT")

set(gen "")
if(GENERATOR)
  set(gen -G "${GENERATOR}")
endif()

file(READ "${FX}/CMakeLists.txt" cml)
string(REPLACE "# @EXTRA@" "oc_ssdt(acpi/SSDT-TEST.dsl)\noc_ssdt(SAMPLES SSDT-SAMPLE)\noc_acpi(acpi/SSDT-PREBUILT.aml)" cml "${cml}")
file(WRITE "${FX}/CMakeLists.txt" "${cml}")

step("configure and build")
run("configure" "${CMAKE_COMMAND}" -S "${FX}" -B "${BUILD}" ${gen})
run("build" "${CMAKE_COMMAND}" --build "${BUILD}")

step("both compiled and prebuilt tables are staged")
assert_exists("${EFI}/OC/ACPI/SSDT-TEST.aml" "compiled .dsl becomes .aml")
assert_exists("${EFI}/OC/ACPI/SSDT-PREBUILT.aml" "prebuilt .aml staged")
assert_same_file("${EFI}/OC/ACPI/SSDT-PREBUILT.aml" "${FX}/acpi/SSDT-PREBUILT.aml"
                 "prebuilt table copied verbatim")
file(SIZE "${EFI}/OC/ACPI/SSDT-TEST.aml" sz)
if(sz LESS 36)
  message(FATAL_ERROR "FAIL: compiled AML is only ${sz} bytes -- shorter than an ACPI header")
endif()

step("a SAMPLES table is compiled out of the OpenCore package")
assert_exists("${EFI}/OC/ACPI/SSDT-SAMPLE.aml" "sample compiled without a local copy")

step("all three appear in ACPI.Add")
run("dump" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/dump_config.py" "${EFI}/OC/config.plist")
assert_matches("${LAST_OUTPUT}" "acpi SSDT-PREBUILT.aml,SSDT-SAMPLE.aml,SSDT-TEST.aml" "ACPI.Add lists all three")

step("editing the .dsl recompiles it")
file(READ "${EFI}/OC/ACPI/SSDT-TEST.aml" before HEX)
file(READ "${FX}/acpi/SSDT-TEST.dsl" dsl)
string(REPLACE "TEST0000" "TEST0001" dsl2 "${dsl}")
# The Makefile generator compares mtimes at second granularity, and this test writes and
# rebuilds within the same second. Wait so the edited source is unambiguously newer than
# the .aml -- otherwise a correct incremental build is indistinguishable from a broken one.
execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 1.1)
file(WRITE "${FX}/acpi/SSDT-TEST.dsl" "${dsl2}")
run("rebuild" "${CMAKE_COMMAND}" --build "${BUILD}")
file(READ "${EFI}/OC/ACPI/SSDT-TEST.aml" after HEX)
if(before STREQUAL after)
  message(FATAL_ERROR "FAIL: .dsl changed but the staged .aml did not")
endif()

step("a broken .dsl fails the build and shows the compiler's diagnostic")
execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 1.1)
file(WRITE "${FX}/acpi/SSDT-TEST.dsl" "DefinitionBlock (\"\", \"SSDT\", 2, \"X\", \"Y\", 0)\n{\n  This Is Not Valid\n}\n")
run_expect_fail("bad dsl" "${CMAKE_COMMAND}" --build "${BUILD}")
assert_matches("${LAST_ERROR}" "syntax error" "iasl diagnostic surfaces")

step("an unknown SAMPLES name lists what the package has")
set(bad "${WORK}/bad-sample")
file(MAKE_DIRECTORY "${bad}")
file(WRITE "${bad}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.25...4.4)
project(bad NONE)
include(${OCMAKE_ROOT}/OCMake.cmake)
oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\")
oc_ssdt(SAMPLES SSDT-NOPE)
oc_efi()
")
run_expect_fail("bad sample" "${CMAKE_COMMAND}" -S "${bad}" -B "${bad}/b" ${gen})
assert_matches("${LAST_ERROR}" "is not an OpenCore ACPI sample" "unknown sample rejected")
assert_matches("${LAST_ERROR}" "SSDT-SAMPLE.dsl" "listing shows what is available")

step("the BOM separates compiled tables from prebuilt ones")
file(READ "${BUILD}/BOM.md" bom)
assert_matches("${bom}" "### Compiled .2." "two compiled tables")
assert_matches("${bom}" "### Prebuilt .1." "one prebuilt table")
# A table compiled out of the OpenCore package is labelled as such, not as a repo file.
assert_matches("${bom}" "SSDT-SAMPLE.aml . .SSDT-SAMPLE.dsl. .OpenCore sample." "sample annotated")
assert_matches("${bom}" "SSDT-PREBUILT.aml . .acpi/SSDT-PREBUILT.aml." "prebuilt cites its path")

step("sources sort case-insensitively")
# Sorting the rendered markdown put [OpenIntelWireless/...] before [acidanthera/...],
# because '[' aside, 'O' < 'a' in ASCII. Sorting is on the source name, case-folded.
run("sortcheck" "${PYTHON}" -c "import sys
sys.path.insert(0, sys.argv[1])
import oc_report as r
names = ['OpenIntelWireless/itlwm', 'acidanthera/Lilu', 'aluveitie/RadeonSensor', 'SongXiaoXi/AppleIGC']
print(','.join(sorted(names, key=r.sort_key)))" "${OCMAKE_ROOT}/scripts")
assert_matches("${LAST_OUTPUT}" "acidanthera/Lilu,aluveitie/RadeonSensor,OpenIntelWireless/itlwm,SongXiaoXi/AppleIGC" "case-insensitive order")

message(STATUS "acpi: PASS")
