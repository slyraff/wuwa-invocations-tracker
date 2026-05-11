#
#    Logiciel libre sous licence GNU GPL v3.0 - https://www.gnu.org/licenses/
#    Utilise par slyraf.com - https://slyraf.com/wuthering-waves/pull-tracker/
#

Add-Type -AssemblyName System.Web

$urlTrouvee   = $false
$erreurs      = ""
$dejaVerifies = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$journaux     = [System.Collections.Generic.List[PSCustomObject]]::new()
$prefErrOrig  = $ErrorActionPreference
$estAdmin     = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# -- Bannière --------------------------------------------------
Clear-Host
Write-Host ""
Write-Host "  +-------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |   Slyraf - Tracker d'Invocations WuWa    |" -ForegroundColor Cyan
Write-Host "  |          Importeur automatique            |" -ForegroundColor Cyan
Write-Host "  +-------------------------------------------+" -ForegroundColor Cyan
Write-Host ""

if ($estAdmin) {
    Write-Host "  Mode administrateur" -ForegroundColor DarkMagenta
} else {
    Write-Host "  Mode utilisateur standard" -ForegroundColor DarkMagenta
}

# -- Checklist -------------------------------------------------
Write-Host ""
Write-Host "  +---------------------------------------------+" -ForegroundColor DarkCyan
Write-Host "  |   Avant de continuer, assure-toi d'avoir :  |" -ForegroundColor DarkCyan
Write-Host "  +---------------------------------------------+" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "   [OK]  Ouvert Wuthering Waves"                  -ForegroundColor Green
Write-Host "   [OK]  Clique sur ""Convier"" dans le jeu"       -ForegroundColor Green
Write-Host "   [OK]  Ouvert l'historique d'invocations"        -ForegroundColor Green
Write-Host ""

# -- Recherche (sans délai) ------------------------------------
Write-Host "  Recherche en cours" -ForegroundColor Cyan -NoNewline
foreach ($_ in 1..10) { Write-Host "." -ForegroundColor Cyan -NoNewline; Start-Sleep -Milliseconds 200 }
Write-Host ""
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
            Write-Host ""
            Write-Host "  [!]  Les journaux du jeu sont desactives, l'import est impossible." -ForegroundColor Red
            Write-Host "     On peut corriger ca automatiquement."                            -ForegroundColor Yellow
            Write-Host ""
            $rep = Read-Host "  Corriger automatiquement ? (O/N)"
            if ($rep -notmatch '^[Oo]$') {
                Write-Host ""
                Write-Host "  Annule. Appuie sur une touche pour fermer." -ForegroundColor Red
                $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                exit
            }

            if (-not $estAdmin) {
                Write-Host ""
                Write-Host "  Des droits administrateur sont necessaires pour cette correction." -ForegroundColor Yellow
                $relance = Read-Host "  Relancer en administrateur ? (O/N)"
                if ($relance -match '^[Oo]$') {
                    $cmd = '-NoProfile -Command "iwr -UseBasicParsing -Headers @{''User-Agent''=''"Mozilla/5.0""''} https://raw.githubusercontent.com/slyraff/wuwa-invocations-tracker/main/import.ps1 | iex"'
                    Start-Process powershell.exe -ArgumentList $cmd -Verb RunAs
                    exit
                }
            }

            Copy-Item -Path $iniPath -Destination "$iniPath.backup" -Force
            $nouveauIni = $ini -replace '\[Core\.Log\][^\[]*', ''
            Set-Content -Path $iniPath -Value $nouveauIni
            Write-Host ""
            Write-Host "  [OK]  Fichier corrige !" -ForegroundColor Green
            Write-Host "     Relance le jeu, ouvre l'historique d'invocations, puis relance ce script." -ForegroundColor White
            Write-Host ""
            Write-Host "  Appuie sur une touche pour fermer." -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            exit
        }
    }

    if (Test-Path $clientLog) {
        $acl = Get-Acl -Path $clientLog
        $refus = $acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.FileSystemRights -match 'Read' }
        if ($refus) {
            Write-Host ""
            Write-Host "  [!]  Des restrictions bloquent la lecture du journal." -ForegroundColor Yellow
            $rep = Read-Host "  Supprimer ces restrictions ? (O/N)"
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
                Write-Host "  [OK]  Permissions reparees." -ForegroundColor Green
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
    if ($chemin -like "*OneDrive*")         { $erreurs += "Ignore (OneDrive) : $chemin`n"; return }
    if ($dejaVerifies.Contains($chemin))    { return }
    $dejaVerifies.Add($chemin) | Out-Null

    $df, $jf = TrouverJournauxDansDossier $chemin
    if (!$df)     { $erreurs += "Dossier absent : $chemin`n" }
    elseif (!$jf) { $erreurs += "Pas de journaux dans : $chemin`n" }
}


