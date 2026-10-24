#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param([ValidateSet('Apply','Restore','Status')][string]$Mode = 'Status')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$mutex = $null
$locked = $false
$root = $null
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows is required.' }
    Import-Module (Join-Path $PSScriptRoot 'lib\GameBarFix.psm1') -Force
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $systemDirectory = [Environment]::SystemDirectory
    $executable = Join-Path $systemDirectory 'systray.exe'
    $command = '"' + $executable + '" "%1"'
    $root = [Microsoft.Win32.Registry]::CurrentUser
    $backupDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GameBarPopupFix'
    $backupPath = Join-Path $backupDirectory 'active-backup.clixml'

    if ($Mode -eq 'Status') {
        Get-GameBarStatus -Root $root -Command $command | Format-Table Path,Name,Matches -AutoSize
        Write-Host ('Active backup: ' + (Test-Path -LiteralPath $backupPath))
        Write-Host 'This checks the current process registry view only. Restart the game to confirm the result.'
        exit 0
    }
    if (-not $PSCmdlet.ShouldProcess('current user Game Bar settings', $Mode)) { exit 0 }

    $mutex = [Threading.Mutex]::new($false,('Local\GameBarPopupFix-' + $sid))
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another fix or restore is already running.' }

    if ($Mode -eq 'Apply') {
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Windows systray.exe is missing; no changes made.' }
        if (@(Get-AppxPackage -Name Microsoft.XboxGamingOverlay -ErrorAction Stop).Count -gt 0) {
            throw 'Xbox Game Bar is installed for this user. This workaround is intended for an already uninstalled Game Bar.'
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
    if ($Mode -eq 'Apply' -and $null -eq $backup) {
        $null = [IO.Directory]::CreateDirectory($backupDirectory)
        $backup = [pscustomobject]@{ UserSid=$sid; CreatedUtc=[DateTime]::UtcNow.ToString('o'); Snapshot=$beforeRun }
        $temporaryPath = Join-Path $backupDirectory ([Guid]::NewGuid().ToString('N') + '.tmp')
        $backup | Export-Clixml -LiteralPath $temporaryPath -Depth 12 -Encoding UTF8 -NoClobber
        # Atomic move fails rather than overwriting an existing original backup.
        [IO.File]::Move($temporaryPath,$backupPath)
        $roundTrip = Import-Clixml -LiteralPath $backupPath
        Assert-GameBarSnapshot $roundTrip.Snapshot
    }

    try {
        if ($Mode -eq 'Apply') {
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
        catch { Write-Warning ('Automatic rollback also failed: ' + $_.Exception.Message) }
        throw $originalError
    }

    if ($Mode -eq 'Restore') {
        $archivePath = Join-Path $backupDirectory ('restored-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff') + '.clixml')
        [IO.File]::Move($backupPath,$archivePath)
        Write-Host ('Restored original targeted values. Backup retained: ' + $archivePath)
    } else {
        Write-Host ('Applied in this process registry view. Original backup: ' + $backupPath)
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
