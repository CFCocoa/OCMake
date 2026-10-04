# oc_kext(), oc_driver(), oc_tool().

# Find top-level kext bundles under a directory. A bundle is a *.kext holding
# Contents/Info.plist; bundles nested inside another bundle are plugins and travel with
# their parent, so they are excluded here (OCSnapshot adds their config entries itself).
#
# NB: the glob pattern is a bare filename. file(GLOB_RECURSE) anchors the directory part
# of a pattern, so "${root}/*/Contents/Info.plist" silently misses archives that nest
# their kexts one level deeper (VirtualSMC ships Kexts/*.kext).
function(_oc_find_kexts root out)
  file(GLOB_RECURSE plists "${root}/Info.plist")
  set(found "")
  foreach(p IN LISTS plists)
    get_filename_component(contents "${p}" DIRECTORY)
    get_filename_component(bundle "${contents}" DIRECTORY)
    if(bundle MATCHES "\\.kext$")
      file(RELATIVE_PATH rel "${root}" "${bundle}")
      if(NOT rel MATCHES "\\.kext/" AND NOT rel MATCHES "(^|/)__MACOSX(/|$)")
        list(APPEND found "${bundle}")
      endif()
    endif()
  endforeach()
  list(SORT found)
  set(${out} "${found}" PARENT_SCOPE)
endfunction()

