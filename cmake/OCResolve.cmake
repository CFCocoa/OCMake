# GitHub release resolution (PLAN.md §3.4).
#
# One API call returns the tag *and* the asset list, so "latest", build-variant
# selection and ASSET globs are all answered together rather than by three mechanisms.
# URLs are never constructed from the tag: NootedRed tags v0.8.10 but names its asset
# NootedRed-0.8.10-RELEASE.zip, and construction would silently 404.

set(OC_API_TTL 600 CACHE STRING "Seconds a cached GitHub API response stays fresh")

# Convert a shell-style glob to a CMake regex, character by character. Verbose, but it
# avoids escaping the escaping of the escapes.
function(_oc_glob_to_regex glob out)
  set(r "")
  string(LENGTH "${glob}" n)
  if(n GREATER 0)
    math(EXPR last "${n}-1")
    foreach(i RANGE ${last})
      string(SUBSTRING "${glob}" ${i} 1 c)
      if(c STREQUAL "*")
        string(APPEND r ".*")
      elseif(c STREQUAL "?")
        string(APPEND r ".")
      elseif(c MATCHES "[A-Za-z0-9_/-]")
        string(APPEND r "${c}")
      else()
        string(APPEND r "\\${c}")
      endif()
    endforeach()
  endif()
  set(${out} "^${r}$" PARENT_SCOPE)
endfunction()

# _oc_http_json(<url> <out_json> <out_code>) -- 200 or 404; anything else is fatal.
function(_oc_http_json url out_json out_code)
  string(SHA256 h "${url}")
  set(cf "${OC_CACHE_DIR}/api/${h}.json")
  if(EXISTS "${cf}")
    string(TIMESTAMP now "%s")
    file(TIMESTAMP "${cf}" ft "%s")
    math(EXPR age "${now} - ${ft}")
    if(age LESS ${OC_API_TTL})
      file(READ "${cf}" j)
      set(${out_json} "${j}" PARENT_SCOPE)
      set(${out_code} 200 PARENT_SCOPE)
      return()
    endif()
  endif()

  if(OC_OFFLINE)
    message(FATAL_ERROR
      "OCMake: OC_OFFLINE=ON but this needs a GitHub API call:\n  ${url}\n"
      "Commit an up-to-date ocmake.lock, or configure once without OC_OFFLINE.")
  endif()

  set(hdrs HTTPHEADER "Accept: application/vnd.github+json"
           HTTPHEADER "X-GitHub-Api-Version: 2022-11-28")
  set(tok "")
  foreach(v GITHUB_TOKEN GH_TOKEN)
    if(NOT tok AND DEFINED ENV{${v}} AND NOT "$ENV{${v}}" STREQUAL "")
      set(tok "$ENV{${v}}")
    endif()
  endforeach()
  if(tok)
    list(APPEND hdrs HTTPHEADER "Authorization: Bearer ${tok}")
  endif()

  file(MAKE_DIRECTORY "${OC_CACHE_DIR}/api")
  set(tmp "${cf}.tmp")
  file(DOWNLOAD "${url}" "${tmp}" STATUS st LOG log ${hdrs})
  list(GET st 0 rc)

  if(rc EQUAL 0)
    file(RENAME "${tmp}" "${cf}")
    file(READ "${cf}" j)
    set(${out_json} "${j}" PARENT_SCOPE)
    set(${out_code} 200 PARENT_SCOPE)
    return()
  endif()
  file(REMOVE "${tmp}")

  # file(DOWNLOAD) discards the response body on an HTTP error, so GitHub's JSON
  # message is unavailable -- the status code comes from the transfer log instead.
  # The log is never printed: it contains the Authorization header.
  set(http "")
  string(REGEX MATCHALL "HTTP/[0-9.]+ [0-9][0-9][0-9]" codes "${log}")
  if(codes)
    list(GET codes -1 lastline)
    string(REGEX REPLACE "^.* " "" http "${lastline}")
  endif()

  if(http STREQUAL "404")
    set(${out_json} "" PARENT_SCOPE)
    set(${out_code} 404 PARENT_SCOPE)
    return()
  elseif(http STREQUAL "403" OR http STREQUAL "429")
    if(tok)
      set(hint "The token in GITHUB_TOKEN/GH_TOKEN may lack access or be expired.")
    else()
      set(hint "Unauthenticated GitHub API access is limited to 60 requests/hour. Set GITHUB_TOKEN, or commit ocmake.lock so warm builds make no API calls at all.")
    endif()
    message(FATAL_ERROR "OCMake: GitHub API refused the request (HTTP ${http}).\n  ${url}\n${hint}")
  elseif(http STREQUAL "401")
    message(FATAL_ERROR "OCMake: GitHub rejected the token (HTTP 401).\n  ${url}\nCheck GITHUB_TOKEN/GH_TOKEN.")
  endif()

  list(GET st 1 msg)
  message(FATAL_ERROR "OCMake: could not reach the GitHub API (HTTP '${http}', ${msg}).\n  ${url}")
