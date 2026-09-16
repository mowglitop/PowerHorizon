#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object Extension -In '.ps1', '.psm1') {
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
}
Import-Module Omnissa.VimAutomation.HorizonView
Import-Module Omnissa.Horizon.Helper -DisableNameChecking
foreach ($name in 'Connect-HVServer', 'Disconnect-HVServer', 'Get-HVMachineSummary') {
    $null = Get-Command $name -ErrorAction Stop
}
Import-Module (Join-Path $root 'Modules/Horizon/HorizonProvider.psm1') -Force
$rejected = $false
try { Get-PHMachine } catch {
    if ($_.Exception.Message -notlike '*Connecte-toi*') { throw }
    $rejected = $true
}
if (-not $rejected) { throw 'Une recherche sans connexion doit échouer.' }
Disconnect-PHHorizon
# Use the installed SDK schema to catch property/namespace mismatches offline.
$sdkPath = Join-Path (Get-Module Omnissa.VimAutomation.HorizonView | Select-Object -First 1).ModuleBase 'netcoreapp3.1/ViewApi.dll'
if (-not (Test-Path $sdkPath)) {
    $sdkPath = Join-Path (Get-Module Omnissa.VimAutomation.HorizonView | Select-Object -First 1).ModuleBase 'ViewApi.dll'
}
$sdk = [Reflection.Assembly]::LoadFrom($sdkPath)
$machineType = $sdk.GetTypes() | Where-Object Name -EQ 'MachineNamesView' | Select-Object -First 1
if ($null -eq $machineType) { throw 'MachineNamesView absent du SDK installé.' }
$machine = [Activator]::CreateInstance($machineType)
foreach ($propertyName in 'Base', 'NamesData') {
    $property = $machineType.GetProperty($propertyName, [Reflection.BindingFlags]'Public, Instance, IgnoreCase')
    $property.SetValue($machine, [Activator]::CreateInstance($property.PropertyType))
}
$machine.Base.Name = 'VD-TEST'
$machine.Base.DnsName = 'vd-test.example.invalid'
$machine.Base.BasicState = 'AVAILABLE'
$machine.NamesData.DesktopName = 'POOL-TEST'
$provider = Get-Module HorizonProvider
try {
    & $provider {
        param($fixture)
        $script:Connection = [pscustomobject]@{ Name = 'offline-test' }
        $script:Fixture = $fixture
        function script:Get-HVMachineSummary {
            param($HvServer, $SuppressInfo, $ErrorAction, $MachineName, $PoolName)
            if ($MachineName -or $PoolName -ne 'POOL-TEST') { throw 'Le pool doit être transmis, le préfixe doit être filtré localement.' }
            $script:Fixture
        }
    } $machine
    $rows = @(Get-PHMachine -MachineName ' vd-t ' -PoolName 'POOL-TEST')
    if ($rows.Count -ne 1 -or $rows[0].Hostname -ne 'VD-TEST' -or $rows[0].Pool -ne 'POOL-TEST' -or $rows[0].AssignedUser) {
        throw 'Projection inventaire incorrecte (dont utilisateur non affecté).'
    }
    if (@(Get-PHMachine -MachineName 'TEST' -PoolName 'POOL-TEST').Count) { throw 'Une sous-chaîne ne doit pas correspondre à un préfixe.' }
    if (@(Get-PHMachine -MachineName 'VD*' -PoolName 'POOL-TEST').Count) { throw 'Un joker doit être traité littéralement.' }
    if (@(Get-PHMachine -PoolName 'POOL-TEST').Count -ne 1) { throw 'Un préfixe vide doit conserver toutes les machines.' }
} finally { Remove-Module HorizonProvider }
& (Join-Path $root 'App.ps1') -ValidateOnly
& (Join-Path $PSScriptRoot 'DiagnosticCredentials.ps1')
& (Join-Path $PSScriptRoot 'Diagnostics.ps1')
& (Join-Path $PSScriptRoot 'DEM.ps1')
& (Join-Path $PSScriptRoot 'PoolImages.ps1')
& (Join-Path $PSScriptRoot 'Pools.ps1')
Write-Output 'Syntaxe, dépendances, garde de connexion, schéma SDK, filtres, projection et WPF : OK'


