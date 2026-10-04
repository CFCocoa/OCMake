# oc_resources([OCBINARYDATA] [FONT ON|OFF] [LABEL ON|OFF] [AUDIO ON|OFF]
#              [IMAGE ON|OFF|<set>] [REF <ref>] [URL <archive> [SHA256 <hash>]]
#              [EFI <name>])
#
# Defaults: FONT ON, LABEL ON, IMAGE ON, AUDIO OFF -- everything OpenCanopy needs to draw
# a picker. AUDIO is opt-in because it is 362 .wav files and 6.3 MB, two thirds of the
# whole repository, read only when UEFI/Audio/AudioSupport is on.
#
# OCBINARYDATA is accepted and is what the defaults already mean; it is there so the call
# can name its source the way oc_driver() does. URL takes an archive of the same shape
# instead -- a fork, a mirror, or an air-gapped copy.
#
# The selectors name subdirectories of the source rather than sources of their own, so
# they follow oc_kext(... KEXTS ...) rather than the source-first rule.
#
# IMAGE takes a *set*: 'Acidanthera/GoldenGate' stages only that icon set and writes
# Misc/Boot/PickerVariant to match, because once the declaration names a set the plist
# repeating it is duplication with two ways to disagree. Bare IMAGE (or IMAGE ON) stages
# the whole Image/ tree and leaves PickerVariant alone, which is what PickerVariant Auto
# needs: it chooses a set by macOS version and so requires all of them present.
#
# PickerVariant is written as an ordinary config op at this call's position, so a later
# oc_config_set(Misc/Boot/PickerVariant ...) still wins -- the same ordering rule the
# built-in defaults follow.
function(oc_resources)
  cmake_parse_arguments(A "OCBINARYDATA" "FONT;LABEL;IMAGE;AUDIO;REF;EFI;URL;SHA256" "" ${ARGN})
  if(A_UNPARSED_ARGUMENTS)
    string(REPLACE ";" " " extra "${A_UNPARSED_ARGUMENTS}")
    message(FATAL_ERROR
      "OCMake: oc_resources() takes FONT, LABEL, IMAGE and AUDIO, not '${extra}'")
  endif()
  _oc_target(t "${A_EFI}")

  # Read explicitly rather than through if(): a set name like Acidanthera/GoldenGate is
  # neither a CMake true nor a false constant, and the unary if() would be guessing.
  _oc_res_selector("${A_FONT}"  ON  FONT  font_on  font_set)
  _oc_res_selector("${A_LABEL}" ON  LABEL label_on label_set)
  _oc_res_selector("${A_IMAGE}" ON  IMAGE image_on image_set)
  _oc_res_selector("${A_AUDIO}" OFF AUDIO audio_on audio_set)
  foreach(pair "FONT;${font_set}" "LABEL;${label_set}" "AUDIO;${audio_set}")
    list(GET pair 0 kw)
    list(GET pair 1 value)
    if(NOT "${value}" STREQUAL "")
      message(FATAL_ERROR
        "OCMake: only IMAGE names a set; ${kw} takes ON or OFF, got '${value}'")
    endif()
  endforeach()

  set(want "")
  foreach(pair "font_on;Font" "label_on;Label" "image_on;Image" "audio_on;Audio")
    list(GET pair 0 flag)
    list(GET pair 1 dir)
    if(${${flag}})
      list(APPEND want "${dir}")
    endif()
  endforeach()
  if(NOT want)
    message(FATAL_ERROR "OCMake: oc_resources() was asked for nothing at all")
  endif()

  set(ref "${A_REF}")
  if("${ref}" STREQUAL "")
    set(ref "${OC_BINARYDATA_REF}")
  endif()

  # One archive, one lock entry. Fetching the individual files would be honest too, but it
  # would put dozens of entries per build variant into a lockfile whose whole point is
  # that a human reviews it in a diff.
  set(out "${CMAKE_BINARY_DIR}/_oc/ocbinarydata")
  if(NOT "${A_URL}" STREQUAL "")
    oc_require_ref(NAME "OcBinaryData" URL "${A_URL}" SHA256 "${A_SHA256}"
                   OUT_DIR "${out}" OUT_URL url)
    set(commit "")
    set(source "${url}")
  else()
    oc_require_ref(NAME "OcBinaryData" REPO "${OC_BINARYDATA_REPO}" REF "${ref}"
                   OUT_DIR "${out}" OUT_VERSION commit OUT_URL url)
    set(source "${OC_BINARYDATA_REPO}")
  endif()
  _oc_archive_root("${out}" root)

  set(short "")
  if(NOT "${commit}" STREQUAL "")
    string(SUBSTRING "${commit}" 0 12 short)
  endif()

  foreach(dir IN LISTS want)
    set(rel "Resources/${dir}")
    if(dir STREQUAL "Image" AND NOT "${image_set}" STREQUAL "")
      # Staged at its own path, not flattened: PickerVariant addresses a set by the path
      # it sits at inside Resources/Image.
      set(rel "Resources/Image/${image_set}")
    endif()
    set(src "${root}/${rel}")
    if(NOT IS_DIRECTORY "${src}")
      _oc_res_available("${root}/Resources/Image" avail)
      set(hint "")
      if(dir STREQUAL "Image" AND NOT "${image_set}" STREQUAL "")
        set(hint "\nSets it does have:\n${avail}")
      endif()
      message(FATAL_ERROR "OCMake: ${source} has no ${rel}:\n  ${src}${hint}")
    endif()
    set_property(TARGET ${t} APPEND PROPERTY OC_RES_SRCS "${src}")
    set_property(TARGET ${t} APPEND PROPERTY OC_RES_DSTS "${rel}")
    if("${A_URL}" STREQUAL "")
      _oc_provenance(${t} RESOURCES "${dir}" ORIGIN github REPO "${OC_BINARYDATA_REPO}"
                     VERSION "${short}" URL "${url}")
    else()
      _oc_provenance(${t} RESOURCES "${dir}" ORIGIN url URL "${url}")
    endif()
  endforeach()

  if(NOT "${image_set}" STREQUAL "")
    # OpenCore writes this path with backslashes; CMake source should not have to.
    string(REPLACE "/" "\\" variant "${image_set}")
    oc_config_set(Misc/Boot/PickerVariant STRING "${variant}" EFI "${A_EFI}")
  endif()

  string(REPLACE ";" ", " listing "${want}")
  if(NOT "${image_set}" STREQUAL "")
    string(REPLACE "Image" "Image/${image_set}" listing "${listing}")
  endif()
  if("${short}" STREQUAL "")
    _oc_info("resources: ${listing} from ${source}")
  else()
    _oc_info("resources: ${listing} from ${source}@${short}")
  endif()
