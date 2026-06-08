<#
    [Licence]
    Script sous licence GNU General Public License v3.0 (GPL-3.0).

    Copyright (C) 2026 Luzefiru
    Adapté pour slyraf.com par Slyraf (2026) — même licence GPL-3.0.

    Ce programme est un logiciel libre : vous pouvez le redistribuer et/ou le modifier
    selon les termes de la GNU General Public License telle que publiée par la Free
    Software Foundation, soit la version 3 de la licence, soit (à votre choix) toute
    version ultérieure. Ce programme est distribué dans l'espoir qu'il sera utile,
    mais SANS AUCUNE GARANTIE.

    Texte complet de la licence : <https://www.gnu.org/licenses/>

    [Crédits]
    - Basé sur le script d'import de WuWa Tracker (https://wuwatracker.com)
    - Créé à l'origine par @theREalpha, inspiré par astrite.gg
    - Merci à @antisocial93, @timas130, @mei.yue, @phenom, @thekiwibirdddd
    - Merci à @RabbyDevs / @kyuxu pour le décodeur XOR du Client.log
#>

Add-Type -AssemblyName System.Web
$gamePath = $null
$urlFound = $false
$logFound = $false
$folderFound = $false
$err = ""
$checkedDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$originalErrorPreference = $ErrorActionPreference
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# === Config slyraf.com ===
$SlyrafScriptUrl  = 'https://raw.githubusercontent.com/slyraff/wuwa-invocations-tracker/main/import.ps1'
$SlyrafTrackerUrl = 'https://slyraf.com/wuthering-waves/pull-tracker/'

# ============================================================
#  Palette "pro classic" : Cyan = info, Gray = neutre,
#  Green = succès, Yellow = warn, Red = erreur, DarkGray = debug.
# ============================================================

function Write-Brand {
    Write-Host ""
    Write-Host "   ____  _                       __" -ForegroundColor Cyan
    Write-Host "  / ___|| |_   _ _ __ __ _ / _|" -ForegroundColor Cyan
    Write-Host "  \___ \| | | | | '__/ _``| |_" -ForegroundColor Cyan
    Write-Host "   ___) | | |_| | | | (_| |  _|" -ForegroundColor Cyan
    Write-Host "  |____/|_|\__, |_|  \__,_|_|" -ForegroundColor Cyan
    Write-Host "           |___/" -ForegroundColor Cyan
    Write-Host "  WuWa Pull Tracker — Importateur d'historique" -ForegroundColor DarkCyan
    Write-Host "  $SlyrafTrackerUrl" -ForegroundColor DarkGray
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
}

