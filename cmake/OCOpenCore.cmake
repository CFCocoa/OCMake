# oc_opencore(): fetch the OpenCorePkg release and record it on the EFI target.

set(OC_OPENCORE_REPO "acidanthera/OpenCorePkg" CACHE STRING "OpenCore source repository")

# oc_opencore(VERSION <x.y.z|latest> [BUILD RELEASE|DEBUG] [ASSET <glob>]
#             [URL <url> [SHA256 <hash>]] [EFI <name>])
function(oc_opencore)
  cmake_parse_arguments(A "" "VERSION;BUILD;SHA256;URL;ASSET;EFI" "" ${ARGN})
  _oc_target(t "${A_EFI}")

  if(NOT "${A_BUILD}" STREQUAL "")
    string(TOUPPER "${A_BUILD}" build)
  else()
    set(build "${OC_BUILD}")
  endif()
  # No VERSION means the newest release. The lockfile is what makes that safe: whatever
  # "latest" resolved to is pinned by URL and hash until -DOC_UPDATE=ON, so a build is
  # still reproducible and a clean clone still builds offline.
  if("${A_VERSION}" STREQUAL "" AND "${A_URL}" STREQUAL "")
    set(A_VERSION "latest")
  endif()

  # Keyed on the version *spec*, not the resolved version, so "latest" has a stable
  # directory. Re-extraction is driven by the archive hash, so a moved "latest" still
  # replaces the tree.
  set(out "${CMAKE_BINARY_DIR}/_oc/OpenCore-${A_VERSION}-${build}")

  oc_require_package(
    NAME "OpenCore"
    GITHUB "${OC_OPENCORE_REPO}"
    VERSION "${A_VERSION}"
    BUILD "${build}"
    ASSET "${A_ASSET}"
    URL "${A_URL}"
    SHA256 "${A_SHA256}"
    OUT_DIR "${out}"
    OUT_VERSION ver
    OUT_BUILD effective
    OUT_URL ocurl)

  # The release zip is laid out as X64/EFI/..., IA32/EFI/..., Docs/, Utilities/.
  set(root "${out}/X64")
  if(NOT EXISTS "${root}/EFI/OC/OpenCore.efi")
    message(FATAL_ERROR "OCMake: the OpenCore archive did not contain X64/EFI/OC/OpenCore.efi")
  endif()

  set_property(TARGET ${t} PROPERTY OC_OPENCORE_PKG   "${out}")
  set_property(TARGET ${t} PROPERTY OC_OPENCORE_ROOT  "${root}")
  set_property(TARGET ${t} PROPERTY OC_OPENCORE_VER   "${ver}")
  set_property(TARGET ${t} PROPERTY OC_OPENCORE_BUILD "${effective}")
  # An explicit URL bypasses the repository, so the BOM must cite what was really used
  # rather than the default repo.
  if(NOT "${A_URL}" STREQUAL "")
    _oc_provenance(${t} PKG OpenCore ORIGIN url VERSION "${ver}" URL "${ocurl}")
  else()
    _oc_provenance(${t} PKG OpenCore ORIGIN github REPO "${OC_OPENCORE_REPO}"
                   VERSION "${ver}" URL "${ocurl}")
  endif()
  _oc_info("OpenCore ${ver} ${effective}")
endfunction()
