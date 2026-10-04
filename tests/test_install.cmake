# Phase 6: oc_resources(), diff-esp/install-esp, CPack and outdated.
# No network -- the resources archive and every package are local file:// URLs.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)

set(FX "${WORK}/fx")
set(BUILD "${WORK}/build")
set(EFI "${BUILD}/EFI")
set(ESP "${WORK}/esp")
file(REMOVE_RECURSE "${WORK}")

step("generate fixture")
run("fixture" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/make_fixture.py" "${FX}" "${OCMAKE_ROOT}")
file(READ "${FX}/CMakeLists.txt" cml)
string(REPLACE "# @EXTRA@"
       "oc_resources(URL \"file://${FX}/ocbinarydata.zip\"
                     AUDIO OFF IMAGE Acidanthera/Test FONT ON LABEL ON)" cml "${cml}")
file(WRITE "${FX}/CMakeLists.txt" "${cml}")

set(gen "")
if(GENERATOR)
  set(gen -G "${GENERATOR}")
endif()

step("configure and build")
run("configure" "${CMAKE_COMMAND}" -S "${FX}" -B "${BUILD}" ${gen}
    -DOC_ESP=${ESP} -DOC_ESP_BACKUP_DIR=${WORK}/backups)
run("build" "${CMAKE_COMMAND}" --build "${BUILD}")

# --- oc_resources ------------------------------------------------------------
step("the selectors decide what is staged, and AUDIO OFF means absent")
assert_exists("${EFI}/OC/Resources/Font/Font_1x.bin" "Font staged")
assert_exists("${EFI}/OC/Resources/Label/Apple.lbl" "Label staged")
assert_missing("${EFI}/OC/Resources/Audio" "Audio is opt-in")

step("naming an icon set stages that set only, at the path PickerVariant addresses")
# Structure intact rather than flattened: PickerVariant addresses a set by where it sits
# inside Resources/Image, so flattening would break every config that names one.
assert_exists("${EFI}/OC/Resources/Image/Acidanthera/Test/Cursor.icns" "the named set is staged")
assert_missing("${EFI}/OC/Resources/Image/Acidanthera/Other" "and only the named set")

step("PickerVariant is derived from the declaration, not repeated in the plist")
# The fixture's base plist never mentions PickerVariant; oc_resources() writes it, with the
# backslash OpenCore expects, so the theme is stated exactly once.
run("picker" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/get_plist.py" "${EFI}/OC/config.plist"
    Misc/Boot/PickerVariant)
# '..' rather than an escaped backslash: get_plist.py prints a Python repr, so the one
# backslash OpenCore wants arrives here doubled, and matching it literally would mean four
# levels of escaping through CMake into the regex engine.
assert_matches("${LAST_OUTPUT}" "PickerVariant='Acidanthera..Test'" "PickerVariant written")

step("the BOM counts the resource sets and cites where they came from")
file(READ "${BUILD}/BOM.md" bom)
assert_matches("${bom}" "## Resources .3." "resources are reported as file count")
# Each fixture set holds exactly one file, so the three rows differ only in the name and
# fold into one -- the same merge the kext and driver tables use.
string(REGEX MATCH "## Resources[^#]*" res_section "${bom}")
assert_matches("${res_section}" "Font.<br>.Image.<br>.Label" "the three sets fold into one row")
assert_matches("${res_section}" "ocbinarydata.zip" "and cite where they came from")

step("with resources staged, a PickerVariant naming a missing set is still caught")
# The complement of the check in `validate`: resources exist, but not the ones named.
# chr(92) rather than a literal backslash: it would have to survive CMake's escaping
# and then Python's, and 'Acidanthera\Nope' is a Python syntax error, not a string.
file(REMOVE_RECURSE "${WORK}/mut")
file(COPY "${EFI}/" DESTINATION "${WORK}/mut")
run("mutate" "${PYTHON}" -c "import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p,'rb'))
d['Misc']['Boot']['PickerMode'] = 'External'
d['Misc']['Boot']['PickerVariant'] = 'Acidanthera' + chr(92) + 'Test'
plistlib.dump(d, open(p,'wb'))" "${WORK}/mut/OC/config.plist")
run("occheck ok" "${PYTHON}" "${OCMAKE_ROOT}/scripts/oc_check.py" --efi "${WORK}/mut"
    --manifest "${BUILD}/_oc/fixture-overrides.json")
run("mutate missing" "${PYTHON}" -c "import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p,'rb'))
d['Misc']['Boot']['PickerVariant'] = 'Acidanthera' + chr(92) + 'Nope'
plistlib.dump(d, open(p,'wb'))" "${WORK}/mut/OC/config.plist")
run_expect_fail("occheck variant" "${PYTHON}" "${OCMAKE_ROOT}/scripts/oc_check.py"
    --efi "${WORK}/mut" --manifest "${BUILD}/_oc/fixture-overrides.json")
assert_matches("${LAST_ERROR}" "picker-resources. PickerVariant is" "missing variant caught")

step("a bare call takes Font, Label and the whole Image tree, and never Audio")
# The explicit selectors above cannot exercise the defaults, and bare IMAGE is its own
# branch: PickerVariant Auto chooses a set by macOS version, so it needs all of them.
set(BARE "${WORK}/bare")
file(REMOVE_RECURSE "${BARE}")
file(COPY "${FX}/" DESTINATION "${BARE}")
file(READ "${BARE}/CMakeLists.txt" barecml)
string(REGEX REPLACE "oc_resources\\([^)]*\\)"
       "oc_resources(URL \"file://${FX}/ocbinarydata.zip\")" barecml "${barecml}")
file(WRITE "${BARE}/CMakeLists.txt" "${barecml}")
run("configure bare" "${CMAKE_COMMAND}" -S "${BARE}" -B "${BARE}/b" ${gen} -DOC_ESP=${ESP})
run("build bare" "${CMAKE_COMMAND}" --build "${BARE}/b")
assert_exists("${BARE}/b/EFI/OC/Resources/Font/Font_1x.bin" "Font by default")
assert_exists("${BARE}/b/EFI/OC/Resources/Label/Apple.lbl" "Label by default")
assert_exists("${BARE}/b/EFI/OC/Resources/Image/Acidanthera/Test/Cursor.icns" "Image by default")
assert_exists("${BARE}/b/EFI/OC/Resources/Image/Acidanthera/Other/Cursor.icns"
              "bare IMAGE stages every set, which is what PickerVariant Auto needs")
assert_missing("${BARE}/b/EFI/OC/Resources/Audio" "Audio is off by default")
run("picker bare" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/get_plist.py"
    "${BARE}/b/EFI/OC/config.plist" Misc/Boot/PickerVariant)
assert_matches("${LAST_OUTPUT}" "PickerVariant=<absent>"
               "naming no set leaves PickerVariant to the config")

step("a later oc_config_set still overrides it")
# Ops apply in declaration order, so oc_resources() writing a config key must not be
# special -- the project's own declaration comes later and wins, as for every default.
set(OVR "${WORK}/override")
file(REMOVE_RECURSE "${OVR}")
file(COPY "${FX}/" DESTINATION "${OVR}")
file(READ "${OVR}/CMakeLists.txt" ocml)
string(REPLACE "oc_efi()"
       "oc_config_set(Misc/Boot/PickerVariant STRING Mine)\noc_efi()" ocml "${ocml}")
file(WRITE "${OVR}/CMakeLists.txt" "${ocml}")
run("configure override" "${CMAKE_COMMAND}" -S "${OVR}" -B "${OVR}/b" ${gen} -DOC_ESP=${ESP})
run("build override" "${CMAKE_COMMAND}" --build "${OVR}/b")
run("picker override" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/get_plist.py"
    "${OVR}/b/EFI/OC/config.plist" Misc/Boot/PickerVariant)
assert_matches("${LAST_OUTPUT}" "PickerVariant='Mine'" "a later op wins")

step("a misspelled icon set is refused, and lists the ones that exist")
set(BADSET "${WORK}/badset")
file(REMOVE_RECURSE "${BADSET}")
file(COPY "${FX}/" DESTINATION "${BADSET}")
file(READ "${BADSET}/CMakeLists.txt" bcml)
string(REPLACE "IMAGE Acidanthera/Test" "IMAGE Acidanthera/Nope" bcml "${bcml}")
file(WRITE "${BADSET}/CMakeLists.txt" "${bcml}")
run_expect_fail("bad set" "${CMAKE_COMMAND}" -S "${BADSET}" -B "${BADSET}/b" ${gen})
assert_matches("${LAST_ERROR}" "has no Resources/Image/Acidanthera/Nope" "names what is missing")
assert_matches("${LAST_ERROR}" "Acidanthera/Test" "and lists what exists")

# --- ESP ---------------------------------------------------------------------
step("an ESP with another loader on it")
file(MAKE_DIRECTORY "${ESP}/EFI/OC/Kexts/Stale.kext" "${ESP}/EFI/Microsoft/Boot")
file(WRITE "${ESP}/EFI/OC/Kexts/Stale.kext/stale" "old")
file(WRITE "${ESP}/EFI/OC/OpenCore.efi" "old")
file(WRITE "${ESP}/EFI/Microsoft/Boot/bootmgfw.efi" "windows")

step("diff-esp reports what would change and touches nothing")
run("diff" "${CMAKE_COMMAND}" --build "${BUILD}" --target diff-esp)
assert_matches("${LAST_OUTPUT}" "OC/Kexts/Alpha.kext" "an added file is listed")
assert_matches("${LAST_OUTPUT}" ". OC/OpenCore.efi" "a changed file is listed")
assert_matches("${LAST_OUTPUT}" "left alone" "files outside OC/ are called out as untouched")
assert_exists("${ESP}/EFI/OC/Kexts/Stale.kext/stale" "diff changed nothing")
assert_missing("${WORK}/backups" "diff wrote no backup")

step("install-esp replaces OC/, keeps other loaders, and archives what it replaced")
run("install" "${CMAKE_COMMAND}" --build "${BUILD}" --target install-esp)
assert_exists("${ESP}/EFI/OC/Kexts/Alpha.kext/Contents/Info.plist" "the staged tree landed")
assert_missing("${ESP}/EFI/OC/Kexts/Stale.kext" "OC/ is replaced, not merged")
# The one that matters: EFI/ is shared with every other bootloader on the machine.
assert_exists("${ESP}/EFI/Microsoft/Boot/bootmgfw.efi" "another loader survived")
file(GLOB backups "${WORK}/backups/EFI-*.zip")
if(NOT backups)
  message(FATAL_ERROR "FAIL: install-esp wrote no backup archive")
endif()

step("a second install is a no-op")
run("reinstall" "${CMAKE_COMMAND}" --build "${BUILD}" --target install-esp)
assert_matches("${LAST_OUTPUT}" "up to date" "nothing left to do")
file(GLOB backups2 "${WORK}/backups/EFI-*.zip")
list(LENGTH backups2 nbackups)
if(NOT nbackups EQUAL 1)
  message(FATAL_ERROR "FAIL: a no-op install still wrote a backup (${nbackups} archives)")
endif()

step("OC_ESP_BACKUP=OFF skips the archive")
file(REMOVE_RECURSE "${ESP}/EFI/OC" "${WORK}/nobackup")
run("configure no-backup" "${CMAKE_COMMAND}" -S "${FX}" -B "${BUILD}" ${gen}
    -DOC_ESP=${ESP} -DOC_ESP_BACKUP_DIR=${WORK}/nobackup -DOC_ESP_BACKUP=OFF)
run("install no-backup" "${CMAKE_COMMAND}" --build "${BUILD}" --target install-esp)
assert_missing("${WORK}/nobackup" "no archive when the option is off")

step("a bad ESP path is refused, and says so")
run_expect_fail("bad esp" "${PYTHON}" "${OCMAKE_ROOT}/scripts/oc_esp.py"
    --efi "${EFI}" --mode diff --esp "${WORK}/does-not-exist")
assert_matches("${LAST_ERROR}" "OC_ESP is not a directory" "missing ESP diagnostic")

step("an unbuilt EFI is refused before anything is touched")
run_expect_fail("unbuilt" "${PYTHON}" "${OCMAKE_ROOT}/scripts/oc_esp.py"
    --efi "${WORK}/nothing-here" --mode install --esp "${ESP}")
assert_matches("${LAST_ERROR}" "not a built EFI tree" "unbuilt diagnostic")

# --- packaging ---------------------------------------------------------------
step("cpack produces a drop-in zip with EFI/ at its root")
run("cpack" "${CMAKE_CPACK_COMMAND}" -G ZIP --config "${BUILD}/CPackConfig.cmake"
    -B "${BUILD}")
file(GLOB pkg "${BUILD}/*.zip")
if(NOT pkg)
  message(FATAL_ERROR "FAIL: cpack produced no archive")
endif()
list(GET pkg 0 zip)
get_filename_component(zipname "${zip}" NAME)
if(NOT zipname MATCHES "OpenCore-1\\.0\\.7-RELEASE")
  message(FATAL_ERROR "FAIL: the package should be named after its OpenCore build: ${zipname}")
endif()
file(ARCHIVE_EXTRACT INPUT "${zip}" DESTINATION "${WORK}/unpacked")
assert_exists("${WORK}/unpacked/EFI/OC/OpenCore.efi" "EFI/ sits at the archive root")

# --- outdated ----------------------------------------------------------------
step("outdated reports every pin and never touches the network for a file:// one")
# Configure the other variant first so the lockfile actually holds both. Without this the
# lock has one entry per package and the de-duplication below cannot fail -- which is
# exactly how it passed with the fix removed the first time it was checked.
run("configure debug" "${CMAKE_COMMAND}" -S "${FX}" -B "${WORK}/dbg" ${gen}
    -DCMAKE_BUILD_TYPE=Debug -DOC_ESP=${ESP})
file(READ "${FX}/ocmake.lock" lock)
string(REGEX MATCHALL "BUILD \"DEBUG\"" dbg "${lock}")
if(NOT dbg)
  message(FATAL_ERROR "FAIL: the lock should now hold DEBUG entries:\n${lock}")
endif()
run("outdated" "${CMAKE_COMMAND}" -DOCMAKE_ROOT=${OCMAKE_ROOT} -DOC_LOCKFILE=${FX}/ocmake.lock
    -DOC_CACHE_DIR=${WORK}/cache -P "${OCMAKE_ROOT}/cmake/OCOutdated.cmake")
assert_matches("${LAST_OUTPUT}" "pinned by URL, not checked" "a file:// pin is reported, not resolved")
assert_matches("${LAST_OUTPUT}" "OpenCore" "every declaration gets a row")
# One row per declaration: RELEASE and DEBUG pin the same version and must not both ask.
string(REGEX MATCHALL "OpenCore +pinned" hits "${LAST_OUTPUT}")
list(LENGTH hits nhits)
if(NOT nhits EQUAL 1)
  message(FATAL_ERROR "FAIL: expected one OpenCore row, got ${nhits}:\n${LAST_OUTPUT}")
endif()

message(STATUS "install: PASS")
