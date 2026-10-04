# A laptop: builtin picker, PS/2 keyboard, backlight.

# Names the EFI everything below belongs to, for the rest of this scope. Nothing here
# needs an EFI keyword, and add_subdirectory() means it cannot leak into the other machine.
oc_efi(laptop)

include(${CMAKE_SOURCE_DIR}/common.cmake)

oc_kext(VoodooPS2      GITHUB acidanthera/VoodooPS2)
oc_kext(BrightnessKeys GITHUB acidanthera/BrightnessKeys)

# SSDT-PNLF is backlight control: a laptop needs it and a desktop has no use for it.
oc_ssdt(SAMPLES SSDT-PLUG SSDT-EC-USBX SSDT-PNLF)

# Apple's HFS+ driver, which OpenCorePkg cannot redistribute.
oc_driver(OCBINARYDATA HfsPlus)

