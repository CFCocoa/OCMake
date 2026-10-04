# One machine, two EFIs: the one it boots from, and a rescue stick -- NOT a validated
# hardware configuration.
#
# PLAN.md's recovery story is "keep a known-good EFI on a USB stick", because on a separate
# volume the standard layout resolves against *that* filesystem: \EFI\BOOT\BOOTx64.efi finds
# \EFI\OC\OpenCore.efi on the stick, not on the internal ESP. This is that stick, declared
# rather than remembered -- so it is rebuilt from the same kexts whenever the main one is,
# instead of slowly rotting in a drawer.
#
# One flat file, grouped by category rather than by EFI. That is the right shape here
# because the two are nearly the same: keeping the kexts together makes it obvious that
# both get the same ones, and keeping the drivers together makes the difference visible on
# adjacent lines. The other layout -- one directory per EFI, examples/multi-efi -- suits
# two genuinely different machines.

cmake_minimum_required(VERSION 3.25...4.4)
project(multi-efi-flat NONE)

if(NOT DEFINED OCMAKE_ROOT)
  set(OCMAKE_ROOT ${CMAKE_CURRENT_LIST_DIR}/../..)
endif()
include(${OCMAKE_ROOT}/OCMake.cmake)

set(BOTH main rescue)

# --- OpenCore ---------------------------------------------------------------
foreach(efi IN LISTS BOTH)
  oc_opencore(EFI ${efi})
endforeach()

# --- kexts ------------------------------------------------------------------
# Identical on both, and declared once each so they cannot drift. A rescue EFI that boots
# with different kexts than the one it is rescuing is not much of a rescue.
foreach(efi IN LISTS BOTH)
  oc_kext(Lilu          GITHUB acidanthera/Lilu          EFI ${efi})
  oc_kext(VirtualSMC    GITHUB acidanthera/VirtualSMC    EFI ${efi}
          KEXTS VirtualSMC SMCProcessor)
  oc_kext(WhateverGreen GITHUB acidanthera/WhateverGreen EFI ${efi})
  oc_kext(AppleALC      GITHUB acidanthera/AppleALC      EFI ${efi})
endforeach()

# --- ACPI -------------------------------------------------------------------
foreach(efi IN LISTS BOTH)
  oc_ssdt(SAMPLES SSDT-PLUG SSDT-EC-USBX EFI ${efi})
endforeach()

# --- drivers ----------------------------------------------------------------
# Where they diverge, on adjacent lines. The rescue stick takes the smallest set that can
# boot: no picker theme to load, nothing to go wrong that is not also on the main EFI.
oc_driver(OpenRuntime OpenCanopy ResetNvramEntry EFI main)
oc_driver(OpenRuntime                            EFI rescue)

oc_resources(IMAGE Acidanthera/GoldenGate EFI main)

# --- tools ------------------------------------------------------------------
# Only on the stick. A shell is what you want when something has gone wrong, and is exactly
# what you do not want sitting on the EFI you boot every day.
oc_tool(OpenShell EFI rescue)

# --- config -----------------------------------------------------------------
# Two bases: the rescue one scans every volume, shows auxiliary entries so the shell is
# reachable, and waits ten seconds rather than booting straight through.
oc_config(config-main.plist   EFI main)
oc_config(config-rescue.plist EFI rescue)

# One secrets file for both. It is the same machine, so it is the same identifiers -- and
# an EFI that boots with someone else's serial is not a rescue either.
foreach(efi IN LISTS BOTH)
  oc_secrets(secrets.plist EFI ${efi})
endforeach()
