# Statistiques du serveur Discord, via un lien d'invitation (gratuit, sans bot).
# Appele par actualiser.ps1 (dot-source) : remplit $discord et $histDc.
$fichierCfgDc  = Join-Path $racine 'config-discord.txt'
$fichierHistDc = Join-Path $dossierDonnees 'historique-discord.json'
$fichierDc     = Join-Path $dossierDonnees 'discord-dernier.json'

$histDc = New-Object System.Collections.ArrayList
if (Test-Path $fichierHistDc) {
    try { foreach ($h in ((Read-Utf8 $fichierHistDc) | ConvertFrom-Json)) { [void]$histDc.Add($h) } } catch { }
}

$invitation = ''
if (Test-Path $fichierCfgDc) {
    foreach ($ligne in (Read-Utf8 $fichierCfgDc) -split "`r?`n") {
        $l = $ligne.Trim()
        if ($l -match '^DISCORD_INVITE\s*=\s*(.*)$') { $invitation = $Matches[1].Trim().Trim('"') }
    }
}
# Accepte le lien complet (discord.gg/xxx, discord.com/invite/xxx) ou juste le code
$codeInv = ($invitation -replace '^(https?://)?(www\.)?(discord\.gg|discord(app)?\.com/invite)/', '' -replace '[/?#].*$', '').Trim()

if (-not $codeInv) {
    $discord = [ordered]@{ ok = $false; erreur = 'dc_config' }
}
elseif ($codeInv -notmatch '^[A-Za-z0-9-]{2,40}$') {
    $discord = [ordered]@{ ok = $false; erreur = 'dc_invite'; detail = $invitation }
}
else {
    Write-Host "Recuperation des stats de ton serveur Discord ..."
    try {
        $rep = Invoke-RestMethod -Method Get -Headers @{ 'User-Agent' = 'MesStats (perso, 1.0)' } `
            -Uri ('https://discord.com/api/v10/invites/' + $codeInv + '?with_counts=true')
        $g = $rep.guild
        if (-not $g) { throw 'invitation sans serveur' }
        $icone = ''
        if ($g.icon) { $icone = 'https://cdn.discordapp.com/icons/' + $g.id + '/' + $g.icon + $(if ($g.icon -like 'a_*') { '.gif' } else { '.png' }) + '?size=256' }
        $profil = [ordered]@{
            id          = $g.id
            nom         = $g.name
            photo       = $icone
            bio         = $g.description
            abonnes     = [int64]$rep.approximate_member_count
            enLigne     = [int64]$rep.approximate_presence_count
            boosts      = [int64]$g.premium_subscription_count
            lien        = 'https://discord.gg/' + $codeInv
            expire      = $rep.expires_at
        }
        $discord = [ordered]@{ ok = $true; epoch = $maintenant; recupereLe = Get-Iso; profil = $profil }
        Write-Utf8 $fichierDc ($discord | ConvertTo-Json -Depth 6)
        [void]$histDc.Add([ordered]@{ date = Get-Iso; epoch = $maintenant; dc_membres = $profil.abonnes; dc_enligne = $profil.enLigne; dc_boosts = $profil.boosts })
        while ($histDc.Count -gt 5000) { $histDc.RemoveAt(0) }
        Write-Utf8 $fichierHistDc (ConvertTo-Json -InputObject @($histDc.ToArray()) -Depth 5)
        Write-Host "OK : $($profil.abonnes) membres, $($profil.enLigne) en ligne."
    } catch {
        $err = $_
        $c = $null; try { $c = [int]$err.Exception.Response.StatusCode } catch { }
        $code = $(if ($c -eq 404) { 'dc_invite' } elseif ($null -eq $c) { 'reseau_dc' } else { 'dc_api' })
        Write-Host "Erreur Discord : $code"
        $cache = $null
        if (Test-Path $fichierDc) { try { $cache = (Read-Utf8 $fichierDc) | ConvertFrom-Json } catch { } }
        if ($cache -and $cache.ok) {
            $discord = $cache
            $discord | Add-Member -NotePropertyName erreurActualisation -NotePropertyValue $code -Force
        } else {
            $discord = [ordered]@{ ok = $false; erreur = $code; detail = $err.Exception.Message }
        }
    }
}
