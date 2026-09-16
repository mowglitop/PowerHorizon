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
foreach ($name in @('Environment', 'CredentialsPanel', 'Server', 'Domain', 'Username', 'Password', 'Connect', 'Disconnect', 'Identity', 'MachineFilter', 'PoolFilter', 'Search', 'Machines', 'Progress', 'Status', 'Collect', 'DiagnosticHost', 'DiagnosticOptions', 'DiagnosticResult', 'DiagSystem', 'DiagNetwork', 'DiagEvents', 'DiagGroupPolicy', 'DiagAgentLogs')) {
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
if ($ValidateOnly) { $Window.Close(); Write-Output 'Configuration et fenêtre WPF : OK'; return }

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
                $Controls.Status.Text = 'Connexion établie. Lance une recherche pour charger les VDI.'
            }
            'Disconnect' {
                $script:Connected = $false
                $Controls.Identity.Text = 'Non connecté'
                $Controls.Machines.ItemsSource = @()
                $Controls.Status.Text = 'Session Horizon déconnectée.'
            }
            'Inventory' {
                $Controls.Machines.ItemsSource = $result
                $Controls.Status.Text = '{0} VDI trouvé(s).' -f $result.Count
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
    $Controls.Machines.ItemsSource = @()
    Start-PHOperation 'Inventory' @{ MachineName = $Controls.MachineFilter.Text.Trim(); PoolName = $Controls.PoolFilter.Text.Trim() }
})
$Controls.Machines.Add_SelectionChanged({
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
$Timer.Start()
try { $null = $Window.ShowDialog() }
finally { $Timer.Stop(); $Worker.Dispose(); $Controls.Password.Clear() }
