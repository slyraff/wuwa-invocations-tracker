<#
    [Licence]
    Script sous licence GNU General Public License v3.0 (GPL-3.0).
    Copyright (C) 2026 Luzefiru. Adapte pour slyraf.com par Slyraf (2026).
    Texte complet : <https://www.gnu.org/licenses/>

    [Credits]
    - Base : script d'import WuWa Tracker (https://wuwatracker.com)
    - @theREalpha (auteur original), inspire par astrite.gg
    - @antisocial93, @timas130, @mei.yue, @phenom, @thekiwibirdddd
    - @RabbyDevs / @kyuxu : decodeur XOR du Client.log
#>

# ============================================================
#  Force UTF-8 dans la console PowerShell (sinon accents = ?)
# ============================================================
try {
    $null = chcp 65001
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
} catch {}

Add-Type -AssemblyName System.Web

# === Etat global ===
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
#  Affichage : preflxes alignes + spinner inline
# ============================================================

function Write-Brand {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor DarkCyan
    Write-Host "   ____   _                          __"                          -ForegroundColor Cyan
    Write-Host "  / ___| | |_   _  _ __  __ _   __ _/ _|"                         -ForegroundColor Cyan
    Write-Host "  \___ \ | || | | || '__|/ _``| / _``| |_"                        -ForegroundColor Cyan
    Write-Host "   ___) || || |_| || |  | (_| || (_| |  _|"                       -ForegroundColor Cyan
    Write-Host "  |____/ |_| \__, ||_|   \__,_| \__,_|_|"                         -ForegroundColor Cyan
    Write-Host "             |___/"                                               -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  WuWa Pull Tracker - Importateur d'historique"                   -ForegroundColor White
    Write-Host "  $SlyrafTrackerUrl"                                              -ForegroundColor DarkGray
    Write-Host "================================================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Info  { param($m) Write-Host "[INFO]    $m" -ForegroundColor Gray }
function Write-Ok    { param($m) Write-Host "[OK]      $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "[ATTENT]  $m" -ForegroundColor Yellow }
function Write-Err   { param($m) Write-Host "[ERREUR]  $m" -ForegroundColor Red }

# Spinner inline. Ecrit sur une seule ligne, mise a jour avec `r.
$script:SpinFrames = @('|','/','-','\')
$script:SpinIndex  = 0
$script:SpinActive = $false
$script:SpinMsg    = ''
$script:SpinWidth  = 0

function Start-Spin {
    param([string]$msg)
    $script:SpinActive = $true
    $script:SpinIndex  = 0
    $script:SpinMsg    = $msg
    $line = "[ . ]     $msg"
    $script:SpinWidth = $line.Length
    Write-Host -NoNewline "`r$line" -ForegroundColor Cyan
}

function Step-Spin {
    param([string]$sub)
    if (-not $script:SpinActive) { return }
    $frame = $script:SpinFrames[$script:SpinIndex % $script:SpinFrames.Length]
    $script:SpinIndex++
    $base = "[ $frame ]     $($script:SpinMsg)"
    if ($sub) { $base = "$base  -  $sub" }
    # Pad pour effacer les caracteres restants de l'iteration precedente
    if ($base.Length -lt $script:SpinWidth) {
        $base = $base.PadRight($script:SpinWidth)
    }
    $script:SpinWidth = $base.Length
    Write-Host -NoNewline "`r$base" -ForegroundColor Cyan
}

function Stop-Spin {
    param([string]$result = $null, [string]$tag = 'OK', [System.ConsoleColor]$color = 'Green')
    if (-not $script:SpinActive) { return }
    $script:SpinActive = $false
    $line = "[$tag]      $($script:SpinMsg)"
    if ($result) { $line = "$line  -  $result" }
    if ($line.Length -lt $script:SpinWidth) {
        $line = $line.PadRight($script:SpinWidth)
    }
    Write-Host "`r$line" -ForegroundColor $color
}

Write-Brand

if ($IsAdmin) {
    Write-Info "Execution en tant qu'Administrateur."
} else {
    Write-Info "Execution en tant qu'utilisateur standard."
}

$ErrorActionPreference = "SilentlyContinue"

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
            Stop-Spin -tag 'ERREUR' -color Red -result 'Engine.ini desactive les logs'
            Write-Err "Engine.ini contient une section qui empeche l'import."
            Write-Info "Fichier : $engineIniPath"
            Write-Warn2 "Reparation auto : backup + suppression de la section [Core.Log]."
            $confirmation = Read-Host "Proceder ? (O/N)"
            if ($confirmation -notmatch '^[OoYy]$') {
                Write-Err "Import annule. Corrige Engine.ini manuellement puis relance."
                $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                exit
            }

            if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
                Write-Warn2 "Droits admin requis pour modifier Engine.ini."
                $retry = Read-Host "Relancer en admin ? (O/N)"
                if ($retry -match '^[OoYy]$') {
                    Write-Info "Redemarrage avec elevation..."
                    $elevatedCommand = "-NoProfile -Command `"iwr -UseBasicParsing -Headers @{'User-Agent'='Mozilla/5.0'} $SlyrafScriptUrl | iex`""
                    Start-Process powershell.exe -ArgumentList $elevatedCommand -Verb RunAs
                    exit
                }
            }

            $backupPath = $engineIniPath + ".backup"
            Copy-Item -Path $engineIniPath -Destination $backupPath -Force
            Write-Ok "Backup cree : $backupPath"

            $newContent = $engineIniContent -replace '\[Core\.Log\][^\[]*', ''
            Set-Content -Path $engineIniPath -Value $newContent
            Write-Ok "Engine.ini repare. Relance le jeu, ouvre l'Historique de Convocation, puis relance ce script."
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            exit
        }
    }

    # Retrait des Deny ACEs sur Client.log
    if (Test-Path $gachaLogPath) {
        try {
            $acl = Get-Acl -Path $gachaLogPath
            $denyRules = $acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.FileSystemRights -match 'Read' }

            if ($denyRules) {
                Stop-Spin -tag 'ATTENT' -color Yellow -result "$($denyRules.Count) regle(s) DENY"
                Write-Warn2 "$($denyRules.Count) regle(s) DENY bloquent la lecture du log."
                $confirm = Read-Host "Retirer ces regles et reparer les permissions ? (O/N)"
                if ($confirm -notmatch '^[OoYy]$') {
                    Write-Info "Etape ACL ignoree."
                }
                else {
                    foreach ($rule in $denyRules) {
                        $id = $rule.IdentityReference.Value
                        try {
                            if ($id -match '^S-\d-\d+-(\d+-){1,}\d+$') {
                                $sid = New-Object System.Security.Principal.SecurityIdentifier($id)
                                $idFriendly = $sid.Translate([System.Security.Principal.NTAccount]).Value
                            } else { $idFriendly = $id }
                        } catch { $idFriendly = $id }

                        $icaclsCmd = "icacls `"$gachaLogPath`" /remove:d `"$idFriendly`" /C"
                        cmd.exe /c $icaclsCmd | Out-Null
                    }
                    takeown /F "$gachaLogPath" | Out-Null
                    icacls "$gachaLogPath" /grant Administrators:F /C | Out-Null
                    Write-Ok "Permissions reparees."
                }
                # Reprend le spinner pour la suite
                Start-Spin -msg $script:SpinMsg
            }
        } catch {
            $err += "ACL ${gachaLogPath} : $_`n"
        }
    }

    if (Test-Path $gachaLogPath) {
        $logFound = $true
        $fileInfo = Get-Item $gachaLogPath -ErrorAction SilentlyContinue
        if ($fileInfo) {
            $Script:collectedLogFiles.Add([PSCustomObject]@{
                Path = $gachaLogPath; Type = 'client'; LastWriteTime = $fileInfo.LastWriteTime
            })
            $err += "[Client.log] $($fileInfo.LastWriteTime) - $gachaLogPath`n"
        }
    }

    if (Test-Path $debugLogPath) {
        $logFound = $true
        $fileInfo = Get-Item $debugLogPath -ErrorAction SilentlyContinue
        if ($fileInfo) {
            $Script:collectedLogFiles.Add([PSCustomObject]@{
                Path = $debugLogPath; Type = 'debug'; LastWriteTime = $fileInfo.LastWriteTime
            })
            $err += "[debug.log]  $($fileInfo.LastWriteTime) - $debugLogPath`n"
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

# Decodeur XOR (patch Kuro recent).
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
        catch { $err += "Lecture Client.log : $_`n" }
    }
    elseif ($logFile.Type -eq 'debug') {
        try {
            $debugLogContent = GetSharedFileContent $logFile.Path
            $debugUrlMatches = [regex]::Matches($debugLogContent, '"#url": "(https://aki-gm-resources(-oversea)?\.aki-game\.(net|com)/aki/gacha/index\.html#/record[^"]*)"')
            if ($debugUrlMatches.Count -gt 0) {
                $urlToCopy = $debugUrlMatches[$debugUrlMatches.Count - 1].Groups[1].Value
            }
        }
        catch { $err += "Lecture debug.log : $_`n" }
    }

    return $urlToCopy
}

