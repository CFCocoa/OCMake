# oc_ssdt() and oc_acpi(): ACPI tables, compiled or prebuilt.

# Pinned fallbacks, per platform:
#
#   macOS   MaciASL commits standalone binaries; Dist/iasl-stable is a universal binary
#           covering Apple silicon and Intel.
#   Windows open-acpica/acpica publishes binaries with every release. NB: the asset named
#           plain "iasl" is the 64-bit *Windows* build (PE32+ x86-64) -- verified with
#           file(1), as are acpidump/acpixtract/acpibin. The ".exe" assets are the 32-bit
#           builds. There is no Linux asset despite the extensionless name suggesting one.
#   Linux   No prebuilt binary is published anywhere, so OCMake asks for the distro
#           package -- which every distro ships.
set(OC_IASL_MACIASL_TAG "1.6.5" CACHE STRING "MaciASL tag providing the macOS iasl")
set(OC_IASL_MACIASL_SHA "93f1f48e6f1ea26b14b45f4a0b6e65a660c1cc6f14969348ec9411ae6b969c12"
    CACHE STRING "SHA256 of the macOS fallback iasl")
set(OC_IASL_ACPICA_TAG "20260408" CACHE STRING "open-acpica/acpica tag providing the Windows iasl")
set(OC_IASL_ACPICA_SHA "b000412c096760f83f8dd8435429deaaac9097e613fddde63037841e7557d1b0"
    CACHE STRING "SHA256 of the Windows fallback iasl")

