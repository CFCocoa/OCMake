# Config layering: overlays, typed keypath sets, boot-args, secrets and the CONFIG filter.
# No network -- the fixture's archives are local file:// URLs.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)

set(FX "${WORK}/fx")
file(REMOVE_RECURSE "${WORK}")

step("generate fixture")
run("fixture" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/make_fixture.py" "${FX}" "${OCMAKE_ROOT}")

run("overlay" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/make_layers.py" "${FX}")

file(READ "${FX}/CMakeLists.txt" cml)
string(REPLACE "# @EXTRA@" "
oc_config_overlay(overlay.plist)
oc_config_set(Misc/Debug/Target            INTEGER 67)
oc_config_set(Misc/Security/SecureBootModel STRING  Disabled)
oc_config_set(Misc/Boot/HideAuxiliary      BOOL    ON)
oc_config_set(UEFI/Quirks/ResizeGpuBars    INTEGER -1)
oc_config_set(Made/Up/Path                 STRING  created)
oc_config_set(Misc/BlessOverride/1         STRING  replaced)
oc_config_set(Test/Hex                     DATA    <0102ff>)
oc_config_set(Test/B64                     DATA    AQL/)
oc_boot_args(APPEND -v debug=0x100 REMOVE keepsyms=1)
oc_secrets(secrets.plist)
oc_config_set(Only/In/Debug STRING yes CONFIG Debug)
oc_config_set(Build/Variant STRING \${OC_BUILD})
" cml "${cml}")
file(WRITE "${FX}/CMakeLists.txt" "${cml}")

set(gen "")
if(GENERATOR)
  set(gen -G "${GENERATOR}")
endif()

function(build_and_dump buildtype outdir)
  run("configure ${buildtype}" "${CMAKE_COMMAND}" -S "${FX}" -B "${outdir}" ${gen}
      -DCMAKE_BUILD_TYPE=${buildtype})
  run("build ${buildtype}" "${CMAKE_COMMAND}" --build "${outdir}")
  run("dump ${buildtype}" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/get_plist.py"
      "${outdir}/EFI/OC/config.plist"
      Misc/Debug/Target Misc/Debug/AppleDebug Misc/Security/SecureBootModel
      Misc/Boot/HideAuxiliary UEFI/Quirks/ResizeGpuBars Made/Up/Path
      Misc/BlessOverride/0 Misc/BlessOverride/1 Test/Hex Test/B64
      PlatformInfo/Generic/SystemSerialNumber Only/In/Debug Build/Variant
      NVRAM/Add/7C436110-AB2A-4BBB-A880-FE41995C9F82/boot-args)
  set(DUMP "${LAST_OUTPUT}" PARENT_SCOPE)
endfunction()

step("Release build")
build_and_dump(Release "${WORK}/rel")

step("every op is applied, not just the last one")
# Regression: ops are stored under an index counter, and a variable named `n` made
# if(NOT n) always true -- so each op overwrote index 0 and only the final one survived.
assert_matches("${DUMP}" "Misc/Debug/Target=67" "INTEGER set")
assert_matches("${DUMP}" "Misc/Security/SecureBootModel='Secret'" "secrets win over an earlier set")
assert_matches("${DUMP}" "Misc/Boot/HideAuxiliary=True" "BOOL set")
assert_matches("${DUMP}" "UEFI/Quirks/ResizeGpuBars=-1" "negative INTEGER set")

step("overlays deep-merge, and later ops see the result")
assert_matches("${DUMP}" "Misc/Debug/AppleDebug=True" "overlay key survives")
assert_matches("${DUMP}" "Misc/BlessOverride/0='keep'" "overlay array element untouched")
assert_matches("${DUMP}" "Misc/BlessOverride/1='replaced'" "numeric keypath indexes an array")

step("missing intermediate dicts are created")
assert_matches("${DUMP}" "Made/Up/Path='created'" "intermediate dicts created")

step("DATA accepts <hex> and base64")
assert_matches("${DUMP}" "Test/Hex=b'\\\\x01\\\\x02\\\\xff'" "hex DATA")
assert_matches("${DUMP}" "Test/B64=b'\\\\x01\\\\x02\\\\xff'" "base64 DATA")

step("boot-args edit in place: append, remove, and replace by key")
assert_matches("${DUMP}" "boot-args='alcid=11 -v debug=0x100'" "boot-args merged")

step("secrets are merged last and never in the committed base")
assert_matches("${DUMP}" "PlatformInfo/Generic/SystemSerialNumber='SECRET123'" "secrets applied")

step("a CONFIG Debug op is absent from a Release build")
assert_matches("${DUMP}" "Only/In/Debug=<absent>" "CONFIG filter excludes")

step("Debug build")
build_and_dump(Debug "${WORK}/dbg")
assert_matches("${DUMP}" "Only/In/Debug='yes'" "CONFIG filter includes")
assert_matches("${DUMP}" "Misc/Debug/Target=67" "unfiltered ops still apply")

step("switching build type in an existing build directory takes effect")
# Regression: the derived OC_BUILD was written to the cache, so on the next configure it
# was indistinguishable from a user override and CMAKE_BUILD_TYPE was ignored. A build
# directory configured Release stayed Release for ever, silently staging RELEASE binaries
# under -DCMAKE_BUILD_TYPE=Debug.
# Observed through OC_BUILD itself, not through a CONFIG-filtered op: the CONFIG filter
# is derived from the same value, so asserting on it alone cannot prove the switch worked.
# Second-granularity mtimes: the regenerated overrides file must be strictly newer than
# the config.plist built from the previous variant, or make considers it up to date.
execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 1.1)
build_and_dump(Debug "${WORK}/rel")
assert_matches("${DUMP}" "Build/Variant='DEBUG'" "Release dir reconfigured to Debug")
assert_matches("${DUMP}" "Only/In/Debug='yes'" "CONFIG ops follow the switch")
execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 1.1)
build_and_dump(Release "${WORK}/rel")
assert_matches("${DUMP}" "Build/Variant='RELEASE'" "and back to Release")
assert_matches("${DUMP}" "Only/In/Debug=<absent>" "CONFIG ops follow back")

step("an explicit -DOC_BUILD overrides CMAKE_BUILD_TYPE and says so")
execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 1.1)
run("override" "${CMAKE_COMMAND}" -S "${FX}" -B "${WORK}/rel" ${gen}
    -DCMAKE_BUILD_TYPE=Release -DOC_BUILD=DEBUG)
