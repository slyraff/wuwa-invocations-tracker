<#
    Logiciel libre sous licence GNU GPL v3.0 — https://www.gnu.org/licenses/
    Utilisé par slyraf.com — https://slyraf.com/wuthering-waves/pull_tracker/
#>

Add-Type -AssemblyName System.Web

$urlTrouvee   = $false
$erreurs      = ""
$dejaVerifies = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$journaux     = [System.Collections.Generic.List[PSCustomObject]]::new()
$prefErrOrig  = $ErrorActionPreference
$estAdmin     = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ""
if ($estAdmin) {
    Write-Host ">> Mode administrateur" -ForegroundColor DarkMagenta
} else {
    Write-Host ">> Mode utilisateur standard" -ForegroundColor DarkMagenta
}
Write-Host ""
Write-Host "Recherche de l'URL en cours..." -ForegroundColor Cyan
Write-Host ""

$ErrorActionPreference = "SilentlyContinue"


function TrouverJournauxDansDossier($dossier) {
    if (!(Test-Path $dossier)) { return $false, $false }

    $iniPath    = "$dossier\Client\Saved\Config\WindowsNoEditor\Engine.ini"
    $clientLog  = "$dossier\Client\Saved\Logs\Client.log"
    $debugLog   = "$dossier\Client\Binaries\Win64\ThirdParty\KrPcSdk_Global\KRSDKRes\KRSDKWebView\debug.log"

    if (Test-Path $iniPath) {
        $ini = Get-Content $iniPath -Raw
        if ($ini -match '\[Core\.Log\][\r\n]+Global=(off|none)') {
            Write-Host "ATTENTION : Les journaux sont désactivés dans Engine.ini, l'import est impossible." -ForegroundColor Red
            $rep = Read-Host "Voulez-vous qu'on corrige automatiquement ce fichier ? (O/N)"
            if ($rep -notmatch '^[Oo]$') {
                Write-Host "Annulé. Appuyez sur une touche pour quitter." -ForegroundColor Red
                $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                exit
            }

            if (-not $estAdmin) {
                $relance = Read-Host "Des droits administrateur sont nécessaires. Relancer en admin ? (O/N)"
                if ($relance -match '^[Oo]$') {
                    $cmd = '-NoProfile -Command "iwr -UseBasicParsing -Headers @{''User-Agent''=''"Mozilla/5.0""''} https://raw.githubusercontent.com/slyraff/wuwa-invocations-tracker/main/import.ps1 | iex"'
                    Start-Process powershell.exe -ArgumentList $cmd -Verb RunAs
                    exit
                }
            }

            Copy-Item -Path $iniPath -Destination "$iniPath.backup" -Force
            $nouveauIni = $ini -replace '\[Core\.Log\][^\[]*', ''
            Set-Content -Path $iniPath -Value $nouveauIni
            Write-Host "Fichier corrigé. Relancez le jeu, ouvrez l'historique d'invocations, puis relancez ce script." -ForegroundColor Green
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            exit
        }
    }

    if (Test-Path $clientLog) {
        $acl = Get-Acl -Path $clientLog
        $refus = $acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.FileSystemRights -match 'Read' }
        if ($refus) {
            Write-Warning "$($refus.Count) règle(s) de refus bloquent la lecture du journal."
            $rep = Read-Host "Supprimer ces restrictions ? (O/N)"
            if ($rep -match '^[Oo]$') {
                foreach ($r in $refus) {
                    $id = $r.IdentityReference.Value
                    try {
                        if ($id -match '^S-\d') {
                            $id = (New-Object System.Security.Principal.SecurityIdentifier($id)).Translate([System.Security.Principal.NTAccount]).Value
                        }
                    } catch {}
                    cmd.exe /c "icacls `"$clientLog`" /remove:d `"$id`" /C" | Out-Null
                }
                takeown /F "$clientLog" | Out-Null
                icacls "$clientLog" /grant Administrators:F /C | Out-Null
                Write-Host "Permissions réparées." -ForegroundColor Green
            }
        }
    }

    $trouve = $false

    foreach ($log in @(@{ chemin = $clientLog; type = 'client' }, @{ chemin = $debugLog; type = 'debug' })) {
        if (Test-Path $log.chemin) {
            $info = Get-Item $log.chemin -ErrorAction SilentlyContinue
            if ($info) {
                $trouve = $true
                $journaux.Add([PSCustomObject]@{ Chemin = $log.chemin; Type = $log.type; Date = $info.LastWriteTime })
                Write-Host "  Trouvé : $($log.chemin)" -ForegroundColor DarkGray
            }
        }
    }

    return $true, $trouve
}


