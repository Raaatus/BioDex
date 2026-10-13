"""
Accès SQLite.

Une connexion par fil d'exécution (SQLite interdit de partager une connexion
entre fils), gardée dans un `threading.local`. Le serveur est en WAL, donc les
lectures ne bloquent jamais les écritures — indispensable dès qu'on a le worker
d'inférence qui écrit pendant que l'API lit.
"""
import sqlite3
import threading
from collections.abc import Iterable, Iterator
from contextlib import contextmanager

from . import config

VERSION_SCHEMA = 26

_local = threading.local()
_verrou_init = threading.Lock()
_initialise = False


def _configure(cx: sqlite3.Connection) -> None:
    cx.row_factory = sqlite3.Row
    cx.execute("PRAGMA journal_mode = WAL")
    cx.execute("PRAGMA foreign_keys = ON")
    cx.execute("PRAGMA synchronous = NORMAL")
    # Sans ça, deux écritures simultanées lèvent « database is locked »
    # immédiatement au lieu d'attendre leur tour.
    cx.execute("PRAGMA busy_timeout = 10000")


def connexion() -> sqlite3.Connection:
    cx = getattr(_local, "cx", None)
    if cx is None:
        config.prepare_dossiers()
        cx = sqlite3.connect(config.BASE, timeout=10, isolation_level=None)
        _configure(cx)
        _local.cx = cx
    return cx


def ferme() -> None:
    """À appeler en fin de vie d'un fil (le worker), pas indispensable ailleurs."""
    cx = getattr(_local, "cx", None)
    if cx is not None:
        cx.close()
        _local.cx = None


@contextmanager
def transaction() -> Iterator[sqlite3.Connection]:
    """Transaction immédiate : on prend le verrou d'écriture tout de suite,
    plutôt que de découvrir le conflit au moment du COMMIT."""
    cx = connexion()
    cx.execute("BEGIN IMMEDIATE")
    try:
        yield cx
    except Exception:
        cx.execute("ROLLBACK")
        raise
    else:
        cx.execute("COMMIT")


# ------------------------------------------------------------------ raccourcis

def lit(sql: str, params: Iterable = ()) -> list[sqlite3.Row]:
    return connexion().execute(sql, params).fetchall()


def lit_un(sql: str, params: Iterable = ()) -> sqlite3.Row | None:
    return connexion().execute(sql, params).fetchone()


def valeur(sql: str, params: Iterable = (), defaut=None):
    r = lit_un(sql, params)
    return r[0] if r is not None else defaut


def ecrit(sql: str, params: Iterable = ()) -> sqlite3.Cursor:
    return connexion().execute(sql, params)


# ----------------------------------------------------------------- initialisation

def initialise() -> None:
    """Crée le schéma si besoin. Idempotent, et sûr même si plusieurs fils
    arrivent en même temps au démarrage."""
    global _initialise
    if _initialise:
        return
    with _verrou_init:
        if _initialise:
            return
        cx = connexion()
        schema = (config.RACINE / "biodex" / "schema.sql").read_text(encoding="utf-8")
        cx.executescript(schema)
        version = cx.execute("PRAGMA user_version").fetchone()[0]
        if version < VERSION_SCHEMA:
            _migre(cx, version)
            cx.execute(f"PRAGMA user_version = {VERSION_SCHEMA}")
        # Les index qui portent sur des colonnes ajoutées après coup ne peuvent
        # pas vivre dans schema.sql : il s'exécute avant les migrations, donc
        # avant que la colonne existe sur une base ancienne.
        cx.executescript(INDEX_TARDIFS)
        _initialise = True


INDEX_TARDIFS = """
CREATE INDEX IF NOT EXISTS idx_cases_regne ON cases(regne);
"""


