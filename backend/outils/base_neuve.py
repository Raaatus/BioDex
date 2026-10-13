#!/usr/bin/env python3
"""Reconstruit une base propre en gardant tout ce qui appartient aux joueurs.

Pourquoi refaire la base plutôt que la migrer sur place : une base qui a suivi
dix-huit versions de schéma porte les traces de toutes — colonnes ajoutées à la
fin dans l'ordre historique, index laissés par des tables refaites, pages
libérées jamais reprises. Repartir du schéma courant donne exactement ce que le
code attend, et rien d'autre.

Ce qui est repris tel quel :

  le dex          cases, alias, visuels — ils sont identiques d'une base à
                  l'autre, on les recopie au lieu de les reconstruire
  les joueurs     comptes, sessions, amitiés
  les trouvailles captures, découvertes, top des propositions, participants
  le social       réactions, favoris, notifications, fiches encyclopédiques

Ce qui ne l'est pas : rien. Aucune donnée de joueur n'est laissée derrière.

    python outils/base_neuve.py                   # sur place, avec sauvegarde
    python outils/base_neuve.py --vers /tmp/x.sqlite   # sans toucher à l'existante
    python outils/base_neuve.py --depuis vieille.sqlite --vers neuve.sqlite

Les photos ne sont jamais touchées : elles vivent sur le disque, pas en base.
"""
import argparse
import datetime
import pathlib
import shutil
import sqlite3
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db  # noqa: E402

# L'ordre compte : une table ne peut être remplie qu'après celles dont elle
# dépend. `utilisateurs` avant `captures`, `captures` avant `decouvertes`.
ORDRE = [
    "visuels", "cases", "alias",
    "utilisateurs", "sessions",
    "captures", "captures_top", "participants",
    "decouvertes", "amities", "reactions", "favoris", "notifications",
    "fiches",
]


def colonnes(cx: sqlite3.Connection, table: str) -> list[str]:
    return [r[1] for r in cx.execute(f"PRAGMA table_info({table})")]


def transfere(source: sqlite3.Connection, cible: sqlite3.Connection,
              table: str) -> tuple[int, list[str]]:
    """Recopie une table, colonne par colonne.

    On ne transfère que les colonnes présentes des deux côtés. C'est ce qui
    permet de passer d'un schéma à l'autre sans écrire une migration par
    version : une colonne nouvelle prend son défaut, une colonne disparue est
    simplement oubliée — et on le dit, pour que personne ne découvre la perte
    six mois plus tard.
    """
    avant = colonnes(source, table)
    apres = colonnes(cible, table)
    if not avant:
        return 0, []
    communes = [c for c in apres if c in avant]
    perdues = [c for c in avant if c not in apres]

    noms = ", ".join(communes)
    marques = ", ".join("?" * len(communes))
    lignes = source.execute(f"SELECT {noms} FROM {table}").fetchall()
    if lignes:
        cible.executemany(
            f"INSERT INTO {table} ({noms}) VALUES ({marques})", lignes)
    return len(lignes), perdues


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--depuis", type=pathlib.Path, default=config.BASE,
                    help="la base à reprendre (défaut : celle du serveur)")
    ap.add_argument("--vers", type=pathlib.Path,
                    help="où écrire la neuve ; sans cette option, on remplace "
                         "l'ancienne après l'avoir sauvegardée")
    a = ap.parse_args()

    if not a.depuis.exists():
        sys.exit(f"Base introuvable : {a.depuis}")

    sur_place = a.vers is None
    destination = a.vers or a.depuis.with_suffix(".neuve.sqlite")
    if destination.exists():
        sys.exit(f"{destination} existe déjà — écartez-le d'abord.")

    print(f"depuis : {a.depuis}  ({a.depuis.stat().st_size / 2**20:.0f} Mo)")
    print(f"vers   : {destination}\n")

    # La source s'ouvre en lecture seule : le serveur tourne peut-être encore,
    # et on ne veut en aucun cas modifier ce dont on part.
    source = sqlite3.connect(f"file:{a.depuis}?mode=ro", uri=True)
    source.row_factory = sqlite3.Row
    if source.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        sys.exit("La base d'origine est corrompue : on s'arrête là.")

    cible = sqlite3.connect(destination)
    cible.executescript(
        (config.RACINE / "biodex" / "schema.sql").read_text(encoding="utf-8"))
    cible.execute(f"PRAGMA user_version = {db.VERSION_SCHEMA}")
    # Les clés étrangères sont relâchées le temps du transfert : `utilisateurs`
    # référence `captures` pour l'avatar, et `captures` référence
    # `utilisateurs`. Aucun ordre ne satisfait les deux, il faut donc vérifier
    # à la fin plutôt qu'au fil de l'eau.
    cible.execute("PRAGMA foreign_keys = OFF")

    total, pertes = 0, {}
    for table in ORDRE:
        n, perdues = transfere(source, cible, table)
        total += n
        if perdues:
            pertes[table] = perdues
        marque = " " if n else "·"
        print(f"  {marque} {table:16} {n:>8}")
    cible.commit()

    if pertes:
        print("\nColonnes présentes dans l'ancienne base et absentes de la "
              "nouvelle :")
        for table, cols in pertes.items():
            print(f"  {table} : {', '.join(cols)}")
        print("Leur contenu n'a pas été repris.")

    print("\nvérifications :")
    fautes = cible.execute("PRAGMA foreign_key_check").fetchall()
    print(f"  clés étrangères  {'ok' if not fautes else f'{len(fautes)} FAUTES'}")
    if fautes:
        for f in fautes[:5]:
            print(f"    {f}")
        sys.exit("On ne remplace rien tant que la nouvelle base n'est pas saine.")
    print(f"  intégrité        {cible.execute('PRAGMA integrity_check').fetchone()[0]}")

    # Un comptage de contrôle, table par table : c'est la seule preuve que rien
    # n'a été laissé en route.
    ecarts = []
    for table in ORDRE:
        try:
            avant = source.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        except sqlite3.OperationalError:
            continue                       # table absente de l'ancienne version
        apres = cible.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        if avant != apres:
            ecarts.append((table, avant, apres))
    if ecarts:
        print("  comptages        ÉCARTS :")
        for t, av, ap in ecarts:
            print(f"    {t} : {av} → {ap}")
        sys.exit("On s'arrête : la nouvelle base ne dit pas la même chose.")
    print("  comptages        identiques table par table")

    cible.execute("VACUUM")
    cible.close()
    source.close()
    print(f"\n{total} lignes transférées, "
          f"{destination.stat().st_size / 2**20:.0f} Mo")

    if sur_place:
        horodatage = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        sauvegarde = a.depuis.with_name(f"avant-base-neuve-{horodatage}.sqlite")
        shutil.move(a.depuis, sauvegarde)
        # Les fichiers de journal appartiennent à l'ancienne base : les laisser
        # à côté de la nouvelle la corromprait au premier démarrage.
        for suffixe in ("-wal", "-shm"):
            compagnon = a.depuis.with_name(a.depuis.name + suffixe)
            if compagnon.exists():
                compagnon.unlink()
        shutil.move(destination, a.depuis)
        print(f"\nAncienne base gardée sous {sauvegarde.name}")
        print("Effacez-la quand vous serez sûr que tout va bien.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