endfunction()

# Fetch a release by tag, tolerating the v-prefix disagreement between tags and versions.
function(_oc_gh_release repo ref out_json)
  if(ref STREQUAL "latest")
    _oc_http_json("https://api.github.com/repos/${repo}/releases/latest" j code)
    if(code EQUAL 200)
      set(${out_json} "${j}" PARENT_SCOPE)
      return()
    endif()
    message(FATAL_ERROR "OCMake: ${repo} has no 'latest' release (HTTP 404).")
  endif()

  set(candidates "${ref}")
  if(ref MATCHES "^v")
    string(SUBSTRING "${ref}" 1 -1 bare)
    list(APPEND candidates "${bare}")
  else()
    list(APPEND candidates "v${ref}")
  endif()
  foreach(c IN LISTS candidates)
    _oc_http_json("https://api.github.com/repos/${repo}/releases/tags/${c}" j code)
    if(code EQUAL 200)
      set(${out_json} "${j}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  string(REPLACE ";" ", " tried "${candidates}")
  message(FATAL_ERROR "OCMake: ${repo} has no release tagged ${tried}.")
endfunction()

# Resolve a git ref (branch, tag or sha) to the commit it points at.
#
# Needed for repositories whose payload lives in the tree rather than in release assets --
# OcBinaryData being the one that matters: its releases are unrelated QEMU CI artefacts,
# and Drivers/ and Resources/ only exist on a branch. Pinning to the commit turns a moving
# branch into an immutable URL, which is what makes the recorded hash meaningful.
function(_oc_gh_commit repo ref out_sha)
  _oc_http_json("https://api.github.com/repos/${repo}/commits/${ref}" j code)
  if(NOT code EQUAL 200)
    message(FATAL_ERROR "OCMake: ${repo} has no ref '${ref}' (HTTP ${code}).")
  endif()
  string(JSON sha ERROR_VARIABLE err GET "${j}" sha)
  if(err OR "${sha}" STREQUAL "")
    message(FATAL_ERROR "OCMake: ${repo}@${ref} returned no commit sha (${err}).")
  endif()
  set(${out_sha} "${sha}" PARENT_SCOPE)
endfunction()

# Dortania's build repo publishes a build of most kexts for every upstream commit, which
# is where you go for a fix that is merged but not released -- and for DEBUG builds of
# projects whose own releases ship none.
#
# https://dortania.github.io/build-repo/ -- one JSON index for all projects, newest build
# first, carrying the download links *and* the sha256 of each. Recording an upstream-
# published digest rather than one we merely observed is a real gain: file(DOWNLOAD)
# verifies against what the publisher said before the bytes are ever used.
set(OC_DORTANIA_INDEX
    "https://raw.githubusercontent.com/dortania/build-repo/builds/config.json"
    CACHE STRING "Dortania build-repo index")

# Resolve one project's newest build. build is RELEASE or DEBUG.
function(_oc_dortania_build project build out_version out_url out_sha out_build)
  # The index lives on raw.githubusercontent.com rather than the API host; the request
  # still carries GITHUB_TOKEN, which is GitHub's own infrastructure and is deliberate --
  # it keeps a rate-limited unauthenticated fetch from being the odd one out.
  _oc_http_json("${OC_DORTANIA_INDEX}" json code)
  if(NOT code EQUAL 200)
    message(FATAL_ERROR "OCMake: could not read the Dortania index (HTTP ${code}).\n  ${OC_DORTANIA_INDEX}")
  endif()

  string(JSON entry ERROR_VARIABLE err GET "${json}" "${project}")
  if(err OR "${entry}" STREQUAL "")
    string(JSON count LENGTH "${json}")
    math(EXPR last "${count}-1")
    set(names "")
    foreach(i RANGE ${last})
      string(JSON name MEMBER "${json}" ${i})
      list(APPEND names "${name}")
    endforeach()
    list(SORT names)
    string(REPLACE ";" "\n    " listing "${names}")
    message(FATAL_ERROR
      "OCMake: Dortania publishes no project called '${project}'.\nIt has:\n    ${listing}")
  endif()

  string(JSON newest ERROR_VARIABLE err GET "${entry}" versions 0)
  if(err)
    message(FATAL_ERROR "OCMake: Dortania has no builds for '${project}' (${err}).")
  endif()

  string(TOLOWER "${build}" want)
  string(JSON url ERROR_VARIABLE err GET "${newest}" links "${want}")
  if(err OR "${url}" STREQUAL "")
    # Same fallback the release resolver uses: a project with no DEBUG build is not a
    # reason to fail, but it is a reason to say what you are getting.
    set(want "release")
    string(JSON url ERROR_VARIABLE err GET "${newest}" links release)
    if(err OR "${url}" STREQUAL "")
      message(FATAL_ERROR "OCMake: Dortania's newest '${project}' build has no download link.")
    endif()
  endif()
  string(JSON sha ERROR_VARIABLE err GET "${newest}" hashes "${want}" sha256)
  if(err)
    set(sha "")
  endif()
  string(JSON ver ERROR_VARIABLE err GET "${newest}" version)
  if(err)
    set(ver "")
  endif()

  string(TOUPPER "${want}" got)
  set(${out_version} "${ver}" PARENT_SCOPE)
  set(${out_url} "${url}" PARENT_SCOPE)
  set(${out_sha} "${sha}" PARENT_SCOPE)
  set(${out_build} "${got}" PARENT_SCOPE)
endfunction()

# Asset selection order: explicit glob > -<BUILD>.zip > -RELEASE.zip fallback > sole asset.
function(_oc_pick_asset json build glob out_name out_url out_build)
  string(JSON count ERROR_VARIABLE e LENGTH "${json}" assets)
  if(e OR count EQUAL 0)
    message(FATAL_ERROR "OCMake: release has no downloadable assets.")
  endif()
  math(EXPR last "${count}-1")
  set(names "")
  foreach(i RANGE ${last})
    string(JSON nm GET "${json}" assets ${i} name)
    list(APPEND names "${nm}")
  endforeach()

  set(chosen "")
  set(effective "${build}")
  if(NOT glob STREQUAL "")
    _oc_glob_to_regex("${glob}" rx)
    foreach(nm IN LISTS names)
      if(NOT chosen AND nm MATCHES "${rx}")
        set(chosen "${nm}")
      endif()
    endforeach()
    if(NOT chosen)
      string(REPLACE ";" "\n    " listing "${names}")
      message(FATAL_ERROR "OCMake: ASSET \"${glob}\" matched none of:\n    ${listing}")
    endif()
  else()
    # Anchored on the dash. An unanchored "RELEASE\\.zip$" also matches NootedRed's
    # RESEARCH_RELEASE.zip, which is a different build entirely.
    foreach(nm IN LISTS names)
      if(NOT chosen AND nm MATCHES "-${build}\\.zip$")
        set(chosen "${nm}")
      endif()
    endforeach()
    if(NOT chosen AND build STREQUAL "DEBUG")
      foreach(nm IN LISTS names)
        if(NOT chosen AND nm MATCHES "-RELEASE\\.zip$")
          set(chosen "${nm}")
          set(effective "RELEASE")
        endif()
      endforeach()
    endif()
    if(NOT chosen AND count EQUAL 1)
      list(GET names 0 chosen)
    endif()
    if(NOT chosen)
      string(REPLACE ";" "\n    " listing "${names}")
      message(FATAL_ERROR
        "OCMake: no asset matched -${build}.zip and the release has several assets.\n"
        "Pass ASSET \"<glob>\" to choose one of:\n    ${listing}")
    endif()
  endif()

  foreach(i RANGE ${last})
    string(JSON nm GET "${json}" assets ${i} name)
    if(nm STREQUAL "${chosen}")
      string(JSON u GET "${json}" assets ${i} browser_download_url)
      set(${out_url} "${u}" PARENT_SCOPE)
    endif()
  endforeach()
  set(${out_name} "${chosen}" PARENT_SCOPE)
  set(${out_build} "${effective}" PARENT_SCOPE)
endfunction()

# oc_require_package(
#   NAME <lock key>  OUT_DIR <extract dir>
#   [GITHUB <owner/repo> VERSION <x.y.z|latest>] [BUILD RELEASE|DEBUG] [ASSET <glob>]
#   [URL <url> [SHA256 <hash>]]          # bypasses resolution entirely
#   [OUT_VERSION <var>] [OUT_BUILD <var>])
#
# A lock hit skips the API call completely -- that is what makes warm builds offline-safe.
function(oc_require_package)
  cmake_parse_arguments(A ""
    "NAME;GITHUB;DORTANIA;VERSION;BUILD;ASSET;URL;SHA256;OUT_DIR;OUT_VERSION;OUT_BUILD;OUT_URL"
    "" ${ARGN})
  if("${A_NAME}" STREQUAL "" OR "${A_OUT_DIR}" STREQUAL "")
    message(FATAL_ERROR "OCMake: oc_require_package requires NAME and OUT_DIR")
  endif()
  if("${A_BUILD}" STREQUAL "")
    set(A_BUILD "${OC_BUILD}")
  endif()
  # Default to the newest release; the lockfile pins whatever that resolved to. Applied
  # before the key is built, so the lock is keyed on the *spec* -- "latest" has a stable
  # identity across the versions it resolves to, exactly as a pinned version does.
  # Not applied when a URL was given: that entry is pinned by the URL, not by a version.
  if("${A_VERSION}" STREQUAL "" AND "${A_URL}" STREQUAL "")
    set(A_VERSION "latest")
  endif()
  # Dortania publishes per-commit builds with no version to ask for, so the spec that goes
  # in the lock key is the source itself.
  if(NOT "${A_DORTANIA}" STREQUAL "")
    set(A_VERSION "dortania")
  endif()
  # Load unconditionally, not just on the GitHub path: an explicit URL skips resolution,
  # but the flush still needs to know which entries the lockfile already holds so it can
  # keep the other build variant's.
  _oc_lock_load()

  set(key "${A_NAME}|${A_VERSION}|${A_BUILD}")
  if(NOT "${A_ASSET}" STREQUAL "")
    string(APPEND key "|${A_ASSET}")
  endif()

  set(url "")
  set(ver "${A_VERSION}")
  set(build "${A_BUILD}")
  set(sha "")

  if(NOT "${A_URL}" STREQUAL "")
    set(url "${A_URL}")
    set(sha "${A_SHA256}")
  else()
    _oc_lock_get("${key}" lv lb lu ls)
    if(lu AND NOT OC_UPDATE)
      set(url "${lu}")
      set(ver "${lv}")
      set(build "${lb}")
      set(sha "${ls}")
    else()
      if(NOT "${A_DORTANIA}" STREQUAL "")
        _oc_dortania_build("${A_DORTANIA}" "${A_BUILD}" ver url sha build)
        if(NOT build STREQUAL "${A_BUILD}")
          _oc_info("${A_NAME}: Dortania publishes no ${A_BUILD} build; using ${build}")
        endif()
        _oc_info("${A_NAME}: Dortania build ${ver}")
      elseif("${A_GITHUB}" STREQUAL "")
        message(FATAL_ERROR
          "OCMake: ${A_NAME} needs GITHUB <owner/repo>, DORTANIA, or an explicit URL.")
      else()
      _oc_gh_release("${A_GITHUB}" "${A_VERSION}" json)
      string(JSON tag GET "${json}" tag_name)
      _oc_pick_asset("${json}" "${A_BUILD}" "${A_ASSET}" aname url build)
      set(ver "${tag}")
      if(ver MATCHES "^v[0-9]")
        string(SUBSTRING "${ver}" 1 -1 ver)
      endif()
      if(NOT build STREQUAL "${A_BUILD}")
        _oc_info("${A_NAME}: no ${A_BUILD} asset published; using ${build}")
      endif()
      if("${A_VERSION}" STREQUAL "latest")
        _oc_info("${A_NAME}: latest resolved to ${ver}")
      endif()
      endif()
    endif()
  endif()

  # An explicit SHA256 is a user pin and outranks whatever the lock or resolver produced.
  if(NOT "${A_SHA256}" STREQUAL "")
    set(sha "${A_SHA256}")
  endif()

  # Cache filename must not collide across repos, but most assets already carry the
  # project name, so only prefix when they do not.
  get_filename_component(fname "${url}" NAME)
  string(FIND "${fname}" "${A_NAME}" pos)
  if(NOT pos EQUAL 0)
    set(fname "${A_NAME}_${fname}")
  endif()
  oc_fetch_archive(URL "${url}" OUT_DIR "${A_OUT_DIR}" SHA256 "${sha}"
                   NAME "${fname}" OUT_SHA256 actual)
  _oc_lock_set("${key}" "${ver}" "${build}" "${url}" "${actual}")

  if(A_OUT_VERSION)
    set(${A_OUT_VERSION} "${ver}" PARENT_SCOPE)
  endif()
  if(A_OUT_BUILD)
    set(${A_OUT_BUILD} "${build}" PARENT_SCOPE)
  endif()
  if(A_OUT_URL)
    set(${A_OUT_URL} "${url}" PARENT_SCOPE)
  endif()
endfunction()

# oc_require_ref(NAME <label> {OUT_FILE <path> | OUT_DIR <dir>}
#                {REPO <owner/repo> REF <ref> [PATH <path in repo>] | URL <url>}
#                [SHA256 <hash>] [OUT_VERSION <var>] [OUT_URL <var>])
#
# The counterpart to oc_require_package() for repositories whose payload is in the tree
# rather than in release assets: same lockfile, same cache, same offline guarantees. With
# PATH it fetches that one file; without, the whole repository archive.
#
# Either way the ref is resolved to a commit first and the commit goes into the URL, so
# the URL is immutable and a recorded hash describes one specific artefact for ever. A
# `master` URL would hash differently the moment the branch moved, and the failure would
# surface much later as an unexplained checksum error on the next cold cache.
#
# Keyed by OC_BUILD like every other entry even though these files have no build variants:
# entries for the *other* variant are what _oc_lock_flush() preserves, so a build-less key
# would never be pruned when its declaration goes away.
function(oc_require_ref)
  cmake_parse_arguments(A ""
    "NAME;REPO;REF;PATH;URL;SHA256;OUT_FILE;OUT_DIR;OUT_VERSION;OUT_URL" "" ${ARGN})
  if("${A_NAME}" STREQUAL "")
    message(FATAL_ERROR "OCMake: oc_require_ref requires NAME")
  endif()
  if("${A_OUT_FILE}" STREQUAL "" AND "${A_OUT_DIR}" STREQUAL "")
    message(FATAL_ERROR "OCMake: oc_require_ref requires OUT_FILE or OUT_DIR")
  endif()
  _oc_lock_load()

  set(ver "")
  set(key "")
  if(NOT "${A_URL}" STREQUAL "")
    set(url "${A_URL}")
    set(sha "${A_SHA256}")
    set(key "${A_NAME}|url|${OC_BUILD}")
  else()
    if("${A_REPO}" STREQUAL "")
      message(FATAL_ERROR "OCMake: ${A_NAME} needs REPO, or an explicit URL.")
    endif()
    set(key "${A_REPO}|${A_REF}|${OC_BUILD}")
    if(NOT "${A_PATH}" STREQUAL "")
      set(key "${A_REPO}:${A_PATH}|${A_REF}|${OC_BUILD}")
    endif()
    _oc_lock_get("${key}" lv lb lu ls)
    if(lu AND NOT OC_UPDATE)
      set(url "${lu}")
      set(ver "${lv}")
      set(sha "${ls}")
    else()
      _oc_gh_commit("${A_REPO}" "${A_REF}" ver)
      if("${A_PATH}" STREQUAL "")
        set(url "https://github.com/${A_REPO}/archive/${ver}.zip")
      else()
        set(url "https://raw.githubusercontent.com/${A_REPO}/${ver}/${A_PATH}")
      endif()
      set(sha "")
      string(SUBSTRING "${ver}" 0 12 short)
      _oc_info("${A_NAME}: ${A_REPO}@${A_REF} pinned to ${short}")
    endif()
  endif()
  if(NOT "${A_SHA256}" STREQUAL "")
    set(sha "${A_SHA256}")
  endif()

  # Cached under the commit it came from: the URL is immutable, so the cache entry is too.
  # An explicit URL has no commit, so it is keyed by a digest of the URL instead.
  if("${ver}" STREQUAL "")
    string(SHA256 h "${url}")
    string(SUBSTRING "${h}" 0 12 tag)
  else()
    string(SUBSTRING "${ver}" 0 12 tag)
  endif()
  if(NOT "${A_REPO}" STREQUAL "")
    string(REGEX REPLACE ".*/" "" repotail "${A_REPO}")
    set(tag "${repotail}-${tag}")
  endif()

  if(NOT "${A_OUT_FILE}" STREQUAL "")
    get_filename_component(bn "${A_OUT_FILE}" NAME)
    oc_fetch_archive(URL "${url}" OUT_FILE "${A_OUT_FILE}" SHA256 "${sha}"
                     NAME "${tag}-${bn}" OUT_SHA256 actual)
  else()
    oc_fetch_archive(URL "${url}" OUT_DIR "${A_OUT_DIR}" SHA256 "${sha}"
                     NAME "${tag}.zip" OUT_SHA256 actual)
  endif()
  _oc_lock_set("${key}" "${ver}" "${OC_BUILD}" "${url}" "${actual}")

  if(A_OUT_VERSION)
    set(${A_OUT_VERSION} "${ver}" PARENT_SCOPE)
  endif()
  if(A_OUT_URL)
    set(${A_OUT_URL} "${url}" PARENT_SCOPE)
  endif()
endfunction()

# A GitHub archive unpacks into a single <repo>-<commit>/ directory. Callers want the
# contents, not the wrapper, and its name changes with every commit.
function(_oc_archive_root dir out)
  file(GLOB children LIST_DIRECTORIES true "${dir}/*")
  set(dirs "")
  foreach(c IN LISTS children)
    if(IS_DIRECTORY "${c}")
      list(APPEND dirs "${c}")
    endif()
  endforeach()
  list(LENGTH dirs count)
  if(count EQUAL 1)
    list(GET dirs 0 only)
    set(${out} "${only}" PARENT_SCOPE)
  else()
    set(${out} "${dir}" PARENT_SCOPE)
  endif()
endfunction()
