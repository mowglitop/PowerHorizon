#requires -Version 7.0
[CmdletBinding()]
param([switch]$ValidateOnly)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'PowerHorizon nécessite Windows et WPF.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Lance : pwsh -NoProfile -STA -File .\App.ps1' }
Add-Type -AssemblyName PresentationFramework
Import-Module (Join-Path $PSScriptRoot 'Modules/Common/Common.psm1') -Force
$reader = [System.Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'UI/MainWindow.xaml'))
try { $script:Window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
$script:Controls = @{}
foreach ($name in @('Environment', 'CredentialsPanel', 'Server', 'Domain', 'Username', 'Password', 'Connect', 'Disconnect', 'Identity', 'MachineFilter', 'PoolFilter', 'Search', 'Machines', 'Progress', 'Status', 'Collect', 'DiagnosticHost', 'DiagnosticOptions', 'DiagnosticResult', 'DiagSystem', 'DiagNetwork', 'DiagEvents', 'DiagGroupPolicy', 'DiagAgentLogs', 'Workspace', 'LoadImages', 'PoolImages', 'ImageCount', 'ImageEmpty', 'MachineCount', 'MachineEmpty', 'DiagnoseSelected', 'PoolPrefix', 'SearchPools', 'Pools', 'PoolsEmpty', 'PoolsCount', 'ExportInventory', 'ExportResult')) {
    $script:Controls[$name] = $Window.FindName($name)
    if ($null -eq $Controls[$name]) { throw "Contrôle XAML absent : $name" }
}
$configPath = Join-Path $PSScriptRoot 'Config/environments.local.json'
if (-not (Test-Path -LiteralPath $configPath)) { $configPath = Join-Path $PSScriptRoot 'Config/environments.json' }
$environments = @(Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json)
if ($environments.Count -eq 0) { throw 'Ajoute au moins un environnement dans la configuration.' }
$Controls.Environment.ItemsSource = $environments
$Controls.Environment.Add_SelectionChanged({
    $entry = $Controls.Environment.SelectedItem
    $Controls.Server.Text = $entry.Server
    $Controls.Domain.Text = $entry.Domain
})
$Controls.Environment.SelectedIndex = 0


$script:Connected = $false
$script:Pending = $null
$script:CloseRequested = $false
$script:AllowClose = $false
$script:LogDirectory = Join-Path $PSScriptRoot 'Logs'
$script:ProviderPath = Join-Path $PSScriptRoot 'Modules/Horizon/HorizonProvider.psm1'
$script:RemotePath = Join-Path $PSScriptRoot 'Modules/RemoteVDI/RemoteVDI.psm1'
$script:DiagnosticSettings = Join-Path $PSScriptRoot 'Config/diagnostics.local.json'
if (-not (Test-Path -LiteralPath $DiagnosticSettings)) { $script:DiagnosticSettings = Join-Path $PSScriptRoot 'Config/diagnostics.json' }
$script:ExportDirectory = Join-Path $PSScriptRoot 'Exports'
$script:Worker = [runspacefactory]::CreateRunspace()
$Worker.ApartmentState = 'MTA'
$Worker.ThreadOptions = 'ReuseThread'
$Worker.Open()

function Update-PHControls {
    $idle = $null -eq $script:Pending -and -not $script:CloseRequested
    $Controls.Connect.IsEnabled = $idle -and -not $script:Connected
    $Controls.Disconnect.IsEnabled = $idle -and $script:Connected
    $Controls.Search.IsEnabled = $idle -and $script:Connected
    $Controls.LoadImages.IsEnabled = $idle -and $script:Connected
    $Controls.SearchPools.IsEnabled = $idle -and $script:Connected
    $Controls.ExportInventory.IsEnabled = $idle -and $script:Connected
    $Controls.DiagnoseSelected.IsEnabled = $idle -and $Controls.Machines.SelectedItems.Count -eq 1
    $Controls.CredentialsPanel.IsEnabled = $idle -and -not $script:Connected
    $Controls.Environment.IsEnabled = $idle -and -not $script:Connected
    $Controls.Collect.IsEnabled = $idle
    $Controls.DiagnosticHost.IsEnabled = $idle
    $Controls.DiagnosticOptions.IsEnabled = $idle
    $Controls.Progress.Visibility = if ($null -eq $script:Pending) { 'Collapsed' } else { 'Visible' }
}

function Write-PHUiAction([string]$Action, [string]$Result) {
    try { Write-PHAction -Directory $LogDirectory -Action $Action -Result $Result }
    catch { Write-Warning 'Impossible dʼécrire le journal local PowerHorizon.' }
}

function Start-PHOperation([string]$Action, [hashtable]$Arguments) {
    if ($null -ne $script:Pending) { return }
    $pipeline = [powershell]::Create()
    $pipeline.Runspace = $Worker
    $null = $pipeline.AddScript({
        param($ProviderPath, $Action, $Arguments, $RemotePath)
        $ErrorActionPreference = 'Stop'
        if ($Action -eq 'Diagnostics') {
            Import-Module $RemotePath -Global
        } elseif (-not (Get-Module HorizonProvider)) { Import-Module $ProviderPath -Global }
        switch ($Action) {
            'Connect' { Connect-PHHorizon @Arguments }
            'Disconnect' { Disconnect-PHHorizon }
            'Inventory' { Get-PHMachine @Arguments }
            'PoolImages' { Get-PHPoolImage }
            'Pools' { Get-PHPoolOverview @Arguments }
            'ExportInventory' { Export-PHInventory @Arguments }
            'Diagnostics' { Export-PHDiagnostics @Arguments }
        }
    }).AddArgument($ProviderPath).AddArgument($Action).AddArgument($Arguments).AddArgument($RemotePath)
    try {
        $script:Pending = @{ Pipeline = $pipeline; Handle = $pipeline.BeginInvoke(); Action = $Action }
        Write-PHUiAction $Action 'Started'
        $Controls.Status.Text = 'Opération en cours…'
    } catch { $pipeline.Dispose(); throw }
    Update-PHControls
}

$script:Timer = [Windows.Threading.DispatcherTimer]::new()
$Timer.Interval = [TimeSpan]::FromMilliseconds(150)
$Timer.Add_Tick({
    if ($null -eq $script:Pending -or -not $script:Pending.Handle.IsCompleted) { return }
    $operation = $script:Pending
    try {
        $result = @($operation.Pipeline.EndInvoke($operation.Handle))
        if ($operation.Pipeline.HadErrors) { throw $operation.Pipeline.Streams.Error[0] }
        $actionResult = 'Succeeded'
        switch ($operation.Action) {
            'Connect' {
                $script:Connected = $true
                $Controls.Identity.Text = '{0}\{1} — {2}' -f $Controls.Domain.Text, $Controls.Username.Text, $Controls.Server.Text
                $Controls.Workspace.SelectedIndex = 1
                $Controls.MachineEmpty.Text = 'Saisissez un préfixe ou lancez une recherche sans filtre.'
                $Controls.ImageEmpty.Text = 'Cliquez sur Charger tous les pools pour retrouver leurs images.'
                $Controls.Status.Text = 'Connexion établie. Choisissez VDI ou Gold images pour consulter cet environnement.'
            }
            'Disconnect' {
                $script:Connected = $false
                $Controls.Identity.Text = 'Non connecté'
                $Controls.Machines.ItemsSource = @()
                $Controls.PoolImages.ItemsSource = @()
                $Controls.Pools.ItemsSource = @()
                $Controls.PoolsEmpty.Text = 'Connectez-vous, puis recherchez un pool.'
                $Controls.PoolsEmpty.Visibility = 'Visible'
                $Controls.PoolsCount.Text = 'Aucun pool chargé'
                $Controls.MachineEmpty.Visibility = 'Visible'
                $Controls.ImageEmpty.Visibility = 'Visible'
                $Controls.MachineEmpty.Text = 'Connectez-vous à Horizon, puis lancez une recherche.'
                $Controls.ImageEmpty.Text = 'Connectez-vous, puis chargez les pools de cet environnement.'
                $Controls.MachineCount.Text = 'Aucun inventaire chargé'
                $Controls.ImageCount.Text = 'Aucun pool chargé'
                $Controls.Status.Text = 'Session Horizon déconnectée.'
            }
            'Inventory' {
                $Controls.Machines.ItemsSource = $result
                $Controls.MachineCount.Text = '{0} VDI trouvé(s)' -f $result.Count
                $Controls.MachineEmpty.Visibility = if ($result.Count) { 'Collapsed' } else { 'Visible' }
                $Controls.MachineEmpty.Text = 'Aucun VDI ne correspond aux filtres.'
                $Controls.Status.Text = '{0} VDI trouvé(s).' -f $result.Count
            }
            'Pools' {
                $Controls.Pools.ItemsSource = $result
                $Controls.PoolsEmpty.Visibility = if ($result.Count) { 'Collapsed' } else { 'Visible' }
                $Controls.PoolsEmpty.Text = 'Aucun pool ne correspond au préfixe.'
                $Controls.PoolsCount.Text = '{0} pool(s) trouvé(s)' -f $result.Count
                $Controls.Status.Text = 'Pools chargés. Consultez les sources et les limites de chaque donnée.'
                if (@($result | Where-Object Notes).Count) { $actionResult = 'Partial' }
            }
            'ExportInventory' {
                $report = $result[0]
                $Controls.ExportResult.Text = $report.Path
                $Controls.Status.Text = '{0} VDI exporté(s), tous pools et tous états. {1} affectation(s) de pool non résolue(s).' -f $report.Count, $report.UnknownPools
                if ($report.UnknownPools) { $actionResult = 'Partial' }
            }
            'PoolImages' {
                $Controls.PoolImages.ItemsSource = $result
                $errors = @($result | Where-Object Status -EQ 'Erreur de lecture').Count
                $Controls.ImageCount.Text = '{0} pool(s) • {1} erreur(s) de lecture' -f $result.Count, $errors
                $Controls.ImageEmpty.Visibility = if ($result.Count) { 'Collapsed' } else { 'Visible' }
                $Controls.ImageEmpty.Text = 'Aucun pool accessible sur cet environnement.'
                $Controls.Status.Text = 'Images des pools chargées. Les images configurées et en attente sont affichées séparément.'
                if ($errors) { $actionResult = 'Partial' }
            }
            'Diagnostics' {
                $report = $result[0]
                $Controls.DiagnosticResult.Text = $report.Archive
                $Controls.Status.Text = 'Archive créée : {0} élément(s) indisponible(s) ou ignoré(s). Détails dans manifest.json.' -f $report.Issues
                if ($report.Issues -gt 0 -or $report.CleanupWarning) { $actionResult = 'Partial' }
                if ($report.CleanupWarning) { $Controls.DiagnosticResult.Text += "`n" + $report.CleanupWarning }
            }
        }
        Write-PHUiAction $operation.Action $actionResult
    } catch {
        $Controls.Status.Text = 'Échec : ' + $_.Exception.Message
        Write-PHUiAction $operation.Action 'Failed'
        if ($operation.Action -eq 'Pools') {
            $Controls.PoolsCount.Text = 'Recherche en échec'
            $Controls.PoolsEmpty.Text = 'Consultez le message en bas de la fenêtre.'
        }
        if ($operation.Action -eq 'ExportInventory') { $Controls.ExportResult.Text = 'Export en échec : ' + $_.Exception.Message }
        if ($operation.Action -eq 'PoolImages') {
            $Controls.ImageCount.Text = 'Chargement en échec'
            $Controls.ImageEmpty.Text = 'Impossible de charger les pools. Consultez le message en bas de la fenêtre.'
        }
        if ($operation.Action -eq 'Inventory') {
            $Controls.MachineCount.Text = 'Recherche en échec'
            $Controls.MachineEmpty.Text = 'Impossible de charger les VDI. Consultez le message en bas de la fenêtre.'
        }
        if ($operation.Action -eq 'Diagnostics') { $Controls.DiagnosticResult.Text = 'Collecte en échec. ' + $_.Exception.Message }
        # Keep the window open on cleanup failure so the user can retry.
        $script:CloseRequested = $false
    } finally {
        $operation.Pipeline.Dispose()
        $script:Pending = $null
        Update-PHControls
    }
    if ($script:CloseRequested) {
        if ($script:Connected) { Start-PHOperation 'Disconnect' @{} }
        else { $script:AllowClose = $true; $Window.Close() }
    }
})

$Controls.Connect.Add_Click({
    try {
        $server = $Controls.Server.Text.Trim()
        $domain = $Controls.Domain.Text.Trim()
        $user = $Controls.Username.Text.Trim()
        if ($server -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') { throw 'Indique un nom DNS de serveur, sans https:// ni chemin.' }
        if (-not $domain -or -not $user -or $user -match '[@\\]' -or $Controls.Password.SecurePassword.Length -eq 0) {
            throw 'Renseigne le domaine, lʼutilisateur sans domaine et le mot de passe.'
        }
        $credential = [pscredential]::new($user, $Controls.Password.SecurePassword)
        $Controls.Password.Clear()
        Start-PHOperation 'Connect' @{ Server = $server; Domain = $domain; Credential = $credential }
    } catch { $Controls.Status.Text = $_.Exception.Message }
})
$Controls.Disconnect.Add_Click({ Start-PHOperation 'Disconnect' @{} })
$Controls.Search.Add_Click({
    $Controls.MachineEmpty.Visibility = 'Visible'
    $Controls.MachineEmpty.Text = 'Recherche en cours…'
    $Controls.MachineCount.Text = 'Chargement des VDI…'
    $Controls.Machines.ItemsSource = @()
    Start-PHOperation 'Inventory' @{ MachineName = $Controls.MachineFilter.Text.Trim(); PoolName = $Controls.PoolFilter.Text.Trim() }
})
$Controls.SearchPools.Add_Click({
    $Controls.Pools.ItemsSource = @()
    $Controls.PoolsEmpty.Visibility = 'Visible'
    $Controls.PoolsEmpty.Text = 'Lecture des pools et de leur historique…'
    $Controls.PoolsCount.Text = 'Chargement…'
    Start-PHOperation 'Pools' @{ Prefix = $Controls.PoolPrefix.Text.Trim() }
})
$Controls.ExportInventory.Add_Click({
    $Controls.ExportResult.Text = 'Lecture de tous les VDI, indépendamment des filtres affichés…'
    Start-PHOperation 'ExportInventory' @{ Destination = $ExportDirectory }
})
$Controls.LoadImages.Add_Click({
    $Controls.PoolImages.ItemsSource = @()
    $Controls.ImageCount.Text = 'Chargement des pools…'
    $Controls.ImageEmpty.Text = 'Lecture des configurations Horizon…'
    $Controls.ImageEmpty.Visibility = 'Visible'
    Start-PHOperation 'PoolImages' @{}
})
$Controls.DiagnoseSelected.Add_Click({
    if ($Controls.Machines.SelectedItems.Count -ne 1) { return }
    $selected = $Controls.Machines.SelectedItem
    $Controls.DiagnosticHost.Text = if ($selected.DNS) { $selected.DNS } else { $selected.Hostname }
    $Controls.Workspace.SelectedIndex = 3
    $null = $Controls.DiagnosticHost.Focus()
})
$Controls.Machines.Add_SelectionChanged({
    Update-PHControls
    $selected = $Controls.Machines.SelectedItem
    if ($null -ne $selected -and $null -eq $script:Pending) {
        $Controls.DiagnosticHost.Text = if ($selected.DNS) { $selected.DNS } else { $selected.Hostname }
    }
})
$Controls.Collect.Add_Click({
    try {
        $target = $Controls.DiagnosticHost.Text.Trim()
        if ($target -notmatch '^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$') { throw 'Renseigne le hostname ou FQDN du VDI.' }
        $categories = @(foreach ($category in 'System', 'Network', 'Events', 'GroupPolicy', 'AgentLogs') {
            if ($Controls[('Diag' + $category)].IsChecked) { $category }
        })
        if ($categories.Count -eq 0) { throw 'Sélectionne au moins une catégorie de diagnostic.' }
        $Controls.DiagnosticResult.Text = 'Collecte en cours…'
        Start-PHOperation 'Diagnostics' @{ ComputerName = $target; Categories = $categories; SettingsPath = $DiagnosticSettings; Destination = $ExportDirectory }
    } catch { $Controls.Status.Text = $_.Exception.Message }
})
$Window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:AllowClose -or (-not $script:Connected -and $null -eq $script:Pending)) { return }
    $eventArgs.Cancel = $true
    $script:CloseRequested = $true
    if ($null -eq $script:Pending) { Start-PHOperation 'Disconnect' @{} }
    $Controls.Status.Text = 'Fermeture après la fin de lʼopération et la déconnexion Horizon…'
    Update-PHControls
})
Update-PHControls
if ($ValidateOnly) {
    $Window.Close()
    $Worker.Dispose()
    Write-Output 'Configuration, contrôles, navigation et fenêtre WPF : OK'
    return
}
$Timer.Start()
try { $null = $Window.ShowDialog() }
finally { $Timer.Stop(); $Worker.Dispose(); $Controls.Password.Clear() }



