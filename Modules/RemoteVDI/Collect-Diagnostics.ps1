# Executed on the target in Windows PowerShell 5.1, or locally by offline tests.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string[]]$Categories,
    [Parameter(Mandatory)][int]$EventDays,
    [Parameter(Mandatory)][int]$MaxFileMB,
    [Parameter(Mandatory)][int]$MaxTotalMB,
    [string[]]$LogDirectories = @()
)
$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Path $OutputDirectory
$results = [Collections.Generic.List[object]]::new()
$bytesCopied = 0L
function Add-Result($Category, $Source, $Status, $Detail) {
    $results.Add([pscustomobject]@{ Category = $Category; Source = $Source; Status = $Status; Detail = $Detail })
}
foreach ($category in $Categories) {
    try {
        switch ($category) {
            'System' {
                [ordered]@{
                    Computer = Get-CimInstance Win32_ComputerSystem | Select-Object Name, Domain, Manufacturer, Model, TotalPhysicalMemory
                    OS = Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, LastBootUpTime, FreePhysicalMemory
                    Disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object DeviceID, Size, FreeSpace)
                    Services = @(Get-Service | Select-Object Name, DisplayName, Status)
                } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'system.json') -Encoding UTF8
                Add-Result $category 'Windows' 'Collected' ''
            }
            'Network' {
                [ordered]@{
                    Adapters = @(Get-NetIPConfiguration | Select-Object InterfaceAlias, InterfaceIndex, IPv4Address, IPv4DefaultGateway, DNSServer)
                    Dns = @(Get-DnsClientServerAddress | Select-Object InterfaceAlias, AddressFamily, ServerAddresses)
                    Routes = @(Get-NetRoute | Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric)
                } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'network.json') -Encoding UTF8
                Add-Result $category 'Windows' 'Collected' ''
            }
            'Events' {
                foreach ($channel in @('System', 'Application', 'Microsoft-Windows-GroupPolicy/Operational')) {
                    try {
                        $name = $channel.Replace('/', '-') + '.evtx'
                        $milliseconds = [long]$EventDays * 86400000
                        $query = '*[System[TimeCreated[timediff(@SystemTime) <= {0}]]]' -f $milliseconds
                        $message = & wevtutil.exe epl $channel (Join-Path $OutputDirectory $name) "/q:$query" 2>&1
                        if ($LASTEXITCODE -ne 0) { throw ($message | Out-String) }
                        Add-Result $category $channel 'Collected' ''
                    } catch { Add-Result $category $channel 'Failed' $_.Exception.Message }
                }
            }
            'GroupPolicy' {
                $message = & gpresult.exe /SCOPE COMPUTER /H (Join-Path $OutputDirectory 'gpresult-computer.html') 2>&1
                if ($LASTEXITCODE -ne 0) { throw ($message | Out-String) }
                Add-Result $category 'Computer' 'Collected' ''
            }
            'AgentLogs' {
                if ($LogDirectories.Count -eq 0) { Add-Result $category 'Configuration' 'Skipped' 'Aucun dossier de logs configure.' }
                $index = 0
                foreach ($directory in $LogDirectories) {
                    $index++
                    $source = [Environment]::ExpandEnvironmentVariables($directory)
                    if ($source -notmatch '^[A-Za-z]:\\' -or $source -match '[*?]') {
                        Add-Result $category $directory 'Failed' 'Un chemin local absolu sans joker est requis.'
                        continue
                    }
                    try {
                        $sourceItem = Get-Item -LiteralPath $source -Force
                        if (-not $sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Dossier normal requis (pas de lien).' }
                        $base = $sourceItem.FullName.TrimEnd('\')
                        $destination = Join-Path $OutputDirectory ('AgentLogs-{0}' -f $index)
                        $queue = [Collections.Generic.Queue[string]]::new()
                        $queue.Enqueue($base)
                        $count = 0
                        while ($queue.Count -gt 0) {
                            $current = $queue.Dequeue()
                            foreach ($item in Get-ChildItem -LiteralPath $current -Force) {
                                # A configured parent directory must not collect our own staging.
                                if ($item.FullName.TrimEnd('\') -eq [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')) { continue }
                                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                                    Add-Result $category $item.FullName 'Skipped' 'Lien ignore.'
                                    continue
                                }
                                if ($item.PSIsContainer) { $queue.Enqueue($item.FullName); continue }
                                if ($item.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-$EventDays)) { continue }
                                if ($item.Length -gt ($MaxFileMB * 1MB) -or ($bytesCopied + $item.Length) -gt ($MaxTotalMB * 1MB)) {
                                    Add-Result $category $item.FullName 'Skipped' 'Limite de taille atteinte.'
                                    continue
                                }
                                try {
                                    $relative = $item.FullName.Substring($base.Length + 1)
                                    $target = Join-Path $destination $relative
                                    $null = New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
                                    Copy-Item -LiteralPath $item.FullName -Destination $target
                                    $bytesCopied += $item.Length
                                    $count++
                                } catch { Add-Result $category $item.FullName 'Failed' $_.Exception.Message }
                            }
                        }
                        Add-Result $category $source 'Collected' ("{0} fichier(s) copie(s)." -f $count)
                    } catch { Add-Result $category $source 'Failed' $_.Exception.Message }
                }
            }
        }
    } catch { Add-Result $category $category 'Failed' $_.Exception.Message }
}
$manifest = [ordered]@{
    ComputerName = $env:COMPUTERNAME
    CollectedAt = [DateTimeOffset]::Now.ToString('o')
    EventDays = $EventDays
    Results = @($results.ToArray())
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'manifest.json') -Encoding UTF8
