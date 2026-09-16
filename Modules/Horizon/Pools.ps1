
# Loaded in the HorizonProvider module scope.
function Get-PHLatestPoolEvent {
    param([Parameter(Mandatory)]$PoolId)
    $query = New-Object Omnissa.Horizon.QueryDefinition
    $query.QueryEntityType = 'AuditEventSummaryView'
    $poolFilter = New-Object Omnissa.Horizon.QueryFilterEquals
    $poolFilter.MemberName = 'desktopId'
    $poolFilter.Value = $PoolId
    $types = foreach ($name in 'AGENT_CONNECTED','AGENT_RECONNECTED') {
        $filter = New-Object Omnissa.Horizon.QueryFilterEquals
        $filter.MemberName = 'eventType'
        $filter.Value = $name
        $filter
    }
    $or = New-Object Omnissa.Horizon.QueryFilterOr
    $or.Filters = $types
    $and = New-Object Omnissa.Horizon.QueryFilterAnd
    $and.Filters = @($poolFilter, $or)
    $query.Filter = $and
    $query.SortBy = 'time'
    $query.SortDescending = $true
    $query.Limit = 1
    $query.MaxPageSize = 1
    # Optional-value flags are not exposed by every Horizon SDK version.
    foreach ($flag in 'SortDescendingSpecified', 'LimitSpecified', 'MaxPageSizeSpecified') {
        if ($null -ne $query.PSObject.Properties[$flag]) { $query.$flag = $true }
    }
    $service = New-Object Omnissa.Horizon.QueryServiceService
    $page = $null
    try {
        $page = $service.QueryService_Create($script:Connection.ExtensionData, $query)
        @($page.Results) | Where-Object { $null -ne $_ } | Select-Object -First 1
    } finally {
        if ($null -ne $page -and $page.Id) { $service.QueryService_Delete($script:Connection.ExtensionData, $page.Id) }
    }
}

function Get-PHPoolOverview {
    [CmdletBinding()]
    param([string]$Prefix = '')
    if ($null -eq $script:Connection) { throw 'Connecte-toi à Horizon avant de rechercher des pools.' }
    $pools = @(Get-HVPoolSummary -HvServer $script:Connection -SuppressInfo $true -ErrorAction Stop |
        Where-Object { ([string]$_.DesktopSummaryData.Name).StartsWith($Prefix.Trim(), [StringComparison]::OrdinalIgnoreCase) })
    if (-not $pools.Count) { return }
    $machines = @(Get-HVMachineSummary -HvServer $script:Connection -SuppressInfo $true -ErrorAction Stop)
    $sessions = @()
    $sessionError = ''
    try { $sessions = @(Get-HVLocalSession -HvServer $script:Connection -ErrorAction Stop) }
    catch { $sessionError = $_.Exception.Message }
    $desktopService = New-Object Omnissa.Horizon.DesktopService
    $farmService = New-Object Omnissa.Horizon.FarmService
    foreach ($summary in $pools) {
        $poolId = [string]$summary.Id.Id
        $data = $summary.DesktopSummaryData
        $notes = [Collections.Generic.List[string]]::new()
        $image = ''
        $snapshot = ''
        try {
            $pool = $desktopService.Desktop_Get($script:Connection.ExtensionData, $summary.Id)
            $farm = $null
            if ($pool.Type -eq 'RDS') { $farm = $farmService.Farm_Get($script:Connection.ExtensionData, $pool.RdsDesktopData.Farm) }
            $imageRow = ConvertTo-PHPoolImage -Pool $pool -Farm $farm
            $image = $imageRow.Image
            $snapshot = $imageRow.Snapshot
            if (-not $image) { $image = if ($imageRow.ImageStream) { $imageRow.ImageStream + ' / ' + $imageRow.ImageTag } else { $imageRow.Status } }
        } catch { $notes.Add('Image : ' + $_.Exception.Message) }
        $latest = $sessions | Where-Object { (Get-PHValue $_ 'referenceData.desktop.id') -eq $poolId -and (Get-PHValue $_ 'sessionData.startTimeSpecified') } |
            Sort-Object { $_.SessionData.StartTime } -Descending | Select-Object -First 1
        $lastUse = $null
        $lastUser = ''
        $source = 'Aucune connexion dans les événements accessibles'
        $client = ''
        $clientDate = $null
        $clientSource = 'Non disponible'
        if ($latest) {
            $client = [string](Get-PHValue $latest 'namesData.clientName')
            if ($client) {
                $clientDate = $latest.SessionData.StartTime
                $clientSource = 'Session encore présente (date de début)'
            }
        }
        try {
            $event = Get-PHLatestPoolEvent -PoolId $summary.Id
            if ($event) {
                # Match the historical session before displaying its client.
                $client = ''
                $clientDate = $null
                $clientSource = 'Session historique non disponible'
                $eventSessionId = Get-PHValue $event 'sessionId.id'
                if ($eventSessionId) {
                    $eventSession = $sessions | Where-Object {
                        (Get-PHValue $_ 'id.id') -eq $eventSessionId -and
                        (Get-PHValue $_ 'referenceData.desktop.id') -eq $poolId
                    } | Select-Object -First 1
                    if ($eventSession) {
                        $client = [string](Get-PHValue $eventSession 'namesData.clientName')
                        $clientSource = 'Session de la dernière connexion retrouvée'
                    }
                }
                $lastUse = $event.Time
                $lastUser = $event.UserDisplayName
                $source = 'Événements Horizon : ' + $event.EventType
                if ($event.UserId) {
                    try {
                        $user = $script:Connection.ExtensionData.ADUserOrGroup.ADUserOrGroup_Get($event.UserId)
                        if ($user.Base.LoginName) { $lastUser = $user.Base.LoginName }
                    } catch { $notes.Add('Compte AD non résolu ; nom Horizon affiché.') }
                }
            }
        } catch { $source = 'Historique indisponible'; $notes.Add('Historique : ' + $_.Exception.Message) }
        if (-not $lastUse -and $latest) {
            $lastUse = $latest.SessionData.StartTime
            $lastUser = $latest.NamesData.UserName
            $source += ' ; début de session encore présente'
        }
        if ($source -notlike 'Événements Horizon :*') { $notes.Add($source) }
        if ($sessionError) { $notes.Add('Client : ' + $sessionError) }
        $count = @($machines | Where-Object { (Get-PHValue $_ 'base.desktop.id') -eq $poolId }).Count
        [pscustomobject]@{
            Pool = $data.Name
            PoolType = $data.Type
            Enabled = $data.Enabled
            Assignment = $data.UserAssignment
            VdiCount = $count
            LastUse = $lastUse
            LastUser = $lastUser
            UsageSource = $source
            ClientName = if ($client) { $client } else { 'Non disponible' }
            ClientDate = $clientDate
            ClientSource = $clientSource
            Image = $image
            Snapshot = $snapshot
            Notes = $notes -join ' | '
        }
    }
}

