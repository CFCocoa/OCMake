# Validation and reporting: ocvalidate, OCMake's own sanity checks, and the BOM.

# The OpenCore package ships a version-matched ocvalidate for all three platforms, so the
# validator always matches the OpenCore being staged -- it refuses to check other versions.
function(_oc_find_ocvalidate pkg out)
  if(WIN32)
    set(name "ocvalidate.exe")
  elseif(APPLE)
    set(name "ocvalidate")
  else()
    set(name "ocvalidate.linux")
  endif()
  set(path "${pkg}/Utilities/ocvalidate/${name}")
  if(NOT EXISTS "${path}")
    set(${out} "" PARENT_SCOPE)
    return()
  endif()
  # Zip extraction does not preserve the executable bit.
  file(CHMOD "${path}" PERMISSIONS
       OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
  set(${out} "${path}" PARENT_SCOPE)
endfunction()

# Serialise recorded provenance for the BOM.
function(_oc_write_provenance t file)
  set(doc "")
  foreach(pair "KEXT;kexts" "ACPI;acpi" "DRIVERS;drivers" "TOOLS;tools"
               "RESOURCES;resources" "PKG;packages")
    list(GET pair 0 kind)
    list(GET pair 1 label)
    get_property(items TARGET ${t} PROPERTY OC_PROV_${kind})
    set(entries "")
    if(items)
      list(REMOVE_DUPLICATES items)
      list(SORT items)
    endif()
    foreach(item IN LISTS items)
      string(REGEX REPLACE "[^A-Za-z0-9]" "_" tok "${kind}_${item}")
      set(fields "")
      foreach(fpair "ORIGIN;origin" "REPO;repo" "VERSION;version" "URL;url" "SOURCE;source")
        list(GET fpair 0 f)
        list(GET fpair 1 key)
        get_property(v TARGET ${t} PROPERTY OC_PROV_${tok}_${f})
        if(NOT "${v}" STREQUAL "")
          _oc_json_str("${key}" kj)
          _oc_json_str("${v}" vj)
          if(fields)
            string(APPEND fields ",")
          endif()
          string(APPEND fields "${kj}:${vj}")
        endif()
      endforeach()
      _oc_json_str("${item}" ij)
      if(entries)
        string(APPEND entries ",")
      endif()
      string(APPEND entries "${ij}:{${fields}}")
    endforeach()
    _oc_json_str("${label}" lj)
    if(doc)
      string(APPEND doc ",")
    endif()
    string(APPEND doc "${lj}:{${entries}}")
  endforeach()
  file(WRITE "${file}" "{${doc}}\n")
endfunction()

# Adds the validate/report targets and registers ctest tests for one EFI.
function(_oc_add_validation n t outdir config)
  if(NOT config)
    return()  # nothing to validate without a config.plist
  endif()
  get_property(pkg TARGET ${t} PROPERTY OC_OPENCORE_PKG)
  get_property(ver TARGET ${t} PROPERTY OC_OPENCORE_VER)
  get_property(build TARGET ${t} PROPERTY OC_OPENCORE_BUILD)
  _oc_find_ocvalidate("${pkg}" ocvalidate)

  set(checks "${OCMAKE_DIR}/scripts/oc_check.py")
  set(reporter "${OCMAKE_DIR}/scripts/oc_report.py")
  set(manifest "${CMAKE_BINARY_DIR}/_oc/${n}-overrides.json")
  set(provenance "${CMAKE_BINARY_DIR}/_oc/${n}-provenance.json")
  _oc_write_provenance(${t} "${provenance}")

  # --- report: regenerated with every build, so the BOM is never stale
  get_filename_component(bomdir "${outdir}" DIRECTORY)   # next to EFI/, not inside it
  set(bom_md "${bomdir}/BOM.md")
  set(bom_json "${bomdir}/BOM.json")
  add_custom_command(
    OUTPUT "${bom_md}" "${bom_json}"
    COMMAND "${Python3_EXECUTABLE}" "${reporter}"
            --efi "${outdir}" --oc-version "${ver}" --oc-build "${build}"
            --name "${n}" --provenance "${provenance}"
            --markdown "${bom_md}" --json "${bom_json}"
    DEPENDS "${config}" "${reporter}" "${provenance}"
    COMMENT "Writing BOM for '${n}'"
    VERBATIM)
  set_property(TARGET ${t} PROPERTY OC_BOM_OUTPUTS "${bom_md}" "${bom_json}")

  add_custom_target(report-${n}
    COMMAND "${CMAKE_COMMAND}" -E cat "${bom_md}"
    DEPENDS "${bom_md}"
    COMMENT "Bill of materials for '${n}'"
    VERBATIM)

  # --- validate: ocvalidate plus OCMake's own checks, on demand
  set(validate_cmds "")
  if(ocvalidate)
    list(APPEND validate_cmds COMMAND "${ocvalidate}" "${config}")
  endif()
  add_custom_target(validate-${n}
    ${validate_cmds}
    COMMAND "${Python3_EXECUTABLE}" "${checks}" --efi "${outdir}" --manifest "${manifest}"
    DEPENDS "${config}"
    COMMENT "Validating '${n}'"
    VERBATIM)

  # --- the same, as ctest tests, so `ctest` after a build checks everything.
  # enable_testing() is called from OCMake.cmake at include time; see the note there.
  if(ocvalidate)
    add_test(NAME "ocvalidate-${n}" COMMAND "${ocvalidate}" "${config}")
  endif()
  add_test(NAME "occheck-${n}"
           COMMAND "${Python3_EXECUTABLE}" "${checks}" --efi "${outdir}" --manifest "${manifest}")
endfunction()
