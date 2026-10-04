# Built-in defaults (OC_DEFAULT_* in OCMake.cmake): config.plist and secrets.plist picked
# up by name, and the DEBUG config knobs seeded ahead of the project's own declarations.
# No network -- the fixture's archives are local file:// URLs.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)

set(FX "${WORK}/fx")
file(REMOVE_RECURSE "${WORK}")

step("generate fixture")
run("fixture" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/make_fixture.py" "${FX}" "${OCMAKE_ROOT}")

set(gen "")
if(GENERATOR)
  set(gen -G "${GENERATOR}")
endif()

# make_project(<name> <body>) -> PRJ. The body is everything the project declares besides
# oc_opencore(), so whatever else ends up in config.plist got there by default.
function(make_project name body)
  set(dir "${WORK}/${name}")
  file(MAKE_DIRECTORY "${dir}")
  file(WRITE "${dir}/CMakeLists.txt"
"cmake_minimum_required(VERSION 3.25...4.4)
project(${name} NONE)
include(${OCMAKE_ROOT}/OCMake.cmake)
oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\")
${body}
oc_efi()
")
  set(PRJ "${dir}" PARENT_SCOPE)
endfunction()

function(dump_keys plist)
  run("dump" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/get_plist.py" "${plist}"
      Misc/Debug/Target Misc/Debug/AppleDebug
      PlatformInfo/Generic/SystemSerialNumber
      NVRAM/Add/7C436110-AB2A-4BBB-A880-FE41995C9F82/boot-args)
  set(DUMP "${LAST_OUTPUT}" PARENT_SCOPE)
endfunction()

# --- picked up by name -------------------------------------------------------
step("a project that declares neither still gets config.plist and secrets.plist")
make_project(byname "")
set(BYNAME "${PRJ}")
file(COPY_FILE "${FX}/base.plist" "${BYNAME}/config.plist")
run("layers" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/make_layers.py" "${BYNAME}")

run("configure release" "${CMAKE_COMMAND}" -S "${BYNAME}" -B "${BYNAME}/rel" ${gen}
    -DCMAKE_BUILD_TYPE=Release)
assert_matches("${LAST_OUTPUT}" "defaults: config.plist, secrets.plist" "defaults are announced")
run("build release" "${CMAKE_COMMAND}" --build "${BYNAME}/rel")
assert_exists("${BYNAME}/rel/EFI/OC/config.plist" "default config.plist was used as the base")
dump_keys("${BYNAME}/rel/EFI/OC/config.plist")
assert_matches("${DUMP}" "SystemSerialNumber='SECRET123'" "default secrets.plist merged")

step("the DEBUG knobs are Debug-only")
assert_matches("${DUMP}" "Misc/Debug/Target=<absent>" "no Debug default in a Release build")
assert_matches("${DUMP}" "Misc/Debug/AppleDebug=<absent>" "no Debug default in a Release build")
assert_matches("${DUMP}" "boot-args=<absent>" "no Debug boot-args in a Release build")

step("a Debug build applies OC_DEFAULT_DEBUG_SET and OC_DEFAULT_DEBUG_BOOT_ARGS")
run("configure debug" "${CMAKE_COMMAND}" -S "${BYNAME}" -B "${BYNAME}/dbg" ${gen}
    -DCMAKE_BUILD_TYPE=Debug)
assert_matches("${LAST_OUTPUT}" "Misc/Debug/Target=67" "applied defaults are named on screen")
run("build debug" "${CMAKE_COMMAND}" --build "${BYNAME}/dbg")
dump_keys("${BYNAME}/dbg/EFI/OC/config.plist")
assert_matches("${DUMP}" "Misc/Debug/Target=67" "INTEGER default")
assert_matches("${DUMP}" "Misc/Debug/AppleDebug=True" "BOOL default")
assert_matches("${DUMP}" "boot-args='-v debug=0x100 keepsyms=1'" "boot-args default")

# --- an explicit declaration always wins -------------------------------------
step("a project declaration overrides a default, because defaults are seeded first")
# The ordering is the whole design: ops apply in declaration order, so a default that was
# added last would silently win over the CMakeLists that tried to change it.
make_project(override "oc_config_set(Misc/Debug/Target INTEGER 3)
oc_boot_args(REMOVE keepsyms=1)")
file(COPY_FILE "${FX}/base.plist" "${PRJ}/config.plist")
run("configure override" "${CMAKE_COMMAND}" -S "${PRJ}" -B "${PRJ}/b" ${gen}
    -DCMAKE_BUILD_TYPE=Debug)
run("build override" "${CMAKE_COMMAND}" --build "${PRJ}/b")
dump_keys("${PRJ}/b/EFI/OC/config.plist")
assert_matches("${DUMP}" "Misc/Debug/Target=3" "oc_config_set beats the default")
assert_matches("${DUMP}" "boot-args='-v debug=0x100'" "oc_boot_args REMOVE strips a default arg")

step("an explicit oc_config() is not overridden by a file named config.plist")
make_project(explicit "oc_config(other.plist)")
file(COPY_FILE "${FX}/base.plist" "${PRJ}/other.plist")
# Unreadable on purpose: if the default were to win anyway, the build would fail loudly
# rather than quietly assembling the wrong plist. Also covers "no secrets, no template,
# no complaint" -- this project has neither.
file(WRITE "${PRJ}/config.plist" "not a plist")
run("configure explicit" "${CMAKE_COMMAND}" -S "${PRJ}" -B "${PRJ}/b" ${gen})
assert_not_matches("${LAST_OUTPUT}" "defaults:" "nothing was defaulted")
run("build explicit" "${CMAKE_COMMAND}" --build "${PRJ}/b")

# --- turning them off --------------------------------------------------------
step("-DOC_DEFAULTS=OFF leaves the project with nothing but what it declared")
run("configure no-defaults" "${CMAKE_COMMAND}" -S "${BYNAME}" -B "${BYNAME}/off" ${gen}
    -DCMAKE_BUILD_TYPE=Debug -DOC_DEFAULTS=OFF)
assert_matches("${LAST_OUTPUT}" "has no config.plist" "the consequence is stated, not silent")
run("build no-defaults" "${CMAKE_COMMAND}" --build "${BYNAME}/off")
assert_missing("${BYNAME}/off/EFI/OC/config.plist" "no config step without a base plist")

step("a default can be redirected from the command line")
# _oc_default() only sets what nobody else has chosen, so -D reaches it. Without the -D the
# stock name is used -- and since nothing is there, it is created, which is what the second
# half asserts.
make_project(cmdline "")
file(COPY_FILE "${FX}/base.plist" "${PRJ}/renamed.plist")
run("configure -D" "${CMAKE_COMMAND}" -S "${PRJ}" -B "${PRJ}/b" ${gen}
    -DOC_DEFAULT_CONFIG=renamed.plist)
assert_matches("${LAST_OUTPUT}" "defaults: renamed.plist" "-D reaches the default")
run("build -D" "${CMAKE_COMMAND}" --build "${PRJ}/b")
assert_exists("${PRJ}/b/EFI/OC/config.plist" "renamed base plist was used")
run("configure without -D" "${CMAKE_COMMAND}" -S "${PRJ}" -B "${PRJ}/stock" ${gen})
assert_matches("${LAST_OUTPUT}" "created config.plist" "and the stock default scaffolds one")
assert_exists("${PRJ}/config.plist" "next to renamed.plist, which the -D run used")

# --- VERSION defaults to latest ------------------------------------------------
step("a declaration with no VERSION is keyed as 'latest', and the lock answers it")
# Proved offline by seeding a lockfile keyed |latest| and configuring with OC_OFFLINE=ON.
# Without the default the key would be |{empty}|, the lock would miss, and offline would
# fail -- so this asserts the key, not merely that some version was chosen.
make_project(deflatest "oc_kext(Alpha GITHUB acidanthera/Lilu)")
file(SHA256 "${FX}/opencore.zip" ocsha)
file(SHA256 "${FX}/flat.zip" ksha)
file(WRITE "${PRJ}/ocmake.lock"
"oc_lock(KEY \"OpenCore|latest|RELEASE\" VERSION \"1.0.7\" BUILD \"RELEASE\"
        URL \"file://${FX}/opencore.zip\" SHA256 \"${ocsha}\")
oc_lock(KEY \"Alpha|latest|RELEASE\" VERSION \"1.7.2\" BUILD \"RELEASE\"
        URL \"file://${FX}/flat.zip\" SHA256 \"${ksha}\")
")
# The project must not name a version anywhere, including for OpenCore.
file(READ "${PRJ}/CMakeLists.txt" dl)
string(REPLACE "oc_opencore(VERSION 1.0.7 URL \"file://${FX}/opencore.zip\")" "oc_opencore()" dl "${dl}")
file(WRITE "${PRJ}/CMakeLists.txt" "${dl}")
run("configure latest-by-default" "${CMAKE_COMMAND}" -S "${PRJ}" -B "${PRJ}/b" ${gen} -DOC_OFFLINE=ON)
run("build latest-by-default" "${CMAKE_COMMAND}" --build "${PRJ}/b")
assert_exists("${PRJ}/b/EFI/OC/Kexts/Alpha.kext" "the kext resolved through the |latest| key")

step("a kext with no source at all names every source it could have had")
make_project(nosource "oc_kext(Orphan)")
run_expect_fail("nosource" "${CMAKE_COMMAND}" -S "${PRJ}" -B "${PRJ}/b" ${gen})
foreach(src "GITHUB .owner/repo." "DORTANIA" "URL .url." "PATH .file.")
  assert_matches("${LAST_ERROR}" "${src}" "${src} is offered")
endforeach()

# --- error paths -------------------------------------------------------------
step("a secrets template with no secrets.plist is an error that names the template")
# The committed .example is how a project says it uses secrets: without it, a missing
# secrets.plist means "this project has none"; with it, it means "you skipped a step".
make_project(template "")
file(COPY_FILE "${FX}/base.plist" "${PRJ}/config.plist")
file(WRITE "${PRJ}/secrets.plist.example" "template")
run_expect_fail("template" "${CMAKE_COMMAND}" -S "${PRJ}" -B "${PRJ}/b" ${gen})
assert_matches("${LAST_ERROR}" "oc_secrets.. file does not exist" "missing secrets is fatal")
assert_matches("${LAST_ERROR}" "Start from the template" "and points at the .example")

step("a malformed OC_DEFAULT_DEBUG_SET entry is rejected at configure time")
make_project(malformed "")
file(COPY_FILE "${FX}/base.plist" "${PRJ}/config.plist")
run_expect_fail("malformed" "${CMAKE_COMMAND}" -S "${PRJ}" -B "${PRJ}/b" ${gen}
    -DCMAKE_BUILD_TYPE=Debug "-DOC_DEFAULT_DEBUG_SET=Misc/Debug/Target 67")
assert_matches("${LAST_ERROR}" "keypath. .TYPE. .value" "the expected shape is stated")

message(STATUS "defaults: PASS")