function ExtraireUrl($journal) {
    if ($journal.Type -eq 'client') {
        $ligne = Select-String -Path $journal.Chemin -Pattern "https://aki-gm-resources(-oversea)?\.aki-game\.(net|com)/aki/gacha/index\.html#/record*" | Select-Object -Last 1
        if ($ligne) { return $ligne -replace '.*?(https://aki-gm-resources(-oversea)?\.aki-game\.(net|com)[^"]*).*', '$1' }
    } elseif ($journal.Type -eq 'debug') {
        $ligne = Select-String -Path $journal.Chemin -Pattern '"#url": "(https://aki-gm-resources(-oversea)?\.aki-game\.(net|com)/aki/gacha/index\.html#/record[^"]*)"' | Select-Object -Last 1
        if ($ligne) { return $ligne.Matches.Groups[1].Value }
    }
    return $null
}


function ScannerDossier($chemin) {
    if ($chemin -like "*OneDrive*")         { $erreurs += "Ignoré (OneDrive) : $chemin`n"; return }
    if ($dejaVerifies.Contains($chemin))    { return }
    $dejaVerifies.Add($chemin) | Out-Null

    $df, $jf = TrouverJournauxDansDossier $chemin
    if (!$df)     { $erreurs += "Dossier absent : $chemin`n" }
    elseif (!$jf) { $erreurs += "Pas de journaux dans : $chemin`n" }
}


function ChercherDansTousLesLecteurs {
    $lecteurs = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name
    Write-Host "Scan des lecteurs : $($lecteurs -join ', ')" -ForegroundColor Yellow

    foreach ($l in [char[]](65..90)) {
        $d = "$($l):"
        if ($l -notin $lecteurs) { continue }

        $candidates = @(
            "$d\SteamLibrary\steamapps\common\Wuthering Waves",
            "$d\SteamLibrary\steamapps\common\Wuthering Waves\Wuthering Waves Game",
            "$d\Program Files (x86)\Steam\steamapps\common\Wuthering Waves",
            "$d\Program Files (x86)\Steam\steamapps\common\Wuthering Waves\Wuthering Waves Game",
            "$d\Program Files\Steam\steamapps\common\Wuthering Waves",
            "$d\Program Files\Steam\steamapps\common\Wuthering Waves\Wuthering Waves Game",
            "$d\Steam\steamapps\common\Wuthering Waves",
            "$d\Steam\steamapps\common\Wuthering Waves\Wuthering Waves Game",
            "$d\Games\Steam\steamapps\common\Wuthering Waves",
            "$d\Games\Steam\steamapps\common\Wuthering Waves\Wuthering Waves Game",
            "$d\Program Files\Epic Games\WutheringWavesj3oFh",
            "$d\Program Files\Epic Games\WutheringWavesj3oFh\Wuthering Waves Game",
            "$d\Program Files (x86)\Epic Games\WutheringWavesj3oFh",
            "$d\Program Files (x86)\Epic Games\WutheringWavesj3oFh\Wuthering Waves Game",
            "$d\Wuthering Waves",
            "$d\Wuthering Waves\Wuthering Waves Game",
            "$d\Program Files\Wuthering Waves\Wuthering Waves Game",
            "$d\Games\Wuthering Waves",
            "$d\Games\Wuthering Waves\Wuthering Waves Game",
            "$d\Program Files (x86)\Wuthering Waves\Wuthering Waves Game"
        )

        foreach ($c in $candidates) { if (Test-Path $c) { ScannerDossier $c } }
    }
}


# Registre MUI Cache
$muiPath = "Registry::HKEY_CURRENT_USER\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"
try {
    $entrees = (Get-ItemProperty -Path $muiPath -ErrorAction SilentlyContinue).PSObject.Properties |
               Where-Object { $_.Value -like "*wuthering*" -and $_.Name -like "*client-win64-shipping.exe*" }
    foreach ($e in $entrees) { ScannerDossier ($e.Name -split '\\client\\')[0] }
} catch {}

# Pare-feu Windows
$pfPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"
try {
    $entrees = (Get-ItemProperty -Path $pfPath -ErrorAction SilentlyContinue).PSObject.Properties |
               Where-Object { $_.Value -like "*wuthering*" -and $_.Name -like "*client-win64-shipping*" }
    foreach ($e in $entrees) { ScannerDossier (($e.Value -split 'App=')[1] -split '\\client\\')[0] }
} catch {}

