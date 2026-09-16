# PowerHorizon

Outil Windows PowerShell 7 / WPF pour Horizon 8 2506 (8.16).

## Démarrer

Depuis ce dossier dans un terminal :

```powershell
pwsh -NoProfile -STA -File .\App.ps1
```

Saisir le FQDN du Connection Server, le domaine AD, le nom d’utilisateur sans domaine et le mot de passe. Le compte doit disposer des droits de consultation Horizon. Le certificat du serveur doit être reconnu par le poste ; l’application ne désactive pas sa validation.

Après connexion, cliquer sur **Rechercher**. Les deux filtres sont facultatifs et combinés : hostname « commence par » (sans distinction majuscules/minuscules) et pool exact. Par exemple, `VD57` retrouve `VD57039` et `VD57040`, sans saisir de `*`. Les caractères saisis sont traités littéralement. Le préfixe est filtré localement après récupération des machines du pool choisi, ou de l’inventaire accessible si aucun pool n’est renseigné. Un hostname vide affiche toutes ces machines. L’utilisateur affiché est celui affecté à la machine, pas une preuve de session active.

## Configuration

Copier `Config/environments.json` vers `Config/environments.local.json` pour enregistrer les noms d’environnements, serveurs et domaines. Ce fichier local est exclu de Git. Ne pas y ajouter de mot de passe. L’interface permet aussi de saisir ces valeurs directement.

Les modules `Omnissa.VimAutomation.HorizonView` et `Omnissa.Horizon.Helper` du [paquet officiel 2506](https://developer.omnissa.com/horizon-powercli/download/) doivent être disponibles dans PowerShell 7.

## Structure et état

- `App.ps1` : orchestration WPF ; appels Horizon dans un runspace persistant en arrière-plan.
- `UI/MainWindow.xaml` : interface.
- `Modules/Horizon/HorizonProvider.psm1` : connexion AD, inventaire et déconnexion.
- `Modules/Common/Common.psm1` : journal JSONL des opérations dans `Logs/`, sans mots de passe ni détails d’erreurs.
- `Tests/Smoke.ps1` : vérifications locales sans connexion à l’infrastructure.

Le mot de passe est transmis comme `PSCredential` au module Omnissa et n’est pas enregistré sur disque. La fermeture attend l’opération en cours, puis déconnecte la session ; il n’y a pas encore d’annulation ni de délai maximal applicatif des appels SDK.

Cette version couvre la connexion, l’inventaire et la collecte ZIP par hostname via WinRM. Envoi de messages aux sessions et intégration vCenter restent à développer. WinRM n’est pas nécessaire à l’inventaire et n’est pas activé par cette application.

## Collecte de diagnostics

Déplier **Collecte de diagnostics par hostname**, saisir un hostname/FQDN (ou sélectionner une ligne de l’inventaire), choisir les catégories et cliquer sur **Collecter en ZIP**. Le chemin de l’archive est affiché et copiable ; les archives sont enregistrées dans `Exports/`.

La collecte fonctionne indépendamment de Horizon : elle ne vérifie pas que la cible appartient à un pool. Elle utilise WinRM/Kerberos avec le compte Windows exécutant PowerHorizon, qui peut être différent du compte saisi pour Horizon. Le poste doit pouvoir joindre le domaine et le VDI, et le compte doit disposer des droits de remoting et de lecture des diagnostics. L’endpoint distant Windows PowerShell 5.1 suffit. Aucun ping préalable ne bloque une machine qui filtre ICMP. Aucun changement de WinRM, de pare-feu ou de TrustedHosts n’est effectué.

Catégories disponibles :

- Système : OS, mémoire, disques et services.
- Réseau : adresses, DNS et routes.
- Journaux Windows : System, Application et GroupPolicy/Operational au format EVTX, sur les trois derniers jours par défaut.
- GPO machine : rapport HTML `gpresult /SCOPE COMPUTER`, sans rapport de la session utilisateur.
- Logs agents : copie des fichiers récemment modifiés dans les dossiers configurés. Les sous-dossiers sont parcourus, les liens sont ignorés et les fichiers verrouillés sont signalés.

Copier `Config/diagnostics.json` vers `Config/diagnostics.local.json` pour régler la période (1–30 jours), les limites de copie et les dossiers de logs locaux du VDI. Aucun chemin propre à Horizon Agent, DEM, App Volumes, BeyondTrust ou Trend Micro n’est supposé : ajouter les chemins réellement utilisés par les gold images, par exemple :

```json
{
  "EventDays": 3,
  "MaxFileMB": 100,
  "MaxTotalMB": 500,
  "LogDirectories": ["C:\\MonAgent\\Logs", "%ProgramData%\\MonAutreAgent\\Logs"]
}
```

Les limites de taille concernent les fichiers des agents, pas les exports EVTX. La période des fichiers se base sur leur dernière modification, sans filtrer leur contenu. Les dossiers UNC et les jokers sont refusés. Un `manifest.json` dans le ZIP détaille les succès, absences et erreurs ; une collecte partielle produit aussi une archive, même si aucune catégorie ne réussit. Les fichiers collectés peuvent contenir des données utilisateurs et restent tels quels dans le ZIP.

Le dossier temporaire distant est nettoyé en fin de traitement. En cas d’échec du transfert ou de compression, le dossier local `.partial` peut rester disponible pour diagnostic. Les appels distants n’ont pas encore d’annulation ni de durée maximale globale ; le délai d’ouverture WinRM est de 15 secondes. La fermeture de la fenêtre attend la fin de la collecte.

Pour utiliser un compte AD distinct en ligne de commande :

```powershell
Import-Module .\Modules\RemoteVDI\RemoteVDI.psm1
Export-PHDiagnostics -ComputerName VD57039 -Categories System,Network,Events `
  -SettingsPath .\Config\diagnostics.json -Destination .\Exports -Credential (Get-Credential)
```

Références : [transfert via PSSession](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/copy-item), [export EVTX avec wevtutil](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/wevtutil).

## Vérification locale

```powershell
pwsh -NoProfile -STA -File .\Tests\Smoke.ps1
```

Ces vérifications ne remplacent pas un essai contre le Connection Server : authentification, certificat, droits et résultats d’inventaire restent à valider sur l’environnement réel.