# oc_kext(<name>
#         [GITHUB <owner/repo> VERSION <v> [ASSET <glob>] [BUILD RELEASE|DEBUG]]
#         [URL <url> [SHA256 <hash>]]
#         [PATH <local .kext or directory>]
#         [KEXTS <a> <b> ...]      # choose from a multi-kext archive
#         [MIN_KERNEL <v>] [MAX_KERNEL <v>] [ARCH <a>] [ENABLED <ON|OFF>] [COMMENT <s>]
#         [EFI <name>])
function(oc_kext name)
  cmake_parse_arguments(A "DORTANIA"
    "GITHUB;VERSION;BUILD;ASSET;URL;SHA256;PATH;MIN_KERNEL;MAX_KERNEL;ARCH;ENABLED;COMMENT;EFI"
    "KEXTS" ${ARGN})
  # DORTANIA names no project of its own: the declaration's name is the project name, which
  # is what the build repo indexes them by.
  #
  # The else() is load-bearing. cmake_parse_arguments() sets an unset option to the *string*
  # FALSE, not to nothing, so forwarding it as a value hands the resolver a project called
  # "FALSE" -- which it then dutifully failed to find.
  if(A_DORTANIA)
    set(A_DORTANIA "${name}")
  else()
    set(A_DORTANIA "")
  endif()
  _oc_target(t "${A_EFI}")

  if(NOT "${A_PATH}" STREQUAL "")
    get_filename_component(abs "${A_PATH}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    if(NOT EXISTS "${abs}")
      message(FATAL_ERROR "OCMake: oc_kext(${name} PATH ...) does not exist:\n  ${abs}")
    endif()
    if(abs MATCHES "\\.kext$")
      set(bundles "${abs}")
    else()
      _oc_find_kexts("${abs}" bundles)
    endif()
  else()
    if("${A_GITHUB}" STREQUAL "" AND "${A_URL}" STREQUAL "" AND "${A_DORTANIA}" STREQUAL "")
      message(FATAL_ERROR
        "OCMake: oc_kext(${name}) needs one of GITHUB <owner/repo>, DORTANIA, URL <url> "
        "or PATH <file>.")
    endif()
    set(out "${CMAKE_BINARY_DIR}/_oc/kext-${name}")
    oc_require_package(
      NAME "${name}" GITHUB "${A_GITHUB}" DORTANIA "${A_DORTANIA}"
      VERSION "${A_VERSION}" BUILD "${A_BUILD}"
      ASSET "${A_ASSET}" URL "${A_URL}" SHA256 "${A_SHA256}"
      OUT_DIR "${out}" OUT_VERSION kver OUT_URL kurl)
    _oc_find_kexts("${out}" all)
    if(NOT all)
      message(FATAL_ERROR "OCMake: oc_kext(${name}) archive contained no .kext bundle")
    endif()

    set(bundles "")
    if(A_KEXTS)
      foreach(want IN LISTS A_KEXTS)
        set(hit "")
        foreach(b IN LISTS all)
          get_filename_component(bn "${b}" NAME)
          if(bn STREQUAL "${want}.kext" OR bn STREQUAL "${want}")
            set(hit "${b}")
          endif()
        endforeach()
        if(NOT hit)
          _oc_kext_listing("${all}" listing)
          message(FATAL_ERROR "OCMake: oc_kext(${name}) has no '${want}' in:\n${listing}")
        endif()
        list(APPEND bundles "${hit}")
      endforeach()
    else()
      foreach(b IN LISTS all)
        get_filename_component(bn "${b}" NAME)
        if(bn STREQUAL "${name}.kext")
          set(bundles "${b}")
        endif()
      endforeach()
      if(NOT bundles)
        list(LENGTH all n)
        if(n EQUAL 1)
          set(bundles "${all}")
        else()
          _oc_kext_listing("${all}" listing)
          message(FATAL_ERROR
            "OCMake: oc_kext(${name}) archive has no ${name}.kext and holds several bundles.\n"
            "Pass KEXTS to choose from:\n${listing}")
        endif()
      endif()
    endif()
    set_property(TARGET ${t} PROPERTY OC_KEXTVER_${name} "${kver}")
  endif()

  foreach(b IN LISTS bundles)
    get_filename_component(bn "${b}" NAME)
    set_property(TARGET ${t} APPEND PROPERTY OC_KEXT_SRCS "${b}")
    if(NOT "${A_PATH}" STREQUAL "")
      _oc_relpath("${b}" rel)
      _oc_provenance(${t} KEXT "${bn}" ORIGIN local SOURCE "${rel}")
    elseif(NOT "${A_GITHUB}" STREQUAL "")
      _oc_provenance(${t} KEXT "${bn}" ORIGIN github REPO "${A_GITHUB}"
                     VERSION "${kver}" URL "${kurl}")
    else()
      _oc_provenance(${t} KEXT "${bn}" ORIGIN url VERSION "${kver}" URL "${kurl}")
    endif()
    string(REGEX REPLACE "[^A-Za-z0-9]" "_" tok "${bn}")
    # Overrides apply to every bundle produced by this declaration.
    foreach(f MIN_KERNEL MAX_KERNEL ARCH ENABLED COMMENT)
      if(NOT "${A_${f}}" STREQUAL "")
        set_property(TARGET ${t} APPEND PROPERTY OC_KEXT_OVERRIDDEN "${bn}")
        set_property(TARGET ${t} PROPERTY OC_KOVR_${tok}_${f} "${A_${f}}")
      endif()
    endforeach()
  endforeach()
endfunction()

function(_oc_kext_listing bundles out)
  set(s "")
  foreach(b IN LISTS bundles)
    get_filename_component(bn "${b}" NAME)
    string(APPEND s "    ${bn}\n")
  endforeach()
  set(${out} "${s}" PARENT_SCOPE)
endfunction()

# OcBinaryData is the second home of UEFI binaries in the OpenCore world: HfsPlus.efi (the
# Apple driver, which OpenCorePkg cannot redistribute) and the picker's Resources/ live
# there and nowhere else. Its GitHub *releases* are unrelated QEMU CI artefacts, so the
# files have to come out of the repository tree -- see oc_require_ref().
# oc_resources() (Phase 6) will share these.
set(OC_BINARYDATA_REPO "acidanthera/OcBinaryData"
    CACHE STRING "Repository providing OcBinaryData drivers and picker resources")
set(OC_BINARYDATA_REF "master"
    CACHE STRING "OcBinaryData ref to resolve on a cold lock; the commit is then pinned")

# Shared by oc_driver() and oc_tool(). A binary can come from four places, and one call
# may mix them freely -- each source keyword introduces the items that come from it, which
# is the same shape as oc_ssdt(SAMPLES ...) and oc_kext(... KEXTS ...):
#
#   <name> ...                 the OpenCore package -- the default, so no keyword
#   OCBINARYDATA <name> ...    OcBinaryData's <subdir>/, pinned to a commit and locked
#   URL <url> [SHA256 <hash>]  one file from anywhere; named after the URL's basename
#   PATH <file.efi> ...        local files -- a fork, or something nobody publishes
#
# The three fetched forms all end up in OC_<kind>_PATHS, exactly like a local file: once
# the binary is on disk, staging and validation do not care where it came from.
function(_oc_add_efi_binaries t kind subdir names paths binarydata ref url sha)
  foreach(d IN LISTS names)
    if(NOT d MATCHES "\\.efi$")
      set(d "${d}.efi")
    endif()
    set_property(TARGET ${t} APPEND PROPERTY OC_${kind} "${d}")
    _oc_provenance(${t} ${kind} "${d}" ORIGIN opencore)
  endforeach()

  if(NOT "${binarydata}" STREQUAL "")
    if(NOT subdir STREQUAL "Drivers")
      message(FATAL_ERROR "OCMake: OcBinaryData ships no ${subdir}/; it has Drivers/ and Resources/.")
    endif()
    if("${ref}" STREQUAL "")
      set(ref "${OC_BINARYDATA_REF}")
    endif()
    foreach(d IN LISTS binarydata)
      if(NOT d MATCHES "\\.efi$")
        set(d "${d}.efi")
      endif()
      set(dest "${CMAKE_BINARY_DIR}/_oc/binary/${subdir}/${d}")
      oc_require_ref(NAME "${d}" REPO "${OC_BINARYDATA_REPO}" REF "${ref}"
                      PATH "${subdir}/${d}" OUT_FILE "${dest}"
                      OUT_VERSION commit OUT_URL got)
      string(SUBSTRING "${commit}" 0 12 short)
      _oc_provenance(${t} ${kind} "${d}" ORIGIN github REPO "${OC_BINARYDATA_REPO}"
                     VERSION "${short}" URL "${got}")
      set_property(TARGET ${t} APPEND PROPERTY OC_${kind}_PATHS "${dest}")
    endforeach()
  endif()

  # Named after the file the URL points at, the same rule PATH follows. One URL per call,
  # because SHA256 pins that one file -- as it does in oc_kext().
  if(NOT "${url}" STREQUAL "")
    get_filename_component(d "${url}" NAME)
    if(NOT d MATCHES "\\.efi$")
      message(FATAL_ERROR "OCMake: URL should point at a .efi, got '${d}':\n  ${url}")
    endif()
    set(dest "${CMAKE_BINARY_DIR}/_oc/binary/${subdir}/${d}")
    oc_require_ref(NAME "${d}" URL "${url}" SHA256 "${sha}" OUT_FILE "${dest}" OUT_URL got)
    _oc_provenance(${t} ${kind} "${d}" ORIGIN url URL "${got}")
    set_property(TARGET ${t} APPEND PROPERTY OC_${kind}_PATHS "${dest}")
  endif()

  foreach(f IN LISTS paths)
    get_filename_component(abs "${f}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    if(NOT EXISTS "${abs}")
      message(FATAL_ERROR "OCMake: PATH does not exist:\n  ${abs}")
    endif()
    get_filename_component(bn "${abs}" NAME)
    set_property(TARGET ${t} APPEND PROPERTY OC_${kind}_PATHS "${abs}")
    _oc_relpath("${abs}" rel)
    _oc_provenance(${t} ${kind} "${bn}" ORIGIN local SOURCE "${rel}")
  endforeach()
endfunction()

# A source keyword given with nothing after it is a typo, not an empty set.
function(_oc_check_sources A_missing fn)
  foreach(kw IN LISTS A_missing)
    message(FATAL_ERROR "OCMake: ${fn}(${kw} ...) needs at least one name after ${kw}")
  endforeach()
endfunction()

# oc_driver([<name> ...] [OCBINARYDATA <name> ... [REF <ref>]] [URL <url> [SHA256 <hash>]]
#           [PATH <file.efi> ...] [EFI <name>])
function(oc_driver)
  cmake_parse_arguments(A "" "EFI;REF;URL;SHA256" "PATH;OCBINARYDATA" ${ARGN})
  _oc_check_sources("${A_KEYWORDS_MISSING_VALUES}" oc_driver)
  _oc_target(t "${A_EFI}")
  _oc_add_efi_binaries(${t} DRIVERS Drivers "${A_UNPARSED_ARGUMENTS}" "${A_PATH}"
                       "${A_OCBINARYDATA}" "${A_REF}" "${A_URL}" "${A_SHA256}")
endfunction()

# oc_tool([<name> ...] [URL <url> [SHA256 <hash>]] [PATH <file.efi> ...] [EFI <name>])
function(oc_tool)
  cmake_parse_arguments(A "" "EFI;REF;URL;SHA256" "PATH;OCBINARYDATA" ${ARGN})
  _oc_check_sources("${A_KEYWORDS_MISSING_VALUES}" oc_tool)
  _oc_target(t "${A_EFI}")
  _oc_add_efi_binaries(${t} TOOLS Tools "${A_UNPARSED_ARGUMENTS}" "${A_PATH}"
                       "${A_OCBINARYDATA}" "${A_REF}" "${A_URL}" "${A_SHA256}")
endfunction()