def _migre(cx: sqlite3.Connection, depuis: int) -> None:
    """Migrations successives. `depuis` == 0 signifie base neuve : le script de
    schéma vient de tout créer, il n'y a rien à rattraper.

    Le script de schéma ne pose que des `CREATE TABLE IF NOT EXISTS` : sur une
    base déjà remplie, il ne touche pas aux tables existantes. Les colonnes
    ajoutées après coup doivent donc l'être ici, à la main.
    """
    if depuis == 0:
        return

    if depuis < 2:
        _ajoute_colonnes(cx, "captures", {
            "decoupe": "TEXT",
            "bbox": "TEXT",
            "corrigee": "INTEGER NOT NULL DEFAULT 0",
        })

    if depuis < 3:
        _ajoute_colonnes(cx, "captures", {
            "source_position": "TEXT NOT NULL DEFAULT ''",
            "source_heure": "TEXT NOT NULL DEFAULT ''",
            "lieu": "TEXT NOT NULL DEFAULT ''",
        })
        # Les captures déjà en base tenaient leur position du téléphone et leur
        # heure de l'EXIF : on l'inscrit pour ne pas les croire orphelines.
        cx.execute("""UPDATE captures SET source_position = 'appareil'
                      WHERE lat IS NOT NULL AND source_position = ''""")
        cx.execute("""UPDATE captures SET source_heure = 'exif'
                      WHERE prise_le IS NOT NULL AND source_heure = ''""")

    if depuis < 4:
        _ajoute_colonnes(cx, "cases", {"points": "INTEGER NOT NULL DEFAULT 25"})

    if depuis < 5:
        _ajoute_colonnes(cx, "utilisateurs", {"avatar": "TEXT"})

    if depuis < 7:
        _libere_visuels(cx)

    if depuis < 8:
        _ajoute_colonnes(cx, "captures", {"titre": "TEXT NOT NULL DEFAULT ''"})

    if depuis < 9:
        # Les pistes sont désormais des cases, pas des binômes latins : c'est
        # une case que le joueur choisit quand il corrige, et la connaître
        # rend la proposition cliquable au lieu d'être un simple texte.
        _ajoute_colonnes(cx, "captures_top", {"case_id": "INTEGER"})
        cx.execute("""UPDATE captures_top SET case_id = (
                          SELECT a.case_id FROM alias a WHERE a.latin = captures_top.latin)
                      WHERE case_id IS NULL""")

    if depuis < 10:
        _fige_identifiants_captures(cx)

    if depuis < 20:
        # Les deux tables sont créées par schema.sql, qui vient de s'exécuter.
        # Rien à migrer : aucun succès n'existait avant.
        pass

    if depuis < 19:
        # Les espèces que les joueurs ajoutent eux-mêmes. `actif` vaut 1 pour
        # tout l'existant : les 977 415 cases du backbone ne sont pas
        # désactivables, seules celles des joueurs le sont.
        _ajoute_colonnes(cx, "cases", {
            "ajoute_par": "INTEGER REFERENCES utilisateurs(id) ON DELETE SET NULL",
            "actif": "INTEGER NOT NULL DEFAULT 1",
        })

    if depuis < 18:
        _ajoute_colonnes(cx, "utilisateurs",
                         {"reglages_notifs": "TEXT NOT NULL DEFAULT ''"})

    if depuis < 17:
        _ajoute_colonnes(cx, "captures", {"fichier_analyse": "TEXT"})

    if depuis < 16:
        # `participants` est créée par schema.sql, qui vient de s'exécuter.
        # Rien à rattraper : aucune photo existante n'a de co-signataire, et
        # l'absence de ligne vaut « personne d'autre n'était là ».
        pass

    if depuis < 15:
        _ajoute_colonnes(cx, "fiches",
                         {"approximation": "TEXT NOT NULL DEFAULT ''"})

    if depuis < 14:
        _ajoute_colonnes(cx, "decouvertes",
                         {"cadrage": "TEXT NOT NULL DEFAULT 'auto'"})

    if depuis < 13:
        _ajoute_colonnes(cx, "cases", {"toxique": "INTEGER NOT NULL DEFAULT 0"})

    if depuis < 12:
        _ouvre_alias_aux_regnes(cx)

    if depuis < 11:
        # Le dex s'ouvre aux plantes et aux champignons. Les cases déjà en base
        # sont toutes animales : le défaut de colonne fait le travail, il n'y a
        # rien à recalculer.
        _ajoute_colonnes(cx, "cases", {"regne": "TEXT NOT NULL DEFAULT 'animal'"})
        _ajoute_colonnes(cx, "captures", {
            "regne": "TEXT NOT NULL DEFAULT 'animal'",
            "moteur": "TEXT NOT NULL DEFAULT ''",
        })
        _ajoute_colonnes(cx, "utilisateurs",
                         {"cle_plantnet": "TEXT NOT NULL DEFAULT ''"})
        cx.execute("CREATE INDEX IF NOT EXISTS idx_cases_regne ON cases(regne)")


    if depuis < 21:
        # La vitrine de profil : des photos choisies à la main. Créée par le
        # schéma pour les bases neuves ; ici pour celles qui existent déjà.
        cx.execute("""
            CREATE TABLE IF NOT EXISTS profil_vitrine (
                utilisateur INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
                capture     INTEGER NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
                rang        INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (utilisateur, capture)
            )""")
        cx.execute("CREATE INDEX IF NOT EXISTS idx_profil_vitrine "
                   "ON profil_vitrine(utilisateur, rang)")


    if depuis < 22:
        # La disposition libre du dex. Créée par le schéma pour les bases
        # neuves ; ici pour celles qui existent déjà.
        cx.execute("""
            CREATE TABLE IF NOT EXISTS dex_disposition (
                utilisateur INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
                case_id     INTEGER NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
                colonne     INTEGER NOT NULL DEFAULT 0,
                rangee      INTEGER NOT NULL DEFAULT 0,
                largeur     INTEGER NOT NULL DEFAULT 1,
                hauteur     INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY (utilisateur, case_id)
            )""")
        cx.execute("CREATE INDEX IF NOT EXISTS idx_dex_disposition "
                   "ON dex_disposition(utilisateur, rangee, colonne)")


    if depuis < 23:
        # La forme de la vignette, au même titre que sa taille : c'est le
        # joueur qui décide à quoi ressemble son dex.
        _ajoute_colonnes(cx, "dex_disposition",
                         {"forme": "TEXT NOT NULL DEFAULT 'arrondi'"})


    if depuis < 24:
        # Masquer une vignette sans la retirer du dex, et poser des cases vides
        # pour aérer une ligne. Deux besoins du même geste : mettre en forme.
        _ajoute_colonnes(cx, "dex_disposition",
                         {"masque": "INTEGER NOT NULL DEFAULT 0"})
        # Les cases vides n'ont pas d'espèce : elles ne peuvent pas vivre dans
        # une table dont la clé étrangère exige une case existante.
        cx.execute("""
            CREATE TABLE IF NOT EXISTS dex_vides (
                utilisateur INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
                rang        INTEGER NOT NULL,
                colonne     INTEGER NOT NULL DEFAULT 0,
                rangee      INTEGER NOT NULL DEFAULT 0,
                largeur     INTEGER NOT NULL DEFAULT 1,
                hauteur     INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY (utilisateur, rang)
            )""")

    if depuis < 26:
        # `photos_vues` : créée par schema.sql, qui vient de s'exécuter. Rien à
        # rattraper — une base ancienne part simplement avec tout « non vu »,
        # ce qui est la vérité.
        pass

    if depuis < 25:
        # Une photo représentative pour les notifications groupées.
        #
        # `ami_actif` garde exprès `capture` à NULL — c'est ce qui porte la
        # clé d'unicité et permet à cinq photos de la même sortie de ne faire
        # qu'une seule ligne. Sans colonne à part, ces notifications n'avaient
        # donc aucune image à montrer : juste le badge 📷.
        _ajoute_colonnes(cx, "notifications", {"apercu": "INTEGER"})


