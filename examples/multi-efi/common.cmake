# Declarations every machine in this repo wants.
#
# There is nothing parameterised here, and that is the point: include() runs in the calling
# directory's scope, so whichever OC_EFI that directory set is still in force. Adding a
# third machine means one more subdirectory, not another edit here.

oc_opencore()

oc_kext(Lilu          GITHUB acidanthera/Lilu)
oc_kext(VirtualSMC    GITHUB acidanthera/VirtualSMC KEXTS VirtualSMC SMCProcessor)
oc_kext(WhateverGreen GITHUB acidanthera/WhateverGreen)

oc_driver(OpenRuntime)

# config.plist and secrets.plist are not named anywhere. Each machine's directory is where
# its EFI was first declared, so the defaults resolve to that directory's own files --
# desktop/config.plist for one, laptop/config.plist for the other.