function ConvertTo-PHInventoryExport {
    param([object[]]$Machines, [object[]]$Pools)
    $byId = @{}
    foreach ($pool in $Pools) { $byId[[string]$pool.Id.Id] = $pool.DesktopSummaryData }
    foreach ($machine in $Machines) {
        if ($null -eq $machine) { continue }
        $id = [string](Get-PHValue $machine 'base.desktop.id')
        $pool = $byId[$id]
        $assignment = if ($null -ne $pool) { $pool.UserAssignment } else { 'UNKNOWN' }
        $users = @()
        if ($assignment -eq 'DEDICATED') {
            $users = @(Get-PHValue $machine 'namesData.userNames' | Where-Object { $_ })
            if (-not $users.Count) { $users = @(Get-PHValue $machine 'namesData.userName' | Where-Object { $_ }) }
        }
        [pscustomobject][ordered]@{
            Pool = Get-PHValue $machine 'namesData.desktopName'
            PoolId = $id
            PoolEnabled = Get-PHValue $pool 'enabled'
            Hostname = Get-PHValue $machine 'base.name'
            DNS = Get-PHValue $machine 'base.dnsName'
            State = Get-PHValue $machine 'base.basicState'
            Assignment = $assignment
            AssignedUsers = $users -join '; '
        }
    }
}

function Export-PHInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Destination)
    if ($null -eq $script:Connection) { throw 'Connecte-toi à Horizon avant de lancer un export.' }
    # Always query fresh data; never reuse the filtered UI grid.
    $pools = @(Get-HVPoolSummary -HvServer $script:Connection -SuppressInfo $true -ErrorAction Stop)
    $machines = @(Get-HVMachineSummary -HvServer $script:Connection -SuppressInfo $true -ErrorAction Stop)
    $rows = @(ConvertTo-PHInventoryExport -Machines $machines -Pools $pools)
    $null = New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop
    $path = Join-Path $Destination ('VDI-tous-pools-{0}-{1}.csv' -f (Get-Date -Format yyyyMMdd-HHmmss), ([guid]::NewGuid().ToString('N').Substring(0,8)))
    # Neutralize spreadsheet formulas in server-provided strings.
    foreach ($row in $rows) {
        foreach ($property in $row.PSObject.Properties) {
            if ($property.Value -is [string] -and $property.Value -match '^[\s]*[=+@-]|^[\t\r\n]') { $property.Value = "'" + $property.Value }
        }
    }
    if ($rows.Count) { $rows | Export-Csv -LiteralPath $path -Delimiter ';' -Encoding utf8BOM -NoTypeInformation -ErrorAction Stop }
    else { '"Pool";"PoolId";"PoolEnabled";"Hostname";"DNS";"State";"Assignment";"AssignedUsers"' | Set-Content -LiteralPath $path -Encoding utf8BOM }
    [pscustomobject]@{ Path = [IO.Path]::GetFullPath($path); Count = $rows.Count; UnknownPools = @($rows | Where-Object Assignment -EQ 'UNKNOWN').Count }
}

