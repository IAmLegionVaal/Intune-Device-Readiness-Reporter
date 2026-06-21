# Intune Device Readiness Reporter

PowerShell tools for Windows device readiness reporting and guarded local Intune-readiness repairs.

## Report

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Intune_Device_Readiness_Reporter.ps1
```

## Repair

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Intune_Device_Readiness_Repair_Toolkit.ps1 -TriggerMdmSync -DryRun
```

Examples:

```powershell
.\Intune_Device_Readiness_Repair_Toolkit.ps1 -EnableWinRE
.\Intune_Device_Readiness_Repair_Toolkit.ps1 -ResumeBitLocker -DriveLetter C
.\Intune_Device_Readiness_Repair_Toolkit.ps1 -RestartMdmServices
.\Intune_Device_Readiness_Repair_Toolkit.ps1 -TriggerMdmSync
```

The repair script captures OS, TPM, Secure Boot, WinRE, BitLocker and management-service state before and after repair. It supports `-DryRun`, confirmation, logs and clear exit codes. It does not start encryption, clear TPM ownership or remove the device from management.

## Author

Dewald Pretorius — L2 IT Support Engineer