function Write-Step  { param($m) Write-Host "[ÉTAPE] $m" -ForegroundColor Cyan }
function Write-Info  { param($m) Write-Host "[INFO]  $m" -ForegroundColor Gray }
function Write-Ok    { param($m) Write-Host "[OK]    $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Write-Err   { param($m) Write-Host "[ERREUR] $m" -ForegroundColor Red }
function Write-Debug2 { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

Write-Brand

if ($IsAdmin) {
    Write-Info "Exécution en tant qu'Administrateur."
} else {
    Write-Info "Exécution en tant qu'Utilisateur standard."
}

$ErrorActionPreference = "SilentlyContinue"

Write-Step "Recherche automatique de l'URL d'historique..."

$Script:collectedLogFiles = [System.Collections.Generic.List[PSCustomObject]]::new()

function LogCheck {
    if (!(Test-Path $args[0])) {
        $folderFound = $false
        $logFound = $false
        return $folderFound, $logFound
    }
    else {
        $folderFound = $true
    }

    $gachaLogPath  = $args[0] + '\Client\Saved\Logs\Client.log'
    $debugLogPath  = $args[0] + '\Client\Binaries\Win64\ThirdParty\KrPcSdk_Global\KRSDKRes\KRSDKWebView\debug.log'
    $engineIniPath = $args[0] + '\Client\Saved\Config\WindowsNoEditor\Engine.ini'

    if (Test-Path $engineIniPath) {
        $engineIniContent = Get-Content $engineIniPath -Raw
        if ($engineIniContent -match '\[Core\.Log\][\r\n]+Global=(off|none)') {
            Write-Err "Engine.ini désactive la journalisation. Sans ça, impossible d'extraire l'URL."
            Write-Info "Fichier concerné : $engineIniPath"
            Write-Warn2 "Procédure automatique : on backup le fichier et on retire la section [Core.Log]."
            $confirmation = Read-Host "Procéder ? (O/N)"
            if ($confirmation -notmatch '^[OoYy]$') {
                Write-Err "Import annulé. Corrige Engine.ini manuellement puis relance."
                $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                exit
            }

            if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
                Write-Warn2 "Droits administrateur requis pour modifier Engine.ini."
                $retry = Read-Host "Relancer en Administrateur ? (O/N)"
                if ($retry -match '^[OoYy]$') {
                    Write-Info "Redémarrage avec élévation..."
                    $elevatedCommand = "-NoProfile -Command `"iwr -UseBasicParsing -Headers @{'User-Agent'='Mozilla/5.0'} $SlyrafScriptUrl | iex`""
                    Start-Process powershell.exe -ArgumentList $elevatedCommand -Verb RunAs
                    exit
                }
            }

            $backupPath = $engineIniPath + ".backup"
            Copy-Item -Path $engineIniPath -Destination $backupPath -Force
            Write-Ok "Backup créé : $backupPath"

            $newContent = $engineIniContent -replace '\[Core\.Log\][^\[]*', ''
            Set-Content -Path $engineIniPath -Value $newContent
            Write-Ok "Engine.ini corrigé. Relance le jeu, ouvre l'Historique de Convocation, puis relance ce script."
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            exit
        }
    }

    # Retrait des Deny ACEs sur Client.log (Kuro en pose pour bloquer la lecture)
    if (Test-Path $gachaLogPath) {
        try {
            $acl = Get-Acl -Path $gachaLogPath
            $denyRules = $acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.FileSystemRights -match 'Read' }

            if ($denyRules) {
                Write-Warn2 "$($denyRules.Count) règle(s) DENY bloquent la lecture de Client.log."
                $confirm = Read-Host "Retirer ces règles et réparer les permissions ? (O/N)"
                if ($confirm -notmatch '^[OoYy]$') {
                    Write-Info "Étape ACL ignorée par l'utilisateur."
                }
                else {
                    foreach ($rule in $denyRules) {
                        $id = $rule.IdentityReference.Value
                        try {
                            if ($id -match '^S-\d-\d+-(\d+-){1,}\d+$') {
                                $sid = New-Object System.Security.Principal.SecurityIdentifier($id)
                                $idFriendly = $sid.Translate([System.Security.Principal.NTAccount]).Value
                            } else {
                                $idFriendly = $id
                            }
                        } catch { $idFriendly = $id }

                        Write-Info "Suppression DENY pour : $idFriendly"
                        $icaclsCmd = "icacls `"$gachaLogPath`" /remove:d `"$idFriendly`" /C"
                        cmd.exe /c $icaclsCmd | Out-Null
                    }
                    takeown /F "$gachaLogPath" | Out-Null
                    icacls "$gachaLogPath" /grant Administrators:F /C | Out-Null
                    Write-Ok "Permissions réparées."
                }
            } else {
                Write-Debug2 "Aucune règle DENY sur Client.log."
            }
        } catch {
            Write-Warn2 "Impossible d'inspecter les ACL pour ${gachaLogPath}: $_"
        }
    }

    if (Test-Path $gachaLogPath) {
        $logFound = $true
        $fileInfo = Get-Item $gachaLogPath -ErrorAction SilentlyContinue
        if ($fileInfo) {
            $Script:collectedLogFiles.Add([PSCustomObject]@{
                Path = $gachaLogPath; Type = 'client'; LastWriteTime = $fileInfo.LastWriteTime
            })
            Write-Debug2 "Client.log trouvé ($($fileInfo.LastWriteTime)) — $gachaLogPath"
        }
    }

    if (Test-Path $debugLogPath) {
        $logFound = $true
        $fileInfo = Get-Item $debugLogPath -ErrorAction SilentlyContinue
        if ($fileInfo) {
            $Script:collectedLogFiles.Add([PSCustomObject]@{
                Path = $debugLogPath; Type = 'debug'; LastWriteTime = $fileInfo.LastWriteTime
            })
            Write-Debug2 "debug.log trouvé ($($fileInfo.LastWriteTime)) — $debugLogPath"
        }
    }

    return $folderFound, $logFound
}

