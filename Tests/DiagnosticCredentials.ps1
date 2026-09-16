#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Modules/Horizon/HorizonProvider.psm1') -Force
$provider = Get-Module HorizonProvider
try {
    & $provider {
        function script:Import-Module { param($Name, $ErrorAction) }
        function script:Connect-HVServer {
            param($Server, $Domain, $Credential, [switch]$NotDefault, $ErrorAction)
            if ($Server -eq 'failed.invalid') { throw 'Fixture: login failed' }
            [pscustomobject]@{ Name = $Server }
        }
        function script:Disconnect-HVServer { param($Server, $Confirm, $ErrorAction) }
    }
    if ($null -ne (Get-PHDiagnosticCredential)) { throw 'Credential before connection.' }
    $secret = ConvertTo-SecureString 'Synthetic-test-only' -AsPlainText -Force
    foreach ($name in 'alice', 'DOM\alice', 'alice@example.invalid') {
        $credential = [pscredential]::new($name, $secret)
        Connect-PHHorizon -Server 'fixture.invalid' -Domain 'DOM' -Credential $credential
        $expected = if ($name -eq 'alice') { 'DOM\alice' } else { $name }
        if ((Get-PHDiagnosticCredential).UserName -ne $expected) { throw 'Incorrect WinRM identity.' }
        Disconnect-PHHorizon
        if ($null -ne (Get-PHDiagnosticCredential)) { throw 'Credential retained after disconnect.' }
        & $provider { if ($null -ne $script:DiagnosticCredential) { throw 'Credential not cleared.' } }
    }
    try { Connect-PHHorizon -Server 'failed.invalid' -Domain 'DOM' -Credential $credential }
    catch { if ($_.Exception.Message -notlike '*login failed*') { throw } }
    if ($null -ne (Get-PHDiagnosticCredential)) { throw 'Credential retained after failed login.' }
    Write-Output 'Identifiants diagnostics : domaine, UPN, déconnexion et échec de connexion : OK'
} finally { Remove-Module HorizonProvider }