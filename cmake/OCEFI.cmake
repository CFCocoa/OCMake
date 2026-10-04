# oc_efi() and finalization: staging manifest, build targets, install rules.

# oc_efi([<name>] [OUTPUT_DIR <dir>])
#
# Names the EFI that the declarations after it belong to, for the rest of the enclosing
# scope. Put it at the top of a machine's CMakeLists.txt, or use it as a section marker in
# a flat file:
#
#   oc_efi(desktop)
#   oc_kext(AppleALC GITHUB acidanthera/AppleALC)   # no EFI keyword needed
#
# Still optional, and still position-independent: finalization is deferred either way, and
# a single-EFI project needs no call at all. `EFI <name>` on an individual declaration
# always wins over the scope this sets, which is what lets one loop declare shared kexts
# for several machines.
#
# The scope is set here rather than by writing OC_EFI directly because a function can
# reject what it does not understand. A misspelled variable cannot: it simply goes unread,
# the PROJECT_NAME fallback takes over, and the declarations land on an EFI nobody named.
function(oc_efi)
  cmake_parse_arguments(A "" "OUTPUT_DIR" "" ${ARGN})
  if(A_KEYWORDS_MISSING_VALUES)
    string(REPLACE ";" ", " missing "${A_KEYWORDS_MISSING_VALUES}")
    message(FATAL_ERROR "OCMake: oc_efi(): ${missing} needs a value")
  endif()
  set(name "")
  list(LENGTH A_UNPARSED_ARGUMENTS extra)
  if(extra GREATER 1)
    string(REPLACE ";" " " listing "${A_UNPARSED_ARGUMENTS}")
    message(FATAL_ERROR
      "OCMake: oc_efi([<name>] [OUTPUT_DIR <dir>]) takes one name, got '${listing}'")
  elseif(extra EQUAL 1)
    list(GET A_UNPARSED_ARGUMENTS 0 name)
  endif()

  _oc_target(t "${name}")
  if(A_OUTPUT_DIR)
    set_property(TARGET ${t} PROPERTY OC_OUTPUT_DIR "${A_OUTPUT_DIR}")
  endif()
  get_property(resolved TARGET ${t} PROPERTY OC_NAME)
  set(OC_EFI "${resolved}" PARENT_SCOPE)
endfunction()

# Append one copy instruction to the generated manifest, and register both the source
# files (as DEPENDS) and the staged files (as OUTPUT).
#
# Declaring the real staged files -- rather than only a stamp -- is what makes the EFI
# tree a tracked build output: delete anything inside it and the next build restores it.
# A stamp alone lets a half-deleted tree look up to date, which cmake --install would
# then happily copy onto a USB.
function(_oc_stage_add lines_var deps_var outs_var src dst)
  set(l "${${lines_var}}")
  string(APPEND l "oc_stage_copy(\"${src}\" \"${dst}\")\n")
  set(${lines_var} "${l}" PARENT_SCOPE)

  set(d "${${deps_var}}")
  set(o "${${outs_var}}")
  if(IS_DIRECTORY "${src}")
    # Enumerate now: extraction already happened at configure time, so this list is in
    # sync with what will be copied. Same glob semantics as OCStage uses when touching.
    file(GLOB_RECURSE files LIST_DIRECTORIES false RELATIVE "${src}" "${src}/*")
    foreach(f IN LISTS files)
      if(NOT f MATCHES "(^|/)(\\.DS_Store|__MACOSX)(/|$)")
        list(APPEND d "${src}/${f}")
        list(APPEND o "${OC_STAGE_OUTDIR}/${dst}/${f}")
      endif()
    endforeach()
  else()
    list(APPEND d "${src}")
    list(APPEND o "${OC_STAGE_OUTDIR}/${dst}")
  endif()
  set(${deps_var} "${d}" PARENT_SCOPE)
  set(${outs_var} "${o}" PARENT_SCOPE)
endfunction()

