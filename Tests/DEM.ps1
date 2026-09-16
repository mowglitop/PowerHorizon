
#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Modules/RemoteVDI/RemoteVDI.psm1') -Force
$module = Get-Module RemoteVDI
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('PowerHorizon-DEM-' + [guid]::NewGuid().ToString('N'))
$null = New-Item $testRoot -ItemType Directory
try {
    foreach ($user in 'alice','bob') {
        $folder = New-Item (Join-Path $testRoot "$user/Logs") -ItemType Directory -Force
        Set-Content (Join-Path $folder.FullName 'FlexEngine.log') "fixture $user"
    }
    $settings = Join-Path $testRoot 'settings.json'
    @{ EventDays=3; MaxFileMB=1; MaxTotalMB=2; LogDirectories=@(); DEMLogDirectories=@('\\fixture.invalid\profiles$\%UsErNaMe%\Logs\FlexEngine.log') } |
        ConvertTo-Json | Set-Content $settings
    $before = Get-Content $settings -Raw
    $credential = [pscredential]::new('DOM\admin', (ConvertTo-SecureString 'fixture' -AsPlainText -Force))
    & $module {
        param($directory, $credential)
        $script:ShareRoot = $directory
        $script:ExpectedCredential = $credential
        $script:Users = @(
            [pscustomobject]@{ UserName='alice'; Domain='DOM'; SessionId=1 },
            [pscustomobject]@{ UserName='bob'; Domain='DOM'; SessionId=2 }
        )
        function script:New-PSSessionOption { param($OpenTimeout) @{} }
        function script:New-PSSession { param($ComputerName,$Authentication,$SessionOption,$ErrorAction,$Credential) [pscustomobject]@{ Fixture=$true } }
        function script:Remove-PSSession { param($Session,$ErrorAction) }
        function script:Invoke-Command {
            param($Session,$ScriptBlock,$ErrorAction,[object[]]$ArgumentList)
            if ($ScriptBlock.ToString().Contains('WtsUsers')) { return $script:Users }
            & $ScriptBlock @ArgumentList
        }
        function script:New-PSDrive {
            param($Name,$PSProvider,$Root,$ErrorAction,$Credential)
            if ($Root -ne '\\fixture.invalid\profiles$' -or $Credential -ne $script:ExpectedCredential) { throw 'Incorrect SMB credentials/root.' }
            Microsoft.PowerShell.Management\New-PSDrive -Name $Name -PSProvider FileSystem -Root $script:ShareRoot -Scope Script
        }
        function script:Copy-Item {
            param($LiteralPath,$Destination,$FromSession,[switch]$Recurse,$ErrorAction)
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse:$Recurse -ErrorAction Stop
        }
    } $testRoot $credential
    $args = @{ ComputerName='fixture.invalid'; Categories=@('AgentLogs'); SettingsPath=$settings; Destination=(Join-Path $testRoot 'exports'); Credential=$credential }
    $report = Export-PHDiagnostics @args
    $dem = @($report.Results | Where-Object Category -EQ DEM)
    if ($dem.Count -ne 2 -or @($dem | Where-Object Status -NE Collected).Count) { throw ($dem | ConvertTo-Json) }
    if ($dem[0].User -ne 'DOM\alice' -or $dem[1].User -ne 'DOM\bob') { throw 'Incorrect session user.' }
    $zip = [IO.Compression.ZipFile]::OpenRead($report.Archive)
    try {
        $names = @($zip.Entries.FullName | ForEach-Object { $_.Replace('\','/') })
        if ('DEM-1/FlexEngine.log' -notin $names -or 'DEM-2/FlexEngine.log' -notin $names) { throw 'DEM logs missing from ZIP.' }
    } finally { $zip.Dispose() }
    if ((Get-Content $settings -Raw) -ne $before) { throw 'Configuration mutated.' }
    & $module { if (@(Get-PSDrive | Where-Object Name -Like 'PHDEM*').Count) { throw 'SMB drive leaked.' }; $script:Users=@() }
    $empty = Export-PHDiagnostics @args
    if (@($empty.Results | Where-Object { $_.Category -eq 'DEM' -and $_.Status -eq 'Skipped' }).Count -ne 1) { throw 'No-user result missing.' }
    & $module { $script:Users=@([pscustomobject]@{ UserName='missing'; Domain='DOM'; SessionId=3 }) }
    $missing = Export-PHDiagnostics @args
    if (@($missing.Results | Where-Object { $_.Category -eq 'DEM' -and $_.Status -eq 'Failed' }).Count -ne 1) { throw 'Missing file not reported.' }
    & $module {
        $bad = $false
        try { Resolve-PHDEMPath '\\server\share\%username%\log' ([pscustomobject]@{ UserName='..\bad' }) } catch { $bad=$true }
        if (-not $bad) { throw 'Invalid username accepted.' }
        if (@(Get-PSDrive | Where-Object Name -Like 'PHDEM*').Count) { throw 'SMB drive leaked after failure.' }
    }
    Write-Output 'DEM : utilisateurs actifs simulés, SMB authentifié simulé, ZIP réel, sessions multiples/absentes, fichier absent et nettoyage : OK'
} finally {
    Remove-Module RemoteVDI
    $full = [IO.Path]::GetFullPath($testRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $full -Leaf) -notlike 'PowerHorizon-DEM-*') { throw 'Invalid cleanup path.' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
