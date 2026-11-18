AMR V1 - DRIVER CENTER INTELLIGENCE UPDATE

Scope
- Driver Center UI refinements only: compact OEM/motherboard identity strip, eye toggle for expanded platform identity, smaller Smart Assistant controls moved directly below the identity strip, translucent dark-glass panels, and a larger driver results area.
- Removed the two long explanatory paragraphs below the device list to reclaim vertical space.
- Added a supplemental Windows PnP cmdlet inventory (Get-PnpDevice -PresentOnly) merged by InstanceId with the existing Win32_PnPEntity scan. This is additive; the primary WMI/CIM path remains intact.
- Added biometric/fingerprint device classification for known sensor names/classes and common USB hardware IDs (including Synaptics/Validity and Goodix families).
- The scan now reports whether a biometric device was enumerated, whether it has a reported PnP issue, or whether no biometric sensor is currently exposed to Plug and Play. The latter is explicitly not treated as proof that the laptop has no fingerprint sensor.
- Expanded HP ZBook family aliases and ASUS model-family aliases for OEM routing. Existing HP Client Driver Pack/HPIA, Dell Driver Pack, Lenovo CDRT, Windows Update, Microsoft Update Catalog and official vendor routing logic remain in place.

Safety
- No automatic driver installation was added.
- Hardware IDs remain the primary device match evidence. OEM/model context is supporting evidence only.
- ASUS model-specific support remains routed to ASUS's official support portal where no stable public catalog adapter is available; AMR does not fabricate package results.
- A fingerprint sensor that is disabled in firmware/BIOS or not enumerated by Windows cannot be conclusively diagnosed by software enumeration alone.
- Do not install a driver solely because its marketing name resembles the device. Verify exact hardware IDs, OS build/architecture, package signature and INF/CAT applicability.

Validation
- ZIP archive integrity checked.
- Embedded WPF XAML parsed as XML successfully.
- Windows PowerShell 5.1 parser and WPF runtime validation were not available in the build environment. Please test on Windows, preferably after creating a restore point.
