[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param(
 [switch]$EnableWinRE,
 [switch]$ResumeBitLocker,
 [ValidatePattern('^[A-Z]$')][string]$DriveLetter='C',
 [switch]$RestartMdmServices,
 [switch]$TriggerMdmSync,
 [switch]$DryRun,
 [switch]$Yes,
 [string]$OutputPath=(Join-Path $env:ProgramData 'IntuneReadinessRepair')
)
$ErrorActionPreference='Stop';$script:Failures=0;$script:Actions=0
$run=Join-Path $OutputPath (Get-Date -Format yyyyMMdd_HHmmss);New-Item -ItemType Directory $run -Force|Out-Null
$log=Join-Path $run 'repair.log';$before=Join-Path $run 'before.json';$after=Join-Path $run 'after.json'
function Log($m){"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"|Tee-Object -FilePath $log -Append}
function Admin{$p=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
function State{[pscustomobject]@{Collected=Get-Date;OS=Get-CimInstance Win32_OperatingSystem|Select-Object Caption,BuildNumber,OSArchitecture;TPM=Get-Tpm -ErrorAction SilentlyContinue;SecureBoot=try{Confirm-SecureBootUEFI}catch{$null};WinRE=(& reagentc.exe /info|Out-String);BitLocker=Get-BitLockerVolume -ErrorAction SilentlyContinue|Select-Object MountPoint,VolumeStatus,ProtectionStatus;Services=Get-Service IntuneManagementExtension,dmwappushservice,DiagTrack -ErrorAction SilentlyContinue|Select-Object Name,Status,StartType}}
function Act($d,[scriptblock]$a){$script:Actions++;Log $d;if($DryRun){Log "DRY-RUN: $d";return};try{&$a;Log "SUCCESS: $d"}catch{$script:Failures++;Log "FAILED: $d - $($_.Exception.Message)"}}
State|ConvertTo-Json -Depth 6|Set-Content $before -Encoding UTF8
if(-not($EnableWinRE -or $ResumeBitLocker -or $RestartMdmServices -or $TriggerMdmSync)){Write-Error 'Choose at least one repair action.';exit 2}
if(-not $DryRun -and -not(Admin)){Write-Error 'Run from elevated PowerShell.';exit 4}
if(-not $Yes -and -not $DryRun){if((Read-Host 'Apply selected Intune readiness repairs? Type YES') -ne 'YES'){Log 'Cancelled.';exit 10}}
if($EnableWinRE){Act 'Enabling Windows Recovery Environment' {& reagentc.exe /enable|Out-File (Join-Path $run 'reagentc-enable.txt');if($LASTEXITCODE){throw "reagentc exited $LASTEXITCODE"}}}
if($ResumeBitLocker){$mount="${DriveLetter}:";$v=Get-BitLockerVolume -MountPoint $mount -ErrorAction Stop;if($v.ProtectionStatus -ne 'On'){Act "Resuming BitLocker protection on $mount" {Resume-BitLocker -MountPoint $mount}}else{Log "$mount BitLocker protection is already active."}}
if($RestartMdmServices){foreach($s in 'IntuneManagementExtension','dmwappushservice','DiagTrack'){if(Get-Service $s -ErrorAction SilentlyContinue){Act "Restarting $s" {Restart-Service $s -Force -ErrorAction Stop}}}}
if($TriggerMdmSync){$tasks=Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -match 'PushLaunch|Schedule|Policy|OMADM'};if(-not $tasks){$script:Failures++;Log 'No EnterpriseMgmt sync tasks found.'}else{foreach($task in $tasks){Act "Starting MDM task $($task.TaskName)" {Start-ScheduledTask -InputObject $task}}}}
Start-Sleep 3;State|ConvertTo-Json -Depth 6|Set-Content $after -Encoding UTF8
if($script:Failures){exit 20};Log "Repair completed. Actions: $script:Actions";exit 0