def _fige_identifiants_captures(cx: sqlite3.Connection) -> None:
    """Empêche la réutilisation des identifiants de capture.

    Sans AUTOINCREMENT, SQLite réattribue les identifiants libérés : après une
    remise à zéro, la première photo reprend l'identifiant 1, donc l'URL exacte
    d'une photo effacée. Les téléphones qui gardaient l'ancienne image en cache
    la resservent à sa place, et l'on croit à des résidus côté serveur alors
    que plus rien n'y traîne.

    SQLite ne sait pas ajouter AUTOINCREMENT après coup : il faut recréer la
    table. On la reconstruit à partir de sa définition d'origine plutôt que
    d'en réécrire une copie, pour ne pas la voir diverger du schéma à la
    prochaine colonne ajoutée.
    """
    ligne = cx.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='captures'"
    ).fetchone()
    if ligne is None or "AUTOINCREMENT" in (ligne["sql"] or ""):
        return                      # table absente, ou déjà migrée

    colonnes = [r["name"] for r in cx.execute("PRAGMA table_info(captures)")]
    noms = ", ".join(colonnes)
    creation = ligne["sql"].replace(
        "CREATE TABLE captures", "CREATE TABLE captures_neuf", 1).replace(
        "INTEGER PRIMARY KEY", "INTEGER PRIMARY KEY AUTOINCREMENT", 1)

    # Les clés étrangères doivent être suspendues le temps de l'échange : les
    # tables qui pointent vers `captures` référenceraient sinon une table en
    # train de disparaître. C'est la procédure que documente SQLite pour ce
    # genre de reconstruction.
    cx.execute("PRAGMA foreign_keys = OFF")
    try:
        # Une tentative interrompue a pu laisser la table intermédiaire :
        # la migration doit pouvoir être rejouée telle quelle.
        cx.execute("DROP TABLE IF EXISTS captures_neuf")
        cx.execute(creation)
        cx.execute(f"INSERT INTO captures_neuf ({noms}) SELECT {noms} FROM captures")
        cx.execute("DROP TABLE captures")
        cx.execute("ALTER TABLE captures_neuf RENAME TO captures")
    finally:
        cx.execute("PRAGMA foreign_keys = ON")

    # Les identifiants déjà distribués ne doivent jamais resservir, même si
    # toutes les captures ont été effacées entre-temps.
    # `sqlite_sequence` ne porte aucune contrainte d'unicité : on remplace la
    # ligne au lieu de compter sur un ON CONFLICT.
    haut = cx.execute("SELECT COALESCE(MAX(id), 0) FROM captures").fetchone()[0]
    cx.execute("DELETE FROM sqlite_sequence WHERE name = 'captures'")
    if haut:
        cx.execute("INSERT INTO sqlite_sequence (name, seq) VALUES ('captures', ?)",
                   (haut,))