function SearchAllDiskLetters {
    Start-Spin -msg "Balayage des disques"
    $availableDrives = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name

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
            Step-Spin -sub "disque $drive"
            if (!(Test-Path $path)) { continue }

            if ($path -like "*OneDrive*") { $err += "Ignore (OneDrive) : $path`n"; continue }
            if ($checkedDirectories.Contains($path)) { $err += "Deja verifie : $path`n"; continue }

            $checkedDirectories.Add($path) | Out-Null
            $folderFound, $logFound = LogCheck $path

            if ($logFound)        { $err += "Verifie : $path`n" }
            elseif ($folderFound) { $err += "Aucun log : $path`n" }
            else                  { $err += "Aucune install : $path`n" }
        }
    }
    Stop-Spin -result "$($Script:collectedLogFiles.Count) log(s) trouve(s)"
}

# ============================================================
#  Phase 1 : MUI Cache
# ============================================================
if (!$urlFound) {
    Start-Spin -msg "Lecture du MUI Cache"
    $muiCachePath = "Registry::HKEY_CURRENT_USER\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"
    try {
        $filteredEntries = (Get-ItemProperty -Path $muiCachePath -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Value -like "*wuthering*" } | Where-Object { $_.Name -like "*client-win64-shipping.exe*" }
        if ($filteredEntries.Count -ne 0) {
            $err += "MUI Cache ($($filteredEntries.Count) entree(s)):`n"
            foreach ($entry in $filteredEntries) {
                Step-Spin
                $gamePath = ($entry.Name -split '\\client\\')[0]
                if ($gamePath -like "*OneDrive*") { $err += "Ignore (OneDrive) : $gamePath`n"; continue }
                if ($checkedDirectories.Contains($gamePath)) { $err += "Deja verifie : $gamePath`n"; continue }
                $checkedDirectories.Add($gamePath) | Out-Null
                $null = LogCheck $gamePath
            }
        } else {
            $err += "Aucune entree MUI Cache.`n"
        }
    } catch { $err += "Erreur MUI Cache : $_`n" }
    Stop-Spin -result "$($Script:collectedLogFiles.Count) log(s)"
}

