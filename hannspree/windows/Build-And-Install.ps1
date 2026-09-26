param(
    [string]$Remote = 'codex-audit@aiden-ubuntu',
    [string]$RemoteRoot = '/media/aiden/Data/hannspree-openwrt-build/openwrt',
    [string]$KeyFile = (Join-Path $env:USERPROFILE '.ssh\codex_audit_ed25519')
)

$ErrorActionPreference = 'Stop'
$ssh = @("$env:WINDIR\System32\OpenSSH\ssh.exe", "$env:WINDIR\Sysnative\OpenSSH\ssh.exe") |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (!$ssh) { throw 'OpenSSH client not found' }
$scp = Join-Path (Split-Path $ssh) 'scp.exe'
if (!(Test-Path -LiteralPath $KeyFile)) { throw "SSH key not found: $KeyFile" }

$cards = @(Get-CimInstance Win32_LogicalDisk | Where-Object {
    $_.VolumeName -eq 'SD' -and $_.FileSystem -eq 'FAT32' -and $_.DriveType -eq 2
})
if ($cards.Count -ne 1) { throw 'Connect exactly one FAT32 removable card labelled SD' }
$card = $cards[0].DeviceID + '\'
$serial = $cards[0].VolumeSerialNumber
$opts = @('-o','BatchMode=yes','-o','ConnectTimeout=15','-o','ServerAliveInterval=15',
          '-o','ServerAliveCountMax=4','-i',$KeyFile)

Write-Host 'Building and verifying on the remote host...'
$output = & $ssh @opts $Remote "cd '$RemoteRoot' && bash hannspree/apply-feeds.sh && bash hannspree/build.sh" 2>&1
$output | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw 'Remote build or verification failed; SD card unchanged' }
$match = $output | Select-String '^BUILD_VERIFIED=(/.+)$' | Select-Object -Last 1
if (!$match) { throw 'Verified output path was not returned; SD card unchanged' }
$stage = $match.Matches[0].Groups[1].Value

$local = Join-Path $PSScriptRoot ('output-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $local | Out-Null
& $scp @opts "${Remote}:$stage/SHA256SUMS" $local
if ($LASTEXITCODE -ne 0) { throw 'Checksum manifest download failed' }

$expectedNames = @(
    'openwrt-hannspree-rk3288-mm8108-initramfs-kernel.bin',
    'openwrt-hannspree-rk3288-mm8108-kernel.bin',
    'openwrt-hannspree-rk3288-mm8108-rootfs.ext4',
    'openwrt-hannspree-rk3288-mm8108-sysupgrade.tar',
    'hannspree-platform.sh',
    'rk3288-firefly-reload.dtb', 'boot.scr', 'boot-emmc.scr'
)
$entries = @()
foreach ($line in Get-Content (Join-Path $local 'SHA256SUMS')) {
    if ($line -notmatch '^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$') { throw 'Invalid checksum manifest' }
    $entries += [pscustomobject]@{ Hash=$Matches[1]; Name=$Matches[2] }
}
if (@(Compare-Object ($entries.Name | Sort-Object) ($expectedNames | Sort-Object)).Count) {
    throw 'Unexpected payload in checksum manifest'
}

foreach ($entry in $entries) {
    & $scp @opts "${Remote}:$stage/$($entry.Name)" $local
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $($entry.Name)" }
    if ((Get-FileHash -LiteralPath (Join-Path $local $entry.Name)).Hash -ne $entry.Hash) {
        throw "Downloaded checksum mismatch: $($entry.Name)"
    }
}

$disk = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $cards[0].DeviceID }
if ($disk.VolumeSerialNumber -ne $serial -or $disk.VolumeName -ne 'SD') { throw 'SD card identity changed' }
$required = 64MB
foreach ($entry in $entries) { $required += (Get-Item (Join-Path $local $entry.Name)).Length }
if ($disk.FreeSpace -lt $required) { throw 'Insufficient space on SD card' }

$backup = Join-Path $local 'sd-backup'
New-Item -ItemType Directory -Path $backup | Out-Null
foreach ($name in $expectedNames + @('SHA256SUMS','INSTALL_TO_EMMC')) {
    $path = Join-Path $card $name
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $backup }
}

$marker = Join-Path $card 'INSTALL_TO_EMMC'
if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
foreach ($entry in $entries) {
    $source = Join-Path $local $entry.Name
    $temporary = Join-Path $card ($entry.Name + '.new')
    Copy-Item -LiteralPath $source -Destination $temporary -Force
    if ((Get-FileHash -LiteralPath $temporary).Hash -ne $entry.Hash) {
        throw "SD staging checksum mismatch: $($entry.Name)"
    }
}
foreach ($entry in $entries) {
    $destination = Join-Path $card $entry.Name
    Move-Item -LiteralPath ($destination + '.new') -Destination $destination -Force
    if ((Get-FileHash -LiteralPath $destination).Hash -ne $entry.Hash) {
        throw "Final SD checksum mismatch: $($entry.Name)"
    }
}
Copy-Item (Join-Path $local 'SHA256SUMS') (Join-Path $card 'SHA256SUMS') -Force
New-Item -ItemType File -Path $marker -Force | Out-Null

Write-Host "DONE: $card is ready. Safely eject it and boot the box."
Write-Host 'Booting the card replaces the first eMMC partition; the existing bootloader is preserved.'
Write-Host "Downloaded artifacts and SD backup: $local"
