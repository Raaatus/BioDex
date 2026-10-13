#!/usr/bin/env python3
"""
Injecte les données des joueurs d'une base dans une autre.

Le cas à traiter : on veut déployer une base neuve — dex complet, alias,
silhouettes — sans perdre ce que les joueurs ont déjà fait sur le serveur.
Comptes, photos, découvertes, amitiés : tout cela n'existe qu'en ligne et
ne se reconstruit pas.

**Le piège est la correspondance des identifiants.** Une capture du serveur
pointe vers la case 4211 ; dans la base neuve, la même espèce porte peut-être
le numéro 9317. Recopier les lignes telles quelles rattacherait chaque photo
à une espèce au hasard — une panne silencieuse, qu'on ne verrait qu'en
ouvrant le dex des semaines plus tard.

On remappe donc **par le nom latin**, seule chose stable d'une base à
l'autre. Une espèce absente de la base neuve fait une capture orpheline :
on la garde, sans case, plutôt que de la jeter ou de l'attacher n'importe où.

Les pseudos suivent la même logique : un compte déjà présent dans la base
d'arrivée est reconnu par son pseudo normalisé et réutilisé, jamais dupliqué.

    python outils/fusionne_bases.py source.sqlite destination.sqlite
    python outils/fusionne_bases.py source.sqlite destination.sqlite --essai
"""
import argparse
import pathlib
import sqlite3
import sys


def latins(cx) -> dict[int, str]:
    """Le nom latin de chaque case, par identifiant."""
    return {r[0]: r[1] for r in cx.execute("SELECT id, latin FROM cases")}


def par_latin(cx) -> dict[str, int]:
    return {r[1]: r[0] for r in cx.execute("SELECT id, latin FROM cases")}


def colonnes(cx, table: str) -> list[str]:
    return [r[1] for r in cx.execute(f"PRAGMA table_info({table})")]


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", type=pathlib.Path, help="la base des joueurs")
    ap.add_argument("destination", type=pathlib.Path, help="la base neuve")
    ap.add_argument("--essai", action="store_true",
                    help="montre ce qui serait fait, sans rien écrire")
    a = ap.parse_args()

    if not a.source.is_file() or not a.destination.is_file():
        raise SystemExit("source ou destination introuvable")

    src = sqlite3.connect(f"file:{a.source}?mode=ro", uri=True)
    src.row_factory = sqlite3.Row
    dst = sqlite3.connect(a.destination)
    dst.row_factory = sqlite3.Row
    dst.execute("PRAGMA foreign_keys = OFF")

    latin_src = latins(src)
    case_dst = par_latin(dst)

    def case(ancienne):
        """L'identifiant de la même espèce dans la base d'arrivée."""
        if ancienne is None:
            return None
        nom = latin_src.get(ancienne)
        return case_dst.get(nom) if nom else None

    resume: dict[str, int] = {}
    orphelines = 0

    # ── Les comptes. Un pseudo déjà présent est réutilisé.
    utilisateur_dst: dict[int, int] = {}
    connus = {r["pseudo_norm"]: r["id"]
              for r in dst.execute("SELECT id, pseudo_norm FROM utilisateurs")}
    cols_u = [c for c in colonnes(src, "utilisateurs") if c != "id"]
    for u in src.execute("SELECT * FROM utilisateurs"):
        deja = connus.get(u["pseudo_norm"])
        if deja is not None:
            utilisateur_dst[u["id"]] = deja
            continue
        if a.essai:
            utilisateur_dst[u["id"]] = -1
        else:
            cur = dst.execute(
                f"INSERT INTO utilisateurs ({','.join(cols_u)}) "
                f"VALUES ({','.join('?' * len(cols_u))})",
                [u[c] for c in cols_u])
            utilisateur_dst[u["id"]] = cur.lastrowid
        resume["comptes créés"] = resume.get("comptes créés", 0) + 1

    # ── Les captures, avec leur case remappée.
    capture_dst: dict[int, int] = {}
    cols_c = [c for c in colonnes(src, "captures") if c != "id"]
    for c in src.execute("SELECT * FROM captures"):
        valeurs = []
        for col in cols_c:
            if col == "utilisateur":
                valeurs.append(utilisateur_dst.get(c["utilisateur"]))
            elif col == "case_id":
                neuve = case(c["case_id"])
                if c["case_id"] is not None and neuve is None:
                    orphelines += 1
                valeurs.append(neuve)
            else:
                valeurs.append(c[col])
        if a.essai:
            capture_dst[c["id"]] = -1
        else:
            cur = dst.execute(
                f"INSERT INTO captures ({','.join(cols_c)}) "
                f"VALUES ({','.join('?' * len(cols_c))})", valeurs)
            capture_dst[c["id"]] = cur.lastrowid
        resume["captures"] = resume.get("captures", 0) + 1

    # ── Ce qui pend aux captures et aux comptes.
    def recopie(table, remap, ignore_si_nul=()):
        cols = colonnes(src, table)
        if "id" in cols:
            cols = [c for c in cols if c != "id"]
        n = 0
        for ligne in src.execute(f"SELECT * FROM {table}"):
            valeurs, saute = [], False
            for col in cols:
                if col in remap:
                    v = remap[col](ligne[col])
                    if v is None and ligne[col] is not None \
                            and col in ignore_si_nul:
                        saute = True
                    valeurs.append(v)
                else:
                    valeurs.append(ligne[col])
            if saute:
                continue
            if not a.essai:
                dst.execute(
                    f"INSERT OR IGNORE INTO {table} ({','.join(cols)}) "
                    f"VALUES ({','.join('?' * len(cols))})", valeurs)
            n += 1
        if n:
            resume[table] = n

    u = lambda v: utilisateur_dst.get(v)          # noqa: E731
    k = lambda v: capture_dst.get(v)              # noqa: E731

    recopie("decouvertes",
            {"utilisateur": u, "case_id": case, "premiere": k, "vedette": k},
            ignore_si_nul=("case_id",))
    recopie("captures_top", {"capture": k, "case_id": case})
    recopie("amities", {"demandeur": u, "destinataire": u})
    recopie("reactions", {"capture": k, "auteur": u})
    recopie("favoris", {"utilisateur": u, "capture": k})
    recopie("notifications", {"destinataire": u, "auteur": u, "capture": k})

    if a.essai:
        dst.rollback()
        print("ESSAI — rien n'a été écrit\n")
    else:
        dst.commit()

    for cle, n in resume.items():
        print(f"  {cle:<16} {n}")
    if orphelines:
        print(f"\n  {orphelines} capture(s) sans case correspondante : "
              f"gardées, mais sans espèce. Leur photo reste, et le joueur "
              f"peut la réattribuer depuis l'application.")
    print("\nLes sessions ne sont pas reprises : les joueurs se reconnectent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