function GetConveneUrlFromText {
    param([string]$content)
    $urlMatches = [regex]::Matches($content, 'https://aki-gm-resources(-oversea)?\.aki-game\.(net|com)/aki/gacha/index\.html#/record[^"\s]*')
    if ($urlMatches.Count -eq 0) { return $null }
    return $urlMatches[$urlMatches.Count - 1].Value
}

function ReadSharedFileBytes {
    param([string]$path)
    $stream = $null; $memoryStream = $null
    try {
        $fileShare = [System.IO.FileShare]([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $fileShare)
        $memoryStream = [System.IO.MemoryStream]::new()
        $stream.CopyTo($memoryStream)
        return $memoryStream.ToArray()
    }
    finally {
        if ($memoryStream) { $memoryStream.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function GetSharedFileContent {
    param([string]$path)
    return [System.Text.Encoding]::UTF8.GetString((ReadSharedFileBytes $path))
}

# Décodeur XOR pour le Client.log obfusqué (Kuro, patch récent).
function GetDecryptedClientLogContent {
    param([string]$path)
    $bytes = ReadSharedFileBytes $path
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $byte = [int]$bytes[$i]
        if ((($byte -band 0x0F) % 2) -eq 1) {
            $bytes[$i] = [byte]($byte -bxor 0xA5)
        } else {
            $bytes[$i] = [byte]($byte -bxor 0xEF)
        }
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function ExtractUrlFromLog {
    param([PSCustomObject]$logFile)
    $urlToCopy = $null

    if ($logFile.Type -eq 'client') {
        try {
            $clientLogContent = GetDecryptedClientLogContent $logFile.Path
            $urlToCopy = GetConveneUrlFromText $clientLogContent
            if ([string]::IsNullOrWhiteSpace($urlToCopy)) {
                $rawClientLogContent = GetSharedFileContent $logFile.Path
                $urlToCopy = GetConveneUrlFromText $rawClientLogContent
            }
        }
        catch { Write-Warn2 "Échec lecture/décodage Client.log ($($logFile.Path)) : $_" }
    }
    elseif ($logFile.Type -eq 'debug') {
        try {
            $debugLogContent = GetSharedFileContent $logFile.Path
            $debugUrlMatches = [regex]::Matches($debugLogContent, '"#url": "(https://aki-gm-resources(-oversea)?\.aki-game\.(net|com)/aki/gacha/index\.html#/record[^"]*)"')
            if ($debugUrlMatches.Count -gt 0) {
                $urlToCopy = $debugUrlMatches[$debugUrlMatches.Count - 1].Groups[1].Value
            }
        }
        catch { Write-Warn2 "Échec lecture debug.log ($($logFile.Path)) : $_" }
    }

    return $urlToCopy
}

function SearchAllDiskLetters {
    Write-Step "Balayage des disques (A-Z)..."
    $availableDrives = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name
    Write-Info "Disques disponibles : $($availableDrives -join ', ')"

    foreach ($driveLetter in [char[]](65..90)) {
        $drive = "$($driveLetter):"
        if ($driveLetter -notin $availableDrives) { continue }

        $gamePaths = @(
            "$drive\SteamLibrary\steamapps\common\Wuthering Waves",
            "$drive\SteamLibrary\steamapps\common\Wuthering Waves\Wuthering Waves Game",
            "$drive\Program Files (x86)\Steam\steamapps\common\Wuthering Waves\Wuthering Waves Game",
            "$drive\Program Files (x86)\Steam\steamapps\common\Wuthering Waves",
            "$drive\Program Files\Steam\steamapps\common\Wuthering Waves\Wuthering Waves Game",
            "$drive\Program Files\Steam\steamapps\common\Wuthering Waves",
            "$drive\Games\Steam\steamapps\common\Wuthering Waves\Wuthering Waves Game",
            "$drive\Games\Steam\steamapps\common\Wuthering Waves",
            "$drive\Steam\steamapps\common\Wuthering Waves\Wuthering Waves Game",
            "$drive\Steam\steamapps\common\Wuthering Waves",
            "$drive\Program Files\Epic Games\WutheringWavesj3oFh",
            "$drive\Program Files\Epic Games\WutheringWavesj3oFh\Wuthering Waves Game",
            "$drive\Program Files (x86)\Epic Games\WutheringWavesj3oFh",
            "$drive\Program Files (x86)\Epic Games\WutheringWavesj3oFh\Wuthering Waves Game",
            "$drive\Wuthering Waves Game",
            "$drive\Wuthering Waves\Wuthering Waves Game",
            "$drive\Program Files\Wuthering Waves\Wuthering Waves Game",
            "$drive\Games\Wuthering Waves Game",
            "$drive\Games\Wuthering Waves\Wuthering Waves Game",
            "$drive\Program Files (x86)\Wuthering Waves\Wuthering Waves Game"
        )

        foreach ($path in $gamePaths) {
            if (!(Test-Path $path)) { continue }
            Write-Info "Dossier candidat : $path"

            if ($path -like "*OneDrive*") {
                $err += "Ignoré (OneDrive) : $($path)`n"; continue
            }
            if ($checkedDirectories.Contains($path)) {
                $err += "Déjà vérifié : $($path)`n"; continue
            }

            $checkedDirectories.Add($path) | Out-Null
            $folderFound, $logFound = LogCheck $path

            if ($logFound)       { $err += "Vérifié : $($path).`n" }
            elseif ($folderFound) { $err += "Aucun log à $path`n" }
            else                 { $err += "Aucune installation à $path`n" }
        }
    }
}

# MUI Cache
if (!$urlFound) {
    Write-Step "Lecture du MUI Cache..."
    $muiCachePath = "Registry::HKEY_CURRENT_USER\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"
    try {
        $filteredEntries = (Get-ItemProperty -Path $muiCachePath -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Value -like "*wuthering*" } | Where-Object { $_.Name -like "*client-win64-shipping.exe*" }
        if ($filteredEntries.Count -ne 0) {
            $err += "MUI Cache ($($filteredEntries.Count) entrée(s)):`n"
            foreach ($entry in $filteredEntries) {
                $gamePath = ($entry.Name -split '\\client\\')[0]
                if ($gamePath -like "*OneDrive*") { $err += "Ignoré (OneDrive) : $($gamePath)`n"; continue }
                if ($checkedDirectories.Contains($gamePath)) { $err += "Déjà vérifié : $($gamePath)`n"; continue }
                $checkedDirectories.Add($gamePath) | Out-Null
                $folderFound, $logFound = LogCheck $gamePath
                if ($logFound)       { $err += "Vérifié : $($gamePath).`n" }
                elseif ($folderFound) { $err += "Aucun log à $gamePath`n" }
                else                 { $err += "Aucune installation à $gamePath`n" }
            }
        } else {
            $err += "Aucune entrée dans MUI Cache.`n"
        }
    } catch { $err += "Erreur accès MUI Cache : $_`n" }
}

# Firewall
if (!$urlFound) {
    Write-Step "Lecture des règles Pare-feu..."
    $firewallPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"
    try {
        $filteredEntries = (Get-ItemProperty -Path $firewallPath -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Value -like "*wuthering*" } | Where-Object { $_.Name -like "*client-win64-shipping*" }
        if ($filteredEntries.Count -ne 0) {
            $err += "Pare-feu ($($filteredEntries.Count) entrée(s)):`n"
            foreach ($entry in $filteredEntries) {
                $gamePath = (($entry.Value -split 'App=')[1] -split '\\client\\')[0]
                if ($gamePath -like "*OneDrive*") { $err += "Ignoré (OneDrive) : $($gamePath)`n"; continue }
                if ($checkedDirectories.Contains($gamePath)) { $err += "Déjà vérifié : $($gamePath)`n"; continue }
                $checkedDirectories.Add($gamePath) | Out-Null
                $folderFound, $logFound = LogCheck $gamePath
                if ($logFound)       { $err += "Vérifié : $($gamePath).`n" }
                elseif ($folderFound) { $err += "Aucun log à $gamePath`n" }
                else                 { $err += "Aucune installation à $gamePath`n" }
            }
        } else {
            $err += "Aucune entrée dans le pare-feu.`n"
        }
    } catch { $err += "Erreur accès pare-feu : $_`n" }
}

# Registry Uninstall
if (!$urlFound) {
    Write-Step "Lecture du registre Désinstallation..."
    $64 = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $32 = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    try {
        $gamePath = (Get-ItemProperty -Path $32, $64 | Where-Object { $_.DisplayName -like "*wuthering*" } | Select-Object -ExpandProperty InstallPath)
        if ($gamePath) {
            if ($gamePath -like "*OneDrive*") { $err += "Ignoré (OneDrive) : $($gamePath)`n" }
            elseif ($checkedDirectories.Contains($gamePath)) { $err += "Déjà vérifié : $($gamePath)`n" }
            else {
                $checkedDirectories.Add($gamePath) | Out-Null
                $folderFound, $logFound = LogCheck $gamePath
                if ($logFound)       { $err += "Vérifié : $($gamePath).`n" }
                elseif ($folderFound) { $err += "Aucun log à $gamePath`n" }
                else                 { $err += "Aucune installation à $gamePath`n" }
            }
        } else {
            $err += "Aucune entrée pour le client natif.`n"
        }
    } catch {
        Write-Err "Accès registre impossible : $_"
        $gamePath = $null
    }
}

if (!$urlFound) { SearchAllDiskLetters }

# Sélection du log le plus récent et extraction
if (!$urlFound -and $Script:collectedLogFiles.Count -gt 0) {
    Write-Host ""
    Write-Step "$($Script:collectedLogFiles.Count) log(s) trouvé(s). Sélection du plus récent..."
    $sortedLogs = $Script:collectedLogFiles | Sort-Object LastWriteTime -Descending
    foreach ($lf in $sortedLogs) {
        Write-Debug2 "[$($lf.LastWriteTime)] $($lf.Path)"
    }

    foreach ($logFile in $sortedLogs) {
        $urlToCopy = ExtractUrlFromLog $logFile
        if (![string]::IsNullOrWhiteSpace($urlToCopy)) {
            $urlFound = $true
            Write-Host ""
            Write-Ok "URL trouvée dans $($logFile.Path)"
            Write-Host ""
            Write-Host "  $urlToCopy" -ForegroundColor White
            Write-Host ""
            Set-Clipboard $urlToCopy
            Write-Ok "Lien copié dans le presse-papier."
            Write-Info "Colle-le sur $SlyrafTrackerUrl puis clique sur Importer."
            break
        }
    }

    if (!$urlFound) {
        $logFound = $true
        $err += "Logs trouvés mais aucune URL d'historique. Ouvre l'Historique de Convocation en jeu d'abord.`n"
    }
}

if (!$urlFound -and $Script:collectedLogFiles.Count -eq 0 -and -not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Warn2 "Détection automatique échouée."
    Write-Info "Certains dossiers nécessitent des droits administrateur."
    $retry = Read-Host "Relancer en Administrateur ? (O = oui / N = saisir le chemin manuellement)"
    if ($retry -match '^[OoYy]$') {
        Write-Info "Redémarrage avec élévation..."
        $elevatedCommand = "-NoProfile -Command `"iwr -UseBasicParsing -Headers @{'User-Agent'='Mozilla/5.0'} $SlyrafScriptUrl | iex`""
        Start-Process powershell.exe -ArgumentList $elevatedCommand -Verb RunAs
        exit
    }
}

$ErrorActionPreference = $originalErrorPreference

if (!$urlFound) {
    Write-Host ""
    Write-Host "─── Détails ───" -ForegroundColor DarkGray
    Write-Host $err -ForegroundColor DarkGray
}

# Saisie manuelle
while (!$urlFound) {
    Write-Host ""
    Write-Err "Dossier d'installation introuvable ou logs manquants. As-tu ouvert l'Historique de Convocation en jeu ?"
    Write-Host ""
    Write-Host "Si tu utilises un outil tiers (mod, proxy, autre tracker), désactive-le et réessaye." -ForegroundColor DarkGray
    Write-Host "En dernier recours, réinstalle le jeu." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Pour de l'aide : $SlyrafTrackerUrl" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Info "Sinon, saisis le chemin d'installation du jeu manuellement."
    Write-Host "Emplacements courants :" -ForegroundColor DarkGray
    Write-Host "  C:\Wuthering Waves" -ForegroundColor DarkGray
    Write-Host "  C:\Wuthering Waves\Wuthering Waves Game" -ForegroundColor DarkGray
    Write-Host "  C:\Program Files\Wuthering Waves\Wuthering Waves Game" -ForegroundColor DarkGray
    Write-Host "  C:\Program Files\Epic Games\WutheringWavesj3oFh" -ForegroundColor DarkGray
    Write-Host "  C:\Steam\steamapps\common\Wuthering Waves" -ForegroundColor DarkGray
    Write-Host ""
    $path = Read-Host "Chemin (ou tape `"exit`" pour quitter)"
    if ($path) {
        if ($path.ToLower() -eq "exit") { break }
        $gamePath = $path
        Write-Host ""
        Write-Info "Chemin saisi : $($path)"
        $folderFound, $logFound = LogCheck $path
        if ($logFound -and $Script:collectedLogFiles.Count -gt 0) {
            $sortedLogs = $Script:collectedLogFiles | Sort-Object LastWriteTime -Descending
            foreach ($logFile in $sortedLogs) {
                $urlToCopy = ExtractUrlFromLog $logFile
                if (![string]::IsNullOrWhiteSpace($urlToCopy)) {
                    $urlFound = $true
                    Write-Host ""
                    Write-Ok "URL trouvée dans $($logFile.Path)"
                    Write-Host ""
                    Write-Host "  $urlToCopy" -ForegroundColor White
                    Write-Host ""
                    Set-Clipboard $urlToCopy
                    Write-Ok "Lien copié dans le presse-papier."
                    Write-Info "Colle-le sur $SlyrafTrackerUrl puis clique sur Importer."
                    break
                }
            }
            if (!$urlFound) {
                Write-Err "URL d'historique introuvable dans Client.log et debug.log. Ouvre l'Historique de Convocation en jeu d'abord."
            }
        }
        elseif ($folderFound) {
            Write-Warn2 "Aucun log trouvé dans $gamePath."
        }
        else {
            Write-Err "Dossier introuvable : $path. Vérifie le chemin ou ouvre l'Historique de Convocation."
        }
    }
    else {
        Write-Err "Chemin vide. Vérifie ton emplacement d'installation."
    }
}

Write-Host ""
Write-Host "─────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  slyraf.com — fin du script" -ForegroundColor DarkCyan
Write-Host ""
