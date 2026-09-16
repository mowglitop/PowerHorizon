#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Modules/Horizon/HorizonProvider.psm1') -Force
Import-Module Omnissa.Horizon.Helper -DisableNameChecking
$module = Get-Module HorizonProvider
$a = [Reflection.Assembly]::LoadFrom((Join-Path (Get-Module Omnissa.Horizon.Helper).ModuleBase '../Omnissa.VimAutomation.HorizonView/netcoreapp3.1/ViewApi.dll'))
function New-Sdk([string]$Name) { [Activator]::CreateInstance(($a.GetTypes() | Where-Object Name -EQ $Name | Select-Object -First 1)) }
$pool = New-Sdk DesktopSummaryView
$pool.Id = New-Sdk DesktopId
$pool.Id.Id = 'pool-1'
$pool.DesktopSummaryData = New-Sdk DesktopSummaryData
$pool.DesktopSummaryData.Name = 'PROD-A'
$pool.DesktopSummaryData.UserAssignment = 'DEDICATED'
$pool.DesktopSummaryData.Type = 'MANUAL'
$pool.DesktopSummaryData.Enabled = $true
$pool2 = New-Sdk DesktopSummaryView
$pool2.Id = New-Sdk DesktopId
$pool2.Id.Id = 'pool-2'
$pool2.DesktopSummaryData = New-Sdk DesktopSummaryData
$pool2.DesktopSummaryData.Name = 'FLOAT-B'
$pool2.DesktopSummaryData.UserAssignment = 'FLOATING'
$machine = New-Sdk MachineNamesView
$machine.Base = New-Sdk MachineBase
$machine.Base.Desktop = $pool.Id
$machine.Base.Name = 'VD01'
$machine.Base.BasicState = 'MAINTENANCE'
$machine.NamesData = New-Sdk MachineNamesData
$machine.NamesData.DesktopName = 'PROD-A'
$machine.NamesData.UserNames = @('DOM\alice','DOM\bob')
$machine2 = New-Sdk MachineNamesView
$machine2.Base = New-Sdk MachineBase
$machine2.Base.Desktop = $pool2.Id
$machine2.Base.Name = '=formula'
$machine2.Base.BasicState = 'ERROR'
$machine2.NamesData = New-Sdk MachineNamesData
$machine2.NamesData.DesktopName = 'FLOAT-B'
$machine2.NamesData.UserName = 'DOM\not-assigned'
$session = New-Sdk SessionLocalSummaryView
$session.ReferenceData = New-Sdk SessionLocalReferenceData
$session.ReferenceData.Desktop = $pool.Id
$session.NamesData = New-Sdk SessionNamesData
$session.NamesData.ClientName = 'CLIENT01'
$session.NamesData.UserName = 'DOM\alice'
$session.SessionData = New-Sdk SessionData
$session.SessionData.StartTime = [datetime]'2026-09-01T10:00:00Z'
$session.SessionData.StartTimeSpecified = $true
$event = New-Sdk AuditEventSummaryView
$event.EventType = 'AGENT_RECONNECTED'
$event.Time = [datetime]'2026-09-02T11:00:00Z'
$event.UserDisplayName = 'DOM\bob'
$detail = New-Sdk DesktopInfo
$detail.Base = New-Sdk DesktopBase
$detail.Base.Name = 'PROD-A'
$detail.Type = 'MANUAL'
$dir = Join-Path $root ('Exports/Test-Pools-' + [guid]::NewGuid().ToString('N'))
try {
    & $module {
        param($pools,$machines,$session,$event,$detail)
        $script:Connection = [pscustomobject]@{ ExtensionData = $null }
        $script:PoolFixture = $pools
        $script:MachineFixture = $machines
        $script:SessionFixture = $session
        $script:EventFixture = $event
        $script:DesktopFixture = [pscustomobject]@{ Pool = $detail }
        $script:DesktopFixture | Add-Member ScriptMethod Desktop_Get { param($s,$id) $this.Pool }
        function script:Get-HVPoolSummary { param($HvServer,$SuppressInfo,$ErrorAction) $script:PoolFixture }
        function script:Get-HVMachineSummary { param($HvServer,$SuppressInfo,$ErrorAction) $script:MachineFixture }
        function script:Get-HVLocalSession { param($HvServer,$ErrorAction) $script:SessionFixture }
        function script:Get-PHLatestPoolEvent { param($PoolId) $script:EventFixture }
        function script:New-Object {
            param($TypeName)
            if ($TypeName -eq 'Omnissa.Horizon.DesktopService') { return $script:DesktopFixture }
            if ($TypeName -eq 'Omnissa.Horizon.FarmService') { return [pscustomobject]@{} }
            Microsoft.PowerShell.Utility\New-Object $TypeName
        }
    } @($pool,$pool2) @($machine,$machine2) $session $event $detail
    $rows = @(Get-PHPoolOverview -Prefix ' prod')
    if ($rows.Count -ne 1 -or $rows[0].VdiCount -ne 1 -or $rows[0].LastUser -ne 'DOM\bob' -or $rows[0].LastUse -ne $event.Time) { throw 'Préfixe/comptage/historique incorrect.' }
    if ($rows[0].ClientName -ne 'CLIENT01' -or $rows[0].ClientDate -ne $session.SessionData.StartTime) { throw 'Client et date incorrects.' }
    if (@(Get-PHPoolOverview -Prefix 'ROD').Count -or @(Get-PHPoolOverview -Prefix 'PRO*').Count) { throw 'Le préfixe doit être littéral.' }
    & $module { function script:Get-PHLatestPoolEvent { param($PoolId) throw 'History denied' } }
    $row = Get-PHPoolOverview -Prefix 'PROD'
    if ($row.UsageSource -notlike 'Historique indisponible*' -or $row.LastUser -ne 'DOM\alice') { throw 'Repli historique non signalé.' }
    $report = Export-PHInventory -Destination $dir
    $csv = @(Import-Csv -LiteralPath $report.Path -Delimiter ';')
    if ($report.Count -ne 2 -or $csv.Count -ne 2) { throw 'Export incomplet.' }
    if ($csv[0].AssignedUsers -ne 'DOM\alice; DOM\bob' -or $csv[1].AssignedUsers) { throw 'Affectations dédiées/flottantes incorrectes.' }
    if ($csv[0].State -ne 'MAINTENANCE' -or $csv[1].State -ne 'ERROR') { throw 'États exclus à tort.' }
    if ($csv[1].Hostname -ne "'=formula") { throw 'Formule CSV non neutralisée.' }
    & $module { $script:MachineFixture = @() }
    $empty = Export-PHInventory -Destination $dir
    if ($empty.Count -ne 0 -or (Get-Content $empty.Path -TotalCount 1) -notlike '*AssignedUsers*') { throw 'Export vide sans en-tête.' }
    Write-Output 'Pools/export : SDK réel, préfixe, comptage, historique, repli, clients, multi-affectations, tous états et CSV : OK'
} finally {
    Remove-Module HorizonProvider
    if (Test-Path -LiteralPath $dir) {
        $full = [IO.Path]::GetFullPath($dir)
        $prefix = [IO.Path]::GetFullPath((Join-Path $root 'Exports')).TrimEnd('\') + '\'
        if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $full -Leaf) -notlike 'Test-Pools-*') { throw 'Chemin de test invalide.' }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

