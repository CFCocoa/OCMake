# Kexts, drivers, tools and config.plist assembly, against a generated fixture.
# No network: every archive is a local file:// URL.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)

set(FX "${WORK}/fx")
set(BUILD "${WORK}/build")
set(EFI "${BUILD}/EFI")
file(REMOVE_RECURSE "${WORK}")

step("generate fixture")
run("fixture" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/make_fixture.py" "${FX}" "${OCMAKE_ROOT}")

set(gen "")
if(GENERATOR)
  set(gen -G "${GENERATOR}")
endif()

step("configure and build")
set(cfg_cmd "${CMAKE_COMMAND}" -S "${FX}" -B "${BUILD}" ${gen})
run("configure" ${cfg_cmd})
run("build" "${CMAKE_COMMAND}" --build "${BUILD}")

step("kexts are staged, and only the declared ones")
assert_exists("${EFI}/OC/Kexts/Alpha.kext/Contents/Info.plist" "flat archive bundle")
assert_exists("${EFI}/OC/Kexts/Beta.kext/Contents/Info.plist" "bundle from nested Kexts/ layout")
assert_exists("${EFI}/OC/Kexts/Delta.kext/Contents/Info.plist" "local PATH bundle")
assert_missing("${EFI}/OC/Kexts/Gamma.kext" "sibling bundle not named in KEXTS")

step("one oc_driver() call mixes package names, a local PATH and a fetched URL")
# Source keywords introduce the items that come from them, so the three can share a call --
# which the earlier call-wide OCBINARYDATA flag could not express.
assert_exists("${EFI}/OC/Drivers/OpenRuntime.efi" "declared driver")
assert_exists("${EFI}/OC/Drivers/OpenCanopy.efi" "declared driver")
assert_missing("${EFI}/OC/Drivers/Unused.efi" "undeclared driver stays out")
assert_exists("${EFI}/OC/Drivers/Forked.efi" "local driver staged from PATH")
assert_exists("${EFI}/OC/Drivers/Remote.efi" "driver fetched from a URL, named after it")
assert_exists("${EFI}/OC/Tools/OpenShell.efi" "declared tool")

step("the standard OC directories exist even when empty")
# OCSnapshot refuses to run without them.
foreach(d ACPI Drivers Kexts Resources Tools)
  assert_exists("${EFI}/OC/${d}" "OC/${d} present")
endforeach()

step("config.plist reflects the staged tree and the declared overrides")
assert_exists("${EFI}/OC/config.plist" "config.plist generated")
run("dump" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/dump_config.py" "${EFI}/OC/config.plist")
set(dump "${LAST_OUTPUT}")
assert_matches("${dump}" "kext Alpha.kext enabled=True min=20.0.0 comment=pinned by test" "overrides applied")
assert_matches("${dump}" "kext Delta.kext enabled=False" "ENABLED OFF override")
assert_matches("${dump}" "order Alpha.kext,Beta.kext,Delta.kext" "dependency order: Beta needs Alpha")
assert_matches("${dump}" "exec Delta.kext=" "plist-only kext has no ExecutablePath")

step("nested plugins are separate Kernel.Add entries, staged inside their parent")
# Regression: verify_snapshot() enumerated only top-level bundles under OC/Kexts, so every
# plugin OCSnapshot correctly listed read as "listed but not staged" and the build failed.
# Found by the laptop example the moment it declared VoodooPS2, whose release nests four.
assert_matches("${dump}" "kext Beta.kext/Contents/PlugIns/BetaPlugin.kext enabled=True"
               "plugin listed in Kernel.Add")
assert_exists("${EFI}/OC/Kexts/Beta.kext/Contents/PlugIns/BetaPlugin.kext/Contents/Info.plist"
              "plugin staged inside its parent")
assert_missing("${EFI}/OC/Kexts/BetaPlugin.kext" "and never as a top-level bundle")
# Forked.efi comes from oc_driver(PATH ...), so the snapshot picks up local drivers too.
assert_matches("${dump}" "drivers Forked.efi,OpenCanopy.efi,OpenRuntime.efi,Remote.efi"
               "declared drivers listed")
assert_matches("${dump}" "tools OpenShell.efi" "tools listed")

step("dropping a declaration prunes it from the tree and from config.plist")
file(READ "${FX}/CMakeLists.txt" cml)
string(REPLACE "oc_kext(Delta PATH local/Delta.kext ENABLED OFF)" "" cml2 "${cml}")
# Second-granularity mtimes again: if the regenerated manifest lands in the same second as
# the previous build's outputs, make sees "not newer" and skips the restage.
execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 1.1)
file(WRITE "${FX}/CMakeLists.txt" "${cml2}")
# Reconfigure explicitly rather than relying on the generator noticing the edit: this test
# rewrites and rebuilds within the same second, and the Makefile generator's regeneration
# check has second granularity, so auto-regeneration is a coin flip. What is under test is
# that a dropped declaration prunes, not CMake's own regeneration machinery.
run("reconfigure" ${cfg_cmd})
run("rebuild" "${CMAKE_COMMAND}" --build "${BUILD}")
assert_missing("${EFI}/OC/Kexts/Delta.kext" "removed kext is gone from the tree")
run("dump2" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/dump_config.py" "${EFI}/OC/config.plist")
if(LAST_OUTPUT MATCHES "Delta")
  message(FATAL_ERROR "FAIL: Delta still in config.plist after removal:\n${LAST_OUTPUT}")
endif()
file(WRITE "${FX}/CMakeLists.txt" "${cml}")

# --- error paths -------------------------------------------------------------
function(bad_project name body)
  set(dir "${WORK}/bad-${name}")
  file(MAKE_DIRECTORY "${dir}")
  file(WRITE "${dir}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.25...4.4)
project(bad NONE)
include(${OCMAKE_ROOT}/OCMake.cmake)
oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\")
${body}
oc_efi()
")
  run_expect_fail("${name}" "${CMAKE_COMMAND}" -S "${dir}" -B "${dir}/b" ${gen})
  set(LAST_ERROR "${LAST_ERROR}" PARENT_SCOPE)
endfunction()

step("declaring the same bundle twice is an error")
bad_project(dup "oc_kext(A URL \"file://${FX}/flat.zip\")\noc_kext(B URL \"file://${FX}/flat.zip\")")
assert_matches("${LAST_ERROR}" "Alpha.kext.* is declared more than once" "duplicate bundle")

step("a declaration name that is a CMake false constant still works")
# N, NO, OFF, FALSE and IGNORE are false constants, so if(NOT A_NAME) misfires on them.
bad_project(falsename "oc_kext(N URL \"file://${FX}/nested.zip\" KEXTS Nope)")
assert_matches("${LAST_ERROR}" "has no 'Nope'" "name 'N' is treated as a name, not as false")

step("KEXTS naming a bundle the archive lacks lists what it has")
bad_project(nokext "oc_kext(Nested URL \"file://${FX}/nested.zip\" KEXTS Nope)")
assert_matches("${LAST_ERROR}" "has no 'Nope'" "missing kext named")
assert_matches("${LAST_ERROR}" "Beta.kext" "listing shows what is available")
assert_matches("${LAST_ERROR}" "Gamma.kext" "listing shows what is available")

step("an ambiguous archive asks for KEXTS")
bad_project(ambig "oc_kext(Whatever URL \"file://${FX}/nested.zip\")")
assert_matches("${LAST_ERROR}" "Pass KEXTS to choose from" "ambiguity guidance")

step("a driver the package lacks lists what it has")
bad_project(nodrv "oc_driver(NoSuchDriver)")
assert_matches("${LAST_ERROR}" "'NoSuchDriver.efi' is not in the OpenCore package" "missing driver")
assert_matches("${LAST_ERROR}" "OpenRuntime.efi" "driver listing")

step("source keywords are rejected where they cannot work")
# OcBinaryData has Drivers/ and Resources/ and no Tools/, so oc_tool() cannot use it.
bad_project(obdtool "oc_tool(OCBINARYDATA HfsPlus)")
assert_matches("${LAST_ERROR}" "OcBinaryData ships no Tools" "OCBINARYDATA on a tool")
# A source keyword with nothing after it is a typo, not a request for nothing.
bad_project(emptysrc "oc_driver(OCBINARYDATA)")
assert_matches("${LAST_ERROR}" "needs at least one name after OCBINARYDATA" "dangling keyword")
# URL takes the staged name from the file it points at, so it has to point at one.
bad_project(nonefi "oc_driver(URL \"file://${FX}/opencore.zip\")")
assert_matches("${LAST_ERROR}" "URL should point at a .efi" "URL without a .efi")

step("a malformed base config.plist is reported clearly")
file(WRITE "${WORK}/not-a-plist.plist" "this is not a plist")
run_expect_fail("bad base" "${PYTHON}" "${OCMAKE_ROOT}/scripts/oc_config.py"
  --base "${WORK}/not-a-plist.plist" --oc-dir "${EFI}/OC"
  --snapshot "${OCMAKE_ROOT}/third_party/OCSnapshot/OCSnapshot.py"
  --out "${WORK}/out.plist")
assert_matches("${LAST_ERROR}" "not a readable plist" "malformed base diagnostic")

step("a missing OC directory is caught before OCSnapshot swallows it")
# OCSnapshot prints "OC folder passed does not exist!" and still exits 0, so the wrapper
# has to check this itself.
run_expect_fail("missing oc dir" "${PYTHON}" "${OCMAKE_ROOT}/scripts/oc_config.py"
  --base "${FX}/base.plist" --oc-dir "${WORK}/nope"
  --snapshot "${OCMAKE_ROOT}/third_party/OCSnapshot/OCSnapshot.py"
  --out "${WORK}/out.plist")
assert_matches("${LAST_ERROR}" "staged OC directory does not exist" "missing oc dir diagnostic")

message(STATUS "phase2: PASS")
