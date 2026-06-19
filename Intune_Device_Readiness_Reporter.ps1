#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputPath)
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
if([string]::IsNullOrWhiteSpace($OutputPath)){$OutputPath=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Intune_Readiness_Reports'}
New-Item -ItemType Directory -Path $OutputPath -Force|Out-Null
$os=Get-CimInstance Win32_OperatingSystem;$cs=Get-CimInstance Win32_ComputerSystem;$cpu=Get-CimInstance Win32_Processor|Select-Object -First 1
$tpm=Get-Tpm -ErrorAction SilentlyContinue
$secureBoot=$null;try{$secureBoot=Confirm-SecureBootUEFI}catch{}
$bitlocker=Get-BitLockerVolume -ErrorAction SilentlyContinue|Select-Object MountPoint,ProtectionStatus,VolumeStatus,EncryptionMethod
$dsreg=dsregcmd.exe /status 2>$null
$joined=($dsreg|Select-String 'AzureAdJoined\s*:\s*YES') -ne $null
$disk=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$summary=[PSCustomObject]@{Computer=$env:COMPUTERNAME;OS=$os.Caption;Build=$os.BuildNumber;MemoryGB=[math]::Round($cs.TotalPhysicalMemory/1GB,2);Processor=$cpu.Name;SystemDriveFreeGB=[math]::Round($disk.FreeSpace/1GB,2);TpmPresent=$tpm.TpmPresent;TpmReady=$tpm.TpmReady;SecureBoot=$secureBoot;EntraJoined=$joined;Generated=Get-Date}
$summary|Export-Csv (Join-Path $OutputPath "intune_readiness_$stamp.csv") -NoTypeInformation -Encoding UTF8
$bitlocker|Export-Csv (Join-Path $OutputPath "bitlocker_status_$stamp.csv") -NoTypeInformation -Encoding UTF8
@{Summary=$summary;BitLocker=$bitlocker}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $OutputPath "intune_readiness_$stamp.json") -Encoding UTF8
$html="<h1>Intune Device Readiness - $env:COMPUTERNAME</h1><p>Generated $(Get-Date)</p><h2>Summary</h2>$(@($summary)|ConvertTo-Html -Fragment)<h2>BitLocker</h2>$($bitlocker|ConvertTo-Html -Fragment)"
$html|ConvertTo-Html -Title 'Intune Device Readiness'|Set-Content (Join-Path $OutputPath "intune_readiness_$stamp.html") -Encoding UTF8
$summary|Format-List
Write-Host "Reports saved to: $OutputPath" -ForegroundColor Green