assert_matches("${LAST_OUTPUT}" "OC_BUILD overrides CMAKE_BUILD_TYPE" "override is announced")
# The second half of that message, which _oc_info() dropped on the floor from Phase 4 until
# a multi-fragment call was noticed being truncated in Phase 7.
assert_matches("${LAST_OUTPUT}" "clear it with .UOC_BUILD" "and says how to undo it")
run("build override" "${CMAKE_COMMAND}" --build "${WORK}/rel")
run("dump override" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/get_plist.py"
    "${WORK}/rel/EFI/OC/config.plist" Only/In/Debug Build/Variant)
assert_matches("${LAST_OUTPUT}" "Build/Variant='DEBUG'" "override actually selects DEBUG")
# CONFIG follows the effective variant, so a Release-only op must NOT fire here.
assert_matches("${LAST_OUTPUT}" "Only/In/Debug='yes'" "CONFIG follows OC_BUILD, not CMAKE_BUILD_TYPE")

# --- greenfield versus migration ----------------------------------------------
# Two ways into an OCMake project, told apart by whether the file is on disk. No detection
# and no marker: a config.plist that OCMake created is cleaned by construction, and one the
# user brought is theirs.
function(base_project name basefile)
  set(dir "${WORK}/${name}")
  file(REMOVE_RECURSE "${dir}")
  file(MAKE_DIRECTORY "${dir}")
  set(cfgline "oc_config(${FX}/${basefile})")
  if("${basefile}" STREQUAL "")
    set(cfgline "")   # no declaration: the default name is used, and it does not exist yet
  endif()
  file(WRITE "${dir}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.25...4.4)
project(${name} NONE)
include(${OCMAKE_ROOT}/OCMake.cmake)
oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\")
${cfgline}
oc_kext(Alpha URL \"file://${FX}/flat.zip\")
oc_efi()
")
  run("configure ${name}" "${CMAKE_COMMAND}" -S "${dir}" -B "${dir}/b" ${gen})
  set(CONFIGURE_LOG "${LAST_OUTPUT}" PARENT_SCOPE)
  run("build ${name}" "${CMAKE_COMMAND}" --build "${dir}/b")
  run("dump ${name}" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/dump_config.py" "${dir}/b/EFI/OC/config.plist")
  set(BASE_DUMP "${LAST_OUTPUT}" PARENT_SCOPE)
  set(PROJECT_DIR "${dir}" PARENT_SCOPE)
endfunction()

step("a project with no config.plist gets one, cleaned, from the package's sample")
base_project(greenfield "")
assert_matches("${CONFIGURE_LOG}" "created config.plist from OpenCore" "the file is created and announced")
assert_exists("${PROJECT_DIR}/config.plist" "written into the project, not the build dir")
# The sample's own Kernel.Add disables Alpha.kext. Cleaning at creation is what stops that
# from outranking the declaration -- OCSnapshot merges, so a surviving entry would win.
assert_matches("${BASE_DUMP}" "kext Alpha.kext enabled=True" "the sample's Enabled=false is gone")
assert_not_matches("${BASE_DUMP}" "SSDT-SAMPLE" "and so are its ACPI entries")

step("everything outside the four derived sections is kept")
run("scaffolded" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/get_plist.py"
    "${PROJECT_DIR}/config.plist" Misc/Security/ScanPolicy)
assert_matches("${LAST_OUTPUT}" "ScanPolicy=" "the sample's other settings survive")

step("a config.plist already on disk is the user's, and is merged into")
# The guard against over-cleaning: identical content to the sample's, different provenance.
# Cleaning this would destroy what merging exists to protect -- b760i's hand-written
# version Comments and ResetNvramEntry's --preserve-boot argument.
base_project(migration own-base.plist)
assert_not_matches("${CONFIGURE_LOG}" "created config.plist" "nothing is created")
assert_matches("${BASE_DUMP}" "kext Alpha.kext enabled=False" "the project's own choice stands")
assert_matches("${BASE_DUMP}" "comment=mine, on purpose" "and its comment survives")

# --- error paths -------------------------------------------------------------
# write_bad(<name> <body>) -> sets BAD_DIR; configure/build expectations are per-test,
# because some mistakes are caught by CMake and others only by the Python config step.
function(write_bad name body)
  set(dir "${WORK}/bad-${name}")
  file(MAKE_DIRECTORY "${dir}")
  set(BAD_DIR "${dir}" PARENT_SCOPE)
  file(WRITE "${dir}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.25...4.4)
project(bad NONE)
include(${OCMAKE_ROOT}/OCMake.cmake)
oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\")
oc_config(${FX}/base.plist)
${body}
oc_efi()
")
endfunction()

function(bad_project name body)
  write_bad("${name}" "${body}")
  run_expect_fail("${name}" "${CMAKE_COMMAND}" -S "${BAD_DIR}" -B "${BAD_DIR}/b" ${gen})
  set(LAST_ERROR "${LAST_ERROR}" PARENT_SCOPE)
endfunction()

step("an unknown type is rejected at configure time")
bad_project(badtype "oc_config_set(A/B WIDGET 1)")
assert_matches("${LAST_ERROR}" "type must be one of" "unknown type")

step("a missing secrets file points at the template")
bad_project(nosecrets "oc_secrets(${FX}/secrets.plist.missing)")
assert_matches("${LAST_ERROR}" "oc_secrets.. file does not exist" "missing secrets")

step("an out-of-range array index fails the build with the path named")
# Caught by the Python step, not CMake: the array only exists once the plist is loaded.
write_bad(badindex "oc_config_set(Misc/BlessOverride/9 STRING x)")
run("configure badindex" "${CMAKE_COMMAND}" -S "${BAD_DIR}" -B "${BAD_DIR}/b" ${gen})
run_expect_fail("badindex build" "${CMAKE_COMMAND}" --build "${BAD_DIR}/b")
assert_matches("${LAST_ERROR}" "Misc/BlessOverride/9: index 9 is out of range" "array index diagnostic")

step("the lockfile keeps both build variants, so switching needs no network")
# Regression: the flush pruned every entry not used this configure, so a Release configure
# deleted the Debug entries and vice versa. Each switch then re-resolved every item from
# the GitHub API -- which is what exhausted the 60/hour limit during development.
file(READ "${FX}/ocmake.lock" lock)
string(REGEX MATCHALL "BUILD \"RELEASE\"" rel "${lock}")
string(REGEX MATCHALL "BUILD \"DEBUG\"" dbg "${lock}")
list(LENGTH rel nrel)
list(LENGTH dbg ndbg)
if(nrel EQUAL 0 OR ndbg EQUAL 0)
  message(FATAL_ERROR
    "FAIL: lock should hold both variants, got ${nrel} RELEASE and ${ndbg} DEBUG:\n${lock}")
endif()

step("both variants then configure with OC_OFFLINE=ON from a clean build dir")
file(REMOVE_RECURSE "${WORK}/rel" "${WORK}/dbg")
run("offline Release" "${CMAKE_COMMAND}" -S "${FX}" -B "${WORK}/rel" ${gen}
    -DCMAKE_BUILD_TYPE=Release -DOC_OFFLINE=ON)
run("offline Debug" "${CMAKE_COMMAND}" -S "${FX}" -B "${WORK}/dbg" ${gen}
    -DCMAKE_BUILD_TYPE=Debug -DOC_OFFLINE=ON)

message(STATUS "config: PASS")