def _ouvre_alias_aux_regnes(cx: sqlite3.Connection) -> None:
    """Fait porter l'unicité des alias sur (nom latin, règne).

    Tant que le dex n'avait que des animaux, un nom latin suffisait à désigner
    une case. Ce n'est plus vrai : le même binôme peut désigner une plante et un
    animal, la nomenclature botanique et la zoologique étant indépendantes. Le
    catalogue en compte une quarantaine, et sans cette correction la
    construction du dex flore échoue sur une violation d'unicité.
    """
    ligne = cx.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='alias'"
    ).fetchone()
    if ligne is None or "PRIMARY KEY (latin, regne)" in (ligne["sql"] or ""):
        return

    cx.execute("PRAGMA foreign_keys = OFF")
    try:
        cx.execute("DROP TABLE IF EXISTS alias_neuf")
        cx.execute("""CREATE TABLE alias_neuf (
            latin TEXT NOT NULL,
            regne TEXT NOT NULL DEFAULT 'animal',
            case_id INTEGER NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
            accepte INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (latin, regne))""")
        # Le règne se lit sur la case pointée : les alias existants sont tous
        # animaux, mais autant le déduire plutôt que le supposer.
        cx.execute("""INSERT INTO alias_neuf (latin, regne, case_id, accepte)
                      SELECT a.latin, COALESCE(c.regne, 'animal'), a.case_id, a.accepte
                      FROM alias a LEFT JOIN cases c ON c.id = a.case_id""")
        cx.execute("DROP TABLE alias")
        cx.execute("ALTER TABLE alias_neuf RENAME TO alias")
        cx.execute("CREATE INDEX IF NOT EXISTS idx_alias_case ON alias(case_id)")
    finally:
        cx.execute("PRAGMA foreign_keys = ON")


def _libere_visuels(cx: sqlite3.Connection) -> None:
    """Retire l'unicité sur `visuels.fichier`.

    Une même silhouette couvre souvent plusieurs taxons : PhyloPic sert le même
    dessin pour une classe et pour l'un de ses ordres. Avec l'ancienne
    contrainte, la seconde insertion écrasait la première, et des groupes
    entiers — les insectes, entre autres — se retrouvaient sans silhouette.
    SQLite ne sachant pas supprimer une contrainte, on recrée la table.
    """
    colonnes = {r["name"] for r in cx.execute("PRAGMA table_info(visuels)")}
    if not colonnes:
        return
    sql = cx.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='visuels'"
    ).fetchone()
    if sql and "UNIQUE" not in (sql["sql"] or ""):
        return                      # déjà migrée

    cx.execute("""CREATE TABLE visuels_neuf (
        id INTEGER PRIMARY KEY, fichier TEXT NOT NULL, rang TEXT NOT NULL,
        cle_gbif INTEGER, etiquette TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT '', licence TEXT NOT NULL DEFAULT '')""")
    cx.execute("""INSERT INTO visuels_neuf
                  SELECT id, fichier, rang, cle_gbif, etiquette, source, licence
                  FROM visuels""")
    cx.execute("DROP TABLE visuels")
    cx.execute("ALTER TABLE visuels_neuf RENAME TO visuels")
    # Les index ne survivent pas au remplacement de la table : on les repose.
    cx.execute("CREATE INDEX IF NOT EXISTS idx_visuels_rang "
               "ON visuels(rang, cle_gbif)")
    cx.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_visuels_unique "
               "ON visuels(fichier, rang, cle_gbif)")


def _ajoute_colonnes(cx: sqlite3.Connection, table: str, colonnes: dict[str, str]) -> None:
    """ALTER TABLE tolérant : n'ajoute que ce qui manque vraiment."""
    presentes = {r["name"] for r in cx.execute(f"PRAGMA table_info({table})")}
    for nom, declaration in colonnes.items():
        if nom not in presentes:
            cx.execute(f"ALTER TABLE {table} ADD COLUMN {nom} {declaration}")
