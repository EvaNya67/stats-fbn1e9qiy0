// Chiffrement pour la version en ligne.
//   node outils/coffre.js ouvrir  -> déchiffre etat.enc dans donnees/ (historique, jetons TikTok…)
//   node outils/coffre.js fermer  -> rechiffre donnees/*.json dans etat.enc (clé : CLE_COFFRE)
//   node outils/coffre.js page    -> chiffre les stats pour la page dans donnees.enc (clé : CODE_APP)
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const racine = path.join(__dirname, '..');
const dossier = path.join(racine, 'donnees');
const ITER_ETAT = 200000, ITER_PAGE = 310000;

function chiffrer(texte, secret, iter) {
  const sel = crypto.randomBytes(16), iv = crypto.randomBytes(12);
  const cle = crypto.pbkdf2Sync(secret, sel, iter, 32, 'sha256');
  const c = crypto.createCipheriv('aes-256-gcm', cle, iv);
  const donnees = Buffer.concat([c.update(texte, 'utf8'), c.final(), c.getAuthTag()]);
  return JSON.stringify({ v: 1, it: iter, sel: sel.toString('base64'), iv: iv.toString('base64'), d: donnees.toString('base64') });
}
function dechiffrer(json, secret) {
  const o = JSON.parse(json);
  const cle = crypto.pbkdf2Sync(secret, Buffer.from(o.sel, 'base64'), o.it, 32, 'sha256');
  const tout = Buffer.from(o.d, 'base64');
  const d = crypto.createDecipheriv('aes-256-gcm', cle, Buffer.from(o.iv, 'base64'));
  d.setAuthTag(tout.subarray(tout.length - 16));
  return Buffer.concat([d.update(tout.subarray(0, tout.length - 16)), d.final()]).toString('utf8');
}
const besoin = n => { const v = process.env[n]; if (!v) { console.error(`Secret manquant : ${n}`); process.exit(1); } return v; };

const mode = process.argv[2];
fs.mkdirSync(dossier, { recursive: true });
if (mode === 'ouvrir') {
  const f = path.join(racine, 'etat.enc');
  if (fs.existsSync(f)) {
    const fichiers = JSON.parse(dechiffrer(fs.readFileSync(f, 'utf8'), besoin('CLE_COFFRE')));
    for (const [nom, contenu] of Object.entries(fichiers)) fs.writeFileSync(path.join(dossier, path.basename(nom)), contenu);
    console.log(`Coffre ouvert : ${Object.keys(fichiers).length} fichiers.`);
  } else console.log('Pas encore de coffre : premier lancement.');
  // Jeton TikTok de départ, fourni une seule fois via le secret TIKTOK_REFRESH_TOKEN
  const jeton = path.join(dossier, 'tiktok-jeton.json');
  if (!fs.existsSync(jeton) && process.env.TIKTOK_REFRESH_TOKEN) {
    const now = Math.floor(Date.now() / 1000);
    fs.writeFileSync(jeton, JSON.stringify({ access_token: '', expire: 0, refresh_token: process.env.TIKTOK_REFRESH_TOKEN.trim(), refresh_expire: now + 300 * 86400 }));
    console.log('Jeton TikTok de départ installé.');
  }
} else if (mode === 'fermer') {
  const fichiers = {};
  for (const nom of fs.readdirSync(dossier)) if (nom.endsWith('.json')) fichiers[nom] = fs.readFileSync(path.join(dossier, nom), 'utf8');
  fs.writeFileSync(path.join(racine, 'etat.enc'), chiffrer(JSON.stringify(fichiers), besoin('CLE_COFFRE'), ITER_ETAT));
  console.log(`Coffre fermé : ${Object.keys(fichiers).length} fichiers.`);
} else if (mode === 'page') {
  let js = fs.readFileSync(path.join(dossier, 'donnees.js'), 'utf8').replace(/^﻿/, '').trim();
  js = js.replace(/^window\.STATS\s*=\s*/, '').replace(/;\s*$/, '');
  JSON.parse(js); // vérifie que c'est du JSON valide
  fs.writeFileSync(path.join(racine, 'donnees.enc'), chiffrer(js, besoin('CODE_APP').trim(), ITER_PAGE));
  console.log('Page chiffrée.');
} else { console.error('Mode inconnu'); process.exit(1); }
