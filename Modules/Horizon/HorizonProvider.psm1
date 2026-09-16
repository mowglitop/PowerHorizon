Set-StrictMode -Version Latest
$script:Connection = $null

function Connect-PHHorizon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$Server,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Domain,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    if ($null -ne $script:Connection) { throw 'Déconnecte la session actuelle avant de changer de serveur.' }
    Import-Module Omnissa.VimAutomation.HorizonView -ErrorAction Stop
    Import-Module Omnissa.Horizon.Helper -DisableNameChecking -ErrorAction Stop
    $script:Connection = Connect-HVServer -Server $Server -Domain $Domain -Credential $Credential -NotDefault -ErrorAction Stop
    if ($null -eq $script:Connection) { throw 'Horizon nʼa retourné aucune connexion.' }
}

function Disconnect-PHHorizon {
    [CmdletBinding()]
    param()
    if ($null -ne $script:Connection) {
        Disconnect-HVServer -Server $script:Connection -Confirm:$false -ErrorAction Stop
        $script:Connection = $null
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

Export-ModuleMember -Function Connect-PHHorizon, Disconnect-PHHorizon, Get-PHMachine
