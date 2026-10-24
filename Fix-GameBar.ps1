#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param([ValidateSet('Menu','Uninstall','Apply','Restore','Status')][string]$Mode = 'Status')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GameBarTargets {
    @(
        @{ Path='Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name='AppCaptureEnabled'; Action='Zero' }
        @{ Path='System\GameConfigStore'; Name='GameDVR_Enabled'; Action='Zero' }
        @{ Path='Software\Microsoft\GameBar'; Name='ShowStartupPanel'; Action='Zero' }
        @{ Path='Software\Microsoft\GameBar'; Name='UseNexusForGameBarEnabled'; Action='Zero' }
    )
    foreach ($protocol in 'ms-gamingoverlay','ms-gamebar','ms-gamebarservices','ms-xbox-overlay') {
        $path = 'Software\Classes\' + $protocol
        @{ Path=$path; Name=''; Action='Description'; Description=('URL:' + $protocol) }
        @{ Path=$path; Name='URL Protocol'; Action='Empty' }
        @{ Path=$path; Name='NoOpenWith'; Action='Delete' }
        @{ Path=($path + '\shell\open\command'); Name=''; Action='Command' }
    }
}

function Get-GameBarKeyPaths {
    $seen = @{}
    foreach ($target in Get-GameBarTargets) {
        $path = ''
        foreach ($part in $target.Path.Split('\')) {
            $path = if ($path) { $path + '\' + $part } else { $part }
            if (-not $seen.ContainsKey($path)) { $seen[$path] = $true; $path }
        }
    }
}

function New-GameBarSnapshot {
    param([Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Root)
    $values = @(foreach ($target in Get-GameBarTargets) {
        $key = $Root.OpenSubKey($target.Path)
        try {
            $exists = $null -ne $key -and $key.GetValueNames() -contains $target.Name
            [pscustomobject]@{
                Path=$target.Path; Name=$target.Name; ValueExisted=[bool]$exists
                Kind=$(if ($exists) { $key.GetValueKind($target.Name).ToString() } else { $null })
                Data=$(if ($exists) { $key.GetValue($target.Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null })
            }
        } finally { if ($key) { $key.Dispose() } }
    })
    $keys = @(foreach ($path in Get-GameBarKeyPaths) {
        $key = $Root.OpenSubKey($path)
        try { [pscustomobject]@{ Path=$path; Existed=($null -ne $key) } }
        finally { if ($key) { $key.Dispose() } }
    })
    [pscustomobject]@{ SchemaVersion=1; Values=$values; Keys=$keys }
}

function Convert-GameBarValue {
    param($Entry)
    switch ($Entry.Kind) {
        'String'       { return [string]$Entry.Data }
        'ExpandString' { return [string]$Entry.Data }
        'DWord'        { return [int]$Entry.Data }
        'QWord'        { return [long]$Entry.Data }
        'Binary'       { return ,([byte[]]$Entry.Data) }
        'None'         { return ,([byte[]]$Entry.Data) }
        'MultiString'  { return ,([string[]]$Entry.Data) }
        default       { throw 'Unsupported registry value kind in backup.' }
    }
}

function Assert-GameBarSnapshot {
    param([Parameter(Mandatory)]$Snapshot)
    $targets = @(Get-GameBarTargets)
    $paths = @(Get-GameBarKeyPaths)
    if ($Snapshot.SchemaVersion -ne 1 -or @($Snapshot.Values).Count -ne $targets.Count -or @($Snapshot.Keys).Count -ne $paths.Count) {
        throw 'Invalid backup structure. No restore was attempted.'
    }
    for ($i=0; $i -lt $targets.Count; $i++) {
        $entry = $Snapshot.Values[$i]
        if ($entry.Path -cne $targets[$i].Path -or $entry.Name -cne $targets[$i].Name -or $entry.ValueExisted -isnot [bool]) {
            throw 'Backup contains an unexpected registry target.'
        }
        if ($entry.ValueExisted) { $null = Convert-GameBarValue $entry }
    }
    for ($i=0; $i -lt $paths.Count; $i++) {
        if ($Snapshot.Keys[$i].Path -cne $paths[$i] -or $Snapshot.Keys[$i].Existed -isnot [bool]) {
            throw 'Backup contains an unexpected registry key.'
        }
    }
}

function Assert-GameBarHandlers {
    param([Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Root)
    foreach ($target in Get-GameBarTargets | Where-Object Action -eq 'Command') {
        $key = $Root.OpenSubKey($target.Path)
        try {
            if ($key -and $key.GetValueNames() -contains 'DelegateExecute') {
                throw ('A COM handler exists at ' + $target.Path + '. This case needs separate diagnosis; no changes made.')
            }
        } finally { if ($key) { $key.Dispose() } }
    }
}

function Set-GameBarFix {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Root,
        [Parameter(Mandatory)][string]$Command
    )
    Assert-GameBarHandlers $Root
    foreach ($target in Get-GameBarTargets) {
        # CreateSubKey preserves all existing contents of the key.
        $key = $Root.CreateSubKey($target.Path)
        try {
            switch ($target.Action) {
                'Zero' { $key.SetValue($target.Name,0,[Microsoft.Win32.RegistryValueKind]::DWord) }
                'Description' {
                    if ($key.GetValueNames() -notcontains '') { $key.SetValue('',$target.Description,[Microsoft.Win32.RegistryValueKind]::String) }
                }
                'Empty' { $key.SetValue($target.Name,'',[Microsoft.Win32.RegistryValueKind]::String) }
                'Delete' { $key.DeleteValue($target.Name,$false) }
                'Command' { $key.SetValue('',$Command,[Microsoft.Win32.RegistryValueKind]::String) }
            }
        } finally { $key.Dispose() }
    }
}

function Restore-GameBarSnapshot {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Root,
        [Parameter(Mandatory)]$Snapshot
    )
    # Validate EVERY target and type before the first registry write.
    Assert-GameBarSnapshot $Snapshot
    foreach ($entry in $Snapshot.Values) {
        if ($entry.ValueExisted) {
            $key = $Root.CreateSubKey($entry.Path)
            try { $key.SetValue($entry.Name,(Convert-GameBarValue $entry),[Microsoft.Win32.RegistryValueKind]$entry.Kind) }
            finally { $key.Dispose() }
        } else {
            $key = $Root.OpenSubKey($entry.Path,$true)
            try { if ($key) { $key.DeleteValue($entry.Name,$false) } }
            finally { if ($key) { $key.Dispose() } }
        }
    }
    # Remove only newly created EMPTY keys, deepest first. Preserve later additions.
    foreach ($entry in $Snapshot.Keys | Sort-Object { $_.Path.Length } -Descending) {
        if ($entry.Existed) { continue }
        $key = $Root.OpenSubKey($entry.Path)
        $empty = $false
        try { if ($key) { $empty = $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0 } }
        finally { if ($key) { $key.Dispose() } }
        if ($empty) { $Root.DeleteSubKey($entry.Path,$false) }
    }
}

function Get-GameBarStatus {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Root,
        [Parameter(Mandatory)][string]$Command
    )
    foreach ($target in Get-GameBarTargets) {
        $key = $Root.OpenSubKey($target.Path)
        try {
            $exists = $null -ne $key -and $key.GetValueNames() -contains $target.Name
            $actual = if ($exists) { $key.GetValue($target.Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
            $kind = if ($exists) { $key.GetValueKind($target.Name).ToString() } else { $null }
            $matches = switch ($target.Action) {
                'Zero' { $exists -and $kind -eq 'DWord' -and $actual -eq 0 }
                'Description' { $exists }
                'Empty' { $exists -and $kind -eq 'String' -and $actual -ceq '' }
                'Delete' { -not $exists }
                'Command' { $exists -and $kind -eq 'String' -and $actual -ceq $Command }
            }
            [pscustomobject]@{ Path=('HKCU\' + $target.Path); Name=$target.Name; Matches=[bool]$matches; Kind=$kind; Actual=$actual }
        } finally { if ($key) { $key.Dispose() } }
    }
}



function Get-CurrentUserGameBarPackage {
    $packages = @(Get-AppxPackage -Name Microsoft.XboxGamingOverlay -ErrorAction Stop)
    foreach ($package in $packages) {
        if ($package.Name -cne 'Microsoft.XboxGamingOverlay' -or
            $package.PublisherId -cne '8wekyb3d8bbwe' -or
            $package.PackageFullName -cnotmatch '^Microsoft\.XboxGamingOverlay_[^\\/]+_8wekyb3d8bbwe$') {
            throw 'Unexpected package identity. No package will be removed.'
        }
    }
    $packages
}

function Remove-CurrentUserGameBar {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()
    $packages = @(Get-CurrentUserGameBarPackage)
    $removed = 0
    foreach ($package in $packages) {
        if ($PSCmdlet.ShouldProcess($package.PackageFullName,'Uninstall Xbox Game Bar for the current user')) {
            Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
            $removed++
        }
    }
    if ($removed -gt 0 -and @(Get-CurrentUserGameBarPackage).Count -gt 0) {
        throw 'Xbox Game Bar is still registered for this user. Uninstall verification failed.'
    }
    $removed
}

# Dot-sourcing loads functions for isolated tests without running the tool.
if ($MyInvocation.InvocationName -eq '.') { return }

$mutex = $null
$locked = $false
$root = $null
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows is required.' }
    if ($Mode -eq 'Menu') {
        if ($WhatIfPreference) { Write-Host 'Menu preview: Uninstall, Apply, Restore, Status. No changes made.'; exit 0 }
        Write-Host 'Game Bar - uninstall and game popup fix'
        Write-Host '1. Uninstall Xbox Game Bar for this user + fix game popups'
        Write-Host '2. Fix game popups (Game Bar must already be uninstalled)'
        Write-Host '3. Restore the backed-up registry settings (does not reinstall Game Bar)'
        Write-Host '4. Check status (read only)'
        Write-Host '0. Exit'
        $choice = Read-Host 'Choose 0-4'
        $Mode = switch ($choice) {
            '1' { 'Uninstall' }
            '2' { 'Apply' }
            '3' { 'Restore' }
            '4' { 'Status' }
            '0' { exit 0 }
            default { throw 'Invalid selection.' }
        }
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $executable = Join-Path ([Environment]::SystemDirectory) 'systray.exe'
    $command = '"' + $executable + '" "%1"'
    $root = [Microsoft.Win32.Registry]::CurrentUser
    $backupDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GameBarPopupFix'
    $backupPath = Join-Path $backupDirectory 'active-backup.clixml'

    if ($Mode -eq 'Status') {
        $packages = @(Get-CurrentUserGameBarPackage)
        Write-Host ('Xbox Game Bar installed for this user: ' + ($packages.Count -gt 0))
        Get-GameBarStatus -Root $root -Command $command | Format-Table Path,Name,Matches -AutoSize
        Write-Host ('Active backup: ' + (Test-Path -LiteralPath $backupPath))
        Write-Host 'This checks the current process registry view. Restart the game to confirm the result.'
        exit 0
    }
    if (-not $PSCmdlet.ShouldProcess('current user Xbox Game Bar and popup settings',$Mode)) { exit 0 }

    $mutex = [Threading.Mutex]::new($false,('Local\GameBarPopupFix-' + $sid))
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another operation is already running.' }
    $initialPackages = @()
    if ($Mode -in @('Apply','Uninstall')) {
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Windows systray.exe is missing; no changes made.' }
        $initialPackages = @(Get-CurrentUserGameBarPackage)
        if ($Mode -eq 'Apply' -and $initialPackages.Count -gt 0) {
            throw 'Xbox Game Bar is installed. Use menu option 1 or -Mode Uninstall to uninstall it and fix game popups.'
        }
        Assert-GameBarHandlers -Root $root
    }
    $backup = $null
    if (Test-Path -LiteralPath $backupPath) {
        $backup = Import-Clixml -LiteralPath $backupPath
        if ($backup.UserSid -ne $sid) { throw 'Backup belongs to another Windows user.' }
        Assert-GameBarSnapshot $backup.Snapshot
    } elseif ($Mode -eq 'Restore') {
        throw ('No active backup found at ' + $backupPath)
    }
    $beforeRun = New-GameBarSnapshot -Root $root
    Assert-GameBarSnapshot $beforeRun
    if ($Mode -in @('Apply','Uninstall') -and $null -eq $backup) {
        $null = [IO.Directory]::CreateDirectory($backupDirectory)
        $backup = [pscustomobject]@{
            UserSid=$sid; CreatedUtc=[DateTime]::UtcNow.ToString('o'); Snapshot=$beforeRun
            InitialGameBarPackages=@($initialPackages | ForEach-Object { $_.PackageFullName })
        }
        $temporaryPath = Join-Path $backupDirectory ([Guid]::NewGuid().ToString('N') + '.tmp')
        $backup | Export-Clixml -LiteralPath $temporaryPath -Depth 12 -Encoding UTF8 -NoClobber
        [IO.File]::Move($temporaryPath,$backupPath)
        $roundTrip = Import-Clixml -LiteralPath $backupPath
        Assert-GameBarSnapshot $roundTrip.Snapshot
    }
    try {
        if ($Mode -eq 'Uninstall') {
            $removed = Remove-CurrentUserGameBar -Confirm:$false
            Write-Host ('Xbox Game Bar packages removed for this user: ' + $removed)
        }
        if ($Mode -in @('Apply','Uninstall')) {
            Set-GameBarFix -Root $root -Command $command
            if (@(Get-GameBarStatus -Root $root -Command $command | Where-Object { -not $_.Matches }).Count -ne 0) {
                throw 'Registry readback did not match the requested settings.'
            }
        } else {
            Restore-GameBarSnapshot -Root $root -Snapshot $backup.Snapshot
        }
        if (-not ('GameBarPopupFix.Shell' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace GameBarPopupFix {
    public static class Shell {
        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
    }
}
'@
        }
        [GameBarPopupFix.Shell]::SHChangeNotify(0x08000000,0x1000,[IntPtr]::Zero,[IntPtr]::Zero)
    } catch {
        $originalError = $_
        try { Restore-GameBarSnapshot -Root $root -Snapshot $beforeRun }
        catch { Write-Warning ('Registry rollback also failed: ' + $_.Exception.Message) }
        if ($Mode -eq 'Uninstall' -and $initialPackages.Count -gt 0) {
            Write-Warning 'Package removal may have completed. Registry rollback cannot reinstall Game Bar; use Microsoft Store to reinstall it if needed.'
        }
        throw $originalError
    }
    if ($Mode -eq 'Restore') {
        $archivePath = Join-Path $backupDirectory ('restored-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff') + '.clixml')
        [IO.File]::Move($backupPath,$archivePath)
        Write-Host ('Restored registry settings. Backup retained: ' + $archivePath)
        Write-Host 'This does not reinstall Game Bar or restore its app data.'
    } else {
        Write-Host ('Applied in this process registry view. Original settings backup: ' + $backupPath)
        Write-Host 'Close and restart your game from its normal launcher to confirm the popup is gone.'
    }
    exit 0
} catch {
    Write-Host ('FAILED: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($root) { $root.Dispose() }
    if ($locked -and $mutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
