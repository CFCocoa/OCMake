# The `outdated` target: re-resolve every pinned item and report, changing nothing.
#
# Run under `cmake -P`, not at configure time. Checking for updates is a question the user
# asks, never something a build should do on its own -- it costs one API call per package
# and the answer must never be able to fail a build.
#
# It reads ocmake.lock and nothing else. The lock already records what was pinned, and the
# URL says where it came from, so no extra state has to be generated and kept in sync.
#
# Usage: cmake -DOCMAKE_ROOT=<dir> -DOC_LOCKFILE=<file> [-DOC_CACHE_DIR=<dir>]
#              -P cmake/OCOutdated.cmake

cmake_minimum_required(VERSION 3.25)
include("${OCMAKE_ROOT}/cmake/OCUtil.cmake")
include("${OCMAKE_ROOT}/cmake/OCLock.cmake")
include("${OCMAKE_ROOT}/cmake/OCResolve.cmake")
_oc_init_cache_dir()

if(NOT EXISTS "${OC_LOCKFILE}")
  message(FATAL_ERROR "OCMake: no lockfile at ${OC_LOCKFILE}; configure once first.")
endif()
include("${OC_LOCKFILE}")

get_property(known GLOBAL PROPERTY OC_LOCK_KNOWN)
if(NOT known)
  message(STATUS "OCMake: the lockfile pins nothing.")
  return()
endif()

# One report line per declaration, not per build variant: RELEASE and DEBUG entries share
# a version and would otherwise each ask GitHub the same question.
set(seen "")
set(rows "")
set(width 0)
set(stale 0)

foreach(key IN LISTS known)
  _oc_lock_token("${key}" tok)
  get_property(ver GLOBAL PROPERTY OC_LOCK_${tok}_VERSION)
  get_property(url GLOBAL PROPERTY OC_LOCK_${tok}_URL)

  # Keys are '|'-separated and never contain ';', so this is a safe way to index fields:
  #   <name>|<version spec>|<BUILD>[|<asset glob>]   a release asset
  #   <repo>[:<path>]|<ref>|<BUILD>                  a file or archive at a ref
  string(REPLACE "|" ";" parts "${key}")
  list(GET parts 0 label)
  string(REGEX REPLACE "^[^/:]+/" "" label "${label}")  # the owner is noise in a table
  set(ref "")
  list(LENGTH parts nparts)
  if(nparts GREATER 1)
    list(GET parts 1 ref)
  endif()
  # Drop the BUILD field so RELEASE and DEBUG collapse into one row -- they pin the same
  # version and would otherwise ask GitHub the same question twice.
  set(ident "${parts}")
  if(nparts GREATER 2)
    list(REMOVE_AT ident 2)
  endif()
  # Back to a single string: list(APPEND) on a ';'-joined value would flatten it into
  # several elements, and IN_LIST could then never match it again.
  string(REPLACE ";" "|" ident "${ident}")
  if("${ident}" IN_LIST seen)
    continue()
  endif()
  list(APPEND seen "${ident}")

  string(LENGTH "${label}" len)
  if(len GREATER width)
    set(width ${len})
  endif()

  # Capture the repository before anything else runs a regex: CMAKE_MATCH_* is global and
  # the next string(REGEX ...) anywhere would overwrite it.
  set(repo "")
  set(kind "")
  if(url MATCHES "^https://github\\.com/([^/]+/[^/]+)/releases/download/")
    set(repo "${CMAKE_MATCH_1}")
    set(kind release)
  elseif(url MATCHES "^https://raw\\.githubusercontent\\.com/([^/]+/[^/]+)/")
    set(repo "${CMAKE_MATCH_1}")
    set(kind commit)
  elseif(url MATCHES "^https://github\\.com/([^/]+/[^/]+)/archive/")
    set(repo "${CMAKE_MATCH_1}")
    set(kind commit)
  endif()

  # _oc_http_json() directly rather than _oc_gh_release(): a repository with no published
  # release is a fact to report, not a reason to abort the whole run. A 403 or 429 still
  # stops it, which is right -- the remaining answers would be wrong anyway.
  set(latest "")
  set(note "")
  set(have "${ver}")
  if(kind STREQUAL "release")
    _oc_http_json("https://api.github.com/repos/${repo}/releases/latest" json code)
    if(code EQUAL 200)
      string(JSON latest ERROR_VARIABLE e GET "${json}" tag_name)
      if(latest MATCHES "^v[0-9]")
        string(SUBSTRING "${latest}" 1 -1 latest)
      endif()
    else()
      set(note "no published release (HTTP ${code})")
    endif()
  elseif(kind STREQUAL "commit")
    _oc_http_json("https://api.github.com/repos/${repo}/commits/${ref}" json code)
    if(code EQUAL 200)
      string(JSON head ERROR_VARIABLE e GET "${json}" sha)
      string(SUBSTRING "${head}" 0 12 latest)
      string(SUBSTRING "${ver}" 0 12 have)
    else()
      set(note "ref '${ref}' is gone (HTTP ${code})")
    endif()
  else()
    set(note "pinned by URL, not checked")
  endif()

  if(NOT "${note}" STREQUAL "")
    # already explained
  elseif(latest STREQUAL "${have}")
    set(note "${have}")
  else()
    math(EXPR stale "${stale}+1")
    set(note "${have} -> ${latest}")
  endif()
  list(APPEND rows "${label}\t${note}")
endforeach()

math(EXPR width "${width}+2")
foreach(row IN LISTS rows)
  string(REGEX REPLACE "\t.*" "" label "${row}")
  string(REGEX REPLACE "^[^\t]*\t" "" note "${row}")
  string(LENGTH "${label}" len)
  math(EXPR pad "${width}-${len}")
  string(REPEAT " " ${pad} spaces)
  message(STATUS "  ${label}${spaces}${note}")
endforeach()

if(stale EQUAL 0)
  message(STATUS "OCMake: everything is at the newest published version.")
else()
  message(STATUS
    "OCMake: ${stale} of the pinned items have a newer version.\n"
    "  Edit the VERSION in your CMakeLists.txt, or re-resolve a 'latest' pin with:\n"
    "    cmake -B <build> -DOC_UPDATE=ON")
endif()