function ChercherDansTousLesLecteurs {
    $lecteurs = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name

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

# Registre desinstallation
try {
    $installPath = Get-ItemProperty -Path "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                                         "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" |
                   Where-Object { $_.DisplayName -like "*wuthering*" } |
                   Select-Object -ExpandProperty InstallPath
    if ($installPath) { ScannerDossier $installPath }
} catch {}

ChercherDansTousLesLecteurs


# -- Succès : URL trouvée ---------------------------------------
function AfficherSucces {
    Write-Host ""
    Write-Host "  +-------------------------------------------+" -ForegroundColor Green
    Write-Host "  |                                           |" -ForegroundColor Green
    Write-Host "  |   [OK]  Lien copie dans le presse-papiers ! |" -ForegroundColor Green
    Write-Host "  |      Tu n'as rien d'autre a faire ici.   |" -ForegroundColor Green
    Write-Host "  |                                           |" -ForegroundColor Green
    Write-Host "  +-------------------------------------------+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Etapes suivantes :" -ForegroundColor White
    Write-Host ""
    Write-Host "   1.  Retourne sur slyraf.com"              -ForegroundColor Cyan
    Write-Host "   2.  Colle le lien dans la case  (Ctrl+V)" -ForegroundColor Cyan
    Write-Host "   3.  Clique sur  Importer"                 -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Tu peux maintenant fermer cette fenetre."  -ForegroundColor DarkGray
    Write-Host ""
}


# -- Analyse des journaux trouvés ------------------------------
if ($journaux.Count -gt 0) {
    foreach ($j in ($journaux | Sort-Object Date -Descending)) {
        $url = ExtraireUrl $j
        if ($url) {
            $urlTrouvee = $true
            Set-Clipboard $url
            AfficherSucces
            break
        }
    }

    if (!$urlTrouvee) {
        Write-Host "  [!]  On a trouve ton jeu, mais pas l'historique." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  -> Retourne dans Wuthering Waves"                         -ForegroundColor White
        Write-Host "  -> Clique sur ""Convier"""                                 -ForegroundColor White
        Write-Host "  -> Ouvre n'importe quel historique de banniere"            -ForegroundColor White
        Write-Host "  -> Reviens ici et appuie sur Entree pour reessayer"        -ForegroundColor White
        Write-Host ""
        Read-Host "  Appuie sur Entree quand c'est fait"
    }
}


# -- Rien trouvé — proposer admin ------------------------------
if (!$urlTrouvee -and $journaux.Count -eq 0 -and -not $estAdmin) {
    Write-Host ""
    Write-Host "  [X]  On n'a pas reussi a trouver ton jeu automatiquement." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Raisons possibles :" -ForegroundColor White
    Write-Host "  -> Tu n'as pas encore ouvert l'historique d'invocations en jeu" -ForegroundColor DarkGray
    Write-Host "  -> Wuthering Waves est installe dans un dossier inhabituel"      -ForegroundColor DarkGray
    Write-Host ""
    $rep = Read-Host "  Relancer en administrateur ? (O/N)"
    if ($rep -match '^[Oo]$') {
        $cmd = '-NoProfile -Command "iwr -UseBasicParsing -Headers @{''User-Agent''=''"Mozilla/5.0""''} https://raw.githubusercontent.com/slyraff/wuwa-invocations-tracker/main/import.ps1 | iex"'
        Start-Process powershell.exe -ArgumentList $cmd -Verb RunAs
        exit
    }
}

$ErrorActionPreference = $prefErrOrig


# -- Saisie manuelle -------------------------------------------
while (!$urlTrouvee) {
    Write-Host ""
    Write-Host "  [X]  Toujours rien trouve, meme en administrateur." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Entre le chemin ou Wuthering Waves est installe." -ForegroundColor White
    Write-Host ""
    Write-Host "  Exemples :" -ForegroundColor DarkGray
    Write-Host "  ->  C:\Wuthering Waves\Wuthering Waves Game"                    -ForegroundColor DarkGray
    Write-Host "  ->  C:\Program Files\Epic Games\WutheringWavesj3oFh"            -ForegroundColor DarkGray
    Write-Host "  ->  D:\Steam\steamapps\common\Wuthering Waves"                  -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Si tu es bloque, visite : slyraf.com/wuthering-waves/pull-tracker/" -ForegroundColor DarkGray
    Write-Host ""

    $chemin = Read-Host "  Chemin (ou ""quitter"")"
    if (!$chemin -or $chemin.ToLower() -eq "quitter") { break }

    $df, $jf = TrouverJournauxDansDossier $chemin

    if (!$df) {
        Write-Host ""
        Write-Host "  [X]  Dossier introuvable. Verifie que le chemin est correct." -ForegroundColor Red
        continue
    }
    if (!$jf) {
        Write-Host ""
        Write-Host "  [!]  Dossier trouve, mais aucun historique dedans."          -ForegroundColor Yellow
        Write-Host "     Ouvre d'abord l'historique d'invocations dans le jeu."  -ForegroundColor White
        continue
    }

    foreach ($j in ($journaux | Sort-Object Date -Descending)) {
        $url = ExtraireUrl $j
        if ($url) {
            $urlTrouvee = $true
            Set-Clipboard $url
            AfficherSucces
            break
        }
    }

    if (!$urlTrouvee) {
        Write-Host ""
        Write-Host "  [!]  Historique trouve mais sans URL d'invocations."        -ForegroundColor Yellow
        Write-Host "     Ouvre d'abord l'historique d'invocations dans le jeu." -ForegroundColor White
    }
}
