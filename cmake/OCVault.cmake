# oc_vault(): Misc/Security/Vault, with the manifest built from the staged tree.

# A floor rather than an exact pin. The signing key is regenerated every build, so the
# version cannot affect the artefact, and the three calls used here have been stable for
# years -- whereas an exact pin would rot and eventually have no wheel for a new Python.
set(OC_CRYPTOGRAPHY "cryptography>=42" CACHE STRING
    "pip requirement providing RSA key generation and signing for oc_vault(SECUREBOOT)")

# oc_vault(<BASIC|SECUREBOOT> [<Release|Debug|All>] [EFI <name>])
#
#   BASIC       vault.plist only. OpenCore checks every file it loads against a SHA-256
#               manifest. The manifest is unauthenticated, so this catches a half-copied
#               tree or a stale file -- not an attacker, who would simply regenerate it.
#   SECUREBOOT  vault.plist, vault.sig, and the public key embedded into OpenCore.efi, so
#               the manifest can no longer be swapped without also replacing the binary
#               that verifies it.
#
# SECUREBOOT rather than OpenCore's own "Secure", because the name should say what it
# needs: the chain it builds terminates at OpenCore.efi, and only firmware UEFI Secure
# Boot verifies *that*. Without it an attacker replaces OpenCore.efi with one carrying
# their own key. OpenCore's documentation makes the same point in a footnote; here it is
# in the API.
#
# The second argument says which build variants to vault, and defaults to All. Vaulting
# only Release would quietly leave a Debug build unprotected, and plenty of people run
# Debug day to day -- they should not have to give up the vault to do it.
#
# Misc/Security/Vault is written as an ordinary config op at this call's position, so a
# later oc_config_set() on the same key still wins.
function(oc_vault)
  cmake_parse_arguments(A "" "EFI" "" ${ARGN})
  set(args "${A_UNPARSED_ARGUMENTS}")
  list(LENGTH args count)
  if(count LESS 1 OR count GREATER 2)
    message(FATAL_ERROR
      "OCMake: oc_vault(<BASIC|SECUREBOOT> [<Release|Debug|All>] [EFI <name>])")
  endif()

  list(GET args 0 mode)
  string(TOUPPER "${mode}" mode)
  if(NOT mode STREQUAL "BASIC" AND NOT mode STREQUAL "SECUREBOOT")
    message(FATAL_ERROR "OCMake: oc_vault() takes BASIC or SECUREBOOT, got '${mode}'")
  endif()

  set(scope "ALL")
  if(count EQUAL 2)
    list(GET args 1 scope)
    string(TOUPPER "${scope}" scope)
  endif()
  if(NOT scope MATCHES "^(RELEASE|DEBUG|ALL)$")
    message(FATAL_ERROR
      "OCMake: oc_vault()'s second argument is Release, Debug or All, got '${scope}'")
  endif()

  # Out of scope for this variant: no manifest, and Vault set to Optional rather than left
  # alone. Declaring oc_vault() at all says the project knows what the key means, so the
  # scoped-out variant should be *correct*, not merely untouched -- a base plist saying
  # Secure with no manifest beside it is a machine that stops at the picker.
  #
  # Scaffolding deliberately does not do this. There the user has said nothing yet, and
  # the sample's Secure is how they find out the setting exists.
  if(NOT scope STREQUAL "ALL" AND NOT scope STREQUAL "${OC_BUILD}")
    _oc_target(t "${A_EFI}")
    oc_config_set(Misc/Security/Vault STRING Optional EFI "${A_EFI}")
    return()
  endif()

  _oc_target(t "${A_EFI}")
  set(interpreter "${Python3_EXECUTABLE}")
  if(mode STREQUAL "SECUREBOOT")
    # Resolved here rather than at finalization so a missing environment is reported
    # against the oc_vault() line that asked for it. BASIC needs nothing but stdlib, and
    # deliberately does not touch this.
    _oc_python_env(interpreter MODULE cryptography REQUIRE "${OC_CRYPTOGRAPHY}"
                   REASON "signing a Secure vault")
    set(value "Secure")
  else()
    set(value "Basic")
  endif()

  set_property(TARGET ${t} PROPERTY OC_VAULT "${mode}")
  set_property(TARGET ${t} PROPERTY OC_VAULT_PYTHON "${interpreter}")
  oc_config_set(Misc/Security/Vault STRING "${value}" EFI "${A_EFI}")
endfunction()

# Adds the vault step. Returns its outputs in out_var, empty when not vaulting.
function(_oc_add_vault_step n t outdir config stamp out_var)
  set(${out_var} "" PARENT_SCOPE)
  get_property(mode TARGET ${t} PROPERTY OC_VAULT)
  if("${mode}" STREQUAL "")
    return()
  endif()
  if("${config}" STREQUAL "")
    message(FATAL_ERROR
      "OCMake: oc_vault() needs a config.plist -- Misc/Security/Vault lives in it, and a "
      "vault OpenCore is not told to check is just a file.")
  endif()
  if(NOT Python3_Interpreter_FOUND)
    message(FATAL_ERROR "OCMake: oc_vault() needs Python 3.9+, which was not found.")
  endif()
  get_property(interpreter TARGET ${t} PROPERTY OC_VAULT_PYTHON)

  set(vault "${outdir}/OC/vault.plist")
  set(outputs "${vault}")
  set(sign_args "")
  if(mode STREQUAL "SECUREBOOT")
    list(APPEND sign_args --sign)
    list(APPEND outputs "${outdir}/OC/vault.sig")
  endif()

  # Runs last: the manifest covers config.plist, so it cannot be built until the config
  # step has written its final bytes. Depending on the staging stamp as well as the config
  # output matters for SECUREBOOT -- signing patches the staged OpenCore.efi, and a restage
  # would put the unpatched one back while vault.sig still described the patched key.
  set(script "${OCMAKE_DIR}/scripts/oc_vault.py")
  add_custom_command(
    OUTPUT ${outputs}
    COMMAND "${interpreter}" "${script}" --oc-dir "${outdir}/OC" --out "${vault}"
            ${sign_args}
    DEPENDS "${config}" "${stamp}" "${script}"
    COMMENT "Building the ${mode} vault for '${n}'"
    VERBATIM)
  set(${out_var} "${outputs}" PARENT_SCOPE)
endfunction()
