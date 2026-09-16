#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Modules/Horizon/HorizonProvider.psm1') -Force
Import-Module Omnissa.VimAutomation.HorizonView
$module = Get-Module HorizonProvider
$dll = Join-Path (Get-Module Omnissa.Horizon.Helper).ModuleBase '../Omnissa.VimAutomation.HorizonView/netcoreapp3.1/ViewApi.dll'
$assembly = [Reflection.Assembly]::LoadFrom($dll)
function New-SdkObject([string]$Name) {
    $type = $assembly.GetTypes() | Where-Object Name -EQ $Name | Select-Object -First 1
    [Activator]::CreateInstance($type)
}
try {
    $pool = New-SdkObject DesktopInfo
    $pool.Base = New-SdkObject DesktopBase
    $pool.Base.Name = 'POOL-IC'
    $pool.Type = 'AUTOMATED'
    $pool.AutomatedDesktopData = New-SdkObject DesktopAutomatedDesktopData
    $data = $pool.AutomatedDesktopData
    $data.ProvisioningType = 'INSTANT_CLONE_ENGINE'
    $data.VirtualCenterNamesData = New-SdkObject DesktopVirtualCenterNamesData
    $data.VirtualCenterNamesData.ParentVmPath = '/DC/vm/Gold/Windows11'
    $data.VirtualCenterNamesData.SnapshotPath = '/release-1'
    $data.ProvisioningStatusData = New-SdkObject DesktopProvisioningStatusData
    $data.ProvisioningStatusData.InstantCloneProvisioningStatusData = New-SdkObject DesktopInstantCloneDesktopProvisioningStatusData
    $pending = $data.ProvisioningStatusData.InstantCloneProvisioningStatusData
    $pending.PendingImageParentVmPath = '/DC/vm/Gold/Windows11-v2'
    $pending.PendingImageSnapshotPath = '/release-2'
    $row = & $module { param($p) ConvertTo-PHPoolImage -Pool $p } $pool
    if ($row.Image -ne '/DC/vm/Gold/Windows11' -or $row.Snapshot -ne '/release-1' -or $row.PendingSnapshot -ne '/release-2') { throw 'Images configurée et en attente confondues.' }
    $data.VirtualCenterNamesData.ParentVmPath = $null
    $data.VirtualCenterNamesData.TemplatePath = '/DC/vm/Templates/W11'
    $row = & $module { param($p) ConvertTo-PHPoolImage -Pool $p } $pool
    if ($row.ImageKind -ne 'Template' -or $row.Image -ne '/DC/vm/Templates/W11') { throw 'Template non identifié.' }
    $data.VirtualCenterNamesData.TemplatePath = $null
    $data.VirtualCenterNamesData.ImageManagementStreamName = 'W11-stream'
    $data.VirtualCenterNamesData.ImageManagementTagName = 'Production'
    $row = & $module { param($p) ConvertTo-PHPoolImage -Pool $p } $pool
    if ($row.ImageKind -ne 'Image Management' -or $row.ImageTag -ne 'Production') { throw 'Stream/tag perdus.' }
    $manual = New-SdkObject DesktopInfo
    $manual.Type = 'MANUAL'
    $manual.Base = New-SdkObject DesktopBase
    $manual.Base.Name = 'POOL-MANUAL'
    $row = & $module { param($p) ConvertTo-PHPoolImage -Pool $p } $manual
    if ($row.Status -ne 'Sans image de provisioning' -or $row.Image) { throw 'Pool manuel mal classé.' }
    $farm = New-SdkObject FarmInfo
    $farm.Data = New-SdkObject FarmData
    $farm.Data.Name = 'RDS-FARM'
    $farm.AutomatedFarmData = New-SdkObject FarmAutomatedFarmData
    $farm.AutomatedFarmData.VirtualCenterNamesData = New-SdkObject FarmVirtualCenterNamesData
    $farm.AutomatedFarmData.VirtualCenterNamesData.ParentVmPath = '/DC/vm/Gold/RDS'
    $manual.Type = 'RDS'
    $row = & $module { param($p,$f) ConvertTo-PHPoolImage -Pool $p -Farm $f } $manual $farm
    if ($row.Farm -ne 'RDS-FARM' -or $row.Image -ne '/DC/vm/Gold/RDS') { throw 'Image de ferme RDS incorrecte.' }
    $rejected = $false
    try { Get-PHPoolImage } catch { if ($_.Exception.Message -notlike 'Connecte-toi*') { throw }; $rejected = $true }
    if (-not $rejected) { throw 'Connexion obligatoire non contrôlée.' }
    Write-Output 'Gold images : SDK réel, image/snapshot, attente, templates, streams, pools manuels et RDS : OK'
} finally { Remove-Module HorizonProvider }

