# Staging script, run via `cmake -P`. Rebuilds OC_EFI_DIR from scratch per OC_MANIFEST.
#
# Wiping and recreating is deliberate (PLAN.md §6): it is the only way removals of kexts,
# SSDTs or drivers actually propagate to the output tree.

cmake_minimum_required(VERSION 3.25)

if(NOT DEFINED OC_MANIFEST OR NOT DEFINED OC_EFI_DIR)
  message(FATAL_ERROR "OCStage: OC_MANIFEST and OC_EFI_DIR must be defined")
endif()

# Copy a file or a directory tree to <EFI>/<dst>. Renaming is supported for both.
function(oc_stage_copy src dst)
  if(NOT EXISTS "${src}")
    message(FATAL_ERROR "OCStage: missing source '${src}' (for ${dst})")
  endif()
  set(out "${OC_EFI_DIR}/${dst}")
  get_filename_component(outdir "${out}" DIRECTORY)
  file(MAKE_DIRECTORY "${outdir}")
  if(IS_DIRECTORY "${src}")
    # Trailing slash copies the *contents*, which is what allows the rename.
    file(COPY "${src}/" DESTINATION "${out}"
         PATTERN ".DS_Store" EXCLUDE
         PATTERN "__MACOSX" EXCLUDE)
    # file(COPY) preserves source timestamps. Left alone, staged files inherit the
    # release zip's 2026 mtimes and read as older than the generated manifest, so the
    # build system would restage on every single build. Touch them to now.
    file(GLOB_RECURSE staged LIST_DIRECTORIES false "${out}/*")
    if(staged)
      file(TOUCH ${staged})
    endif()
  else()
    file(COPY_FILE "${src}" "${out}")
    file(TOUCH "${out}")
  endif()
endfunction()

function(oc_stage_mkdir dst)
  file(MAKE_DIRECTORY "${OC_EFI_DIR}/${dst}")
endfunction()

file(REMOVE_RECURSE "${OC_EFI_DIR}")
file(MAKE_DIRECTORY "${OC_EFI_DIR}")
include("${OC_MANIFEST}")
