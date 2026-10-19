# Partie TikTok : charge par actualiser.ps1 (dot-source). Definit $tiktok et $histTt.
$fichierTtJeton = Join-Path $dossierDonnees 'tiktok-jeton.json'
$fichierTtCache = Join-Path $dossierDonnees 'tiktok-dernier.json'
$fichierTtHist  = Join-Path $dossierDonnees 'historique-tiktok.json'
$ttPort = 8765
$ttRedirect = "http://127.0.0.1:$ttPort/callback/"
$ttScopes = 'user.info.basic,user.info.profile,user.info.stats,video.list'
$ttDelai = 10

$fichierTtConfig = Join-Path $racine 'config-tiktok.txt'
if (Test-Path $fichierTtConfig) {
    foreach ($ligne in (Read-Utf8 $fichierTtConfig) -split "`r?`n") {
        $l = $ligne.Trim()
        if ($l -and -not $l.StartsWith('#') -and $l.Contains('=')) {
            $i = $l.IndexOf('=')
            $config[$l.Substring(0, $i).Trim()] = $l.Substring($i + 1).Trim().Trim('"')
        }
    }
}
$ttKey    = $config['TIKTOK_CLIENT_KEY']
$ttSecret = $config['TIKTOK_CLIENT_SECRET']

$histTt = New-Object System.Collections.ArrayList
if (Test-Path $fichierTtHist) {
    try { foreach ($h in ((Read-Utf8 $fichierTtHist) | ConvertFrom-Json)) { [void]$histTt.Add($h) } } catch { }
}
$ttCache = $null
if (Test-Path $fichierTtCache) { try { $ttCache = (Read-Utf8 $fichierTtCache) | ConvertFrom-Json } catch { } }

function Invoke-TtJson([string]$methode, [string]$url, $entetes, [string]$corps, [string]$typeCorps) {
    # Decode toujours la reponse en UTF-8 (emojis dans les titres)
    $params = @{ Uri = $url; Method = $methode; UseBasicParsing = $true }
    if ($entetes) { $params.Headers = $entetes }
    if ($corps) {
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($corps)
        $params.ContentType = $typeCorps
    }
    $r = Invoke-WebRequest @params
    $ms = New-Object System.IO.MemoryStream
    $r.RawContentStream.Position = 0
    $r.RawContentStream.CopyTo($ms)
    $texte = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    return ($texte | ConvertFrom-Json)
}
function ConvertTo-Form($table) {
    ($table.GetEnumerator() | ForEach-Object { [uri]::EscapeDataString($_.Key) + '=' + [uri]::EscapeDataString([string]$_.Value) }) -join '&'
}
function Save-TtJeton($rep) {
    $now = Get-Epoch
    $j = [ordered]@{
        access_token     = $rep.access_token
        expire           = $now + [int64]$rep.expires_in - 120
        refresh_token    = $rep.refresh_token
        refresh_expire   = $now + [int64]$rep.refresh_expires_in - 120
        open_id          = $rep.open_id
        scope            = $rep.scope
    }
    Write-Utf8 $fichierTtJeton ($j | ConvertTo-Json)
    return (($j | ConvertTo-Json) | ConvertFrom-Json)
}

