# Python environments for the scripts that need more than the standard library.
#
# Almost everything OCMake runs is stdlib-only and uses ${Python3_EXECUTABLE} directly.
# A few things cannot be: signing a Secure vault needs real RSA key generation, and
# hand-rolling that is not a trade worth making. This is the shared way to ask for an
# interpreter with a package available, so the next script that needs one does not invent
# its own answer.

# The venv is shared across projects and across packages, so the second caller costs
# nothing. Overridable for anyone who would rather point at an environment they manage.
set(OC_PYTHON_ENV "" CACHE PATH
    "Python environment for scripts needing third-party packages; empty = managed in OC_CACHE_DIR")

# _oc_python_env(<out_var> MODULE <import name> REQUIRE <pip requirement> REASON <what for>)
#
# Resolution order, cheapest first:
#   1. the interpreter already found -- a distro package or an active venv, nothing to do
#   2. the managed environment, if a previous call already provisioned it
#   3. provision: create the environment if needed, then install
#
# Step 1 matters more than it looks: on a machine where the package is already available
# nothing is downloaded, nothing is cached, and OC_OFFLINE stays satisfiable.
function(_oc_python_env out)
  cmake_parse_arguments(A "" "MODULE;REQUIRE;REASON" "" ${ARGN})
  if("${A_MODULE}" STREQUAL "" OR "${A_REQUIRE}" STREQUAL "")
    message(FATAL_ERROR "OCMake: _oc_python_env() needs MODULE and REQUIRE")
  endif()
  if(NOT Python3_Interpreter_FOUND)
    message(FATAL_ERROR "OCMake: ${A_REASON} needs Python 3.9+, which was not found.")
  endif()

  _oc_python_has("${Python3_EXECUTABLE}" "${A_MODULE}" found)
  if(found)
    set(${out} "${Python3_EXECUTABLE}" PARENT_SCOPE)
    return()
  endif()

  set(venv "${OC_PYTHON_ENV}")
  if("${venv}" STREQUAL "")
    # Keyed by interpreter version: an environment built for 3.9 is not usable from 3.13.
    set(venv "${OC_CACHE_DIR}/python-${Python3_VERSION_MAJOR}.${Python3_VERSION_MINOR}")
  endif()
  if(WIN32)
    set(py "${venv}/Scripts/python.exe")
  else()
    set(py "${venv}/bin/python")
  endif()

  if(EXISTS "${py}")
    _oc_python_has("${py}" "${A_MODULE}" found)
    if(found)
      set(${out} "${py}" PARENT_SCOPE)
      return()
    endif()
  endif()

  if(OC_OFFLINE)
    message(FATAL_ERROR
      "OCMake: ${A_REASON} needs the Python package '${A_MODULE}', which is neither "
      "importable nor already in\n  ${venv}\n"
      "OC_OFFLINE=ON forbids fetching it. Configure once without OC_OFFLINE, or install "
      "${A_MODULE} yourself and OCMake will use it.")
  endif()

  if(NOT EXISTS "${py}")
    _oc_info("creating a Python environment in ${venv} (once per machine)")
    execute_process(COMMAND "${Python3_EXECUTABLE}" -m venv "${venv}"
                    RESULT_VARIABLE rc OUTPUT_VARIABLE o ERROR_VARIABLE e)
    if(NOT rc EQUAL 0)
      message(FATAL_ERROR "OCMake: could not create ${venv}\n${o}${e}")
    endif()
  endif()

  _oc_info("installing ${A_REQUIRE} for ${A_REASON}")
  execute_process(
    COMMAND "${py}" -m pip install --disable-pip-version-check --quiet "${A_REQUIRE}"
    RESULT_VARIABLE rc OUTPUT_VARIABLE o ERROR_VARIABLE e)
  if(NOT rc EQUAL 0)
    message(FATAL_ERROR
      "OCMake: could not install ${A_REQUIRE} into ${venv}.\n"
      "Where no wheel exists for this platform and Python, pip falls back to building "
      "from source, which for some packages needs a Rust toolchain.\n${o}${e}")
  endif()
  _oc_python_has("${py}" "${A_MODULE}" found)
  if(NOT found)
    message(FATAL_ERROR
      "OCMake: installed ${A_REQUIRE} but '${A_MODULE}' still does not import.")
  endif()
  set(${out} "${py}" PARENT_SCOPE)
endfunction()

# Asked by import rather than by looking for a directory: an install interrupted halfway
# leaves something that looks present and is not.
function(_oc_python_has interpreter module out)
  execute_process(COMMAND "${interpreter}" -c "import ${module}"
                  RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
  if(rc EQUAL 0)
    set(${out} TRUE PARENT_SCOPE)
  else()
    set(${out} FALSE PARENT_SCOPE)
  endif()
endfunction()
