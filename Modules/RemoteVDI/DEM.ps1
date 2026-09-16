
function Resolve-PHDEMPath {
    param([string]$Template, $User)
    if ($User.UserName -match '[\\/:*?"<>|%]' -or $User.UserName -in '.', '..' -or [string]::IsNullOrWhiteSpace($User.UserName)) {
        throw 'Nom utilisateur invalide pour un chemin DEM.'
    }
    $resolved = [regex]::Replace($Template, '(?i)%username%', [Text.RegularExpressions.MatchEvaluator]{ param($m) [string]$User.UserName })
    if ($resolved -match '%' -or $resolved -match '[*?]' -or $resolved -match '(^|\\)\.\.(\\|$)') {
        throw 'Variable non résolue, joker ou chemin relatif dans le chemin DEM.'
    }
    $resolved
}

function Copy-PHDEMLogs {
    param($Session, [string[]]$Templates, $Settings, [string]$Staging, [pscredential]$Credential)
    $results = [Collections.Generic.List[object]]::new()
    function Add-DEMResult($Source, $Status, $Detail, $User) {
        $results.Add([pscustomobject]@{ Category='DEM'; Source=$Source; Status=$Status; Detail=$Detail; User=$User })
    }
    try {
        $scriptBlock = [scriptblock]::Create((Get-Content (Join-Path $PSScriptRoot 'Get-ActiveUsers.ps1') -Raw))
        $users = @(Invoke-Command -Session $Session -ScriptBlock $scriptBlock -ErrorAction Stop |
            Sort-Object Domain, UserName -Unique)
    } catch {
        Add-DEMResult 'Sessions Windows' 'Failed' $_.Exception.Message ''
        return $results.ToArray()
    }
    if (-not $users.Count) {
        Add-DEMResult 'Sessions Windows' 'Skipped' 'Aucun utilisateur avec une session active sur le VDI.' ''
        return $results.ToArray()
    }
    $bytes = 0L
    foreach ($file in Get-ChildItem $Staging -File -Recurse) {
        if ($file.FullName -match '[\\/]AgentLogs-\d+[\\/]') { $bytes += $file.Length }
    }
    $index = 0
    foreach ($user in $users) {
        $identity = '{0}\{1}' -f $user.Domain, $user.UserName
        foreach ($template in $Templates) {
            $index++
            $drive = $null
            $resolved = $template
            try {
                $resolved = Resolve-PHDEMPath $template $user
                if ($resolved -notmatch '^\\\\([^\\]+)\\([^\\]+)\\(.+)$') {
                    throw 'DEM : un chemin UNC vers un fichier ou dossier est requis.'
                }
                $share = '\\{0}\{1}' -f $Matches[1], $Matches[2]
                $relative = $Matches[3]
                $driveName = 'PHDEM' + [guid]::NewGuid().ToString('N')
                $options = @{ Name=$driveName; PSProvider='FileSystem'; Root=$share; ErrorAction='Stop' }
                if ($Credential) { $options.Credential = $Credential }
                $drive = New-PSDrive @options
                $source = '{0}:\{1}' -f $driveName, $relative
                $item = Get-Item -LiteralPath $source -Force -ErrorAction Stop
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lien DEM ignoré.' }
                $destination = Join-Path $Staging ('DEM-{0}' -f $index)
                $queue = [Collections.Generic.Queue[object]]::new()
                $queue.Enqueue([pscustomobject]@{ Item=$item; Path=$source; Relative=if ($item.PSIsContainer) { '' } else { $item.Name } })
                $count = 0
                while ($queue.Count) {
                    $entry = $queue.Dequeue()
                    $file = $entry.Item
                    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        Add-DEMResult $resolved 'Skipped' ('Lien ignoré : ' + $entry.Relative) $identity
                        continue
                    }
                    if ($file.PSIsContainer) {
                        foreach ($child in Get-ChildItem -LiteralPath $entry.Path -Force -ErrorAction Stop) {
                            $childRelative = if ($entry.Relative) { Join-Path $entry.Relative $child.Name } else { $child.Name }
                            $queue.Enqueue([pscustomobject]@{ Item=$child; Path=(Join-Path $entry.Path $child.Name); Relative=$childRelative })
                        }
                        continue
                    }
                    if ($file.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-$Settings.EventDays)) { continue }
                    if ($file.Length -gt $Settings.MaxFileMB * 1MB -or $bytes + $file.Length -gt $Settings.MaxTotalMB * 1MB) {
                        Add-DEMResult $resolved 'Skipped' ('Limite de taille : ' + $entry.Relative) $identity
                        continue
                    }
                    $target = Join-Path $destination $entry.Relative
                    $null = New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
                    Copy-Item -LiteralPath $entry.Path -Destination $target -ErrorAction Stop
                    $bytes += $file.Length
                    $count++
                }
                Add-DEMResult $resolved 'Collected' ("{0} fichier(s) ; session {1} ; archive DEM-{2}." -f $count, $user.SessionId, $index) $identity
            } catch { Add-DEMResult $resolved 'Failed' $_.Exception.Message $identity }
            finally { if ($drive) { Remove-PSDrive -Name $drive.Name -ErrorAction SilentlyContinue } }
        }
    }
    $results.ToArray()
}
