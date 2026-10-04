# ESP install/diff targets, the `outdated` target, and CPack packaging.

# Adds install-esp-<n>, diff-esp-<n> and outdated-<n> for one EFI.
function(_oc_add_install_targets n t outdir)
  if(NOT Python3_Interpreter_FOUND)
    return()  # every one of these is a Python script
  endif()
  set(esp "${OCMAKE_DIR}/scripts/oc_esp.py")
  set(backup_args "")
  if(NOT OC_ESP_BACKUP)
    set(backup_args --no-backup)
  endif()
  if(NOT "${OC_ESP_BACKUP_DIR}" STREQUAL "")
    list(APPEND backup_args --backup-dir "${OC_ESP_BACKUP_DIR}")
  endif()

  # Both depend on efi-<n>: comparing or installing a stale tree is never what was meant.
  add_custom_target(diff-esp-${n}
    COMMAND "${Python3_EXECUTABLE}" "${esp}" --efi "${outdir}" --mode diff --esp "${OC_ESP}"
    DEPENDS efi-${n}
    COMMENT "Comparing '${n}' with the ESP"
    VERBATIM USES_TERMINAL)

  add_custom_target(install-esp-${n}
    COMMAND "${Python3_EXECUTABLE}" "${esp}" --efi "${outdir}" --mode install
            --esp "${OC_ESP}" ${backup_args}
    DEPENDS efi-${n}
    COMMENT "Installing '${n}' onto the ESP"
    VERBATIM USES_TERMINAL)

  add_custom_target(outdated-${n}
    COMMAND "${CMAKE_COMMAND}" -DOCMAKE_ROOT=${OCMAKE_DIR} -DOC_LOCKFILE=${OC_LOCKFILE}
            -DOC_CACHE_DIR=${OC_CACHE_DIR} -P "${OCMAKE_DIR}/cmake/OCOutdated.cmake"
    COMMENT "Checking for newer versions of everything '${n}' pins"
    VERBATIM USES_TERMINAL)
endfunction()

# With a single EFI the suffix is noise, so every per-EFI target gets a bare alias. With
# several there is nothing sensible for a bare name to mean, so they are not created.
function(_oc_add_target_aliases n)
  foreach(base validate report diff-esp install-esp outdated)
    if(TARGET ${base}-${n} AND NOT TARGET ${base})
      add_custom_target(${base})
      add_dependencies(${base} ${base}-${n})
    endif()
  endforeach()
endfunction()

# `cpack -G ZIP` in the build directory produces the staged EFI as one archive: what you
# hand someone, or attach to a release, without asking them to run CMake at all.
function(_oc_add_packaging n t)
  if(NOT OC_PACKAGE)
    return()
  endif()
  # CPack is a per-project singleton, and every EFI packs to the archive root. With more
  # than one the second include(CPack) would win and the zip would hold a mixture, which is
  # the same collision the install guard refuses -- so there is nothing sensible to
  # register.
  get_property(efis GLOBAL PROPERTY OC_EFIS)
  list(LENGTH efis efi_count)
  if(efi_count GREATER 1)
    _oc_info("'${n}': no cpack target -- this project builds ${efi_count} EFIs and they "
             "would pack to the same archive root")
    return()
  endif()
  get_property(ver   TARGET ${t} PROPERTY OC_OPENCORE_VER)
  get_property(build TARGET ${t} PROPERTY OC_OPENCORE_BUILD)
  set(CPACK_GENERATOR "ZIP")
  set(CPACK_PACKAGE_NAME "${n}")
  set(CPACK_PACKAGE_VENDOR "OCMake")
  set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "OpenCore EFI for ${n}")
  # Named after what is inside it rather than a project version: the thing that decides
  # whether two of these archives are interchangeable is the OpenCore build.
  set(CPACK_PACKAGE_FILE_NAME "${n}-EFI-OpenCore-${ver}-${build}")
  set(CPACK_PACKAGE_VERSION "${ver}")
  set(CPACK_VERBATIM_VARIABLES TRUE)
  set(CPACK_INCLUDE_TOPLEVEL_DIRECTORY OFF)  # EFI/ at the archive root, drop-in ready
  set(CPACK_SOURCE_GENERATOR "")
  include(CPack)
endfunction()
