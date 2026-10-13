# Mettre à jour un serveur qui tourne

Ce guide suppose une installation faite comme décrit dans le README du dépôt :
le code dans `/opt/biodex`, l'environnement Python dans `/opt/biodex/.venv`,
deux services systemd `biodex` (l'API) et `biodex-web` (le site). Adaptez les
chemins si les vôtres diffèrent.

Rien de ce qui appartient aux joueurs n'est touché par une mise à jour : les
photos vivent sur le disque, la base est reprise telle quelle, et une
migration ne fait qu'ajouter.

## La marche à suivre

```bash
# 1. Arrêter les services. La migration lit la base ; une écriture pendant
#    l'opération se perdrait.
systemctl stop biodex biodex-web

# 2. Une copie de sûreté. Le script en fait une aussi, mais celle-ci est la
#    vôtre et vous savez où elle est.
cd /opt/biodex/backend
cp donnees/biodex.sqlite /root/biodex-avant-maj.sqlite

# 3. Poser le nouveau code par-dessus l'ancien. L'archive porte un dossier
#    `backend/` à sa racine : elle se déplie dans /opt/biodex, pas dans /opt.
cd /opt/biodex
unzip -o ~/biodex-serveur.zip

#    Vérifiez : la date doit être celle du jour.
stat -c '%y %n' /opt/biodex/backend/biodex/schema.sql

# 4. Les dépendances. Avec uv, qui n'installe pas pip dans le venv :
cd /opt/biodex/backend
uv pip install -p /opt/biodex/.venv/bin/python -r requirements.txt
#    Sans uv :
#        /opt/biodex/.venv/bin/python -m ensurepip --upgrade
#        /opt/biodex/.venv/bin/python -m pip install -r requirements.txt

# 5. Reconstruire la base sur le schéma courant, en gardant tout.
.venv/bin/python outils/base_neuve.py

# 6. Repartir.
systemctl start biodex biodex-web
```

## Ce que fait l'étape 5

Elle crée une base neuve au schéma courant, y recopie **tout** — dex, comptes,
sessions, photos, découvertes, amitiés, réactions, favoris, notifications,
fiches — puis vérifie trois choses avant de remplacer quoi que ce soit :

- les clés étrangères tiennent,
- l'intégrité SQLite est bonne,
- **le compte de lignes est identique table par table.**

Au moindre écart elle s'arrête sans rien remplacer. L'ancienne base est gardée
sous `donnees/avant-base-neuve-AAAAMMJJ-HHMMSS.sqlite` ; effacez-la quand vous
serez sûr que tout va bien.

Vous pouvez l'essayer sans risque avant de vous engager :

```bash
.venv/bin/python outils/base_neuve.py --vers /tmp/essai.sqlite
```

## Si quelque chose se passe mal

```bash
systemctl stop biodex
cd /opt/biodex/backend/donnees
mv biodex.sqlite biodex.sqlite.rate
mv avant-base-neuve-*.sqlite biodex.sqlite
rm -f biodex.sqlite-wal biodex.sqlite-shm
systemctl start biodex
```

Les fichiers `-wal` et `-shm` appartiennent à la base qu'on écarte : les
laisser à côté d'une autre la corromprait au premier démarrage.

## Venir d'une installation nommée « animalsgo »

Le projet s'appelait Animalsgo. Si votre serveur date de cette époque :

- le paquet Python est `biodex/` et non plus `animalsgo/` : l'unité systemd
  doit lancer `biodex.main:app` (ou `run.sh`, qui le fait) ;
- les variables d'environnement sont `BIODEX_*` au lieu de `ANIMALSGO_*` ;
- la base s'appelle `biodex.sqlite` par défaut. Soit vous renommez le fichier
  (`mv donnees/animalsgo.sqlite donnees/biodex.sqlite`, avec ses `-wal` et
  `-shm` s'ils existent, services arrêtés), soit vous gardez l'ancien nom
  avec `BIODEX_BASE=/chemin/animalsgo.sqlite`.

## ⚠️ La purge des photos sans espèce

Elle s'applique à toutes les photos restées sans espèce — y compris celles
détachées à la main — passé `BIODEX_JOURS_AVANT_PURGE` jours (7 par défaut),
et s'exécute **au lancement du service**. Pour garder ces photos et trancher
soi-même depuis « À trancher » :

```bash
BIODEX_JOURS_AVANT_PURGE=0 ./run.sh
```

Pour compter d'abord ce que vous perdriez :

```sql
SELECT COUNT(*) FROM captures
 WHERE case_id IS NULL AND etat NOT IN ('attente','analyse')
   AND cree_le < datetime('now', '-7 days');
```
