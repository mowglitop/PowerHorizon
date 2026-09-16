Set-StrictMode -Version Latest
$script:DiagnosticCredential = $null
$script:Connection = $null

function Connect-PHHorizon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$Server,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Domain,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    if ($null -ne $script:Connection) { throw 'Déconnecte la session actuelle avant de changer de serveur.' }
    $script:DiagnosticCredential = $null
    Import-Module Omnissa.VimAutomation.HorizonView -ErrorAction Stop
    Import-Module Omnissa.Horizon.Helper -DisableNameChecking -ErrorAction Stop
    $script:Connection = Connect-HVServer -Server $Server -Domain $Domain -Credential $Credential -NotDefault -ErrorAction Stop
    if ($null -eq $script:Connection) { throw 'Horizon nʼa retourné aucune connexion.' }
    $remoteUser = $Credential.UserName
    if (-not $remoteUser.Contains('@') -and -not $remoteUser.Contains('\')) { $remoteUser = '{0}\{1}' -f $Domain, $remoteUser }
    $script:DiagnosticCredential = [pscredential]::new($remoteUser, $Credential.Password)
}

function Get-PHDiagnosticCredential {
    if ($null -ne $script:Connection) { $script:DiagnosticCredential }
}

function Disconnect-PHHorizon {
    [CmdletBinding()]
    param()
    if ($null -ne $script:Connection) {
        Disconnect-HVServer -Server $script:Connection -Confirm:$false -ErrorAction Stop
        $script:Connection = $null
        $script:DiagnosticCredential = $null
    }
}

function Get-PHMachine {
    [CmdletBinding()]
    param([string]$MachineName, [string]$PoolName)
    if ($null -eq $script:Connection) { throw 'Connecte-toi à Horizon avant de rechercher des VDI.' }
    $parameters = @{ HvServer = $script:Connection; SuppressInfo = $true; ErrorAction = 'Stop' }
    $prefix = $MachineName.Trim()
    if ($PoolName) { $parameters.PoolName = $PoolName }
    foreach ($machine in @(Get-HVMachineSummary @parameters)) {
        if ($null -eq $machine) { continue }
        # Literal, case-insensitive prefix: user input is never a wildcard expression.
        if ($prefix -and -not ([string]$machine.Base.Name).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        [pscustomobject]@{
            Hostname = $machine.Base.Name
            DNS = $machine.Base.DnsName
            Pool = $machine.NamesData.DesktopName
            State = $machine.Base.BasicState
            AssignedUser = $machine.NamesData.UserName
        }
    }
}


function Get-PHValue($Object, [string]$Path) {
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $Object) { return $null }
        $property = $Object.PSObject.Properties[$part]
        if ($null -eq $property) { return $null }
        $Object = $property.Value
    }
    return $Object
}

function ConvertTo-PHPoolImage {
    param([Parameter(Mandatory)]$Pool, $Farm)
    $data = Get-PHValue $Pool 'automatedDesktopData'
    $farmName = ''
    if ($Pool.Type -eq 'RDS') {
        $data = Get-PHValue $Farm 'automatedFarmData'
        $farmName = Get-PHValue $Farm 'data.name'
    }
    $names = Get-PHValue $data 'virtualCenterNamesData'
    $pending = Get-PHValue $data 'provisioningStatusData.instantCloneProvisioningStatusData'
    $image = Get-PHValue $names 'parentVmPath'
    $kind = 'VM parente'
    if (-not $image) { $image = Get-PHValue $names 'templatePath'; $kind = 'Template' }
    $stream = Get-PHValue $names 'imageManagementStreamName'
    if (-not $image -and $stream) { $kind = 'Image Management' }
    $status = if ($image -or $stream) { 'Configurée' } elseif ($null -eq $data) { 'Sans image de provisioning' } else { 'Image non renseignée' }
    [pscustomobject]@{
        Pool = Get-PHValue $Pool 'base.name'
        PoolType = $Pool.Type
        Provisioning = Get-PHValue $data 'provisioningType'
        Farm = $farmName
        ImageKind = if ($image -or $stream) { $kind } else { '—' }
        Image = $image
        Snapshot = Get-PHValue $names 'snapshotPath'
        ImageStream = $stream
        ImageTag = Get-PHValue $names 'imageManagementTagName'
        PendingImage = Get-PHValue $pending 'pendingImageParentVmPath'
        PendingSnapshot = Get-PHValue $pending 'pendingImageSnapshotPath'
        PendingStream = Get-PHValue $pending 'pendingImageManagementStreamName'
        PendingTag = Get-PHValue $pending 'pendingImageManagementTagName'
        PendingState = Get-PHValue $pending 'instantClonePendingImageState'
        Status = $status
        Error = ''
    }
}

function Get-PHPoolImage {
    [CmdletBinding()]
    param()
    if ($null -eq $script:Connection) { throw 'Connecte-toi à Horizon avant de rechercher les gold images.' }
    $desktopService = New-Object Omnissa.Horizon.DesktopService
    $farmService = New-Object Omnissa.Horizon.FarmService
    $farms = @{}
    foreach ($summary in @(Get-HVPoolSummary -HvServer $script:Connection -SuppressInfo $true -ErrorAction Stop)) {
        if ($null -eq $summary) { continue }
        try {
            $pool = $desktopService.Desktop_Get($script:Connection.ExtensionData, $summary.Id)
            $farm = $null
            if ($pool.Type -eq 'RDS') {
                $farmId = $pool.RdsDesktopData.Farm
                $key = $farmId.Id
                if (-not $farms.ContainsKey($key)) { $farms[$key] = $farmService.Farm_Get($script:Connection.ExtensionData, $farmId) }
                $farm = $farms[$key]
            }
            ConvertTo-PHPoolImage -Pool $pool -Farm $farm
        } catch {
            [pscustomobject]@{ Pool = (Get-PHValue $summary 'desktopSummaryData.name'); PoolType = ''; Image = ''; Snapshot = ''; Status = 'Erreur de lecture'; Error = $_.Exception.Message }
        }
    }
}
Export-ModuleMember -Function Get-PHDiagnosticCredential, Connect-PHHorizon, Disconnect-PHHorizon, Get-PHMachine, Get-PHPoolImage


. (Join-Path $PSScriptRoot 'Pools.ps1')
Export-ModuleMember -Function Get-PHPoolOverview, Export-PHInventory
