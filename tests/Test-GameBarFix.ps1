#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Fix-GameBar.ps1')

# All registry operations are rooted in a newly created, random test-only key.
$testPath = 'Software\GameBarPopupFixTests\' + [Guid]::NewGuid().ToString('N')
$root = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($testPath)
$tempFile = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N') + '.clixml')
$command = '"C:\Windows\System32\systray.exe" "%1"'
$passed = 0

function Assert-True($Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Get-StateJson {
    New-GameBarSnapshot -Root $root | ConvertTo-Json -Depth 12 -Compress
}
function Pass([string]$Message) {
    $script:passed++
    Write-Host ('PASS: ' + $Message)
}
function Set-TestValue([string]$Path,[string]$Name,$Data,[Microsoft.Win32.RegistryValueKind]$Kind) {
    $key = $root.CreateSubKey($Path)
    try { $key.SetValue($Name,$Data,$Kind) } finally { $key.Dispose() }
}
function Expect-Failure([scriptblock]$Action) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    Assert-True $failed 'Expected the operation to fail.'
}

try {
    $empty = New-GameBarSnapshot -Root $root
    Set-TestValue 'Keep' 'Unrelated' 'preserve me' String
    Set-GameBarFix -Root $root -Command $command
    $key = $root.OpenSubKey('Software\Microsoft\GameBar')
    try {
        Assert-True ($key.GetValue('ShowStartupPanel') -eq 0) 'Startup tips were not disabled.'
        Assert-True ($key.GetValueKind('ShowStartupPanel') -eq 'DWord') 'Preference was not a DWORD.'
    } finally { $key.Dispose() }
    foreach ($protocol in 'ms-gamingoverlay','ms-gamebar','ms-gamebarservices','ms-xbox-overlay') {
        $key = $root.OpenSubKey('Software\Classes\' + $protocol + '\shell\open\command')
        try { Assert-True ($key.GetValue('') -ceq $command) ('Bad protocol command: ' + $protocol) }
        finally { $key.Dispose() }
    }
    Pass 'Correct preference types and all four handler commands under the isolated test root'

    $firstApply = Get-StateJson
    Set-GameBarFix -Root $root -Command $command
    Assert-True ((Get-StateJson) -ceq $firstApply) 'Repeated apply changed the targeted state.'
    Pass 'Repeated apply is idempotent'
    Restore-GameBarSnapshot -Root $root -Snapshot $empty
    Assert-True ((Get-StateJson) -ceq ($empty | ConvertTo-Json -Depth 12 -Compress)) 'New keys or values were not fully restored.'
    $key = $root.OpenSubKey('Keep')
    try { Assert-True ($key.GetValue('Unrelated') -ceq 'preserve me') 'Unrelated data was changed.' }
    finally { $key.Dispose() }
    Pass 'Absent original keys restored; unrelated data preserved'

    # Exercise every supported registry value kind and missing values through CLIXML.
    Set-TestValue 'Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' ([int]-1) DWord
    Set-TestValue 'System\GameConfigStore' 'GameDVR_Enabled' ([long]9223372036854775806) QWord
    Set-TestValue 'Software\Microsoft\GameBar' 'ShowStartupPanel' ([byte[]]@(0,128,255)) Binary
    Set-TestValue 'Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' ([string[]]@('one','two')) MultiString
    Set-TestValue 'Software\Classes\ms-gamingoverlay' '' 'Existing description' String
    Set-TestValue 'Software\Classes\ms-gamingoverlay' 'URL Protocol' '%TEMP%\literal' ExpandString
    Set-TestValue 'Software\Classes\ms-gamebar' 'NoOpenWith' ([byte[]]@(1,0,2)) None
    Set-TestValue 'Software\Microsoft\GameBar' 'Unrelated' 'keep this too' String
    $seeded = New-GameBarSnapshot -Root $root
    $seeded | Export-Clixml -LiteralPath $tempFile -Depth 12
    $loaded = Import-Clixml -LiteralPath $tempFile
    Assert-GameBarSnapshot $loaded
    Set-GameBarFix -Root $root -Command $command
    $key = $root.OpenSubKey('Software\Classes\ms-gamingoverlay')
    try { Assert-True ($key.GetValue('') -ceq 'Existing description') 'Existing description was overwritten.' }
    finally { $key.Dispose() }
    Set-GameBarFix -Root $root -Command $command
    Restore-GameBarSnapshot -Root $root -Snapshot $loaded
    Assert-True ((Get-StateJson) -ceq ($seeded | ConvertTo-Json -Depth 12 -Compress)) 'Value data/types did not round-trip.'
    Pass 'CLIXML round trip restores all seven kinds, missing values and original descriptions'

    Set-GameBarFix -Root $root -Command $command
    Set-TestValue 'Software\Classes\ms-xbox-overlay\LaterChild' 'LaterValue' 'new data' String
    Restore-GameBarSnapshot -Root $root -Snapshot $loaded
    $key = $root.OpenSubKey('Software\Classes\ms-xbox-overlay\LaterChild')
    try { Assert-True ($key.GetValue('LaterValue') -ceq 'new data') 'Restore deleted a later addition.' }
    finally { $key.Dispose() }
    $key = $root.OpenSubKey('Software\Microsoft\GameBar')
    try { Assert-True ($key.GetValue('Unrelated') -ceq 'keep this too') 'An existing unrelated value changed.' }
    finally { $key.Dispose() }
    Pass 'Restore preserves unrelated existing values and subsequently added subkeys'

    $invalid = Import-Clixml -LiteralPath $tempFile
    $invalid.Values[0].Path = 'Software\SomethingUnrelated'
    $beforeInvalid = Get-StateJson
    Expect-Failure { Restore-GameBarSnapshot -Root $root -Snapshot $invalid }
    Assert-True ((Get-StateJson) -ceq $beforeInvalid) 'Malformed restore made a partial write.'
    Pass 'Unexpected backup targets rejected before any writes'

    $invalid = Import-Clixml -LiteralPath $tempFile
    $invalid.Values[5].Kind = 'Unsupported'
    Expect-Failure { Restore-GameBarSnapshot -Root $root -Snapshot $invalid }
    Assert-True ((Get-StateJson) -ceq $beforeInvalid) 'Unsupported kind caused a partial restore.'
    Pass 'Unsupported backup types rejected before any writes'

    $invalid = Import-Clixml -LiteralPath $tempFile
    $invalid.Values[0].Data = 'not an integer'
    Expect-Failure { Restore-GameBarSnapshot -Root $root -Snapshot $invalid }
    Assert-True ((Get-StateJson) -ceq $beforeInvalid) 'Invalid value data caused a partial restore.'
    Pass 'Invalid backup value data rejected before any writes'

    Set-TestValue 'Software\Classes\ms-gamebar\shell\open\command' 'DelegateExecute' '{test-only}' String
    $beforeConflict = Get-StateJson
    Expect-Failure { Set-GameBarFix -Root $root -Command $command }
    Assert-True ((Get-StateJson) -ceq $beforeConflict) 'Conflicting COM handler caused partial changes.'
    Pass 'Conflicting COM handlers rejected before apply'

    # Mock both Appx cmdlets: tests NEVER invoke the real package manager.
    $script:mockPackages=@()
    $script:removedPackages=@()
    $script:failRemoval=$false
    $script:keepPackage=$false
    function Get-AppxPackage {
        [CmdletBinding()]
        param([string]$Name)
        Assert-True ($Name -ceq 'Microsoft.XboxGamingOverlay') 'Package query was not narrowly scoped.'
        $script:mockPackages
    }
    function Remove-AppxPackage {
        [CmdletBinding()]
        param([string]$Package)
        if($script:failRemoval){throw 'Simulated removal failure'}
        $script:removedPackages+=@($Package)
        if(-not $script:keepPackage){$script:mockPackages=@($script:mockPackages | Where-Object {$_.PackageFullName -cne $Package})}
    }
    $sample=[pscustomobject]@{Name='Microsoft.XboxGamingOverlay';PublisherId='8wekyb3d8bbwe';PackageFullName='Microsoft.XboxGamingOverlay_1.0.0.0_x64__8wekyb3d8bbwe'}
    Assert-True ((Remove-CurrentUserGameBar) -eq 0) 'Absent package should be a no-op.'
    Assert-True ($script:removedPackages.Count -eq 0) 'Tried to remove an absent package.'
    Pass 'Uninstall is a no-op if Game Bar is already absent (mocked Appx)'

    $script:mockPackages=@($sample)
    Assert-True ((Remove-CurrentUserGameBar -WhatIf) -eq 0) 'WhatIf attempted package removal.'
    Assert-True ($script:removedPackages.Count -eq 0 -and $script:mockPackages.Count -eq 1) 'WhatIf mutated package state.'
    Pass 'Uninstall WhatIf never calls Remove-AppxPackage (mocked Appx)'

    Assert-True ((Remove-CurrentUserGameBar) -eq 1) 'Installed Game Bar was not removed.'
    Assert-True ($script:removedPackages.Count -eq 1 -and $script:removedPackages[0] -ceq $sample.PackageFullName) 'Unexpected package removal.'
    Pass 'Only the exact current-user Game Bar package is removed (mocked Appx)'

    $script:mockPackages=@($sample,[pscustomobject]@{Name='Microsoft.GamingServices';PublisherId='8wekyb3d8bbwe';PackageFullName='Microsoft.GamingServices_1.0.0.0_x64__8wekyb3d8bbwe'})
    $script:removedPackages=@()
    Expect-Failure {Remove-CurrentUserGameBar}
    Assert-True ($script:removedPackages.Count -eq 0) 'An unrelated package caused partial removal.'
    Pass 'Unexpected package identity rejected before any removal (mocked Appx)'

    $script:mockPackages=@([pscustomobject]@{Name='Microsoft.XboxGamingOverlay';PublisherId='otherpublisher';PackageFullName='Microsoft.XboxGamingOverlay_1.0.0.0_x64__otherpublisher'})
    Expect-Failure {Remove-CurrentUserGameBar}
    Assert-True ($script:removedPackages.Count -eq 0) 'An unexpected publisher was accepted.'
    Pass 'Unexpected publisher rejected (mocked Appx)'

    $script:mockPackages=@($sample)
    $script:failRemoval=$true
    Expect-Failure {Remove-CurrentUserGameBar}
    Assert-True ($script:mockPackages.Count -eq 1) 'Removal failure was ignored.'
    $script:failRemoval=$false
    Pass 'Package manager failure is propagated (mocked Appx)'

    $script:keepPackage=$true
    Expect-Failure {Remove-CurrentUserGameBar}
    Assert-True ($script:mockPackages.Count -eq 1) 'Test fixture lost the retained package.'
    Pass 'Uninstall verifies the package actually disappeared (mocked Appx)'

    Write-Host ("All $passed tests passed. Real Game Bar keys and installed apps were not modified.")
} finally {
    $root.Dispose()
    # This exact newly created GUID key is owned solely by this test invocation.
    if ($testPath -notmatch '^Software\\GameBarPopupFixTests\\[0-9a-f]{32}$') { throw 'Invalid test cleanup path.' }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($testPath,$false)
    if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile }
}
