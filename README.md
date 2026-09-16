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

Ouvrir l'onglet **Diagnostics**, saisir un hostname/FQDN (ou sélectionner une ligne de l’inventaire), choisir les catégories et cliquer sur **Collecter en ZIP**. Le chemin de l’archive est affiché et copiable ; les archives sont enregistrées dans `Exports/`.

La collecte fonctionne indépendamment de Horizon : elle ne vérifie pas que la cible appartient à un pool. Elle utilise WinRM/Kerberos avec le compte AD de la connexion Horizon active (domaine et utilisateur). Sans connexion Horizon, elle utilise le compte Windows exécutant PowerHorizon. Les identifiants restent en mémoire jusqu’à la déconnexion et ne sont pas enregistrés. Les logs locaux des agents sont transférés par Copy-Item -FromSession. Les logs DEM sur partage sont lus directement depuis PowerHorizon par SMB avec le même compte de diagnostic, sans délégation via le VDI. Le compte utilisé est affiché dans Diagnostics. Aucun repli vers un autre compte ne se produit si WinRM refuse les identifiants Horizon. Le poste doit pouvoir joindre le domaine et le VDI, et le compte doit disposer des droits de remoting et de lecture des diagnostics. L’endpoint distant Windows PowerShell 5.1 suffit. Aucun ping préalable ne bloque une machine qui filtre ICMP. Aucun changement de WinRM, de pare-feu ou de TrustedHosts n’est effectué.

Catégories disponibles :

- Système : OS, mémoire, disques et services.
- Réseau : adresses, DNS et routes.
- Journaux Windows : System, Application et GroupPolicy/Operational au format EVTX, sur les trois derniers jours par défaut.
- GPO machine : rapport HTML `gpresult /SCOPE COMPUTER`, sans rapport de la session utilisateur.
- Logs agents : copie des fichiers récemment modifiés dans les dossiers configurés. Les sous-dossiers sont parcourus, les liens sont ignorés et les fichiers verrouillés sont signalés.

Copier `Config/diagnostics.json` vers `Config/diagnostics.local.json` pour régler la période (1–30 jours), les limites de copie et les dossiers de logs locaux du VDI. Les emplacements Horizon Agent (Omnissa et VMware) et App Volumes (Omnissa et CloudVolumes) sont préremplis. Versions du déploiement : Horizon Agent 2506 / 8.16, App Volumes 2506 / 4.18-3124 et DEM 10.16.0.2292. Un fichier local existant remplace entièrement la configuration par défaut : y reporter ces chemins si nécessaire. Adapter les chemins aux gold images, par exemple :

```json
{
  "EventDays": 3,
  "MaxFileMB": 100,
  "MaxTotalMB": 500,
  "LogDirectories": ["%ProgramData%\\Omnissa\\Horizon\\logs", "%ProgramFiles%\\Omnissa\\AppVolumes\\Agent\\Logs"],
  "DEMLogDirectories": []
}
```

DEM : DEMLogDirectories accepte les chemins UNC vers un fichier (par exemple FlexEngine.log) ou un dossier. Lors de la collecte AgentLogs, PowerHorizon interroge les sessions Windows actives du VDI par WinRM (API WTS), puis remplace %USERNAME% sans distinction de casse par le nom de chaque utilisateur connecté, sans son domaine. Le compte administrateur WinRM ne sert jamais de valeur de remplacement. La configuration reste inchangée ; la résolution est refaite à chaque collecte. Les autres variables dans les chemins UNC sont refusées.

Chaque utilisateur actif est traité séparément dans DEM-1, DEM-2, etc. Le manifeste associe le compte, la session observée, le chemin résolu et le dossier du ZIP. Les sessions déconnectées sont exclues. Sans session active, les logs DEM sont ignorés avec une explication. Un échec de détection, un accès refusé ou un fichier absent est signalé sans empêcher les autres diagnostics. La session peut évoluer après cet instantané ; le fichier DEM partagé peut contenir des traces de plusieurs VDI pour le même utilisateur.

Le partage est lu depuis le poste PowerHorizon au moyen de lecteurs PowerShell temporaires, avec le compte Horizon connecté ou le compte Windows courant sans connexion Horizon. Ces lecteurs sont retirés après lecture. Les limites de taille et de période des agents sont également appliquées à DEM, avec un budget total partagé. Le poste PowerHorizon doit donc pouvoir accéder au partage SMB. Les dossiers DEM locaux fixes restent pris en charge ; les modèles %USERNAME% nécessitent un chemin UNC. Références : [sessions Windows](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/nf-wtsapi32-wtsquerysessioninformationa), [lecteurs SMB avec identifiants](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/new-psdrive).

