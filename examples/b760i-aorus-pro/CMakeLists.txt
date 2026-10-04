# B760I AORUS PRO, validated for Sonoma. See README.md.
#
# The hand-written config.plist stays authoritative -- OCMake only rewrites the
# file-derived sections (ACPI.Add, Kernel.Add, UEFI.Drivers, Misc.Tools).
#
# config.plist and secrets.plist are picked up by name, and configuring with
# -DCMAKE_BUILD_TYPE=Debug adds OpenCore's usual debug knobs on top of them -- the same
# flag that switches OpenCore, every kext and the drivers to their DEBUG builds. All of
# that is OCMake's built-in defaults; the OC_DEFAULT_* block in OCMake.cmake spells out
# what they are and how to change them.

cmake_minimum_required(VERSION 3.25...4.4)
project(b760i-aorus-pro NONE)

if(NOT DEFINED OCMAKE_ROOT)
  set(OCMAKE_ROOT ${CMAKE_CURRENT_LIST_DIR}/../..)
endif()
include(${OCMAKE_ROOT}/OCMake.cmake)

oc_opencore(VERSION 1.0.7)

# --- kexts ------------------------------------------------------------------
# Every version here is pinned deliberately. VERSION now defaults to latest, which is the
# right default for a new machine, but this example reproduces one specific EFI that was
# validated on this board -- so it names what it was validated with. See
# examples/laptop-template for the other way round.
oc_kext(Lilu           GITHUB acidanthera/Lilu           VERSION 1.6.7)
oc_kext(VirtualSMC     GITHUB acidanthera/VirtualSMC     VERSION 1.3.2
        KEXTS VirtualSMC SMCProcessor SMCSuperIO)      # archive ships six; take three
oc_kext(WhateverGreen  GITHUB acidanthera/WhateverGreen  VERSION 1.6.6)
oc_kext(AppleALC       GITHUB acidanthera/AppleALC       VERSION 1.8.9)
oc_kext(CPUFriend      GITHUB acidanthera/CPUFriend      VERSION 1.2.7)
oc_kext(RestrictEvents GITHUB acidanthera/RestrictEvents VERSION 1.1.3)

# BlueToolFixup is published inside the BrcmPatchRAM release.
oc_kext(BlueToolFixup  GITHUB acidanthera/BrcmPatchRAM   VERSION 2.6.8
        KEXTS BlueToolFixup)

# Tagged v2.4.0 and v1.8 upstream; the resolver retries the v-prefixed tag. Both ship a
# single asset with no build variants, which is selected automatically.
oc_kext(IntelBluetooth GITHUB OpenIntelWireless/IntelBluetoothFirmware VERSION 2.4.0
        KEXTS IntelBluetoothFirmware IntelBTPatcher)
oc_kext(RadeonSensor   GITHUB aluveitie/RadeonSensor     VERSION 0.3.3
        KEXTS RadeonSensor SMCRadeonGPU)
oc_kext(AppleIGC       GITHUB SongXiaoXi/AppleIGC        VERSION 1.8)

# itlwm publishes one asset per macOS release rather than build variants.
oc_kext(AirportItlwm   GITHUB OpenIntelWireless/itlwm    VERSION 2.3.0
        ASSET "AirportItlwm_*_Sonoma14.4.kext.zip")

# Not fetchable: machine-generated, or rehabman-era with no GitHub releases.
oc_kext(CPUFriendDataProvider PATH kexts/CPUFriendDataProvider.kext)
oc_kext(USBInjectAll          PATH kexts/USBInjectAll.kext)
oc_kext(XHCI-unsupported      PATH kexts/XHCI-unsupported.kext)

# --- ACPI -------------------------------------------------------------------
# oc_ssdt(acpi/SSDT-PLUG-ALT.dsl) local file (useful if edited)
oc_ssdt(SAMPLES SSDT-PLUG-ALT)                     # compiled from OpenCore's own samples
oc_acpi(acpi/SSDT-AWAC.aml acpi/SSDT-EC-USBX.aml)  # prebuilt, no .dsl to compile from

# --- drivers ----------------------------------------------------------------
oc_driver(OpenCanopy OpenRuntime ResetNvramEntry ToggleSipEntry)

# HfsPlus.efi is Apple's own HFS+ driver, which OpenCorePkg cannot redistribute -- it
# lives only in OcBinaryData's tree, so it is fetched from a pinned commit rather than
# from a release. OpenCorePkg's OpenHfsPlus.efi is the open reimplementation and the
# drop-in alternative; most builds prefer this one for speed.
oc_driver(OCBINARYDATA HfsPlus)

# OpenCanopy draws nothing without these -- icons, font and entry labels all live in
# OcBinaryData, not in OpenCorePkg. Naming the icon set stages only that set and writes
# Misc/Boot/PickerVariant to match, so the theme is stated once. AUDIO OFF is the default
# and is spelled out here: it is 6.3 MB of .wav that only UEFI/Audio reads, and this board
# has AudioSupport disabled.
oc_resources(OCBINARYDATA AUDIO OFF IMAGE Acidanthera/GoldenGate FONT ON LABEL ON)

# --- tools ------------------------------------------------------------------
# OpenShell is the UEFI shell OpenCore ships for poking at the firmware from the picker --
# dumping ACPI tables, checking what the board really exposes. OCSnapshot marks it
# Auxiliary, and this config leaves Misc/Boot/HideAuxiliary false, so it appears in the
# picker rather than needing the spacebar toggle.
oc_tool(OpenShell)

oc_vault(SECUREBOOT release)

oc_efi()
