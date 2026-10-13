#!/usr/bin/env python3
"""
Efface les comptes, les photos et toute la progression.

Ce qui disparaît : les joueurs, leurs sessions, leurs photos et les fichiers qui
vont avec, leurs découvertes, leurs amitiés, leurs réactions et leurs favoris.

Ce qui reste : **le dex lui-même** — les 376 000 cases, leurs alias, leurs
silhouettes, les fiches Wikipédia déjà récupérées. Le reconstruire demanderait
de rejouer le backbone GBIF, la récolte des noms français et celle de PhyloPic,
soit près d'une heure de travail machine, pour un résultat identique. Cette
partie n'a rien de personnel : c'est le catalogue du vivant, pas des données de
joueurs.

    python outils/remise_a_zero.py --confirmer
"""
import argparse
import pathlib
import shutil
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db  # noqa: E402

# Dans l'ordre : les dépendances d'abord, même si les clés étrangères en
# cascade feraient le travail. Être explicite rend l'effet lisible.
TABLES = [
    "reactions",
    "favoris",
    "captures_top",
    "decouvertes",
    "amities",
    "captures",
    "sessions",
    "utilisateurs",
]

# Dossiers dont le contenu appartient aux joueurs.
DOSSIERS = ["photos", "vignettes", "decoupes", "avatars", "miniatures"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--confirmer", action="store_true",
                    help="sans cette option, on se contente de lister")
    ap.add_argument("--sans-sauvegarde", action="store_true",
                    help="ne pas copier la base avant d'effacer (déconseillé)")
    a = ap.parse_args()

    db.initialise()

    print("Seront effacés :")
    total = 0
    for t in TABLES:
        n = db.valeur(f"SELECT COUNT(*) FROM {t}", (), 0)
        total += n
        print(f"  {t:<16} {n:>7} lignes")
    for d in DOSSIERS:
        chemin = config.DONNEES / d
        n = sum(1 for x in chemin.rglob("*") if x.is_file()) if chemin.exists() else 0
        print(f"  {d + '/':<16} {n:>7} fichiers")

    print("\nSeront conservés :")
    for t in ("cases", "alias", "visuels", "fiches"):
        print(f"  {t:<16} {db.valeur(f'SELECT COUNT(*) FROM {t}', (), 0):>7} lignes")
    silhouettes = sum(1 for x in config.SILHOUETTES.rglob("*") if x.is_file())
    print(f"  {'silhouettes/':<16} {silhouettes:>7} fichiers")

    if not a.confirmer:
        print("\nRien n'a été touché. Relancer avec --confirmer pour effacer.")
        return 0

    # Une copie de la base avant d'y toucher. Ce script efface les comptes de
    # tout le monde, pas seulement ceux qu'on vient de créer en essayant
    # quelque chose : une sauvegarde coûte quelques secondes et évite de perdre
    # des données que personne n'avait demandé à perdre.
    if not a.sans_sauvegarde:
        horo = __import__("datetime").datetime.now().strftime("%Y%m%d-%H%M%S")
        sauvegarde = config.DONNEES / f"avant-remise-a-zero-{horo}.sqlite"
        cx = db.connexion()
        cx.execute("PRAGMA wal_checkpoint(FULL)")
        shutil.copy2(config.BASE, sauvegarde)
        print(f"\nSauvegarde : {sauvegarde.name} "
              f"({sauvegarde.stat().st_size / 2**20:.0f} Mo)")
        print("  (les photos, elles, ne sont pas sauvegardées)")

    with db.transaction() as cx:
        for t in TABLES:
            cx.execute(f"DELETE FROM {t}")

    for d in DOSSIERS:
        chemin = config.DONNEES / d
        if chemin.exists():
            shutil.rmtree(chemin, ignore_errors=True)
        chemin.mkdir(parents=True, exist_ok=True)

    # Le fichier rend la place des lignes supprimées. On ne touche pas à
    # `sqlite_sequence` : les identifiants de capture ne doivent jamais
    # resservir, sous peine de voir les téléphones ressortir de leur cache les
    # images des photos effacées, dont les URLs seraient identiques.
    cx = db.connexion()
    cx.execute("VACUUM")

    print(f"\n{total} lignes et les fichiers associés ont été effacés.")
    print("Le dex est intact : il n'y a plus qu'à créer un compte et "
          "photographier une bête.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