function Get-TtAutorisation {
    # Ouvre la page TikTok dans le navigateur et attend le retour sur 127.0.0.1
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~'
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $octets = New-Object byte[] 64
    $rng.GetBytes($octets)
    $verifier = -join ($octets | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
    $challenge = -join ($hash | ForEach-Object { $_.ToString('x2') })
    $etat = [guid]::NewGuid().ToString('N')

    $url = 'https://www.tiktok.com/v2/auth/authorize/?client_key=' + [uri]::EscapeDataString($ttKey) +
        '&response_type=code&scope=' + [uri]::EscapeDataString($ttScopes) +
        '&redirect_uri=' + [uri]::EscapeDataString($ttRedirect) +
        '&state=' + $etat + '&code_challenge=' + $challenge + '&code_challenge_method=S256'

    $ecoute = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $ttPort)
    $ecoute.Start()
    try {
        Write-Host ''
        Write-Host 'TikTok : une page va s''ouvrir dans ton navigateur.'
        Write-Host 'Connecte-toi et clique sur Autoriser, puis reviens ici.'
        Start-Process $url
        $limite = (Get-Date).AddMinutes(4)
        $code = $null; $erreur = $null
        while ((Get-Date) -lt $limite -and -not $code -and -not $erreur) {
            if (-not $ecoute.Pending()) { Start-Sleep -Milliseconds 300; continue }
            $client = $ecoute.AcceptTcpClient()
            try {
                $flux = $client.GetStream()
                $lecteur = New-Object System.IO.StreamReader($flux, [System.Text.Encoding]::ASCII, $false, 8192, $true)
                $ligne = $lecteur.ReadLine()
                $chemin = ''
                if ($ligne -match '^GET\s+(\S+)') { $chemin = $Matches[1] }
                $params = @{}
                if ($chemin.Contains('?')) {
                    foreach ($p in $chemin.Substring($chemin.IndexOf('?') + 1).Split('&')) {
                        $kv = $p.Split('=', 2)
                        if ($kv.Count -eq 2) { $params[[uri]::UnescapeDataString($kv[0])] = [uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
                    }
                }
                $ok = $false
                if ($chemin.StartsWith('/callback')) {
                    if ($params['error']) { $erreur = $params['error'] }
                    elseif ($params['state'] -ne $etat) { $erreur = 'state' }
                    elseif ($params['code']) { $code = $params['code']; $ok = $true }
                }
                if ($ok) { $msg = 'C''est bon ! Tu peux fermer cette page et revenir a tes stats.' }
                elseif ($chemin.StartsWith('/callback')) { $msg = 'Autorisation TikTok refusee ou interrompue. Tu peux fermer cette page.' }
                else { $msg = '' }
                $html = '<!doctype html><meta charset="utf-8"><title>Mes stats</title><body style="font:18px sans-serif;background:#0b0b10;color:#eee;display:grid;place-items:center;height:100vh;margin:0"><p>' + $msg + '</p></body>'
                $corps = [System.Text.Encoding]::UTF8.GetBytes($html)
                $tete = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($corps.Length)`r`nConnection: close`r`n`r`n")
                $flux.Write($tete, 0, $tete.Length); $flux.Write($corps, 0, $corps.Length); $flux.Flush()
            } finally { $client.Close() }
        }
    } finally { $ecoute.Stop() }

    if ($erreur) { throw "autorisation:$erreur" }
    if (-not $code) { throw 'autorisation:delai' }

    $form = ConvertTo-Form ([ordered]@{
        client_key = $ttKey; client_secret = $ttSecret; code = $code
        grant_type = 'authorization_code'; redirect_uri = $ttRedirect; code_verifier = $verifier
    })
    $rep = Invoke-TtJson 'Post' 'https://open.tiktokapis.com/v2/oauth/token/' @{ 'Cache-Control' = 'no-cache' } $form 'application/x-www-form-urlencoded'
    if (-not $rep.access_token) { throw ('jeton:' + ($rep | ConvertTo-Json -Compress)) }
    return (Save-TtJeton $rep)
}

function Get-TtJetonValide {
    $j = $null
    if (Test-Path $fichierTtJeton) { try { $j = (Read-Utf8 $fichierTtJeton) | ConvertFrom-Json } catch { } }
    $now = Get-Epoch
    if ($j -and $j.access_token -and [int64]$j.expire -gt $now) { return $j }
    if ($j -and $j.refresh_token -and [int64]$j.refresh_expire -gt $now) {
        try {
            $form = ConvertTo-Form ([ordered]@{
                client_key = $ttKey; client_secret = $ttSecret
                grant_type = 'refresh_token'; refresh_token = $j.refresh_token
            })
            $rep = Invoke-TtJson 'Post' 'https://open.tiktokapis.com/v2/oauth/token/' @{ 'Cache-Control' = 'no-cache' } $form 'application/x-www-form-urlencoded'
            if ($rep.access_token) { return (Save-TtJeton $rep) }
        } catch { }
    }
    if ($Auto) { throw 'autorisation:auto' }
    return (Get-TtAutorisation)
}

$tiktok = $null
$maintenantTt = Get-Epoch
if (-not $ttKey -or -not $ttSecret) {
    $tiktok = [ordered]@{ ok = $false; erreur = 'tt_config' }
}
elseif ($ttCache -and $ttCache.ok -and (($maintenantTt - [int64]$ttCache.epoch) / 60) -lt $ttDelai) {
    $tiktok = $ttCache
    $tiktok | Add-Member -NotePropertyName depuisCache -NotePropertyValue $true -Force
}
else {
    try {
        $jeton = Get-TtJetonValide
        Write-Host 'Recuperation de tes stats TikTok ...'
        $ent = @{ Authorization = 'Bearer ' + $jeton.access_token }
        $champs = 'open_id,avatar_url,avatar_large_url,display_name,username,bio_description,is_verified,profile_deep_link,follower_count,following_count,likes_count,video_count'
        $ru = Invoke-TtJson 'Get' ('https://open.tiktokapis.com/v2/user/info/?fields=' + $champs) $ent $null $null
        if ($ru.error -and $ru.error.code -and $ru.error.code -ne 'ok') { throw ('api:' + $ru.error.code + ' ' + $ru.error.message) }
        $u = $ru.data.user
        $profilTt = [ordered]@{
            nom         = $u.display_name
            pseudo      = $u.username
            photo       = $(if ($u.avatar_large_url) { $u.avatar_large_url } else { $u.avatar_url })
            bio         = $u.bio_description
            certifie    = [bool]$u.is_verified
            lien        = $u.profile_deep_link
            abonnes     = [int64]$u.follower_count
            abonnements = [int64]$u.following_count
            likes       = [int64]$u.likes_count
            videos      = [int64]$u.video_count
        }

        $videos = New-Object System.Collections.ArrayList
        $avertTt = $null
        try {
            $champsV = 'id,title,video_description,create_time,cover_image_url,share_url,duration,view_count,like_count,comment_count,share_count'
            $rv = Invoke-TtJson 'Post' ('https://open.tiktokapis.com/v2/video/list/?fields=' + $champsV) $ent '{"max_count":20}' 'application/json; charset=UTF-8'
            if ($rv.error -and $rv.error.code -and $rv.error.code -ne 'ok') { throw ('api:' + $rv.error.code) }
            foreach ($v in @($rv.data.videos)) {
                if ($null -eq $v) { continue }
                $titre = $v.title
                if (-not $titre) { $titre = $v.video_description }
                [void]$videos.Add([ordered]@{
                    id          = [string]$v.id
                    texte       = $titre
                    date        = ([DateTimeOffset]::FromUnixTimeSeconds([int64]$v.create_time)).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
                    lien        = $v.share_url
                    image       = $v.cover_image_url
                    duree       = [int]$v.duration
                    vues        = [int64]$v.view_count
                    likes       = [int64]$v.like_count
                    commentaires = [int64]$v.comment_count
                    partages    = [int64]$v.share_count
                })
            }
        } catch { $avertTt = 'videos' }

        $tiktok = [ordered]@{
            ok            = $true
            epoch         = $maintenantTt
            recupereLe    = Get-Iso
            profil        = $profilTt
            videos        = @($videos.ToArray())
            avertissement = $avertTt
        }
        Write-Utf8 $fichierTtCache ($tiktok | ConvertTo-Json -Depth 8)
        [void]$histTt.Add([ordered]@{
            date = Get-Iso; epoch = $maintenantTt
            tt_abonnes = $profilTt.abonnes; tt_abonnements = $profilTt.abonnements
            tt_likes = $profilTt.likes; tt_videos = $profilTt.videos
        })
        while ($histTt.Count -gt 5000) { $histTt.RemoveAt(0) }
        Write-Utf8 $fichierTtHist (ConvertTo-Json -InputObject @($histTt.ToArray()) -Depth 5)
        Write-Host "OK TikTok : $($profilTt.abonnes) abonnes, $($videos.Count) videos recentes."
    } catch {
        $msg = $_.Exception.Message
        $code = 'tt_api'
        if ($msg -like 'autorisation:*') { $code = 'tt_autorisation' }
        elseif ($msg -like 'jeton:*') { $code = 'tt_jeton' }
        $detail = $msg
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) }
        Write-Host "Erreur TikTok : $code"
        if ($ttCache -and $ttCache.ok) {
            $tiktok = $ttCache
            $tiktok | Add-Member -NotePropertyName depuisCache -NotePropertyValue $true -Force
            $tiktok | Add-Member -NotePropertyName erreurActualisation -NotePropertyValue $code -Force
            $tiktok | Add-Member -NotePropertyName detail -NotePropertyValue $detail -Force
        } else {
            $tiktok = [ordered]@{ ok = $false; erreur = $code; detail = $detail }
        }
    }
}