Sources des chemins : [Horizon, changement de marque](https://techzone.omnissa.com/api/checkuseraccess?referer=%2Fsites%2Fdefault%2Ffiles%2Fassociated-content-noindex%2FPARTNER_COMMUNICATION-_REBRANDING_CHANGES_-_HORIZON_PRODUCTS_-FINALNov2024.pdf), [App Volumes](https://docs.omnissa.com/AppVolumesAdminGuide-V2512/TroubleshootingAppVolumes), [configuration DEM](https://techzone.omnissa.com/resource/dynamic-environment-manager-configuration).

Les limites de taille concernent les fichiers des agents, pas les exports EVTX. La période des fichiers se base sur leur dernière modification, sans filtrer leur contenu. Dans LogDirectories, les dossiers UNC et les jokers sont refusés ; les chemins UNC DEM doivent être placés dans DEMLogDirectories. Un `manifest.json` dans le ZIP détaille les succès, absences et erreurs ; une collecte partielle produit aussi une archive, même si aucune catégorie ne réussit. Les fichiers collectés peuvent contenir des données utilisateurs et restent tels quels dans le ZIP.

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

## Navigation et gold images

L’interface est organisée en quatre onglets : Connexion, VDI, Gold images et Diagnostics. La session Horizon et le résultat des opérations restent visibles. Après connexion, l’onglet VDI s’ouvre. Sélectionner un seul VDI puis **Diagnostiquer le VDI sélectionné** ouvre les diagnostics avec son hostname prérempli.

Dans **Gold images**, cliquer sur **Charger tous les pools** pour lire les pools accessibles au compte sur le Connection Server connecté. Une ligne indique la VM parente ou le template, le snapshot configuré, et les images/snapshots en attente déclarés par Horizon. Les streams et tags Image Management sont également affichés lorsqu’ils sont renseignés. Les pools RDS sont résolus via leur ferme ; les pools manuels restent visibles sans image de provisioning. Les erreurs de lecture individuelles sont conservées dans le tableau.

La collecte utilise uniquement Horizon et ne nécessite pas de connexion vCenter séparée. Ce relevé représente la configuration des pools, pas un audit des images effectivement utilisées par chaque VDI pendant une transition ni un inventaire de toutes les VM candidates à devenir des gold images. Il est limité au périmètre visible depuis cette connexion et ne parcourt pas automatiquement les autres pods. Les listes sont effacées à la déconnexion.

Les tests Gold images utilisent les types réels du SDK 2506 avec des données synthétiques. La validation sur l’infrastructure reste nécessaire. Tests/RenderUI.ps1 génère des captures WPF hors écran dans Exports/UI pour vérifier la présentation sans serveur.

## Pools et export complet des VDI

L’onglet **Pools** recherche les noms par préfixe littéral, sans distinction de casse. Un préfixe vide inclut tous les pools visibles depuis la connexion courante.

- **VDI présents** : machines actuellement déclarées dans le pool, tous états inclus (maintenance, erreur, etc.). Les serveurs RDS ne sont pas comptés comme des VDI ; un pool RDS peut donc afficher zéro.
- **Dernière connexion retrouvée** : dernier événement AGENT_CONNECTED ou AGENT_RECONNECTED associé au pool, parmi les événements exposés par Horizon. La base d’événements doit être configurée et accessible au compte. La vue AuditEventSummaryView ne parcourt pas les tables historiques archivées. Aucune trace ne signifie pas « jamais utilisé ».
- **Utilisateur** : compte AD résolu quand possible, sinon nom retourné par Horizon. Si les événements sont absents ou inaccessibles, la date de début de la session encore présente la plus récente sert de repli, signalé dans Détails / limites.
- **Poste client** : nom déclaré par la session correspondant à la dernière connexion historique, si elle est encore accessible. Sans historique, la session encore présente la plus récente sert de repli. Un client provenant d’une autre session n’est jamais associé à un événement historique. Si la session est terminée, le hostname peut être indisponible.
- **Gold image / snapshot** : configuration du pool ou de sa ferme RDS. Les erreurs individuelles restent visibles dans Détails / limites.

Dans **VDI**, **Exporter tous les VDI (CSV)** interroge à nouveau tous les pools et toutes les machines accessibles. Les filtres de recherche et les lignes sélectionnées sont ignorés. Le CSV horodaté dans Exports contient pool, identifiant du pool, activation, hostname, DNS, état, mode d’affectation et utilisateurs affectés aux pools DEDICATED (y compris les affectations multiples). « Persistant » correspond ici à l’affectation dédiée Horizon ; les pools flottants ne sont pas présentés comme ayant un utilisateur permanent.

Le CSV utilise le séparateur point-virgule et UTF-8 avec BOM pour Excel. Les chaînes susceptibles d’être interprétées comme des formules sont précédées d’une apostrophe. Un inventaire vide produit un fichier avec en-tête. Le périmètre est celui du compte et du pod connecté, sans parcours automatique de la fédération. Une erreur de lecture générale interrompt l’export.

Référence : [API AuditEventSummaryView](https://developer.omnissa.com/horizon-apis/view/versions/2206/vdi.infrastructure.AuditEvent.AuditEventSummaryView/) (événements courants uniquement).