# ============================================================
#  Phase 2 : Pare-feu
# ============================================================
if (!$urlFound) {
    Start-Spin -msg "Lecture des regles Pare-feu"
    $firewallPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"
    try {
        $filteredEntries = (Get-ItemProperty -Path $firewallPath -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Value -like "*wuthering*" } | Where-Object { $_.Name -like "*client-win64-shipping*" }
        if ($filteredEntries.Count -ne 0) {
            $err += "Pare-feu ($($filteredEntries.Count) entree(s)):`n"
            foreach ($entry in $filteredEntries) {
                Step-Spin
                $gamePath = (($entry.Value -split 'App=')[1] -split '\\client\\')[0]
                if ($gamePath -like "*OneDrive*") { $err += "Ignore (OneDrive) : $gamePath`n"; continue }
                if ($checkedDirectories.Contains($gamePath)) { $err += "Deja verifie : $gamePath`n"; continue }
                $checkedDirectories.Add($gamePath) | Out-Null
                $null = LogCheck $gamePath
            }
        } else {
            $err += "Aucune entree Pare-feu.`n"
        }
    } catch { $err += "Erreur Pare-feu : $_`n" }
    Stop-Spin -result "$($Script:collectedLogFiles.Count) log(s)"
}

# ============================================================
#  Phase 3 : Registre desinstallation
#  Fix : InstallPath peut renvoyer plusieurs valeurs -> on itere
# ============================================================
if (!$urlFound) {
    Start-Spin -msg "Lecture du registre Desinstallation"
    $reg64 = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $reg32 = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    try {
        $entries = Get-ItemProperty -Path $reg32, $reg64 -ErrorAction SilentlyContinue |
                   Where-Object { $_.DisplayName -like "*wuthering*" -and $_.InstallPath }
        if ($entries) {
            foreach ($entry in $entries) {
                Step-Spin
                $gp = [string]$entry.InstallPath
                if ([string]::IsNullOrWhiteSpace($gp)) { continue }
                if ($gp -like "*OneDrive*") { $err += "Ignore (OneDrive) : $gp`n"; continue }
                if ($checkedDirectories.Contains($gp)) { $err += "Deja verifie : $gp`n"; continue }
                $checkedDirectories.Add($gp) | Out-Null
                $null = LogCheck $gp
            }
        } else {
            $err += "Aucune entree pour le client natif.`n"
        }
    } catch {
        $err += "Erreur registre : $_`n"
    }
    Stop-Spin -result "$($Script:collectedLogFiles.Count) log(s)"
}

