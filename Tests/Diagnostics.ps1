#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Modules/RemoteVDI/RemoteVDI.psm1') -Force
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('PowerHorizon-Test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    $source = Join-Path $testRoot 'source'
    $null = New-Item -ItemType Directory -Path $source
    Set-Content -LiteralPath (Join-Path $source 'agent.log') -Value 'Synthetic diagnostic fixture'
    Set-Content -LiteralPath (Join-Path $source 'old.log') -Value 'Old fixture'
    (Get-Item -LiteralPath (Join-Path $source 'old.log')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-10)
    [IO.File]::WriteAllBytes((Join-Path $source 'large.log'), [byte[]]::new(1MB + 1))
    $settingsPath = Join-Path $testRoot 'settings.json'
    @{ EventDays = 3; MaxFileMB = 1; MaxTotalMB = 2; LogDirectories = @($source, (Join-Path $testRoot 'missing')) } |
        ConvertTo-Json | Set-Content -LiteralPath $settingsPath
    # Replace only transport with an in-process session; exercise the real collector,
    # transfer, ZIP creation, manifest and cleanup. No machine is contacted.
    $module = Get-Module RemoteVDI
    & $module {
        function script:New-PSSessionOption { param($OpenTimeout) @{ OpenTimeout = $OpenTimeout } }
        function script:New-PSSession {
            param($ComputerName, $Authentication, $SessionOption, $ErrorAction)
            if ($ComputerName -ne 'fixture.invalid' -or $Authentication -ne 'Kerberos') { throw 'Unexpected transport arguments.' }
            [pscustomobject]@{ Fixture = $true }
        }
        function script:Invoke-Command {
            param($Session, $ScriptBlock, $ErrorAction, [object[]]$ArgumentList)
            & $ScriptBlock @ArgumentList
        }
        function script:Copy-Item {
            param($LiteralPath, $Destination, $FromSession, [switch]$Recurse, $ErrorAction)
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse:$Recurse -ErrorAction Stop
        }
        function script:Remove-PSSession { param($Session, $ErrorAction) }
    }
    $report = Export-PHDiagnostics -ComputerName 'fixture.invalid' -Categories AgentLogs -SettingsPath $settingsPath -Destination (Join-Path $testRoot 'exports')
    if (-not (Test-Path -LiteralPath $report.Archive)) { throw 'ZIP absent.' }
    if ($report.Issues -ne 2 -or $report.CleanupWarning) { throw ('Bilan inattendu : ' + ($report | ConvertTo-Json -Depth 6)) }
    $zip = [IO.Compression.ZipFile]::OpenRead($report.Archive)
    try {
        $names = @($zip.Entries.FullName | ForEach-Object { $_.Replace('\', '/') })
        if ('manifest.json' -notin $names -or 'AgentLogs-1/agent.log' -notin $names) { throw 'Archive incomplète.' }
        if ($names -match '(old|large)\.log') { throw 'Filtrage taille/date incorrect.' }
    } finally { $zip.Dispose() }
    if (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'exports') -Directory).Count) { throw 'Staging non nettoyé.' }
    $invalidPath = Join-Path $testRoot 'invalid.json'
    @{ EventDays = 0; MaxFileMB = 1; MaxTotalMB = 2; LogDirectories = @() } | ConvertTo-Json | Set-Content $invalidPath
    $rejected = $false
    try { Get-PHDiagnosticSettings -Path $invalidPath } catch { $rejected = $true }
    if (-not $rejected) { throw 'Configuration invalide acceptée.' }
    # A transport failure must never be reported as a successful archive.
    & $module {
        function script:New-PSSession {
            param($ComputerName, $Authentication, $SessionOption, $ErrorAction)
            throw 'Fixture: WinRM unavailable'
        }
    }
    $failed = $false
    try {
        Export-PHDiagnostics -ComputerName 'fixture.invalid' -Categories System -SettingsPath $settingsPath -Destination (Join-Path $testRoot 'failed')
    } catch {
        if ($_.Exception.Message -notlike '*WinRM unavailable*') { throw }
        $failed = $true
    }
    if (-not $failed -or @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'failed') -File).Count) { throw 'Échec de transport mal géré.' }
    Write-Output 'Diagnostics : transport simulé, ZIP réel, manifeste partiel, filtres, nettoyage et configuration : OK'
} finally {
    Remove-Module RemoteVDI
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'PowerHorizon-Test-*') { throw 'Chemin de test invalide.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
