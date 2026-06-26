#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$EnableWinRE,
    [switch]$ResumeBitLocker,
    [ValidatePattern('^[A-Z]$')][string]$DriveLetter = 'C',
    [switch]$RestartMdmServices,
    [switch]$TriggerMdmSync,
    [switch]$DryRun,
    [switch]$Yes,
    [ValidateNotNullOrEmpty()][string]$OutputPath = (Join-Path $env:ProgramData 'IntuneReadinessRepair')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:VerificationFailures = 0
$script:Actions = 0

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($env:OS -ne 'Windows_NT') {
    Write-Error 'This tool requires Windows.'
    exit 3
}
if (-not ($EnableWinRE -or $ResumeBitLocker -or $RestartMdmServices -or $TriggerMdmSync)) {
    Write-Error 'Choose at least one repair action.'
    exit 2
}
if (-not $DryRun -and -not (Test-Administrator)) {
    Write-Error 'Run from an elevated PowerShell session.'
    exit 4
}
if ($ResumeBitLocker -and -not (Get-Command -Name 'Get-BitLockerVolume' -ErrorAction SilentlyContinue)) {
    Write-Error 'BitLocker PowerShell cmdlets are unavailable on this Windows edition.'
    exit 3
}
if ($EnableWinRE -and -not (Get-Command -Name 'reagentc.exe' -ErrorAction SilentlyContinue)) {
    Write-Error 'reagentc.exe is required.'
    exit 3
}

$runPath = Join-Path $OutputPath (Get-Date -Format 'yyyyMMdd_HHmmss')
New-Item -ItemType Directory -Path $runPath -Force | Out-Null
$logPath = Join-Path $runPath 'repair.log'
$beforePath = Join-Path $runPath 'before.json'
$afterPath = Join-Path $runPath 'after.json'

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)

    '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message |
        Tee-Object -FilePath $logPath -Append
}

function Get-MdmTasks {
    if (-not (Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue)) {
        return @()
    }

    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -like '\Microsoft\Windows\EnterpriseMgmt\*' -and
        $_.TaskName -match 'PushLaunch|Schedule|Policy|OMADM'
    })

    foreach ($task in $tasks) {
        $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue
        [pscustomobject]@{
            TaskName = $task.TaskName
            TaskPath = $task.TaskPath
            State = $task.State
            LastRunTime = if ($info) { $info.LastRunTime } else { $null }
            LastTaskResult = if ($info) { $info.LastTaskResult } else { $null }
        }
    }
}

function Get-WinREInformation {
    if (-not (Get-Command -Name 'reagentc.exe' -ErrorAction SilentlyContinue)) {
        return 'reagentc.exe unavailable'
    }

    return (& reagentc.exe /info 2>&1 | Out-String)
}

function Get-SecureBootState {
    try {
        return Confirm-SecureBootUEFI -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-BitLockerState {
    if (-not (Get-Command -Name 'Get-BitLockerVolume' -ErrorAction SilentlyContinue)) {
        return @()
    }

    return @(Get-BitLockerVolume -ErrorAction SilentlyContinue |
        Select-Object MountPoint, VolumeStatus, ProtectionStatus)
}

function Get-RepairState {
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue |
        Select-Object Caption, BuildNumber, OSArchitecture
    $tpm = if (Get-Command -Name 'Get-Tpm' -ErrorAction SilentlyContinue) {
        Get-Tpm -ErrorAction SilentlyContinue
    }
    else {
        $null
    }

    return [pscustomobject]@{
        Collected = Get-Date
        OS = $operatingSystem
        TPM = $tpm
        SecureBoot = Get-SecureBootState
        WinRE = Get-WinREInformation
        BitLocker = @(Get-BitLockerState)
        Services = @(Get-Service -Name 'IntuneManagementExtension', 'dmwappushservice', 'DiagTrack' -ErrorAction SilentlyContinue |
            Select-Object Name, Status, StartType)
        MdmTasks = @(Get-MdmTasks)
    }
}

function Invoke-RepairAction {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Script
    )

    $script:Actions++
    Write-Log "ACTION: $Description"

    if ($DryRun) {
        Write-Log "DRY-RUN: $Description"
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Description, 'Apply selected Intune readiness repair')) {
        Write-Log "SKIPPED: $Description"
        return
    }

    try {
        $result = & $Script 2>&1
        if ($null -ne $result) {
            $result | Out-String | Add-Content -LiteralPath $logPath -Encoding UTF8
        }
        Write-Log "SUCCESS: $Description"
    }
    catch {
        $script:Failures++
        Write-Log "FAILED: $Description - $($_.Exception.Message)"
    }
}

