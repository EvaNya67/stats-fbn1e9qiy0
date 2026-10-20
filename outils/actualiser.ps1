# Actualise les statistiques X et prepare les donnees du tableau de bord.
# Lance par "Ouvrir mes stats.bat" ou par la tache planifiee (-Auto).
param([switch]$Auto)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$racine = Split-Path -Parent $PSScriptRoot
$dossierDonnees = Join-Path $racine 'donnees'
if (-not (Test-Path $dossierDonnees)) { New-Item -ItemType Directory -Path $dossierDonnees | Out-Null }
$fichierConfig = Join-Path $racine 'config.txt'
$fichierHist   = Join-Path $dossierDonnees 'historique.json'
$fichierCache  = Join-Path $dossierDonnees 'x-dernier.json'
$fichierJs     = Join-Path $dossierDonnees 'donnees.js'

function Get-Epoch { [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }
function Get-Iso { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Write-Utf8([string]$chemin, [string]$texte) {
    [System.IO.File]::WriteAllText($chemin, $texte, (New-Object System.Text.UTF8Encoding($false)))
}
function Read-Utf8([string]$chemin) {
    [System.IO.File]::ReadAllText($chemin, [System.Text.Encoding]::UTF8)
}

# ---------- Lecture de la configuration ----------
$config = @{}
if (Test-Path $fichierConfig) {
    foreach ($ligne in (Read-Utf8 $fichierConfig) -split "`r?`n") {
        $l = $ligne.Trim()
        if ($l -and -not $l.StartsWith('#') -and $l.Contains('=')) {
            $i = $l.IndexOf('=')
            $config[$l.Substring(0, $i).Trim()] = $l.Substring($i + 1).Trim().Trim('"')
        }
    }
}
$token  = $config['X_BEARER_TOKEN']
$pseudo = ($config['X_PSEUDO'] + '').TrimStart('@')
$delai  = 30
if ($config['DELAI_MINUTES'] -match '^\d+$') { $delai = [int]$config['DELAI_MINUTES'] }

function Get-CodeErreur($err) {
    $code = $null
    try { $code = [int]$err.Exception.Response.StatusCode } catch { }
    switch ($code) {
        401 { return 'token_invalide' }
        402 { return 'credits' }
        403 { return 'acces' }
        404 { return 'pseudo' }
        429 { return 'limite' }
    }
    if ($null -eq $code) { return 'reseau' }
    return 'autre'
}
function Get-Detail($err) {
    $d = $err.Exception.Message
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) { $d = $err.ErrorDetails.Message }
    else { try {
        $flux = $err.Exception.Response.GetResponseStream()
        $lecteur = New-Object System.IO.StreamReader($flux)
        $corps = $lecteur.ReadToEnd()
        if ($corps) { $d = $corps }
    } catch { } }
    if ($d.Length -gt 400) { $d = $d.Substring(0, 400) }
    return $d
}


function Get-XCompte([string]$pseudo, [string]$fichierCache, [string]$fichierHist) {
    # ---------- Historique ----------
    $hist = New-Object System.Collections.ArrayList
    if (Test-Path $fichierHist) {
        try {
            $brut = (Read-Utf8 $fichierHist) | ConvertFrom-Json
            foreach ($h in $brut) { [void]$hist.Add($h) }
        } catch { }
    }

    # ---------- Cache de la derniere recuperation reussie ----------
    $cache = $null
    if (Test-Path $fichierCache) {
        try { $cache = (Read-Utf8 $fichierCache) | ConvertFrom-Json } catch { $cache = $null }
    }

    $x = $null

    if (-not $token) {
        $x = [ordered]@{ ok = $false; erreur = 'token_manquant' }
    }
    elseif (-not $pseudo) {
        $x = [ordered]@{ ok = $false; erreur = 'pseudo_manquant' }
    }
    elseif ($cache -and $cache.ok -and $cache.pseudoDemande -eq $pseudo -and (($maintenant - [int64]$cache.epoch) / 60) -lt $delai) {
        # Derniere mise a jour trop recente : on reutilise les donnees pour economiser les credits
        $x = $cache
        $x | Add-Member -NotePropertyName depuisCache -NotePropertyValue $true -Force
        $x | Add-Member -NotePropertyName delaiMinutes -NotePropertyValue $delai -Force
    }
    else {
        Write-Host "Recuperation de tes stats X pour @$pseudo ..."
        $entetes = @{ Authorization = "Bearer $token" }
        try {
            $urlProfil = 'https://api.x.com/2/users/by/username/' + [uri]::EscapeDataString($pseudo) +
                '?user.fields=public_metrics,profile_image_url,description,created_at,verified,withheld,protected'
            $rep = Invoke-RestMethod -Uri $urlProfil -Headers $entetes -Method Get
            if (-not $rep.data) {
                $x = [ordered]@{ ok = $false; erreur = 'pseudo'; detail = ($rep | ConvertTo-Json -Depth 5 -Compress) }
            }
            else {
                $u = $rep.data
                $m = $u.public_metrics
                $photo = ''
                if ($u.profile_image_url) { $photo = $u.profile_image_url -replace '_normal\.', '_400x400.' }
                $profil = [ordered]@{
                    id          = $u.id
                    nom         = $u.name
                    pseudo      = $u.username
                    photo       = $photo
                    bio         = $u.description
                    creeLe      = $u.created_at
                    certifie    = [bool]$u.verified
                    abonnes     = [int64]$m.followers_count
                    abonnements = [int64]$m.following_count
                    posts       = [int64]$m.tweet_count
                    listes      = [int64]$m.listed_count
                    likesDonnes = [int64]$m.like_count
                    medias      = [int64]$m.media_count
                    protege     = [bool]$u.protected
                    paysBloques = @($(if ($u.withheld -and $u.withheld.country_codes) { @($u.withheld.country_codes) } else { @() }))
                }

                $posts = New-Object System.Collections.ArrayList
                $avertissement = $null
                try {
                    $urlPosts = 'https://api.x.com/2/users/' + $u.id +
                        '/tweets?max_results=10&exclude=replies,retweets&tweet.fields=public_metrics,created_at,attachments,possibly_sensitive&expansions=attachments.media_keys&media.fields=type'
                    $rp = Invoke-RestMethod -Uri $urlPosts -Headers $entetes -Method Get
                    $typesMedia = @{}
                    if ($rp.includes -and $rp.includes.media) { foreach ($md in @($rp.includes.media)) { if ($md) { $typesMedia[[string]$md.media_key] = [string]$md.type } } }
                    foreach ($t in @($rp.data)) {
                        if ($null -eq $t) { continue }
                        $pm = $t.public_metrics
                        [void]$posts.Add([ordered]@{
                            id        = $t.id
                            texte     = $t.text
                            date      = $t.created_at
                            likes     = [int64]$pm.like_count
                            reposts   = [int64]$pm.retweet_count
                            reponses  = [int64]$pm.reply_count
                            citations = [int64]$pm.quote_count
                            signets   = [int64]$pm.bookmark_count
                            vues      = [int64]$pm.impression_count
                            sensible  = [bool]$t.possibly_sensitive
                            media     = $(if ($t.attachments -and $t.attachments.media_keys) { $k = @($t.attachments.media_keys)[0]; if ($typesMedia.ContainsKey([string]$k)) { $typesMedia[[string]$k] -replace 'animated_gif','gif' } else { 'photo' } } else { '' })
                        })
                    }
                } catch {
                    $avertissement = 'posts_' + (Get-CodeErreur $_)
                }

                $x = [ordered]@{
                    ok            = $true
                    epoch         = $maintenant
                    recupereLe    = Get-Iso
                    pseudoDemande = $pseudo
                    profil        = $profil
                    posts         = @($posts.ToArray())
                    avertissement = $avertissement
                }
                Write-Utf8 $fichierCache ($x | ConvertTo-Json -Depth 8)

                [void]$hist.Add([ordered]@{
                    date          = Get-Iso
                    epoch         = $maintenant
                    x_abonnes     = $profil.abonnes
                    x_abonnements = $profil.abonnements
                    x_posts       = $profil.posts
                    x_listes      = $profil.listes
                })
                while ($hist.Count -gt 5000) { $hist.RemoveAt(0) }
                Write-Utf8 $fichierHist (ConvertTo-Json -InputObject @($hist.ToArray()) -Depth 5)
                Write-Host "OK : $($profil.abonnes) abonnes, $($posts.Count) posts recents."
            }
        } catch {
            $code = Get-CodeErreur $_
            $detail = Get-Detail $_
            Write-Host "Erreur X : $code"
            if ($cache -and $cache.ok) {
                $x = $cache
                $x | Add-Member -NotePropertyName depuisCache -NotePropertyValue $true -Force
                $x | Add-Member -NotePropertyName erreurActualisation -NotePropertyValue $code -Force
                $x | Add-Member -NotePropertyName detail -NotePropertyValue $detail -Force
            } else {
                $x = [ordered]@{ ok = $false; erreur = $code; detail = $detail }
            }
        }
    }
    return @{ x = $x; hist = $hist }
}

$maintenant = Get-Epoch
$resPrincipal = Get-XCompte $pseudo $fichierCache $fichierHist
$x = $resPrincipal.x
$hist = $resPrincipal.hist

# ---------- Autres comptes X (config-x-comptes.txt) ----------
$autres = New-Object System.Collections.ArrayList
$fichierAutres = Join-Path $racine 'config-x-comptes.txt'
if ($token -and (Test-Path $fichierAutres)) {
    foreach ($ligne in (Read-Utf8 $fichierAutres) -split "`r?`n") {
        $l = $ligne.Trim().TrimStart('@')
        if (-not $l -or $l.StartsWith('#')) { continue }
        if ($l -notmatch '^[A-Za-z0-9_]{1,15}$') { continue }
        if ($l -eq $pseudo) { continue }
        $cle = $l.ToLower()
        $r = Get-XCompte $l (Join-Path $dossierDonnees "x-$cle-dernier.json") (Join-Path $dossierDonnees "historique-x-$cle.json")
        [void]$autres.Add([ordered]@{ pseudo = $l; x = $r.x; historique = @($r.hist.ToArray()) })
    }
}

# ---------- TikTok ----------
$tiktok = $null
$histTt = New-Object System.Collections.ArrayList
try { . (Join-Path $PSScriptRoot 'tiktok.ps1') }
catch { $tiktok = [ordered]@{ ok = $false; erreur = 'tt_api'; detail = $_.Exception.Message } }

# ---------- Discord ----------
$discord = $null
$histDc = New-Object System.Collections.ArrayList
try { . (Join-Path $PSScriptRoot 'discord.ps1') }
catch { $discord = [ordered]@{ ok = $false; erreur = 'dc_api'; detail = $_.Exception.Message } }

# ---------- Ecriture des donnees pour le tableau de bord ----------
$sortie = [ordered]@{
    genereLe          = Get-Iso
    epoch             = $maintenant
    x                 = $x
    xAutres           = @($autres.ToArray())
    historique        = @($hist.ToArray())
    tiktok            = $tiktok
    historiqueTiktok  = @($histTt.ToArray())
    discord           = $discord
    historiqueDiscord = @($histDc.ToArray())
}
$json = ConvertTo-Json -InputObject $sortie -Depth 10
Write-Utf8 $fichierJs ("window.STATS = " + $json + ";")
