# Intune Device Readiness Reporter

PowerShell tooling for Windows device-readiness reporting and guarded local Intune-readiness recovery.

## Scripts

- `Intune_Device_Readiness_Reporter.ps1` — read-only OS, TPM, Secure Boot, BitLocker, join-state, hardware, and storage reporting.
- `Intune_Device_Readiness_Repair_Toolkit.ps1` — targeted WinRE, BitLocker protection, management-service, and MDM task actions.

The repair workflow does not start BitLocker encryption, clear TPM ownership, unenroll the device, remove certificates, or delete management registry data.

## Repair actions

- `-EnableWinRE` — enables Windows Recovery Environment with `reagentc`.
- `-ResumeBitLocker -DriveLetter C` — resumes protection on an existing BitLocker volume.
- `-RestartMdmServices` — starts or restarts available Intune/MDM-related services.
- `-TriggerMdmSync` — starts matching EnterpriseMgmt policy and synchronization tasks.

Actual changes require an elevated PowerShell session. BitLocker cmdlets must be available when BitLocker repair is selected.

## Examples

Preview an MDM task trigger:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Intune_Device_Readiness_Repair_Toolkit.ps1 `
  -TriggerMdmSync -DryRun
```

Enable WinRE, resume BitLocker protection, and trigger management tasks:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Intune_Device_Readiness_Repair_Toolkit.ps1 `
  -EnableWinRE -ResumeBitLocker -DriveLetter C `
  -RestartMdmServices -TriggerMdmSync -Yes
```

Omit `-Yes` to require typing `YES`.

## Evidence and verification

Each run creates a timestamped directory under `%ProgramData%\IntuneReadinessRepair` unless `-OutputPath` is supplied. It contains `before.json`, `after.json`, `repair.log`, and command output such as `reagentc-enable.txt` when applicable.

Verification checks WinRE status, requested BitLocker protection state, management-service state, and whether at least one selected MDM task LastRunTime advanced. `-DryRun` records planned actions without applying or verifying them.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Completed successfully, including a successful dry run |
| 2 | Invalid arguments |
| 3 | Unsupported platform or missing required commands/cmdlets |
| 4 | Elevation required |
| 10 | User cancelled |
| 20 | One or more repair actions failed |
| 30 | Post-repair verification failed |

## Validation status

The scripts were source-reviewed during this update. They were not runtime-tested on an Intune-managed Windows device.

## Author

Dewald Pretorius — L2 IT Support Engineer
