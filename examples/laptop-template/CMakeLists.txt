# A laptop starting point -- NOT a validated machine configuration.
#
# The b760i example next door reproduces a real, booted EFI. This one does not: its
# config.plist is OpenCore 1.0.7's own Docs/Sample.plist with laptop-shaped edits, and it
# has never booted anything. What it shows is the *declarations* a laptop needs and a
# desktop does not -- trackpad and keyboard drivers, battery and backlight, the ACPI
# tables that come out of OpenCore's own samples. Read README.md before using it.

cmake_minimum_required(VERSION 3.25...4.4)
project(laptop-template NONE)

if(NOT DEFINED OCMAKE_ROOT)
  set(OCMAKE_ROOT ${CMAKE_CURRENT_LIST_DIR}/../..)
endif()
include(${OCMAKE_ROOT}/OCMake.cmake)

oc_opencore(VERSION 1.0.7)

# --- kexts ------------------------------------------------------------------
# No VERSION means the newest release, pinned in ocmake.lock the first time it resolves.
# That is the right default for a template -- a new machine wants current kexts, and the
# lock keeps every build after the first reproducible. Pin a version when you have a
# reason to, as examples/b760i-aorus-pro does to reproduce one specific validated EFI.
oc_kext(Lilu           GITHUB acidanthera/Lilu)

# SMCBatteryManager and SMCLightSensor are the two plugins a desktop never takes: battery
# percentage and the ambient light sensor behind auto-brightness.
oc_kext(VirtualSMC     GITHUB acidanthera/VirtualSMC
        KEXTS VirtualSMC SMCProcessor SMCBatteryManager SMCLightSensor)

oc_kext(WhateverGreen  GITHUB acidanthera/WhateverGreen)
oc_kext(AppleALC       GITHUB acidanthera/AppleALC)

# Keyboard, and the trackpad on anything that still speaks PS/2. The release ships one
# bundle with its plugins inside, so no KEXTS selector is needed.
oc_kext(VoodooPS2      GITHUB acidanthera/VoodooPS2)

# I2C trackpad. Ships alongside VoodooPS2 quite happily: both bundle their own
# VoodooInput.kext, and the snapshot disables exactly the duplicate *entry* -- not either
# parent -- so the keyboard keeps working and the trackpad gets its driver.
oc_kext(VoodooI2C      GITHUB VoodooI2C/VoodooI2C KEXTS VoodooI2C VoodooI2CHID)

oc_kext(ECEnabler      GITHUB averycblack/ECEnabler)

oc_kext(BrightnessKeys GITHUB acidanthera/BrightnessKeys)  # brightness keys
oc_kext(NVMeFix        GITHUB acidanthera/NVMeFix)         # NVMe power saving
oc_kext(HibernationFixup GITHUB acidanthera/HibernationFixup)

# AMD APU laptops -- Ryzen with Vega or RDNA graphics -- drive the iGPU with NootedRed
# rather than WhateverGreen. Staged but disabled, because it is wrong for an Intel machine:
# if your laptop is AMD, flip this to ON and take WhateverGreen off.
#
# Pinned on purpose, and it is worth seeing why. Its tags carry a v prefix (v0.8.10) while
# its assets do not (NootedRed-0.8.10-RELEASE.zip), so oc_kext retries the v-prefixed tag.
# It also publishes RESEARCH_RELEASE builds next to RELEASE ones, which is the asset the
# resolver must not match -- the one case that made -RELEASE.zip an anchored pattern.
oc_kext(NootedRed      GITHUB ChefKissInc/NootedRed VERSION 0.8.10 ENABLED OFF)

# --- ACPI -------------------------------------------------------------------
# All three come straight out of OpenCorePkg's Docs/AcpiSamples/Source, compiled by iasl
# at build time -- nothing to commit, and they track the OpenCore version automatically.
#   SSDT-PLUG     CPU power management (XCPM plugin type)
#   SSDT-EC-USBX  the fake EC every Catalina-and-later machine needs, plus USB power
#                 (pre-Skylake machines want SSDT-EC instead)
#   SSDT-PNLF     backlight control -- laptop-only
oc_ssdt(SAMPLES SSDT-PLUG SSDT-EC-USBX SSDT-PNLF)

# --- drivers, resources, tools ----------------------------------------------
oc_driver(OpenRuntime OpenCanopy ResetNvramEntry)
oc_driver(OCBINARYDATA HfsPlus)
oc_resources(OCBINARYDATA AUDIO OFF IMAGE Acidanthera/GoldenGate FONT ON LABEL ON)
oc_tool(OpenShell)

# --- vaulting ---------------------------------------------------------------
# Sample.plist ships Misc/Security/Vault = Secure, and OCMake does not quietly relax it:
# a config that asks for a vault should get one, and a project that wants no vault says so
# itself. SECUREBOOT signs the manifest and embeds the public key in OpenCore.efi, so the
# manifest cannot be swapped without also replacing the binary that checks it.
#
# The name is a reminder rather than a promise: the chain ends at OpenCore.efi, and only
# firmware UEFI Secure Boot verifies that. Without it, this raises the cost of tampering;
# it does not stop it.
#
# All, not Release: running Debug day to day should not mean giving up the vault.
oc_vault(SECUREBOOT All)

oc_efi()