function(_oc_finalize_all)
  get_property(efis GLOBAL PROPERTY OC_EFIS)
  if(NOT efis)
    return()
  endif()
  add_custom_target(efi ALL)

  # Every EFI installs to <prefix>/EFI, because that is the only layout firmware looks for.
  # With more than one that means they would overwrite each other, and `cmake --install`
  # would quietly leave a mixture of two trees on the USB stick. Registered before the
  # per-EFI rules so it stops the install before anything is copied.
  list(LENGTH efis count)
  if(count GREATER 1)
    string(REPLACE ";" ", " names "${efis}")
    install(CODE "
      if(NOT CMAKE_INSTALL_COMPONENT)
        message(FATAL_ERROR
          \"OCMake: this project builds ${count} EFIs (${names}), and each installs to \"
          \"<prefix>/EFI -- installing them together would overwrite one with another.\\n\"
          \"Install one at a time:\\n\"
          \"  cmake --install <build> --component <name> --prefix <path>\")
      endif()")
  endif()

  foreach(n IN LISTS efis)
    _oc_finalize_one("${n}")
    add_dependencies(efi efi-${n})
  endforeach()

  # With more than one EFI, say what each ended up with. Which EFI a declaration belongs to
  # is decided by an EFI keyword or by the enclosing oc_efi() scope, and putting one in the
  # wrong place is valid CMake that no check can catch -- so the resolution is reported
  # rather than enforced, at configure time instead of in a BOM after a build.
  if(count GREATER 1)
    set(summary "")
    foreach(n IN LISTS efis)
      _oc_efi_contents("oc_${n}" what)
      if(summary)
        string(APPEND summary ", ")
      endif()
      string(APPEND summary "${n} (${what})")
    endforeach()
    _oc_info("${count} EFIs: ${summary}")
  endif()
  if(count EQUAL 1)
    _oc_add_target_aliases("${efis}")
  endif()
  _oc_lock_flush()
endfunction()

# "6 kexts, 2 ACPI, 3 drivers" -- only the parts that are actually there.
function(_oc_efi_contents t out)
  set(parts "")
  foreach(pair "OC_KEXT_SRCS;kexts" "OC_ACPI_SRCS;ACPI" "OC_DRIVERS;drivers"
               "OC_TOOLS;tools" "OC_RES_DSTS;resource sets")
    list(GET pair 0 prop)
    list(GET pair 1 label)
    get_property(items TARGET ${t} PROPERTY ${prop})
    list(LENGTH items n)
    # Drivers and tools can also arrive as local or fetched files.
    if(prop STREQUAL "OC_DRIVERS" OR prop STREQUAL "OC_TOOLS")
      get_property(extra TARGET ${t} PROPERTY ${prop}_PATHS)
      list(LENGTH extra m)
      math(EXPR n "${n}+${m}")
    endif()
    if(n GREATER 0)
      if(n EQUAL 1)
        string(REGEX REPLACE "s$" "" label "${label}")   # "1 kext", not "1 kexts"
      endif()
      list(APPEND parts "${n} ${label}")
    endif()
  endforeach()
  if(NOT parts)
    set(parts "nothing declared")
  endif()
  string(REPLACE ";" ", " parts "${parts}")
  set(${out} "${parts}" PARENT_SCOPE)
endfunction()

function(_oc_finalize_one n)
  set(t "oc_${n}")
  get_property(root   TARGET ${t} PROPERTY OC_OPENCORE_ROOT)
  get_property(outdir TARGET ${t} PROPERTY OC_OUTPUT_DIR)
  get_property(ver    TARGET ${t} PROPERTY OC_OPENCORE_VER)
  get_property(build  TARGET ${t} PROPERTY OC_OPENCORE_BUILD)

  if(NOT root)
    message(FATAL_ERROR
      "OCMake: EFI '${n}' has no OpenCore package. Add oc_opencore(VERSION <x.y.z>).")
  endif()

  # Fill in the conventional file names the project did not declare, then say what the
  # built-in defaults actually did -- a default that silently rewrites config.plist is
  # exactly the kind of thing that should be on screen.
  _oc_default_files("${n}" "${t}" defaults)
  get_property(opdefaults TARGET ${t} PROPERTY OC_DEFAULTS_APPLIED)
  list(APPEND defaults ${opdefaults})
  if(NOT "${defaults}" STREQUAL "")
    string(REPLACE ";" ", " listing "${defaults}")
    _oc_info("'${n}' defaults: ${listing}")
  endif()

  # A declared config.plist that is not on disk yet is a new project, not a mistake: it is
  # created from the OpenCore package's own sample, with the four derived sections emptied.
  get_property(base TARGET ${t} PROPERTY OC_CONFIG_BASE)
  if(NOT "${base}" STREQUAL "" AND NOT EXISTS "${base}")
    _oc_scaffold_config("${n}" "${t}" "${base}")
    if(NOT EXISTS "${base}")
      set_property(TARGET ${t} PROPERTY OC_CONFIG_BASE "")   # scaffolding declined
      set(base "")
    endif()
  endif()

  # No config.plist at all is legal -- examples/minimal clears OC_DEFAULT_CONFIG to stay a
  # bare OpenCore tree -- but it does not boot, so say so rather than quietly skipping.
  if("${base}" STREQUAL "")
    _oc_info("'${n}' has no config.plist (OC_DEFAULT_CONFIG is empty and no oc_config()); "
             "ocvalidate, occheck and the BOM are skipped")
  endif()

  # Before the staging manifest: staging depends on the .aml files these rules produce.
  _oc_add_acpi_steps("${t}")

  set(lines "# Generated by OCMake ${OCMAKE_VERSION} -- do not edit.\n")
  set(deps "")
  set(outs "")
  set(OC_STAGE_OUTDIR "${outdir}")

  _oc_stage_add(lines deps outs "${root}/EFI/BOOT/BOOTx64.efi" "BOOT/BOOTx64.efi")
  _oc_stage_add(lines deps outs "${root}/EFI/OC/OpenCore.efi"  "OC/OpenCore.efi")

  # OpenCore's package ships these as empty directories, and OCSnapshot refuses to run
  # without them ("Incorrect OC Folder Structure"), so recreate them even when nothing
  # is staged into them.
  foreach(d ACPI Drivers Kexts Resources Tools)
    string(APPEND lines "oc_stage_mkdir(\"OC/${d}\")\n")
  endforeach()

  # ACPI tables: compiled .aml files do not exist until build time, which is fine --
  # _oc_stage_add records them as dependencies, so staging waits for iasl.
  get_property(acpi TARGET ${t} PROPERTY OC_ACPI_SRCS)
  set(seen_acpi "")
  foreach(a IN LISTS acpi)
    get_filename_component(an "${a}" NAME)
    if(an IN_LIST seen_acpi)
      message(FATAL_ERROR "OCMake: ACPI table '${an}' is declared more than once for EFI '${n}'")
    endif()
    list(APPEND seen_acpi "${an}")
    _oc_stage_add(lines deps outs "${a}" "OC/ACPI/${an}")
  endforeach()

  # Picker resources: whole directories, staged structure-intact under OC/Resources.
  get_property(res_srcs TARGET ${t} PROPERTY OC_RES_SRCS)
  get_property(res_dsts TARGET ${t} PROPERTY OC_RES_DSTS)
  if(res_srcs)
    list(LENGTH res_srcs res_count)
    math(EXPR res_last "${res_count}-1")
    foreach(i RANGE ${res_last})
      list(GET res_srcs ${i} rsrc)
      list(GET res_dsts ${i} rdst)
      _oc_stage_add(lines deps outs "${rsrc}" "OC/${rdst}")
    endforeach()
  endif()

  # Kexts. Duplicate bundle names would silently overwrite each other in OC/Kexts.
  get_property(ksrcs TARGET ${t} PROPERTY OC_KEXT_SRCS)
  set(seen "")
  foreach(k IN LISTS ksrcs)
    get_filename_component(bn "${k}" NAME)
    if(bn IN_LIST seen)
      message(FATAL_ERROR "OCMake: '${bn}' is declared more than once for EFI '${n}'")
    endif()
    list(APPEND seen "${bn}")
    _oc_stage_add(lines deps outs "${k}" "OC/Kexts/${bn}")
  endforeach()

  # Drivers and tools come out of the OpenCore package itself.
  foreach(kind "Drivers;OC_DRIVERS" "Tools;OC_TOOLS")
    list(GET kind 0 dir)
    list(GET kind 1 prop)
    get_property(items TARGET ${t} PROPERTY ${prop})
    foreach(f IN LISTS items)
      set(src "${root}/EFI/OC/${dir}/${f}")
      if(NOT EXISTS "${src}")
        file(GLOB avail RELATIVE "${root}/EFI/OC/${dir}" "${root}/EFI/OC/${dir}/*.efi")
        list(SORT avail)
        string(REPLACE ";" "\n    " listing "${avail}")
        message(FATAL_ERROR
          "OCMake: '${f}' is not in the OpenCore package's ${dir}/.\nAvailable:\n    ${listing}")
      endif()
      _oc_stage_add(lines deps outs "${src}" "OC/${dir}/${f}")
    endforeach()
    get_property(local TARGET ${t} PROPERTY ${prop}_PATHS)
    foreach(f IN LISTS local)
      get_filename_component(bn "${f}" NAME)
      _oc_stage_add(lines deps outs "${f}" "OC/${dir}/${bn}")
    endforeach()
  endforeach()

  # OpenCore ships .contentFlavour/.contentVisibility next to both binaries; they drive
  # picker icon flavour and entry visibility, and are easy to lose in a naive copy.
  foreach(d "BOOT" "OC")
    foreach(f ".contentFlavour" ".contentVisibility")
      if(EXISTS "${root}/EFI/${d}/${f}")
        _oc_stage_add(lines deps outs "${root}/EFI/${d}/${f}" "${d}/${f}")
      endif()
    endforeach()
  endforeach()

  set(manifest "${CMAKE_BINARY_DIR}/_oc/${n}-stage.cmake")
  set(stamp    "${CMAKE_BINARY_DIR}/_oc/${n}-stage.stamp")
  file(WRITE "${manifest}" "${lines}")

  add_custom_command(
    OUTPUT ${outs} "${stamp}"
    COMMAND "${CMAKE_COMMAND}" -DOC_MANIFEST=${manifest} -DOC_EFI_DIR=${outdir}
            -P "${OCMAKE_DIR}/cmake/OCStage.cmake"
    COMMAND "${CMAKE_COMMAND}" -E touch "${stamp}"
    DEPENDS "${manifest}" ${deps}
    COMMENT "Staging EFI '${n}' (OpenCore ${ver} ${build}) -> ${outdir}"
    VERBATIM)
  _oc_add_config_step("${n}" "${t}" "${outdir}" "${stamp}" configout)
  _oc_add_vault_step("${n}" "${t}" "${outdir}" "${configout}" "${stamp}" vaultout)
  _oc_add_validation("${n}" "${t}" "${outdir}" "${configout}")
  get_property(bom TARGET ${t} PROPERTY OC_BOM_OUTPUTS)
  add_custom_target(efi-${n} DEPENDS "${stamp}" ${configout} ${vaultout} ${bom})

  # cmake --install --prefix /Volumes/USB  =>  /Volumes/USB/EFI/...
  # No USE_SOURCE_PERMISSIONS: the destination is usually FAT32, which has no permission
  # bits, and copying modes there is at best a no-op.
  install(CODE "
    if(NOT EXISTS \"${outdir}/OC/OpenCore.efi\")
      message(FATAL_ERROR \"OCMake: '${n}' is not built yet -- run cmake --build first\")
    endif()" COMPONENT "${n}")
  install(DIRECTORY "${outdir}" DESTINATION "." COMPONENT "${n}")

  _oc_add_install_targets("${n}" "${t}" "${outdir}")
  _oc_add_packaging("${n}" "${t}")
endfunction()
