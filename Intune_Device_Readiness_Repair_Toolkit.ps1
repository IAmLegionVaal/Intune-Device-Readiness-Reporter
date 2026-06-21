[CmdletBinding()]
param(
    [switch]$EnableWinRE,
    [switch]$ResumeBitLocker,
    [ValidatePattern('^[A-Z]$')][string]$DriveLetter = 'C',
    [switch]$RestartMdmServices,
    [switch]$TriggerMdmSync,
    [switch]$DryRun,
    [switch]$Yes,
    [string]$OutputPath = (Join-Path $env:ProgramData 'IntuneReadinessRepair')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:VerificationFailures = 0
$script:Actions = 0

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($env:OS -ne 'Windows_NT') { Write-Error 'This tool requires Windows.'; exit 3 }
if (-not ($EnableWinRE -or $ResumeBitLocker -or $RestartMdmServices -or $TriggerMdmSync)) { Write-Error 'Choose at least one repair action.'; exit 2 }
if (-not $DryRun -and -not (Test-Administrator)) { Write-Error 'Run from an elevated PowerShell session.'; exit 4 }
if ($ResumeBitLocker -and -not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) { Write-Error 'BitLocker PowerShell cmdlets are unavailable on this Windows edition.'; exit 3 }
if (($EnableWinRE) -and -not (Get-Command reagentc.exe -ErrorAction SilentlyContinue)) { Write-Error 'reagentc.exe is required.'; exit 3 }

$runPath = Join-Path $OutputPath (Get-Date -Format 'yyyyMMdd_HHmmss')
New-Item -ItemType Directory -Path $runPath -Force | Out-Null
$logPath = Join-Path $runPath 'repair.log'
$beforePath = Join-Path $runPath 'before.json'
$afterPath = Join-Path $runPath 'after.json'

function Write-Log([string]$Message) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Tee-Object -FilePath $logPath -Append
}
function Get-MdmTasks {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return @() }
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -like '\Microsoft\Windows\EnterpriseMgmt\*' -and $_.TaskName -match 'PushLaunch|Schedule|Policy|OMADM'
    })
    foreach ($task in $tasks) {
        $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue
        [pscustomobject]@{ TaskName=$task.TaskName; TaskPath=$task.TaskPath; State=$task.State; LastRunTime=$info.LastRunTime; LastTaskResult=$info.LastTaskResult }
    }
}
function Get-RepairState {
    $winReOutput = if (Get-Command reagentc.exe -ErrorAction SilentlyContinue) { & reagentc.exe /info 2>&1 | Out-String } else { 'reagentc.exe unavailable' }
    [pscustomobject]@{
        Collected = Get-Date
        OS = Get-CimInstance Win32_OperatingSystem | Select-Object Caption,BuildNumber,OSArchitecture
        TPM = Get-Tpm -ErrorAction SilentlyContinue
        SecureBoot = try { Confirm-SecureBootUEFI } catch { $null }
        WinRE = $winReOutput
        BitLocker = @(if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) { Get-BitLockerVolume -ErrorAction SilentlyContinue | Select-Object MountPoint,VolumeStatus,ProtectionStatus })
        Services = @(Get-Service IntuneManagementExtension,dmwappushservice,DiagTrack -ErrorAction SilentlyContinue | Select-Object Name,Status,StartType)
        MdmTasks = @(Get-MdmTasks)
    }
}
function Invoke-RepairAction([string]$Description,[scriptblock]$Script) {
    $script:Actions++
    Write-Log "ACTION: $Description"
    if ($DryRun) { Write-Log "DRY-RUN: $Description"; return }
    try {
        $result = & $Script 2>&1
        if ($null -ne $result) { $result | Out-String | Add-Content $logPath }
        Write-Log "SUCCESS: $Description"
    } catch {
        $script:Failures++
        Write-Log "FAILED: $Description - $($_.Exception.Message)"
    }
}

$beforeState = Get-RepairState
$beforeState | ConvertTo-Json -Depth 8 | Set-Content $beforePath -Encoding UTF8
$beforeTaskTimes = @{}
foreach ($task in $beforeState.MdmTasks) { $beforeTaskTimes["$($task.TaskPath)$($task.TaskName)"] = $task.LastRunTime }
Write-Log "Saved pre-repair readiness evidence to $beforePath"