# ============================================================
#  Phase 4 : Balayage complet des disques (lent, spinner long)
# ============================================================
if (!$urlFound) { SearchAllDiskLetters }

# ============================================================
#  Extraction URL depuis le log le plus recent
# ============================================================
if (!$urlFound -and $Script:collectedLogFiles.Count -gt 0) {
    Start-Spin -msg "Extraction de l'URL depuis les logs"
    $sortedLogs = $Script:collectedLogFiles | Sort-Object LastWriteTime -Descending

    foreach ($logFile in $sortedLogs) {
        Step-Spin -sub ([System.IO.Path]::GetFileName($logFile.Path))
        $urlToCopy = ExtractUrlFromLog $logFile
        if (![string]::IsNullOrWhiteSpace($urlToCopy)) {
            $urlFound = $true
            Stop-Spin -result "trouve dans $([System.IO.Path]::GetFileName($logFile.Path))"

            Write-Host ""
            Write-Host "================================================================" -ForegroundColor DarkGreen
            Write-Host "  URL d'historique de convocation :" -ForegroundColor Green
            Write-Host ""
            Write-Host "  $urlToCopy" -ForegroundColor White
            Write-Host ""
            Set-Clipboard $urlToCopy
            Write-Host "  Lien copie dans le presse-papier."        -ForegroundColor Green
            Write-Host "  -> Colle-le sur $SlyrafTrackerUrl"        -ForegroundColor White
            Write-Host "     puis clique sur Importer."             -ForegroundColor White
            Write-Host "================================================================" -ForegroundColor DarkGreen
            break
        }
    }

    if (!$urlFound) {
        Stop-Spin -tag 'ECHEC' -color Yellow -result "aucune URL dans les logs"
        $logFound = $true
        $err += "Logs presents mais aucune URL. Ouvre l'Historique de Convocation en jeu d'abord.`n"
    }
}

