function Write-PHAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][ValidateSet('Connect', 'Disconnect', 'Inventory', 'Diagnostics', 'PoolImages', 'Pools', 'ExportInventory')][string]$Action,
        [Parameter(Mandatory)][ValidateSet('Started', 'Succeeded', 'Partial', 'Failed')][string]$Result
    )
    # Deliberately no arbitrary message or exception: secrets never enter this log.
    $null = New-Item -ItemType Directory -Path $Directory -Force
    [ordered]@{ Timestamp = [DateTimeOffset]::Now.ToString('o'); Action = $Action; Result = $Result } |
        ConvertTo-Json -Compress |
        Add-Content -LiteralPath (Join-Path $Directory ('actions-{0}.jsonl' -f (Get-Date -Format yyyy-MM-dd))) -Encoding utf8
}
Export-ModuleMember -Function Write-PHAction