if (-not $DryRun -and -not $Yes) {
    if ((Read-Host 'Apply selected Intune readiness repairs? Type YES') -cne 'YES') { Write-Log 'Repair cancelled.'; exit 10 }
}

if ($EnableWinRE) {
    Invoke-RepairAction 'Enabling Windows Recovery Environment' {
        $output = & reagentc.exe /enable 2>&1
        $output | Set-Content (Join-Path $runPath 'reagentc-enable.txt') -Encoding UTF8
        if ($LASTEXITCODE -ne 0) { throw "reagentc /enable exited with code $LASTEXITCODE." }
    }
}
if ($ResumeBitLocker) {
    $mountPoint = "${DriveLetter}:"
    Invoke-RepairAction "Resuming BitLocker protection on $mountPoint" {
        $volume = Get-BitLockerVolume -MountPoint $mountPoint -ErrorAction Stop
        if ($volume.ProtectionStatus -ne 'On') { Resume-BitLocker -MountPoint $mountPoint | Out-Null }
    }
}
if ($RestartMdmServices) {
    foreach ($serviceName in 'IntuneManagementExtension','dmwappushservice','DiagTrack') {
        if (Get-Service $serviceName -ErrorAction SilentlyContinue) {
            Invoke-RepairAction "Starting or restarting $serviceName" {
                $service = Get-Service $serviceName -ErrorAction Stop
                if ($service.Status -eq 'Running') { Restart-Service $serviceName -Force } else { Start-Service $serviceName }
            }
        } else {
            Write-Log "INFO: service $serviceName is not installed."
        }
    }
}
if ($TriggerMdmSync) {
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -like '\Microsoft\Windows\EnterpriseMgmt\*' -and $_.TaskName -match 'PushLaunch|Schedule|Policy|OMADM'
    })
    if (-not $tasks) {
        $script:Failures++
        Write-Log 'FAILED: no EnterpriseMgmt sync tasks were found.'
    } else {
        foreach ($task in $tasks) {
            Invoke-RepairAction "Starting MDM task $($task.TaskPath)$($task.TaskName)" { Start-ScheduledTask -InputObject $task }
        }
    }
}

if (-not $DryRun) { Start-Sleep -Seconds 5 }
$afterState = Get-RepairState
$afterState | ConvertTo-Json -Depth 8 | Set-Content $afterPath -Encoding UTF8

if (-not $DryRun) {
    if ($EnableWinRE -and $afterState.WinRE -notmatch 'Windows RE status\s*:\s*Enabled') { $script:VerificationFailures++; Write-Log 'VERIFY FAILED: Windows RE is not enabled.' }
    if ($ResumeBitLocker) {
        $mountPoint = "${DriveLetter}:"
        $volume = $afterState.BitLocker | Where-Object MountPoint -eq $mountPoint | Select-Object -First 1
        if (-not $volume -or $volume.ProtectionStatus -ne 'On') { $script:VerificationFailures++; Write-Log "VERIFY FAILED: BitLocker protection is not On for $mountPoint." }
    }
    if ($RestartMdmServices) {
        foreach ($service in $afterState.Services) {
            if ($service.StartType -ne 'Disabled' -and $service.Status -ne 'Running') { $script:VerificationFailures++; Write-Log "VERIFY FAILED: $($service.Name) is not running." }
        }
    }
    if ($TriggerMdmSync) {
        $advanced = $false
        foreach ($task in $afterState.MdmTasks) {
            $key = "$($task.TaskPath)$($task.TaskName)"
            if (-not $beforeTaskTimes.ContainsKey($key) -or $task.LastRunTime -gt $beforeTaskTimes[$key]) { $advanced = $true; break }
        }
        if (-not $advanced) { $script:VerificationFailures++; Write-Log 'VERIFY FAILED: no MDM task LastRunTime advanced.' }
    }
}

if ($script:Failures -gt 0) { exit 20 }
if ($script:VerificationFailures -gt 0) { exit 30 }
Write-Log "Workflow completed. Actions: $script:Actions; DryRun: $DryRun"
exit 0