$beforeState = Get-RepairState
$beforeState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $beforePath -Encoding UTF8
$beforeTaskTimes = @{}
foreach ($task in $beforeState.MdmTasks) {
    $beforeTaskTimes["$($task.TaskPath)$($task.TaskName)"] = $task.LastRunTime
}
Write-Log "Saved pre-repair readiness evidence to $beforePath"

if (-not $DryRun -and -not $Yes) {
    if ((Read-Host 'Apply selected Intune readiness repairs? Type YES') -cne 'YES') {
        Write-Log 'Repair cancelled.'
        exit 10
    }
}

if ($EnableWinRE) {
    Invoke-RepairAction -Description 'Enable Windows Recovery Environment' -Script {
        $output = & reagentc.exe /enable 2>&1
        $output | Set-Content -LiteralPath (Join-Path $runPath 'reagentc-enable.txt') -Encoding UTF8
        if ($LASTEXITCODE -ne 0) {
            throw "reagentc /enable exited with code $LASTEXITCODE."
        }
    }
}

if ($ResumeBitLocker) {
    $mountPoint = "${DriveLetter}:"
    Invoke-RepairAction -Description "Resume BitLocker protection on $mountPoint" -Script {
        $volume = Get-BitLockerVolume -MountPoint $mountPoint -ErrorAction Stop
        if ($volume.ProtectionStatus -ne 'On') {
            Resume-BitLocker -MountPoint $mountPoint -ErrorAction Stop | Out-Null
        }
    }
}

if ($RestartMdmServices) {
    foreach ($serviceName in 'IntuneManagementExtension', 'dmwappushservice', 'DiagTrack') {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Log "INFO: service '$serviceName' is not installed."
            continue
        }

        Invoke-RepairAction -Description "Start or restart $serviceName" -Script {
            $current = Get-Service -Name $serviceName -ErrorAction Stop
            if ($current.Status -eq 'Running') {
                Restart-Service -Name $serviceName -Force -ErrorAction Stop
            }
            else {
                Start-Service -Name $serviceName -ErrorAction Stop
            }
        }
    }
}

if ($TriggerMdmSync) {
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -like '\Microsoft\Windows\EnterpriseMgmt\*' -and
        $_.TaskName -match 'PushLaunch|Schedule|Policy|OMADM'
    })

    if ($tasks.Count -eq 0) {
        $script:Failures++
        Write-Log 'FAILED: no EnterpriseMgmt sync tasks were found.'
    }
    else {
        foreach ($task in $tasks) {
            Invoke-RepairAction -Description "Start MDM task $($task.TaskPath)$($task.TaskName)" -Script {
                Start-ScheduledTask -InputObject $task -ErrorAction Stop
            }
        }
    }
}

if (-not $DryRun) {
    Start-Sleep -Seconds 5
}
$afterState = Get-RepairState
$afterState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $afterPath -Encoding UTF8

if (-not $DryRun) {
    if ($EnableWinRE -and $afterState.WinRE -notmatch 'Windows RE status\s*:\s*Enabled') {
        $script:VerificationFailures++
        Write-Log 'VERIFY FAILED: Windows RE is not enabled.'
    }

    if ($ResumeBitLocker) {
        $mountPoint = "${DriveLetter}:"
        $volume = $afterState.BitLocker |
            Where-Object MountPoint -eq $mountPoint |
            Select-Object -First 1
        if (-not $volume -or $volume.ProtectionStatus -ne 'On') {
            $script:VerificationFailures++
            Write-Log "VERIFY FAILED: BitLocker protection is not On for $mountPoint."
        }
    }

    if ($RestartMdmServices) {
        foreach ($service in $afterState.Services) {
            if ($service.StartType -ne 'Disabled' -and $service.Status -ne 'Running') {
                $script:VerificationFailures++
                Write-Log "VERIFY FAILED: $($service.Name) is not running."
            }
        }
    }

    if ($TriggerMdmSync) {
        $advanced = $false
        foreach ($task in $afterState.MdmTasks) {
            $key = "$($task.TaskPath)$($task.TaskName)"
            if (-not $beforeTaskTimes.ContainsKey($key) -or
                ($task.LastRunTime -and $task.LastRunTime -gt $beforeTaskTimes[$key])) {
                $advanced = $true
                break
            }
        }
        if (-not $advanced) {
            $script:VerificationFailures++
            Write-Log 'VERIFY FAILED: no MDM task LastRunTime advanced.'
        }
    }
}

if ($script:Failures -gt 0) {
    exit 20
}
if ($script:VerificationFailures -gt 0) {
    exit 30
}

Write-Log "Workflow completed. Actions: $script:Actions; DryRun: $DryRun"
exit 0