if (!$urlFound -and $Script:collectedLogFiles.Count -eq 0 -and -not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Warn2 "Detection automatique echouee."
    Write-Info "Certains dossiers necessitent des droits administrateur."
    $retry = Read-Host "Relancer en Administrateur ? (O = oui / N = saisir le chemin manuellement)"
    if ($retry -match '^[OoYy]$') {
        Write-Info "Redemarrage avec elevation..."
        $elevatedCommand = "-NoProfile -Command `"iwr -UseBasicParsing -Headers @{'User-Agent'='Mozilla/5.0'} $SlyrafScriptUrl | iex`""
        Start-Process powershell.exe -ArgumentList $elevatedCommand -Verb RunAs
        exit
    }
}

$ErrorActionPreference = $originalErrorPreference

# ============================================================
#  En cas d'echec : dump des details pour debug
# ============================================================
if (!$urlFound) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor DarkGray
    Write-Host "  Details (pour debug)" -ForegroundColor DarkGray
    Write-Host "================================================================" -ForegroundColor DarkGray
    Write-Host $err -ForegroundColor DarkGray
}

# ============================================================
#  Saisie manuelle (dernier recours)
# ============================================================
while (!$urlFound) {
    Write-Host ""
    Write-Err "Dossier d'installation introuvable ou logs manquants."
    Write-Info "As-tu ouvert l'Historique de Convocation en jeu avant de lancer le script ?"
    Write-Host ""
    Write-Host "  Si tu utilises un outil tiers (mod, proxy, autre tracker), desactive-le." -ForegroundColor DarkGray
    Write-Host "  En dernier recours, reinstalle le jeu."                                  -ForegroundColor DarkGray
    Write-Host "  Aide : $SlyrafTrackerUrl"                                                -ForegroundColor DarkCyan
    Write-Host ""
    Write-Info "Sinon, saisis le chemin d'installation du jeu manuellement."
    Write-Host "  Emplacements courants :"                                            -ForegroundColor DarkGray
    Write-Host "    C:\Wuthering Waves"                                               -ForegroundColor DarkGray
    Write-Host "    C:\Wuthering Waves\Wuthering Waves Game"                          -ForegroundColor DarkGray
    Write-Host "    C:\Program Files\Wuthering Waves\Wuthering Waves Game"            -ForegroundColor DarkGray
    Write-Host "    C:\Program Files\Epic Games\WutheringWavesj3oFh"                  -ForegroundColor DarkGray
    Write-Host "    C:\Steam\steamapps\common\Wuthering Waves"                        -ForegroundColor DarkGray
    Write-Host ""
    $path = Read-Host "Chemin (ou tape `"exit`" pour quitter)"
    if ($path) {
        if ($path.ToLower() -eq "exit") { break }
        Write-Host ""
        Write-Info "Chemin saisi : $path"
        $folderFound, $logFound = LogCheck $path
        if ($logFound -and $Script:collectedLogFiles.Count -gt 0) {
            $sortedLogs = $Script:collectedLogFiles | Sort-Object LastWriteTime -Descending
            foreach ($logFile in $sortedLogs) {
                $urlToCopy = ExtractUrlFromLog $logFile
                if (![string]::IsNullOrWhiteSpace($urlToCopy)) {
                    $urlFound = $true
                    Write-Host ""
                    Write-Host "  URL : $urlToCopy" -ForegroundColor White
                    Write-Host ""
                    Set-Clipboard $urlToCopy
                    Write-Ok "Lien copie dans le presse-papier."
                    Write-Info "Colle-le sur $SlyrafTrackerUrl puis clique sur Importer."
                    break
                }
            }
            if (!$urlFound) {
                Write-Err "Aucune URL d'historique. Ouvre l'Historique de Convocation en jeu d'abord."
            }
        }
        elseif ($folderFound) {
            Write-Warn2 "Aucun log trouve dans $path."
        }
        else {
            Write-Err "Dossier introuvable : $path."
        }
    }
    else {
        Write-Err "Chemin vide."
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor DarkCyan
Write-Host "  slyraf.com - fin du script"                                     -ForegroundColor DarkCyan
Write-Host ""
