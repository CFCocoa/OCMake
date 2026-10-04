# Download + extract with a shared on-disk cache.
#
# Phase 0 takes an explicit URL. Phase 1 replaces the callers' URL construction with
# the GitHub resolver (PLAN.md §3.4) and records hashes in ocmake.lock (§3.5).

# oc_fetch_archive(URL <url> {OUT_DIR <dir> | OUT_FILE <path>}
#                  [SHA256 <hash>] [NAME <cached filename>]
#                  [OUT_VAR <var>] [OUT_SHA256 <var>])
#
# OUT_DIR extracts the archive there. OUT_FILE is for a source that is not an archive at
# all -- a single .efi from a repository tree -- and copies the verified file to that
# path. Everything before the split (cache lookup, hash policy, OC_OFFLINE diagnostics)
# is identical, which is the reason this is one function and not two.
#
# OUT_VAR receives the extraction directory or the copied file.
function(oc_fetch_archive)
  cmake_parse_arguments(A "" "URL;OUT_DIR;OUT_FILE;SHA256;NAME;OUT_VAR;OUT_SHA256" "" ${ARGN})
  if(NOT A_URL)
    message(FATAL_ERROR "OCMake: oc_fetch_archive requires URL")
  endif()
  if("${A_OUT_DIR}" STREQUAL "" AND "${A_OUT_FILE}" STREQUAL "")
    message(FATAL_ERROR "OCMake: oc_fetch_archive requires OUT_DIR or OUT_FILE")
  endif()
  if(NOT "${A_OUT_DIR}" STREQUAL "" AND NOT "${A_OUT_FILE}" STREQUAL "")
    message(FATAL_ERROR "OCMake: oc_fetch_archive takes OUT_DIR or OUT_FILE, not both")
  endif()
  if(NOT A_NAME)
    get_filename_component(A_NAME "${A_URL}" NAME)
  endif()

  set(archive "${OC_CACHE_DIR}/${A_NAME}")
  file(MAKE_DIRECTORY "${OC_CACHE_DIR}")

  # Reuse a cached archive only if it satisfies the declared hash.
  #
  # With no hash to check against, the cache is keyed by filename alone, so a changed
  # source at the same URL would be invisible. That is safe for release assets, which are
  # immutable per URL -- but not for a local file, which is exactly what a developer edits
  # between configures. So local sources always refresh; copying them again is cheap.
  set(need_download TRUE)
  set(mismatch "")
  if(A_URL MATCHES "^file://")
    set(local_source TRUE)
  else()
    set(local_source FALSE)
  endif()
  if(EXISTS "${archive}" AND NOT local_source)
    if(A_SHA256)
      file(SHA256 "${archive}" have)
      if(have STREQUAL "${A_SHA256}")
        set(need_download FALSE)
      else()
        set(mismatch "${have}")
        _oc_warn("cached ${A_NAME} has hash ${have}, expected ${A_SHA256}; re-downloading")
      endif()
    else()
      set(need_download FALSE)
    endif()
  endif()

  # OC_OFFLINE means "no network", not "no filesystem": a local source is always readable.
  if(need_download AND OC_OFFLINE AND NOT local_source)
    # "not cached" and "cached but wrong" are different problems with different fixes.
    if(mismatch)
      message(FATAL_ERROR
        "OCMake: OC_OFFLINE=ON and the cached ${A_NAME} does not match the expected hash.\n"
        "  cached:   ${mismatch}\n  expected: ${A_SHA256}\n"
        "The lockfile and the cache disagree. Re-resolve with -DOC_UPDATE=ON (needs network).")
    endif()
    message(FATAL_ERROR
      "OCMake: OC_OFFLINE=ON but ${A_NAME} is not in the cache:\n  ${OC_CACHE_DIR}\n"
      "Configure once without OC_OFFLINE to populate it.")
  endif()

  if(need_download)
    _oc_info("downloading ${A_NAME}")
    if(A_SHA256)
      file(DOWNLOAD "${A_URL}" "${archive}" STATUS st LOG log EXPECTED_HASH SHA256=${A_SHA256})
    else()
      file(DOWNLOAD "${A_URL}" "${archive}" STATUS st LOG log)
    endif()
    list(GET st 0 code)
    if(NOT code EQUAL 0)
      list(GET st 1 err)
      file(REMOVE "${archive}")
      message(FATAL_ERROR "OCMake: failed to download ${A_URL}\n  ${err}\n${log}")
    endif()
  endif()

  file(SHA256 "${archive}" actual)

  # A single binary: nothing to unpack, but copy it into the build tree anyway so that
  # every staging input lives in the build directory rather than in the shared cache --
  # clearing the cache should not break an already-configured build.
  #
  # ONLY_IF_DIFFERENT keeps the copy's mtime stable across configures. A reconfigure
  # restages regardless today (the generated manifest is rewritten, and it is a dependency
  # too), so this is not currently observable -- it is here so that this file is not the
  # thing standing in the way if that ever changes.
  if(NOT "${A_OUT_FILE}" STREQUAL "")
    get_filename_component(dest_dir "${A_OUT_FILE}" DIRECTORY)
    file(MAKE_DIRECTORY "${dest_dir}")
    file(COPY_FILE "${archive}" "${A_OUT_FILE}" ONLY_IF_DIFFERENT)
    if(A_OUT_VAR)
      set(${A_OUT_VAR} "${A_OUT_FILE}" PARENT_SCOPE)
    endif()
    if(A_OUT_SHA256)
      set(${A_OUT_SHA256} "${actual}" PARENT_SCOPE)
    endif()
    return()
  endif()

  # Extract once; the stamp records which archive the directory was built from, so a
  # changed hash forces a clean re-extract.
  set(stamp "${A_OUT_DIR}/.ocmake-extracted")
  set(stamped "")
  if(EXISTS "${stamp}")
    file(READ "${stamp}" stamped)
    string(STRIP "${stamped}" stamped)
  endif()
  if(NOT stamped STREQUAL actual)
    file(REMOVE_RECURSE "${A_OUT_DIR}")
    file(MAKE_DIRECTORY "${A_OUT_DIR}")
    file(ARCHIVE_EXTRACT INPUT "${archive}" DESTINATION "${A_OUT_DIR}")
    file(WRITE "${stamp}" "${actual}")
    _oc_info("extracted ${A_NAME}")
  endif()

  if(A_OUT_VAR)
    set(${A_OUT_VAR} "${A_OUT_DIR}" PARENT_SCOPE)
  endif()
  if(A_OUT_SHA256)
    set(${A_OUT_SHA256} "${actual}" PARENT_SCOPE)
  endif()
endfunction()
