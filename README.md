# Intune Device Readiness Reporter

A read-only PowerShell toolkit for Windows device readiness in Microsoft Intune environments.

## Features

- Windows edition and build inventory
- TPM, Secure Boot, and BitLocker readiness
- Entra join-state context
- Hardware and storage summary
- CSV, JSON, and HTML reports

## Run

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Intune_Device_Readiness_Reporter.ps1
```

## Safety

Read-only reporting only. No enrollment or security settings are changed.