# Registre désinstallation
try {
    $installPath = Get-ItemProperty -Path "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                                         "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" |
                   Where-Object { $_.DisplayName -like "*wuthering*" } |
                   Select-Object -ExpandProperty InstallPath
    if ($installPath) { ScannerDossier $installPath }
} catch {}

ChercherDansTousLesLecteurs


if ($journaux.Count -gt 0) {
    Write-Host ""
    Write-Host "$($journaux.Count) journal(aux) trouvé(s). Analyse en cours..." -ForegroundColor Cyan

    foreach ($j in ($journaux | Sort-Object Date -Descending)) {
        $url = ExtraireUrl $j
        if ($url) {
            $urlTrouvee = $true
            Write-Host ""
            Write-Host "URL trouvée !" -ForegroundColor Green
            Write-Host "$url"
            Set-Clipboard $url
            Write-Host ""
            Write-Host "Lien copié dans le presse-papiers. Rendez-vous sur slyraf.com/wuthering-waves/pull_tracker/ et collez-le." -ForegroundColor Green
            break
        }
    }

    if (!$urlTrouvee) {
        Write-Host "Des journaux ont été trouvés mais ils ne contiennent pas d'URL d'invocations." -ForegroundColor Yellow
        Write-Host "Ouvrez d'abord l'historique d'invocations en jeu, puis relancez ce script." -ForegroundColor Yellow
    }
}


if (!$urlTrouvee -and $journaux.Count -eq 0 -and -not $estAdmin) {
    Write-Host ""
    Write-Host "Rien trouvé. Certains dossiers nécessitent peut-être des droits administrateur." -ForegroundColor Yellow
    $rep = Read-Host "Relancer en administrateur ? (O/N)"
    if ($rep -match '^[Oo]$') {
        $cmd = '-NoProfile -Command "iwr -UseBasicParsing -Headers @{''User-Agent''=''"Mozilla/5.0""''} https://raw.githubusercontent.com/slyraff/wuwa-invocations-tracker/main/import.ps1 | iex"'
        Start-Process powershell.exe -ArgumentList $cmd -Verb RunAs
        exit
    }
}

$ErrorActionPreference = $prefErrOrig

if (!$urlTrouvee) {
    Write-Host $erreurs -ForegroundColor Magenta
}


while (!$urlTrouvee) {
    Write-Host ""
    Write-Host "Impossible de trouver automatiquement le jeu." -ForegroundColor Red
    Write-Host "Avez-vous bien ouvert l'historique d'invocations en jeu avant de lancer ce script ?" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Si le problème persiste, visitez : https://slyraf.com/wuthering-waves/pull_tracker/"
    Write-Host ""
    Write-Host "Emplacements d'installation courants :"
    Write-Host "  C:\Wuthering Waves\Wuthering Waves Game" -ForegroundColor Yellow
    Write-Host "  C:\Program Files\Wuthering Waves\Wuthering Waves Game" -ForegroundColor Yellow
    Write-Host "  C:\Program Files\Epic Games\WutheringWavesj3oFh\Wuthering Waves Game" -ForegroundColor Yellow
    Write-Host "  C:\Steam\steamapps\common\Wuthering Waves" -ForegroundColor Yellow
    Write-Host ""

    $chemin = Read-Host "Entrez le chemin d'installation manuellement (ou 'quitter')"
    if (!$chemin -or $chemin.ToLower() -eq "quitter") { break }

    $df, $jf = TrouverJournauxDansDossier $chemin

    if (!$df) {
        Write-Host "Dossier introuvable : $chemin" -ForegroundColor Red
        continue
    }
    if (!$jf) {
        Write-Host "Dossier trouvé mais aucun journal dedans. Avez-vous ouvert l'historique d'invocations en jeu ?" -ForegroundColor Red
        continue
    }

    foreach ($j in ($journaux | Sort-Object Date -Descending)) {
        $url = ExtraireUrl $j
        if ($url) {
            $urlTrouvee = $true
            Write-Host ""
            Write-Host "URL trouvée !" -ForegroundColor Green
            Write-Host "$url"
            Set-Clipboard $url
            Write-Host ""
            Write-Host "Lien copié ! Collez-le sur slyraf.com/wuthering-waves/pull_tracker/" -ForegroundColor Green
            break
        }
    }

    if (!$urlTrouvee) {
        Write-Host "Journal trouvé mais sans URL. Ouvrez d'abord l'historique d'invocations en jeu." -ForegroundColor Red
    }
}
