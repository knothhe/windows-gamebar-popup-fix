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

Export-ModuleMember -Function Get-GameBarTargets,New-GameBarSnapshot,Assert-GameBarSnapshot,Assert-GameBarHandlers,Set-GameBarFix,Restore-GameBarSnapshot,Get-GameBarStatus