endfunction()

# Split a selector into on/off plus, for IMAGE, the set it named.
function(_oc_res_selector value fallback kw out_on out_set)
  set(${out_set} "" PARENT_SCOPE)
  if("${value}" STREQUAL "")
    set(${out_on} "${fallback}" PARENT_SCOPE)
    return()
  endif()
  string(TOUPPER "${value}" up)
  if(up MATCHES "^(OFF|NO|FALSE|N|0)$")
    set(${out_on} OFF PARENT_SCOPE)
  elseif(up MATCHES "^(ON|YES|TRUE|Y|1)$")
    set(${out_on} ON PARENT_SCOPE)
  else()
    set(${out_on} ON PARENT_SCOPE)
    set(${out_set} "${value}" PARENT_SCOPE)
  endif()
endfunction()

# What Image/ actually holds, for the diagnostic when a set was misspelled.
function(_oc_res_available image_root out)
  set(listing "")
  file(GLOB_RECURSE icons LIST_DIRECTORIES false "${image_root}/*")
  set(sets "")
  foreach(f IN LISTS icons)
    get_filename_component(d "${f}" DIRECTORY)
    file(RELATIVE_PATH r "${image_root}" "${d}")
    if(NOT r IN_LIST sets)
      list(APPEND sets "${r}")
    endif()
  endforeach()
  list(SORT sets)
  foreach(sset IN LISTS sets)
    string(APPEND listing "    ${sset}\n")
  endforeach()
  set(${out} "${listing}" PARENT_SCOPE)
endfunction()
