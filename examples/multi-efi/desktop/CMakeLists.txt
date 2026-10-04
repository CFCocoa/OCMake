# A desktop: graphical picker, discrete audio, no battery or backlight to worry about.

# Names the EFI everything below belongs to, for the rest of this scope. Nothing here
# needs an EFI keyword, and add_subdirectory() means it cannot leak into the other machine.
oc_efi(desktop)

include(${CMAKE_SOURCE_DIR}/common.cmake)

oc_kext(AppleALC       GITHUB acidanthera/AppleALC)
oc_kext(RestrictEvents GITHUB acidanthera/RestrictEvents)

oc_ssdt(SAMPLES SSDT-PLUG SSDT-EC-USBX)

# OpenCanopy needs Misc/Boot/PickerMode set to External, which config.plist does. Naming an
# icon set also writes Misc/Boot/PickerVariant, so the theme is stated once.
oc_driver(OpenCanopy ResetNvramEntry)
oc_resources(IMAGE Acidanthera/GoldenGate)
