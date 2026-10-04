# Validation and reporting: ocvalidate wiring, OCMake's own checks, and the BOM.
# No network -- the fixture ships a stub ocvalidate alongside its fake OpenCore package.

cmake_minimum_required(VERSION 3.25)
include(${CMAKE_CURRENT_LIST_DIR}/assert.cmake)

set(FX "${WORK}/fx")
set(BUILD "${WORK}/build")
set(EFI "${BUILD}/EFI")
set(CHECK "${OCMAKE_ROOT}/scripts/oc_check.py")
file(REMOVE_RECURSE "${WORK}")

step("generate fixture and build")
run("fixture" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/make_fixture.py" "${FX}" "${OCMAKE_ROOT}")
set(gen "")
if(GENERATOR)
  set(gen -G "${GENERATOR}")
endif()
run("configure" "${CMAKE_COMMAND}" -S "${FX}" -B "${BUILD}" ${gen})
run("build" "${CMAKE_COMMAND}" --build "${BUILD}")

step("ctest registers and passes both validation tests")
run("ctest" "${CMAKE_CTEST_COMMAND}" --test-dir "${BUILD}" --output-on-failure)
assert_matches("${LAST_OUTPUT}" "ocvalidate-fixture" "ocvalidate test registered")
assert_matches("${LAST_OUTPUT}" "occheck-fixture" "occheck test registered")
assert_matches("${LAST_OUTPUT}" "100% tests passed" "both pass on a good tree")

step("a BOM is written next to the EFI, with no timestamp")
assert_exists("${BUILD}/BOM.md" "BOM.md")
assert_exists("${BUILD}/BOM.json" "BOM.json")
file(READ "${BUILD}/BOM.md" bom)
assert_matches("${bom}" "OpenCore ..1.0.7.. .RELEASE." "BOM names the OpenCore build")
assert_matches("${bom}" "Alpha.kext" "BOM lists kexts")
assert_matches("${bom}" "## ACPI .0." "BOM renders an empty ACPI section")
assert_matches("${bom}" "## Kexts .3." "BOM counts kexts")

step("the BOM separates fetched from local kexts and cites each source")
assert_matches("${bom}" "### Fetched .2." "fetched group")
assert_matches("${bom}" "### Local .1." "local group")
assert_matches("${bom}" "Delta.kext .* .local/Delta.kext." "local kext cites its path")
assert_matches("${bom}" "Alpha.kext .* .flat.zip." "fetched kext cites what was downloaded")
assert_matches("${bom}" "OpenRuntime.efi" "BOM lists drivers")
# Drivers name their source too, so every section cites where its contents came from.
assert_matches("${bom}" "## Drivers .4. . Driver . Source ." "drivers render as a table")

step("a driver that did not come from OpenCore is not attributed to it")
# oc_driver(PATH ...) stages a fork, or a driver OpenCore does not ship. Before per-item
# provenance the report hardcoded the package as the source for every driver.
assert_matches("${bom}" ".Forked.efi. . .local/Forked.efi." "forked driver cites its own path")
# Same for one fetched by URL: it is neither the package nor a path in the repo.
assert_matches("${bom}" ".Remote.efi. . .Remote.efi." "URL driver cites what was downloaded")
string(REGEX MATCH "## Drivers[^#]*" drivers_section "${bom}")
if(NOT drivers_section MATCHES "opencore.zip")
  message(FATAL_ERROR "FAIL: package drivers should still cite the package:\n${drivers_section}")
endif()

step("rows differing only in the name fold into one")
# The two package drivers share every other field, so they become a single row with the
# names stacked -- markdown expresses a multi-line cell with <br>.
assert_matches("${drivers_section}" ".OpenCanopy.efi..br>.OpenRuntime.efi." "driver rows merged")

step("a source shared by consecutive rows is printed once")
# Count the link *label*, not the bare filename: it also appears inside the link target.
string(REGEX MATCHALL "\\[opencore.zip\\]" pkg_cites "${drivers_section}")
list(LENGTH pkg_cites n_cites)
if(NOT n_cites EQUAL 1)
  message(FATAL_ERROR
    "FAIL: two drivers share one source, so it should appear once, not ${n_cites} times:\n${drivers_section}")
endif()
run("bom json" "${PYTHON}" -c "import json, sys
d = json.load(open(sys.argv[1]))
print('kexts', len(d['kexts']))" "${BUILD}/BOM.json")
assert_matches("${LAST_OUTPUT}" "kexts 3" "BOM.json is machine-readable")

step("a rebuild produces an identical BOM")
# No timestamp inside, so the BOM only changes when the EFI does.
file(READ "${BUILD}/BOM.md" before)
run("rebuild" "${CMAKE_COMMAND}" --build "${BUILD}")
file(READ "${BUILD}/BOM.md" after)
if(NOT before STREQUAL after)
  message(FATAL_ERROR "FAIL: BOM changed across an unchanged rebuild")
endif()

# --- the checks that ocvalidate cannot make ---------------------------------
set(MANIFEST "${BUILD}/_oc/fixture-overrides.json")

function(mutate_config script)
  file(REMOVE_RECURSE "${WORK}/mut")
  file(COPY "${EFI}/" DESTINATION "${WORK}/mut")
  run("mutate" "${PYTHON}" -c "${script}" "${WORK}/mut/OC/config.plist")
  run_expect_fail("occheck" "${PYTHON}" "${CHECK}" --efi "${WORK}/mut" --manifest "${MANIFEST}")
  set(LAST_ERROR "${LAST_ERROR}" PARENT_SCOPE)
endfunction()

step("a kext in the plist but not on disk is caught")
file(REMOVE_RECURSE "${WORK}/mut")
file(COPY "${EFI}/" DESTINATION "${WORK}/mut")
file(REMOVE_RECURSE "${WORK}/mut/OC/Kexts/Alpha.kext")
run_expect_fail("missing kext" "${PYTHON}" "${CHECK}" --efi "${WORK}/mut" --manifest "${MANIFEST}")
assert_matches("${LAST_ERROR}" "missing-file. Kernel.Add references Alpha.kext" "missing kext")

step("a dependency loaded after its dependent is caught")
mutate_config("import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p,'rb'))
a = d['Kernel']['Add']
i = [n for n,e in enumerate(a) if e['BundlePath']=='Alpha.kext'][0]
a.append(a.pop(i))
plistlib.dump(d, open(p,'wb'))")
assert_matches("${LAST_ERROR}" "load-order. Beta.kext loads before" "load order")

step("MinKernel above MaxKernel is caught")
mutate_config("import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p,'rb'))
d['Kernel']['Add'][0]['MinKernel'] = '24.0.0'
d['Kernel']['Add'][0]['MaxKernel'] = '20.0.0'
plistlib.dump(d, open(p,'wb'))")
assert_matches("${LAST_ERROR}" "kernel-range" "kernel range")

step("a declared kext missing from Kernel.Add is caught")
mutate_config("import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p,'rb'))
d['Kernel']['Add'] = [e for e in d['Kernel']['Add'] if e['BundlePath'] != 'Delta.kext']
plistlib.dump(d, open(p,'wb'))")
assert_matches("${LAST_ERROR}" "declared-kexts. Delta.kext was declared" "declared but absent")

step("two kexts claiming one identifier over overlapping kernels are caught")
file(REMOVE_RECURSE "${WORK}/mut")
file(COPY "${EFI}/" DESTINATION "${WORK}/mut")
# Trailing slash copies the *contents*; without it the bundle nests inside itself.
file(COPY "${WORK}/mut/OC/Kexts/Alpha.kext/" DESTINATION "${WORK}/mut/OC/Kexts/Clone.kext")
run("clone entry" "${PYTHON}" -c "import copy, plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p,'rb'))
e = copy.deepcopy([x for x in d['Kernel']['Add'] if x['BundlePath']=='Alpha.kext'][0])
e['BundlePath'] = 'Clone.kext'
d['Kernel']['Add'].append(e)
plistlib.dump(d, open(p,'wb'))" "${WORK}/mut/OC/config.plist")
run_expect_fail("dupe" "${PYTHON}" "${CHECK}" --efi "${WORK}/mut" --manifest "${MANIFEST}")
assert_matches("${LAST_ERROR}" "duplicate-identifier" "duplicate identifier")

step("OpenCanopy with an empty Resources/ is caught")
# Nothing in config.plist references the picker's icons, font or labels, so no other check
# can notice they were never staged. The symptom on hardware is a black screen at boot.
mutate_config("import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p,'rb'))
d['Misc']['Boot']['PickerMode'] = 'External'
plistlib.dump(d, open(p,'wb'))")
assert_matches("${LAST_ERROR}" "picker-resources. OpenCanopy is enabled" "empty picker resources")

# --- vaulting ----------------------------------------------------------------
step("oc_vault() writes a manifest of the staged tree and turns Vault on")
# Vault Basic makes OpenCore refuse any file whose digest disagrees, so a stale manifest is
# a machine that stops at the picker. That is why it is a build step and not a script you
# remember to re-run.
set(VLT "${WORK}/vault")
file(REMOVE_RECURSE "${VLT}")
file(COPY "${FX}/" DESTINATION "${VLT}")
file(READ "${VLT}/CMakeLists.txt" vcml)
string(REPLACE "oc_efi()" "oc_vault(BASIC All)\noc_efi()" vcml "${vcml}")
file(WRITE "${VLT}/CMakeLists.txt" "${vcml}")
run("configure vault" "${CMAKE_COMMAND}" -S "${VLT}" -B "${VLT}/b" ${gen})
run("build vault" "${CMAKE_COMMAND}" --build "${VLT}/b")
assert_exists("${VLT}/b/EFI/OC/vault.plist" "vault.plist written")
run("vault keys" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/get_plist.py"
    "${VLT}/b/EFI/OC/config.plist" Misc/Security/Vault)
assert_matches("${LAST_OUTPUT}" "Vault='Basic'" "Misc/Security/Vault declared")

step("the manifest covers config.plist and excludes what OpenCore cannot hash")
# OpenCore.efi is excluded because it is the thing doing the verifying, and vault.* because
# they are the manifest itself. Both exclusions come from OpenCorePkg's create_vault.sh.
run("vault dump" "${PYTHON}" "-c"
"import plistlib,sys
f=plistlib.load(open(sys.argv[1],'rb'))['Files']
print('count', len(f))
print('has-config', 'config.plist' in f)
print('has-self', 'vault.plist' in f)
print('has-opencore', 'OpenCore.efi' in f)
print('sep', [k for k in f if 'Kexts' in k][:1])"
    "${VLT}/b/EFI/OC/vault.plist")
assert_matches("${LAST_OUTPUT}" "has-config True" "config.plist is hashed")
assert_matches("${LAST_OUTPUT}" "has-self False" "vault.plist is not")
assert_matches("${LAST_OUTPUT}" "has-opencore False" "nor is OpenCore.efi")
assert_matches("${LAST_OUTPUT}" "Kexts.\\\\." "paths use backslashes, as OpenCore reads them")

step("occheck recomputes the manifest and catches a tree that has drifted")
run("occheck vault" "${PYTHON}" "${CHECK}" --efi "${VLT}/b/EFI"
    --manifest "${VLT}/b/_oc/fixture-overrides.json")
file(APPEND "${VLT}/b/EFI/OC/Drivers/OpenRuntime.efi" "tampered")
run_expect_fail("occheck tampered" "${PYTHON}" "${CHECK}" --efi "${VLT}/b/EFI"
    --manifest "${VLT}/b/_oc/fixture-overrides.json")
assert_matches("${LAST_ERROR}" "does not match its vault.plist digest" "the drifted file is named")

step("the variant scope decides whether there is a vault at all")
# oc_vault(BASIC Debug) in a Release build must leave no manifest *and* no Vault key: a
# config claiming Basic with nothing to check against is a machine that stops at the picker.
set(SCOPED "${WORK}/scoped")
file(REMOVE_RECURSE "${SCOPED}")
file(COPY "${FX}/" DESTINATION "${SCOPED}")
file(READ "${SCOPED}/CMakeLists.txt" scml)
string(REPLACE "oc_efi()" "oc_vault(BASIC Debug)\noc_efi()" scml "${scml}")
file(WRITE "${SCOPED}/CMakeLists.txt" "${scml}")
run("configure scoped" "${CMAKE_COMMAND}" -S "${SCOPED}" -B "${SCOPED}/b" ${gen}
    -DCMAKE_BUILD_TYPE=Release)
run("build scoped" "${CMAKE_COMMAND}" --build "${SCOPED}/b")
assert_missing("${SCOPED}/b/EFI/OC/vault.plist" "no manifest for an out-of-scope variant")
run("scoped vault key" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/get_plist.py"
    "${SCOPED}/b/EFI/OC/config.plist" Misc/Security/Vault)
# Optional, not merely untouched. Declaring oc_vault() at all says the project knows what
# the key means, so the scoped-out variant is made correct rather than left as the base had
# it -- a base saying Secure with no manifest is a machine that stops at the picker.
assert_matches("${LAST_OUTPUT}" "Vault='Optional'" "the scoped-out variant is set correct")

step("oc_vault() rejects a mode or a scope it does not have")
function(bad_vault name body)
  set(dir "${WORK}/badvault-${name}")
  file(REMOVE_RECURSE "${dir}")
  file(COPY "${FX}/" DESTINATION "${dir}")
  file(READ "${dir}/CMakeLists.txt" bcml)
  string(REPLACE "oc_efi()" "${body}\noc_efi()" bcml "${bcml}")
  file(WRITE "${dir}/CMakeLists.txt" "${bcml}")
  run_expect_fail("${name}" "${CMAKE_COMMAND}" -S "${dir}" -B "${dir}/b" ${gen})
  set(LAST_ERROR "${LAST_ERROR}" PARENT_SCOPE)
endfunction()
bad_vault(mode "oc_vault(SECURE)")
assert_matches("${LAST_ERROR}" "takes BASIC or SECUREBOOT" "the modes are named")
bad_vault(scope "oc_vault(BASIC Sometimes)")
assert_matches("${LAST_ERROR}" "Release, Debug or All" "the scopes are named")
bad_vault(empty "oc_vault()")
assert_matches("${LAST_ERROR}" "BASIC.SECUREBOOT" "and the signature is shown")

# SECUREBOOT signs with pyca/cryptography. OCMake would provision it, but this test is
# network-free by contract, so it asks whether one is already available and skips rather
# than reaching for the network. CI installs it so the branch always runs there.
execute_process(COMMAND "${PYTHON}" -c "import cryptography"
                RESULT_VARIABLE has_crypto OUTPUT_QUIET ERROR_QUIET)
set(SIGNER "${PYTHON}")
if(NOT has_crypto EQUAL 0)
  # The environment OCMake manages, if some earlier build already provisioned it.
  execute_process(COMMAND "${PYTHON}" -c
                  "import sys;print('{}.{}'.format(*sys.version_info[:2]))"
                  OUTPUT_VARIABLE pytag OUTPUT_STRIP_TRAILING_WHITESPACE)
  set(managed "$ENV{HOME}/.cache/ocmake/python-${pytag}/bin/python")
  if(EXISTS "${managed}")
    execute_process(COMMAND "${managed}" -c "import cryptography"
                    RESULT_VARIABLE has_crypto OUTPUT_QUIET ERROR_QUIET)
    set(SIGNER "${managed}")
  endif()
endif()
if(NOT has_crypto EQUAL 0)
  message(STATUS "  .. (skipped SECUREBOOT: no cryptography available without fetching it)")
endif()
if(has_crypto EQUAL 0)
  step("SECUREBOOT signs the manifest and embeds the key in OpenCore.efi")
  set(SB "${WORK}/secureboot")
  file(REMOVE_RECURSE "${SB}")
  file(COPY "${FX}/" DESTINATION "${SB}")
  file(READ "${SB}/CMakeLists.txt" sbcml)
  string(REPLACE "oc_efi()" "oc_vault(SECUREBOOT All)\noc_efi()" sbcml "${sbcml}")
  file(WRITE "${SB}/CMakeLists.txt" "${sbcml}")
  run("configure secureboot" "${CMAKE_COMMAND}" -S "${SB}" -B "${SB}/b" ${gen}
      -DPython3_EXECUTABLE=${SIGNER})
  run("build secureboot" "${CMAKE_COMMAND}" --build "${SB}/b")
  assert_exists("${SB}/b/EFI/OC/vault.sig" "vault.sig written")
  run("secureboot vault key" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/get_plist.py"
      "${SB}/b/EFI/OC/config.plist" Misc/Security/Vault)
  assert_matches("${LAST_OUTPUT}" "Vault='Secure'" "Vault declared Secure")

  step("a binary with no key slot is refused rather than silently unsigned")
  set(NOSLOT "${WORK}/noslot")
  file(REMOVE_RECURSE "${NOSLOT}")
  file(COPY "${SB}/b/EFI/OC/" DESTINATION "${NOSLOT}")
  file(WRITE "${NOSLOT}/OpenCore.efi" "MZ not really opencore")
  run_expect_fail("noslot" "${SIGNER}" "${OCMAKE_ROOT}/scripts/oc_vault.py"
      --oc-dir "${NOSLOT}" --out "${NOSLOT}/vault.plist" --sign)
  assert_matches("${LAST_ERROR}" "no OC VAULT markers" "the missing slot is named")

  step("the signature verifies against the key embedded in OpenCore.efi")
  # Checked the way OpenCore checks it -- raw RSA-2048 over the SHA-256 of vault.plist,
  # against the key read back out of the patched binary. Nothing here trusts the generator.
  run("verify chain" "${PYTHON}" "${CMAKE_CURRENT_LIST_DIR}/verify_vault.py" "${SB}/b/EFI/OC")
  assert_matches("${LAST_OUTPUT}" "chain OK" "the embedded key signs this manifest")
endif()

message(STATUS "validate: PASS")
