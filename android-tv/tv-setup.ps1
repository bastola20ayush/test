<#
Installs FLauncher on an Android TV over the network, makes it the home
screen, and turns off the stock launcher, ads and the apps listed in
packages-to-remove.txt.

Usage:
  powershell -ExecutionPolicy Bypass -File tv-setup.ps1 <tv-ip>[:port]            set up the TV
  powershell -ExecutionPolicy Bypass -File tv-setup.ps1 <tv-ip>[:port] -Restore   undo everything this did
#>
param(
    [Parameter(Mandatory = $true)][string]$TvIp,
    [switch]$Restore
)

$Here = $PSScriptRoot
$Serial = if ($TvIp -like '*:*') { $TvIp } else { "${TvIp}:5555" }
$List = Join-Path $Here 'packages-to-remove.txt'
$Log = Join-Path $Here ('removed-packages-' + ($Serial -replace '[:.]', '_') + '.log')

$FlauncherPkg = 'me.efesser.flauncher'
$FlauncherHome = 'me.efesser.flauncher/.MainActivity'
$FlauncherApk = Join-Path $Here 'flauncher-0.18.0.apk'
$FlauncherUrl = 'https://gitlab.com/api/v4/projects/26632151/packages/generic/flauncher/0.18.0/flauncher-0.18.0.apk'
$FlauncherSha256 = '376fc528c880cdf7c7c04b2d3708c69f911144498218babb6300808b772af32e'

# Never turned off, even if someone adds them to the list: the TV would stop
# booting, lose its settings menu or its on-screen keyboard.
$Protected = @('android', 'com.android.systemui', 'com.android.tv.settings', 'com.android.settings',
    'com.google.android.gms', 'com.google.android.gsf', 'com.android.providers.settings',
    'com.google.android.inputmethod.latin', 'com.google.android.leanback.ime', $FlauncherPkg)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# Invoke-WebRequest downloads very slowly while it draws a progress bar.
$ProgressPreference = 'SilentlyContinue'

function Find-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
    $adb = Join-Path $Here 'platform-tools\adb.exe'
    if (-not (Test-Path $adb)) {
        Write-Host 'adb not found, downloading Android platform-tools...'
        $zip = Join-Path $Here 'platform-tools.zip'
        Invoke-WebRequest -UseBasicParsing -ErrorAction Stop -OutFile $zip `
            -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
        Expand-Archive -Path $zip -DestinationPath $Here -Force -ErrorAction Stop
        Remove-Item $zip
    }
    return $adb
}

# Runs a command line on the TV and returns its output as one string.
function Invoke-TvShell([string]$Command) {
    $out = & $Adb -s $Serial shell $Command 2>&1 | ForEach-Object { "$_" }
    return ($out -join "`n") -replace "`r", ''
}

function Connect-Tv {
    Write-Host "Connecting to $Serial..."
    & $Adb connect $Serial 2>&1 | Out-Null
    for ($i = 0; $i -lt 60; $i++) {
        $state = "$(& $Adb -s $Serial get-state 2>&1)".Trim()
        if ($state -eq 'device') {
            Write-Host 'Connected.'
            return
        }
        if ($state -like '*unauthorized*') {
            Write-Host '  Choose "Allow" on the TV screen (tick "Always allow").'
        } else {
            & $Adb connect $Serial 2>&1 | Out-Null
        }
        Start-Sleep -Seconds 2
    }
    Write-Host "Could not connect to $Serial. Check the IP address, that the TV and this" -ForegroundColor Red
    Write-Host 'computer are on the same network, and that USB/network debugging is on.' -ForegroundColor Red
    exit 1
}

function Install-Flauncher {
    if (-not (Test-Path $FlauncherApk)) {
        Write-Host 'Downloading FLauncher 0.18.0...'
        Invoke-WebRequest -UseBasicParsing -ErrorAction Stop -Uri $FlauncherUrl -OutFile "$FlauncherApk.part"
        Move-Item "$FlauncherApk.part" $FlauncherApk
    }
    if ((Get-FileHash -Algorithm SHA256 $FlauncherApk).Hash -ne $FlauncherSha256) {
        Remove-Item $FlauncherApk
        Write-Host 'Downloaded FLauncher is corrupt (checksum mismatch). Run the script again.' -ForegroundColor Red
        exit 1
    }

    Write-Host 'Installing FLauncher...'
    & $Adb -s $Serial install -r $FlauncherApk
    # Stop here if it didn't install: turning off the stock home screen
    # without a replacement would leave the TV with no home screen.
    $packages = (Invoke-TvShell "pm list packages $FlauncherPkg") -split "`n"
    if ($packages -notcontains "package:$FlauncherPkg") {
        Write-Host 'FLauncher did not install, so nothing else was changed.' -ForegroundColor Red
        exit 1
    }
    Invoke-TvShell "cmd package set-home-activity $FlauncherHome" | Out-Null
}

function Remove-Packages {
    Write-Host 'Turning off stock launcher, ads and preinstalled apps...'
    $installed = (Invoke-TvShell 'pm list packages -e') -split "`n" -replace '^package:', ''
    foreach ($line in Get-Content $List) {
        $pkg = ($line -replace '#.*', '').Trim()
        if (-not $pkg -or $installed -notcontains $pkg) { continue }
        if ($Protected -contains $pkg) {
            Write-Host "  skipped   $pkg (needed by the TV)"
            continue
        }
        $out = Invoke-TvShell "pm disable-user --user 0 $pkg"
        if ($out -match 'new state: disabled-user') {
            Write-Host "  disabled  $pkg"
        } else {
            $out = Invoke-TvShell "pm uninstall -k --user 0 $pkg"
            if ($out -notmatch 'Success') {
                Write-Host "  FAILED    ${pkg}: $out"
                continue
            }
            Write-Host "  removed   $pkg"
        }
        Add-Content -Path $Log -Value $pkg
    }
}

function Restore-Tv {
    if (-not (Test-Path $Log)) {
        Write-Host "Nothing to restore: $Log not found." -ForegroundColor Red
        exit 1
    }
    Write-Host 'Turning stock apps back on...'
    foreach ($pkg in (Get-Content $Log | Sort-Object -Unique)) {
        Invoke-TvShell "pm install-existing $pkg" | Out-Null
        Invoke-TvShell "pm enable --user 0 $pkg" | Out-Null
        Write-Host "  restored  $pkg"
    }
    Write-Host 'Uninstalling FLauncher...'
    & $Adb -s $Serial uninstall $FlauncherPkg 2>&1 | Out-Null
    Remove-Item $Log
    Invoke-TvShell 'am start -a android.intent.action.MAIN -c android.intent.category.HOME' | Out-Null
    Write-Host 'Done. The TV is back to its original home screen.'
}

$Adb = Find-Adb
Connect-Tv
if ($Restore) {
    Restore-Tv
    exit
}
Install-Flauncher
Remove-Packages
Invoke-TvShell 'am start -a android.intent.action.MAIN -c android.intent.category.HOME' | Out-Null
Write-Host 'Done. Press Home on the remote; if the TV asks which app to use, pick FLauncher, then Always.'
Write-Host "To undo: powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" $TvIp -Restore"
