Set-StrictMode -Version Latest

function Get-PHDiagnosticSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $settings = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    foreach ($name in 'EventDays', 'MaxFileMB', 'MaxTotalMB') {
        if ($settings.$name -isnot [long] -and $settings.$name -isnot [int]) { throw "Valeur entière requise : $name" }
        if ($settings.$name -lt 1 -or $settings.$name -gt 10000) { throw "Valeur hors limites : $name" }
    }
    if ($settings.EventDays -gt 30) { throw 'La période maximale est de 30 jours.' }
    if ($settings.MaxFileMB -gt $settings.MaxTotalMB) { throw 'MaxFileMB doit être inférieur ou égal à MaxTotalMB.' }
    if ($settings.LogDirectories -isnot [array]) { throw 'LogDirectories doit être un tableau.' }
    foreach ($directory in $settings.LogDirectories) {
        if ($directory -isnot [string] -or [string]::IsNullOrWhiteSpace($directory)) { throw 'Dossier de logs invalide.' }
    }
    $settings
}

function Export-PHDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$')][string]$ComputerName,
        [Parameter(Mandatory)][ValidateSet('System','Network','Events','GroupPolicy','AgentLogs')][string[]]$Categories,
        [Parameter(Mandatory)][string]$SettingsPath,
        [Parameter(Mandatory)][string]$Destination,
        [pscredential]$Credential
    )
    if ($Categories.Count -eq 0) { throw 'Sélectionne au moins une catégorie.' }
    $settings = Get-PHDiagnosticSettings -Path $SettingsPath
    $null = New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop
    $destinationRoot = (Resolve-Path -LiteralPath $Destination -ErrorAction Stop).ProviderPath
    $id = [guid]::NewGuid().ToString('N')
    $name = '{0}-{1}-{2}' -f $ComputerName, (Get-Date -Format 'yyyyMMdd-HHmmss'), $id.Substring(0,8)
    $staging = Join-Path $destinationRoot ($name + '.partial')
    $archive = Join-Path $destinationRoot ($name + '.zip')
    $session = $null
    $remoteRoot = $null
    $cleanupWarning = $null
    try {
        $options = @{ ComputerName = $ComputerName; Authentication = 'Kerberos'; ErrorAction = 'Stop'
            SessionOption = (New-PSSessionOption -OpenTimeout 15000) }
        if ($Credential) { $options.Credential = $Credential }
        $session = New-PSSession @options
        $remoteRoot = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            param($Id)
            Join-Path ([IO.Path]::GetTempPath()) ('PowerHorizon-' + $Id)
        } -ArgumentList $id
        $collector = [scriptblock]::Create((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Collect-Diagnostics.ps1') -Raw))
        $null = Invoke-Command -Session $session -ScriptBlock $collector -ErrorAction Stop -ArgumentList @(
            $remoteRoot, $Categories, $settings.EventDays, $settings.MaxFileMB, $settings.MaxTotalMB, $settings.LogDirectories
        )
        Copy-Item -LiteralPath $remoteRoot -Destination $staging -FromSession $session -Recurse -ErrorAction Stop
        $manifest = Get-Content -LiteralPath (Join-Path $staging 'manifest.json') -Raw | ConvertFrom-Json
        # ZipFile also includes hidden files, unlike Compress-Archive.
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $archive)
        $issues = @($manifest.Results | Where-Object Status -NE 'Collected').Count
        $result = [pscustomobject]@{ Archive = $archive; Issues = $issues; Results = $manifest.Results; CleanupWarning = $null }
    } finally {
        if ($session) {
            if ($remoteRoot) {
                try {
                    Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                        param($Id, $Expected)
                        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
                        $target = [IO.Path]::GetFullPath((Join-Path $tempRoot ('PowerHorizon-' + $Id)))
                        if ($target -ne $Expected -or -not $target.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Chemin de nettoyage invalide.' }
                        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
                    } -ArgumentList $id, $remoteRoot
                } catch { $cleanupWarning = "Dossier temporaire à supprimer sur ${ComputerName} : $remoteRoot" }
            }
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
    # Only delete local staging after successful compression; preserve it on failure.
    $fullStaging = [IO.Path]::GetFullPath($staging)
    $prefix = $destinationRoot.TrimEnd('\') + '\'
    if (-not $fullStaging.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $fullStaging -Leaf) -ne ($name + '.partial')) { throw 'Chemin de nettoyage local invalide.' }
    try { Remove-Item -LiteralPath $fullStaging -Recurse -Force -ErrorAction Stop }
    catch { $cleanupWarning = "$cleanupWarning Dossier local conservé : $fullStaging".Trim() }
    $result.CleanupWarning = $cleanupWarning
    $result
}

Export-ModuleMember -Function Get-PHDiagnosticSettings, Export-PHDiagnostics
