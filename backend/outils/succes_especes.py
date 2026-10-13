#!/usr/bin/env python3
"""
Décide quelles espèces répondent à quel succès, une fois pour toutes.

C'est la partie difficile. Dire « trouve une espèce qui évoque le feu » est
facile ; le dire à 977 415 cases ne l'est pas. Trois erreurs guettent, et cet
outil est construit contre elles.

**Le faux positif.** « Pélican à lune*ttes* » n'a rien de céleste. On cherche
donc des mots entiers, pas des suites de lettres.

**L'oubli.** Chercher « piment » dans les noms français rate *Capsicum
frutescens*, qui n'a pas de nom français au dex. On ancre donc les thèmes sur
le **genre** quand il en existe un : `Capsicum` attrape tous les piments,
nommés ou non.

**L'invérifiable.** Aucune règle ne dira que « Piment royal » est un myrique.
D'où la liste d'exclusion, et surtout : cet outil **imprime ce qu'il a
retenu**. On regarde, on corrige `succes.py`, on relance. Une liste qu'on ne
relit pas est une liste fausse.

    python -m outils.succes_especes            calcule et écrit
    python -m outils.succes_especes --essai    montre sans rien écrire
"""
import argparse
import pathlib
import re
import sys
import unicodedata

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import db, succes  # noqa: E402


def sans_accents(t: str) -> str:
    """Pour comparer « flammé » et « flamme » sans multiplier les motifs."""
    return "".join(c for c in unicodedata.normalize("NFD", t)
                   if unicodedata.category(c) != "Mn").lower()


def motif(mots: list[str]) -> re.Pattern | None:
    """Un motif qui ne reconnaît que des mots entiers.

    On borde par « pas une lettre ni un chiffre » plutôt que par `\\b` : les
    expressions à apostrophe comme « d'Amérique » ont déjà une frontière avant
    leur première lettre, et `\\b` s'y comporte mal.
    """
    if not mots:
        return None
    parts = [re.escape(sans_accents(m)) for m in mots]
    return re.compile(r"(?<![a-z0-9])(?:" + "|".join(parts) + r")(?![a-z0-9])")


def calcule() -> dict[str, set[int]]:
    """Pour chaque thème, l'ensemble des cases éligibles."""
    lignes = db.lit(
        """SELECT id, latin, nom_fr, genre, famille, ordre, classe,
                  embranchement, regne, toxique
             FROM cases WHERE actif = 1""")
    print(f"{len(lignes)} cases parcourues\n")

    prepares = {}
    for nom, t in succes.THEMES.items():
        # Les ancres taxonomiques, du plus précis au plus large. Une ancre ne
        # se discute pas : elle attrape les espèces sans nom français, que les
        # motifs de nom rateraient toujours.
        prepares[nom] = {
            "rangs": [(champ, {x.lower() for x in t.get(cle, [])})
                      for champ, cle in (("genre", "genres"),
                                         ("famille", "familles"),
                                         ("ordre", "ordres"),
                                         ("classe", "classes"),
                                         ("embranchement", "embranchements"))
                      if t.get(cle)],
            "fr": motif(t.get("fr", [])),
            "latin": motif(t.get("latin", [])),
            "regne": t.get("regne"),
            "toxique": t.get("toxique", False),
            "exclus": {sans_accents(x) for x in t.get("exclus", [])},
        }

    trouve = {nom: set() for nom in succes.THEMES}
    for r in lignes:
        nom_fr = sans_accents(r["nom_fr"] or "")
        latin = sans_accents(r["latin"] or "")
        for theme, p in prepares.items():
            if p["regne"]:
                if r["regne"] == p["regne"] and (not p["toxique"] or r["toxique"]):
                    trouve[theme].add(r["id"])
                continue
            if nom_fr and nom_fr in p["exclus"]:
                continue
            # Les ancres taxonomiques d'abord : c'est la seule preuve qui ne se
            # discute pas, et la seule qui attrape les espèces sans nom français.
            if any((r[champ] or "").lower() in valeurs for champ, valeurs in p["rangs"]):
                trouve[theme].add(r["id"])
                continue
            if p["fr"] and nom_fr and p["fr"].search(nom_fr):
                trouve[theme].add(r["id"])
                continue
            if p["latin"] and latin and p["latin"].search(latin):
                trouve[theme].add(r["id"])
    return trouve


def couleurs() -> dict[str, set[int]]:
    """Les cases par couleur, pour « Palette » et « Arc-en-ciel »."""
    lignes = db.lit(
        "SELECT id, nom_fr FROM cases WHERE actif = 1 AND nom_fr IS NOT NULL")
    prepares = {c: motif(mots) for c, mots in succes.COULEURS.items()}
    trouve = {c: set() for c in succes.COULEURS}
    for r in lignes:
        n = sans_accents(r["nom_fr"])
        for c, m in prepares.items():
            if m.search(n):
                trouve[c].add(r["id"])
    return trouve


def montre(nom: str, ids: set[int], combien: int = 6) -> None:
    """Ce qu'on a retenu, du plus observé au moins : c'est ce qu'un joueur
    croisera en premier, donc ce qu'il faut relire en priorité."""
    if not ids:
        print(f"  {nom:<14} {0:>6}   AUCUNE ESPÈCE — succès impossible")
        return
    ech = list(ids)[:900]
    q = ",".join("?" * len(ech))
    exemples = db.lit(
        f"""SELECT COALESCE(nom_fr, latin) AS n FROM cases
            WHERE id IN ({q}) ORDER BY obs DESC LIMIT {combien}""", ech)
    print(f"  {nom:<14} {len(ids):>6}   "
          + ", ".join(x["n"] for x in exemples if x["n"])[:78])


def ecrit(themes: dict[str, set[int]], coul: dict[str, set[int]]) -> int:
    total = 0
    with db.transaction() as cx:
        cx.execute("DELETE FROM succes_especes")
        for nom, ids in list(themes.items()) + [
                (f"couleur:{c}", i) for c, i in coul.items()]:
            cx.executemany(
                "INSERT OR IGNORE INTO succes_especes (succes, case_id) VALUES (?,?)",
                [(nom, i) for i in ids])
            total += len(ids)
    return total


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--essai", action="store_true",
                    help="montre le résultat sans rien écrire en base")
    a = ap.parse_args()

    themes = calcule()
    coul = couleurs()

    print("=== thèmes ===")
    for nom in succes.THEMES:
        montre(nom, themes[nom])
    print("\n=== couleurs ===")
    for c in succes.COULEURS:
        montre(c, coul[c])

    vides = [n for n, i in themes.items() if not i]
    if vides:
        print(f"\n!! thèmes sans aucune espèce : {', '.join(vides)}")
        print("   Les succès correspondants seraient impossibles à obtenir.")

    if a.essai:
        print("\n(essai : rien n'a été écrit)")
        return 1 if vides else 0

    total = ecrit(themes, coul)
    print(f"\n{total} associations écrites dans succes_especes")
    return 1 if vides else 0


if __name__ == "__main__":
    raise SystemExit(main())