function(_oc_require_iasl out)
  if(OC_IASL AND EXISTS "${OC_IASL}")
    set(${out} "${OC_IASL}" PARENT_SCOPE)
    return()
  endif()

  find_program(OC_IASL NAMES iasl
               HINTS /opt/homebrew/bin /usr/local/bin /usr/bin
               DOC "Intel ACPI Source Language compiler")
  if(OC_IASL)
    _oc_info("iasl: ${OC_IASL}")
    set(${out} "${OC_IASL}" PARENT_SCOPE)
    return()
  endif()

  set(url "")
  if(APPLE)
    set(dest "${OC_CACHE_DIR}/iasl-maciasl-${OC_IASL_MACIASL_TAG}")
    set(url "https://raw.githubusercontent.com/acidanthera/MaciASL/${OC_IASL_MACIASL_TAG}/Dist/iasl-stable")
    set(sha "${OC_IASL_MACIASL_SHA}")
    set(what "the pinned MaciASL build")
  elseif(WIN32)
    set(dest "${OC_CACHE_DIR}/iasl-acpica-${OC_IASL_ACPICA_TAG}.exe")
    set(url "https://github.com/open-acpica/acpica/releases/download/${OC_IASL_ACPICA_TAG}/iasl")
    set(sha "${OC_IASL_ACPICA_SHA}")
    set(what "the pinned open-acpica build")
  endif()

  if(url STREQUAL "")
    message(FATAL_ERROR
      "OCMake: iasl (the ACPI compiler) was not found, and no prebuilt binary is published\n"
      "for this platform -- install the distro package:\n"
      "  Debian/Ubuntu : sudo apt install acpica-tools\n"
      "  Fedora        : sudo dnf install acpica-tools\n"
      "  Arch          : sudo pacman -S acpica\n"
      "Or point at one directly: -DOC_IASL=/path/to/iasl")
  endif()

  if(NOT EXISTS "${dest}")
    if(OC_OFFLINE)
      message(FATAL_ERROR
        "OCMake: iasl is not installed and OC_OFFLINE=ON prevents fetching it.\n"
        "Install it locally, or pass -DOC_IASL=/path/to/iasl.")
    endif()
    _oc_info("iasl not found; fetching ${what}")
    file(MAKE_DIRECTORY "${OC_CACHE_DIR}")
    file(DOWNLOAD "${url}" "${dest}" EXPECTED_HASH SHA256=${sha} STATUS st)
    list(GET st 0 code)
    if(NOT code EQUAL 0)
      list(GET st 1 err)
      file(REMOVE "${dest}")
      message(FATAL_ERROR "OCMake: could not download iasl: ${err}\n  ${url}")
    endif()
  endif()
  file(CHMOD "${dest}" PERMISSIONS
       OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
  set(OC_IASL "${dest}" CACHE FILEPATH "Intel ACPI Source Language compiler" FORCE)
  set(${out} "${dest}" PARENT_SCOPE)
endfunction()

# Strip one trailing extension. get_filename_component(NAME_WE) cuts at the *first* dot,
# which mangles names like SSDT-XHC.1.dsl.
function(_oc_basename path out)
  get_filename_component(fname "${path}" NAME)
  string(REGEX REPLACE "\\.[^.]*$" "" fname "${fname}")
  set(${out} "${fname}" PARENT_SCOPE)
endfunction()

# Ordered storage, so a FLAGS list containing a semicolon cannot corrupt a parallel list.
function(_oc_add_acpi_compile t src out prefix flags)
  get_property(count TARGET ${t} PROPERTY OC_ACPI_COMPILE_COUNT)
  if("${count}" STREQUAL "")
    set(count 0)
  endif()
  set_property(TARGET ${t} PROPERTY OC_ACPI_COMPILE_${count}_SRC "${src}")
  set_property(TARGET ${t} PROPERTY OC_ACPI_COMPILE_${count}_OUT "${out}")
  set_property(TARGET ${t} PROPERTY OC_ACPI_COMPILE_${count}_PREFIX "${prefix}")
  set_property(TARGET ${t} PROPERTY OC_ACPI_COMPILE_${count}_FLAGS "${flags}")
  math(EXPR next "${count}+1")
  set_property(TARGET ${t} PROPERTY OC_ACPI_COMPILE_COUNT ${next})
endfunction()

# Called from _oc_finalize_one(), in the directory where the consuming targets are created.
function(_oc_add_acpi_steps t)
  get_property(count TARGET ${t} PROPERTY OC_ACPI_COMPILE_COUNT)
  if("${count}" STREQUAL "")
    return()
  endif()
  get_property(iasl TARGET ${t} PROPERTY OC_IASL)
  math(EXPR last "${count}-1")
  foreach(i RANGE ${last})
    get_property(src    TARGET ${t} PROPERTY OC_ACPI_COMPILE_${i}_SRC)
    get_property(out    TARGET ${t} PROPERTY OC_ACPI_COMPILE_${i}_OUT)
    get_property(prefix TARGET ${t} PROPERTY OC_ACPI_COMPILE_${i}_PREFIX)
    get_property(flags  TARGET ${t} PROPERTY OC_ACPI_COMPILE_${i}_FLAGS)
    get_filename_component(base "${out}" NAME_WE)
    # iasl exits 255 on a compile error and prints the offending line, so a failed build
    # surfaces the real diagnostic. -p sets the output prefix; without -tc it writes only
    # the .aml (with it, a stray .hex lands next to it).
    add_custom_command(
      OUTPUT "${out}"
      COMMAND "${iasl}" ${flags} -p "${prefix}" "${src}"
      DEPENDS "${src}"
      COMMENT "Compiling ${base}.dsl"
      VERBATIM)
  endforeach()
endfunction()

# oc_ssdt(<file.dsl> ... [SAMPLES <name> ...] [FLAGS <extra iasl flags>] [EFI <name>])
#
# SAMPLES compiles a table straight out of OpenCorePkg's Docs/AcpiSamples/Source/, which
# is already on disk from oc_opencore() -- no need to commit a copy of an upstream file
# you do not intend to edit. Anything you *do* edit belongs in the repo as a plain path.
function(oc_ssdt)
  cmake_parse_arguments(A "" "EFI" "FLAGS;SAMPLES" ${ARGN})
  _oc_target(t "${A_EFI}")
  if(NOT A_UNPARSED_ARGUMENTS AND NOT A_SAMPLES)
    message(FATAL_ERROR "OCMake: oc_ssdt() needs at least one .dsl file or SAMPLES entry")
  endif()

  if(A_SAMPLES)
    get_property(pkg TARGET ${t} PROPERTY OC_OPENCORE_PKG)
    if(NOT pkg)
      message(FATAL_ERROR
        "OCMake: oc_ssdt(SAMPLES ...) needs the OpenCore package; call oc_opencore() first.")
    endif()
    set(dir "${pkg}/Docs/AcpiSamples/Source")
    foreach(name IN LISTS A_SAMPLES)
      if(NOT name MATCHES "\\.dsl$")
        set(name "${name}.dsl")
      endif()
      if(NOT EXISTS "${dir}/${name}")
        file(GLOB avail RELATIVE "${dir}" "${dir}/*.dsl")
        list(SORT avail)
        string(REPLACE ";" "\n    " listing "${avail}")
        message(FATAL_ERROR
          "OCMake: '${name}' is not an OpenCore ACPI sample.\nAvailable:\n    ${listing}")
      endif()
      list(APPEND A_UNPARSED_ARGUMENTS "${dir}/${name}")
      set_property(TARGET ${t} APPEND PROPERTY OC_ACPI_SAMPLES "${name}")
    endforeach()
  endif()
  _oc_require_iasl(iasl)
  set_property(TARGET ${t} PROPERTY OC_IASL "${iasl}")
  get_property(n TARGET ${t} PROPERTY OC_NAME)
  set(gen "${CMAKE_BINARY_DIR}/_oc/acpi/${n}")
  file(MAKE_DIRECTORY "${gen}")

  foreach(src IN LISTS A_UNPARSED_ARGUMENTS)
    get_filename_component(abs "${src}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    if(NOT EXISTS "${abs}")
      message(FATAL_ERROR "OCMake: oc_ssdt() source does not exist:\n  ${abs}")
    endif()
    _oc_basename("${abs}" base)
    set(aml "${gen}/${base}.aml")
    # Recorded now, compiled at finalization. add_custom_command(OUTPUT) is visible only to
    # targets in the directory that created it, and the targets are created by the deferred
    # finalize at the top level -- so a project that declares its SSDTs in a subdirectory
    # would otherwise build rules nothing can reach. Everything else already works this
    # way; this was the one declaration that created a rule where it stood.
    _oc_add_acpi_compile(${t} "${abs}" "${aml}" "${gen}/${base}" "${A_FLAGS}")
    set_property(TARGET ${t} APPEND PROPERTY OC_ACPI_SRCS "${aml}")
    get_property(samples TARGET ${t} PROPERTY OC_ACPI_SAMPLES)
    get_filename_component(srcname "${abs}" NAME)
    if(srcname IN_LIST samples)
      _oc_provenance(${t} ACPI "${base}.aml" ORIGIN compiled-sample SOURCE "${srcname}")
    else()
      _oc_relpath("${abs}" rel)
      _oc_provenance(${t} ACPI "${base}.aml" ORIGIN compiled SOURCE "${rel}")
    endif()
  endforeach()
endfunction()

# oc_acpi(<file.aml> ... [EFI <name>]) -- prebuilt tables, e.g. generated by SSDTTime.
function(oc_acpi)
  cmake_parse_arguments(A "" "EFI" "" ${ARGN})
  _oc_target(t "${A_EFI}")
  foreach(src IN LISTS A_UNPARSED_ARGUMENTS)
    get_filename_component(abs "${src}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    if(NOT EXISTS "${abs}")
      message(FATAL_ERROR "OCMake: oc_acpi() file does not exist:\n  ${abs}")
    endif()
    set_property(TARGET ${t} APPEND PROPERTY OC_ACPI_SRCS "${abs}")
    get_filename_component(an "${abs}" NAME)
    _oc_relpath("${abs}" rel)
    _oc_provenance(${t} ACPI "${an}" ORIGIN prebuilt SOURCE "${rel}")
  endforeach()
endfunction()
