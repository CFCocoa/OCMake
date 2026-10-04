# oc_config() and the config.plist assembly step.

# oc_config(<path to hand-written config.plist> [CLEAN] [EFI <name>])
#
# CLEAN rebuilds all four derived sections from the staged tree instead of merging into
# them -- ProperTree's "OC Clean Snapshot". It is rarely needed: a section still identical
# to OpenCore's own Docs/Sample.plist is detected and rebuilt anyway, and merging is what
# keeps hand-written Comments and driver Arguments alive.
function(oc_config path)
  cmake_parse_arguments(A "CLEAN" "EFI" "" ${ARGN})
  _oc_target(t "${A_EFI}")
  get_filename_component(abs "${path}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
  # A path that does not exist yet is not an error -- it is a new project. Finalization
  # creates it from the OpenCore package's own Docs/Sample.plist; see _oc_scaffold_config().
  set_property(TARGET ${t} PROPERTY OC_CONFIG_BASE "${abs}")
  set_property(TARGET ${t} PROPERTY OC_CONFIG_CLEAN "${A_CLEAN}")
endfunction()

# CONFIG <type> limits a declaration to one build type. Evaluated at configure time:
# OCMake is single-config by design (two build dirs coexist instead), so there is no need
# for generator expressions -- and the Python side never has to know about build types.
function(_oc_config_applies cfg out)
  if("${cfg}" STREQUAL "")
    set(${out} TRUE PARENT_SCOPE)
    return()
  endif()
  # Compare against the effective variant only. Also accepting CMAKE_BUILD_TYPE meant
  # that with -DOC_BUILD=DEBUG -DCMAKE_BUILD_TYPE=Release *both* CONFIG Debug and CONFIG
  # Release ops applied -- and it masked a build-type switching bug, because a CONFIG op
  # kept firing off CMAKE_BUILD_TYPE while the staged binaries followed OC_BUILD.
  string(TOUPPER "${cfg}" want)
  if(want STREQUAL "${OC_BUILD}")
    set(${out} TRUE PARENT_SCOPE)
  else()
    set(${out} FALSE PARENT_SCOPE)
  endif()
endfunction()

# Ops are applied in declaration order, so they are stored indexed rather than as a list:
# a JSON blob or a keypath value could contain a semicolon and corrupt a CMake list.
function(_oc_add_op t kind out_index)
  get_property(count TARGET ${t} PROPERTY OC_CFG_OP_COUNT)
  # NB: not if(NOT count). The unary form of if() matches CMake's constant table -- which
  # contains N, Y, NO, OFF, IGNORE -- *before* dereferencing, case-insensitively. A
  # variable named n therefore always reads as false, whatever it holds.
  if("${count}" STREQUAL "")
    set(count 0)
  endif()
  set_property(TARGET ${t} PROPERTY OC_CFG_OP_${count}_KIND "${kind}")
  math(EXPR next "${count}+1")
  set_property(TARGET ${t} PROPERTY OC_CFG_OP_COUNT ${next})
  set(${out_index} ${count} PARENT_SCOPE)
endfunction()

# oc_config_overlay(<fragment.plist> [CONFIG <type>] [EFI <name>])
# Deep-merged over the base: dicts merge recursively, everything else replaces.
function(oc_config_overlay path)
  cmake_parse_arguments(A "" "CONFIG;EFI" "" ${ARGN})
  _oc_config_applies("${A_CONFIG}" applies)
  if(NOT applies)
    return()
  endif()
  _oc_target(t "${A_EFI}")
  get_filename_component(abs "${path}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
  if(NOT EXISTS "${abs}")
    message(FATAL_ERROR "OCMake: oc_config_overlay() file does not exist:\n  ${abs}")
  endif()
  _oc_add_op(${t} overlay i)
  set_property(TARGET ${t} PROPERTY OC_CFG_OP_${i}_PATH "${abs}")
endfunction()

# oc_config_set(<keypath> <TYPE> <value> [CONFIG <type>] [EFI <name>])
# Keypath separator is '/', because NVRAM GUIDs contain dashes and dots would be ambiguous.
# Numeric components index into arrays: Kernel/Add/0/Enabled.
function(oc_config_set keypath type value)
  cmake_parse_arguments(A "" "CONFIG;EFI" "" ${ARGN})
  _oc_config_applies("${A_CONFIG}" applies)
  if(NOT applies)
    return()
  endif()
  string(TOUPPER "${type}" type)
  set(known STRING INTEGER BOOL DATA REAL)
  if(NOT type IN_LIST known)
    string(REPLACE ";" ", " listing "${known}")
    message(FATAL_ERROR "OCMake: oc_config_set() type must be one of ${listing}, got '${type}'")
  endif()
  _oc_target(t "${A_EFI}")
  _oc_add_op(${t} set i)
  set_property(TARGET ${t} PROPERTY OC_CFG_OP_${i}_KEYPATH "${keypath}")
  set_property(TARGET ${t} PROPERTY OC_CFG_OP_${i}_TYPE "${type}")
  set_property(TARGET ${t} PROPERTY OC_CFG_OP_${i}_VALUE "${value}")
endfunction()

# oc_boot_args([APPEND <arg> ...] [REMOVE <arg> ...] [CONFIG <type>] [EFI <name>])
# Edits NVRAM boot-args in place rather than replacing it, so hand-written args survive.
function(oc_boot_args)
  cmake_parse_arguments(A "" "CONFIG;EFI" "APPEND;REMOVE" ${ARGN})
  _oc_config_applies("${A_CONFIG}" applies)
  if(NOT applies)
    return()
  endif()
  if(NOT A_APPEND AND NOT A_REMOVE)
    message(FATAL_ERROR "OCMake: oc_boot_args() needs APPEND or REMOVE")
  endif()
  _oc_target(t "${A_EFI}")
  _oc_add_op(${t} bootargs i)
  set_property(TARGET ${t} PROPERTY OC_CFG_OP_${i}_APPEND "${A_APPEND}")
  set_property(TARGET ${t} PROPERTY OC_CFG_OP_${i}_REMOVE "${A_REMOVE}")
endfunction()

# oc_secrets(<plist> [OPTIONAL] [EFI <name>])
# Merged last, after the snapshot and every override, so machine identifiers never need to
# live in the committed config.plist.
function(oc_secrets path)
  cmake_parse_arguments(A "OPTIONAL" "EFI" "" ${ARGN})
  _oc_target(t "${A_EFI}")
  get_filename_component(abs "${path}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
  if(NOT EXISTS "${abs}")
    if(A_OPTIONAL)
      return()
    endif()
    set(hint "")
    if(EXISTS "${abs}.example")
      set(hint "\nStart from the template: cp ${abs}.example ${abs}")
    endif()
    message(FATAL_ERROR
      "OCMake: oc_secrets() file does not exist:\n  ${abs}${hint}\n"
      "Pass OPTIONAL to allow building without it.")
  endif()
  set_property(TARGET ${t} PROPERTY OC_CFG_SECRETS "${abs}")
endfunction()

# --- built-in defaults --------------------------------------------------------------
# The values live in OCMake.cmake, as OC_DEFAULT_*; this is only the machinery that
# applies them. It runs at two different moments, because "an explicit declaration wins"
# means two different things:
#
#   ops   are ordered, so the defaults are seeded when the EFI is created -- ahead of
#         every project declaration, which therefore overrides simply by coming later.
#   files are single-valued, so they are filled in at finalization -- the first point at
#         which it is known that the project declared none of its own.

# Seeded from _oc_create_efi(). DEBUG only: config.plist is rebuilt from the hand-written
# base on every build, so a Release build needs no counterpart to undo these.
function(_oc_default_ops n)
  if(NOT OC_DEFAULTS OR NOT OC_BUILD STREQUAL "DEBUG")
    return()
  endif()
  set(applied "")
  foreach(entry IN LISTS OC_DEFAULT_DEBUG_SET)
    # UNIX_COMMAND rather than a plain split, so a value containing spaces can be quoted.
    separate_arguments(parts UNIX_COMMAND "${entry}")
    list(LENGTH parts fields)
    if(NOT fields EQUAL 3)
      message(FATAL_ERROR
        "OCMake: OC_DEFAULT_DEBUG_SET entries are '<keypath> <TYPE> <value>', got:\n  ${entry}")
    endif()
    list(GET parts 0 keypath)
    list(GET parts 1 type)
    list(GET parts 2 value)
    oc_config_set("${keypath}" "${type}" "${value}" EFI "${n}")
    list(APPEND applied "${keypath}=${value}")
  endforeach()
  if(NOT "${OC_DEFAULT_DEBUG_BOOT_ARGS}" STREQUAL "")
    oc_boot_args(APPEND ${OC_DEFAULT_DEBUG_BOOT_ARGS} EFI "${n}")
    string(REPLACE ";" " " args "${OC_DEFAULT_DEBUG_BOOT_ARGS}")
    list(APPEND applied "boot-args += ${args}")
  endif()
  set_property(TARGET oc_${n} APPEND PROPERTY OC_DEFAULTS_APPLIED ${applied})
endfunction()

# Create a project's config.plist when it has none yet.
#
# Two ways to arrive at an OCMake project, and this is what separates them:
#
#   greenfield  no config.plist on disk -> OCMake writes one, cleaned, from the OpenCore
#               package's own Docs/Sample.plist
#   migration   a config.plist exists   -> it is the user's, and it is merged into
#
# File existence is a fact, so neither case needs detecting. The point of writing the file
# cleaned is that a config.plist in an OCMake project is then never a raw Sample.plist
# copy: OCSnapshot merges, and the sample's own entries -- including a *disabled*
# VoodooPS2Controller.kext -- would otherwise outrank what the project declares.
function(_oc_scaffold_config n t path)
  get_property(pkg TARGET ${t} PROPERTY OC_OPENCORE_PKG)
  set(sample "${pkg}/Docs/Sample.plist")
  if(NOT EXISTS "${sample}")
    _oc_warn("'${n}' has no config.plist and the OpenCore package ships no Docs/Sample.plist "
             "to start one from:\n  ${sample}")
    return()
  endif()
  if(NOT Python3_Interpreter_FOUND)
    message(FATAL_ERROR "OCMake: creating a config.plist needs Python 3.9+, which was not found.")
  endif()
  execute_process(
    COMMAND "${Python3_EXECUTABLE}" "${OCMAKE_DIR}/scripts/oc_config.py"
            --sample "${sample}" --scaffold "${path}"
    RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
  if(NOT rc EQUAL 0)
    message(FATAL_ERROR "OCMake: could not create ${path}\n${out}${err}")
  endif()
  get_property(ver TARGET ${t} PROPERTY OC_OPENCORE_VER)
  _oc_relpath("${path}" rel)
  _oc_info("created ${rel} from OpenCore ${ver}'s Docs/Sample.plist -- "
           "hand-written from here on, so commit it")
endfunction()

# Called from _oc_finalize_one(). Returns what it filled in, for the status line.
function(_oc_default_files n t out)
  set(applied "")
  if(NOT OC_DEFAULTS)
    set(${out} "" PARENT_SCOPE)
    return()
  endif()
  get_property(dir TARGET ${t} PROPERTY OC_DECL_DIR)

  get_property(base TARGET ${t} PROPERTY OC_CONFIG_BASE)
  if("${base}" STREQUAL "" AND NOT "${OC_DEFAULT_CONFIG}" STREQUAL "")
    # Two EFIs declared in one directory would both default to the same file, and would
    # then share one machine's config while appearing to have their own. Silent, and never
    # what anyone means. An *explicit* oc_config() pointing both at one base is left alone:
    # that is a choice, and this is not.
    set(want "${dir}/${OC_DEFAULT_CONFIG}")
    get_property(claimed GLOBAL PROPERTY OC_CONFIG_CLAIMED)
    if("${want}" IN_LIST claimed)
      _oc_relpath("${want}" rel)
      message(FATAL_ERROR
        "OCMake: EFI '${n}' would default to ${rel}, which another EFI in this directory "
        "already uses.\nGive each one its own base, e.g.\n"
        "  oc_config(${n}/config.plist EFI ${n})")
    endif()
    set_property(GLOBAL APPEND PROPERTY OC_CONFIG_CLAIMED "${want}")
    # Whether or not it exists yet: if it does not, it is about to.
    oc_config("${want}" EFI "${n}")
    list(APPEND applied "${OC_DEFAULT_CONFIG}")
  endif()

  get_property(secrets TARGET ${t} PROPERTY OC_CFG_SECRETS)
  if("${secrets}" STREQUAL "" AND NOT "${OC_DEFAULT_SECRETS}" STREQUAL "")
    set(path "${dir}/${OC_DEFAULT_SECRETS}")
    # A committed <file>.example template is how a project says it uses secrets: with one
    # present, a missing secrets.plist is a mistake worth stopping for, and oc_secrets()
    # already reports it and names the template. With neither, the project has no secrets.
    if(EXISTS "${path}" OR EXISTS "${path}.example")
      oc_secrets("${path}" EFI "${n}")
      list(APPEND applied "${OC_DEFAULT_SECRETS}")
    endif()
  endif()
  set(${out} "${applied}" PARENT_SCOPE)
endfunction()

function(_oc_json_str s out)
  string(REPLACE "\\" "\\\\" s "${s}")
  string(REPLACE "\"" "\\\"" s "${s}")
  string(REPLACE "\n" "\\n" s "${s}")
  string(REPLACE "\t" "\\t" s "${s}")
  set(${out} "\"${s}\"" PARENT_SCOPE)
endfunction()

# Declared per-entry overrides, as JSON for scripts/oc_config.py. JSON is used here
# because the consumer is Python -- the staging manifest stays CMake for the same reason.
function(_oc_write_overrides t file)
  get_property(bundles TARGET ${t} PROPERTY OC_KEXT_OVERRIDDEN)
  set(objects "")
  if(bundles)
    list(REMOVE_DUPLICATES bundles)
    list(SORT bundles)
  endif()
  foreach(bn IN LISTS bundles)
    string(REGEX REPLACE "[^A-Za-z0-9]" "_" tok "${bn}")
    set(fields "")
    foreach(pair "MIN_KERNEL;MinKernel" "MAX_KERNEL;MaxKernel" "ARCH;Arch"
                 "ENABLED;Enabled" "COMMENT;Comment")
      list(GET pair 0 f)
      list(GET pair 1 key)
      get_property(v TARGET ${t} PROPERTY OC_KOVR_${tok}_${f})
      if(NOT "${v}" STREQUAL "")
        if(f STREQUAL "ENABLED")
          if(v)
            set(json "true")
          else()
            set(json "false")
          endif()
        else()
          _oc_json_str("${v}" json)
        endif()
        _oc_json_str("${key}" kjson)
        if(fields)
          string(APPEND fields ",")
        endif()
        string(APPEND fields "${kjson}:${json}")
      endif()
    endforeach()
    _oc_json_str("${bn}" bjson)
    if(objects)
      string(APPEND objects ",")
    endif()
    string(APPEND objects "${bjson}:{${fields}}")
  endforeach()

  get_property(ksrcs TARGET ${t} PROPERTY OC_KEXT_SRCS)
  set(declared "")
  foreach(k IN LISTS ksrcs)
    get_filename_component(kn "${k}" NAME)
    _oc_json_str("${kn}" kj)
    if(declared)
      string(APPEND declared ",")
    endif()
    string(APPEND declared "${kj}")
  endforeach()

  _oc_ops_json(${t} ops)
  get_property(secrets TARGET ${t} PROPERTY OC_CFG_SECRETS)
  set(sjson "null")
  if(secrets)
    _oc_json_str("${secrets}" sjson)
  endif()
  file(WRITE "${file}"
     "{\"ops\":[${ops}],\"kexts\":{${objects}},\"declared_kexts\":[${declared}],\"secrets\":${sjson}}\n")
endfunction()

function(_oc_json_list values out)
  set(items "")
  foreach(v IN LISTS values)
    _oc_json_str("${v}" j)
    if(items)
      string(APPEND items ",")
    endif()
    string(APPEND items "${j}")
  endforeach()
  set(${out} "[${items}]" PARENT_SCOPE)
endfunction()

function(_oc_ops_json t out)
  get_property(count TARGET ${t} PROPERTY OC_CFG_OP_COUNT)
  if(NOT count)
    set(${out} "" PARENT_SCOPE)
    return()
  endif()
  math(EXPR last "${count}-1")
  set(acc "")
  foreach(i RANGE ${last})
    get_property(kind TARGET ${t} PROPERTY OC_CFG_OP_${i}_KIND)
    if(kind STREQUAL "overlay")
      get_property(v TARGET ${t} PROPERTY OC_CFG_OP_${i}_PATH)
      _oc_json_str("${v}" vj)
      set(obj "{\"op\":\"overlay\",\"path\":${vj}}")
    elseif(kind STREQUAL "set")
      get_property(kp TARGET ${t} PROPERTY OC_CFG_OP_${i}_KEYPATH)
      get_property(ty TARGET ${t} PROPERTY OC_CFG_OP_${i}_TYPE)
      get_property(va TARGET ${t} PROPERTY OC_CFG_OP_${i}_VALUE)
      _oc_json_str("${kp}" kpj)
      _oc_json_str("${ty}" tyj)
      _oc_json_str("${va}" vaj)
      set(obj "{\"op\":\"set\",\"keypath\":${kpj},\"type\":${tyj},\"value\":${vaj}}")
    elseif(kind STREQUAL "bootargs")
      get_property(ap TARGET ${t} PROPERTY OC_CFG_OP_${i}_APPEND)
      get_property(rm TARGET ${t} PROPERTY OC_CFG_OP_${i}_REMOVE)
      _oc_json_list("${ap}" apj)
      _oc_json_list("${rm}" rmj)
      set(obj "{\"op\":\"bootargs\",\"append\":${apj},\"remove\":${rmj}}")
    else()
      message(FATAL_ERROR "OCMake: unknown config op '${kind}'")
    endif()
    if(acc)
      string(APPEND acc ",")
    endif()
    string(APPEND acc "${obj}")
  endforeach()
  set(${out} "${acc}" PARENT_SCOPE)
endfunction()

# Adds the config.plist build step. Returns its output path in out_var (empty when the
# project declared no oc_config()).
function(_oc_add_config_step n t outdir stamp out_var)
  set(${out_var} "" PARENT_SCOPE)
  get_property(base TARGET ${t} PROPERTY OC_CONFIG_BASE)
  if(NOT base)
    return()
  endif()
  get_property(ver TARGET ${t} PROPERTY OC_OPENCORE_VER)
  # The version selects OCSnapshot's schema. Anything it does not recognise falls back to
  # the *oldest* schema (UEFI.Drivers as bare strings), which then crashes it -- so pass
  # the flag only for a plausible version and otherwise let it auto-detect from the binary.
  if(NOT ver MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+$")
    set(ver "")
  endif()

  set(sample_args "")
  get_property(clean TARGET ${t} PROPERTY OC_CONFIG_CLEAN)
  if(clean)
    list(APPEND sample_args --clean)
  endif()

  set(overrides "${CMAKE_BINARY_DIR}/_oc/${n}-overrides.json")
  _oc_write_overrides(${t} "${overrides}")

  # Overlays and the secrets file are inputs: editing one must rebuild config.plist.
  set(extra_deps "")
  get_property(count TARGET ${t} PROPERTY OC_CFG_OP_COUNT)
  if(count)
    math(EXPR last "${count}-1")
    foreach(i RANGE ${last})
      get_property(kind TARGET ${t} PROPERTY OC_CFG_OP_${i}_KIND)
      if(kind STREQUAL "overlay")
        get_property(v TARGET ${t} PROPERTY OC_CFG_OP_${i}_PATH)
        list(APPEND extra_deps "${v}")
      endif()
    endforeach()
  endif()
  get_property(secrets TARGET ${t} PROPERTY OC_CFG_SECRETS)
  if(secrets)
    list(APPEND extra_deps "${secrets}")
  endif()

  if(NOT Python3_Interpreter_FOUND)
    message(FATAL_ERROR "OCMake: oc_config() needs Python 3.9+, which was not found.")
  endif()

  set(out "${outdir}/OC/config.plist")
  set(script "${OCMAKE_DIR}/scripts/oc_config.py")
  set(snapshot "${OCMAKE_DIR}/third_party/OCSnapshot/OCSnapshot.py")
  if(NOT EXISTS "${snapshot}")
    message(FATAL_ERROR "OCMake: vendored OCSnapshot is missing:\n  ${snapshot}")
  endif()
  file(GLOB snapshot_srcs "${OCMAKE_DIR}/third_party/OCSnapshot/Scripts/*")

  # Depends on the staging stamp, so this reruns whenever the tree is rebuilt -- staging
  # wipes EFI/, config.plist included.
  add_custom_command(
    OUTPUT "${out}"
    COMMAND "${Python3_EXECUTABLE}" "${script}"
            --base "${base}"
            --oc-dir "${outdir}/OC"
            --snapshot "${snapshot}"
            --overrides "${overrides}"
            $<$<BOOL:${ver}>:--oc-version> $<$<BOOL:${ver}>:${ver}>
            ${sample_args}
            --out "${out}"
    DEPENDS "${stamp}" "${base}" "${overrides}" "${script}" "${snapshot}" ${snapshot_srcs}
            ${extra_deps}
    COMMENT "Building config.plist for '${n}' (snapshot + overrides)"
    VERBATIM)
  set(${out_var} "${out}" PARENT_SCOPE)
endfunction()
