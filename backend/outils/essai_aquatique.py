#!/usr/bin/env python3
"""
Le règne aquatique sert-il à quelque chose ? Mesure, sur des poissons connus.

Compare trois configurations sur les mêmes images, en passant par la vraie
classe `Catalogue` — pas par une réimplémentation qui pourrait diverger :

  1. catalogue animal          ce que fait le serveur aujourd'hui
  2. catalogue aquatique       le champ réduit aux poissons, sans tête
  3. aquatique + tête genres   plus l'avis appris sur FishNet

Les images viennent du **split de contrôle** de FishNet : la tête ne les a
jamais vues. Leur espèce est donnée par les annotations officielles, et on ne
garde que celles qui ont une case au dex — sans case, il n'y a pas de bonne
réponse à comparer.

Ce que la mesure ne dit pas : ce que ça donnera sur un aquarium. FishNet est
fait de photos de référence et d'observations de terrain, pas de poissons
derrière une vitre avec un éclairage bleu. C'est un plancher, pas une promesse.

Usage :
    python -m outils.essai_aquatique --embeddings ~/fishnet-travail/poissons_embeddings.pt
"""
import argparse
import collections
import pathlib
import random
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db  # noqa: E402


def cases_attendues(especes: set[str]) -> dict[str, int]:
    """L'espèce vraie → sa case au dex, via la table des alias."""
    par_nom = dict(db.lit(
        """SELECT a.latin, a.case_id FROM alias a
           JOIN cases c ON c.id = a.case_id WHERE c.regne = 'animal'"""))
    return {e: par_nom[e] for e in especes if e in par_nom}


def echantillon(chemin: pathlib.Path, combien: int, graine: int):
    import torch

    d = torch.load(chemin, weights_only=False, map_location="cpu")
    idx = [i for i, (sp, sl) in enumerate(zip(d["espece"], d["split"]))
           if sp and sl == "test"]
    vers_case = cases_attendues({d["espece"][i] for i in idx})
    idx = [i for i in idx if d["espece"][i] in vers_case]
    print(f"{len(idx)} images de contrôle dont l'espèce a une case au dex")

    random.Random(graine).shuffle(idx)
    idx = idx[:combien]
    genre_de = dict(db.lit("SELECT latin, genre FROM cases WHERE regne='animal'"))
    return (
        d["emb"][torch.tensor(idx)].float(),
        [vers_case[d["espece"][i]] for i in idx],
        [d["espece"][i] for i in idx],
        [d["genre"][i] for i in idx],
        genre_de,
    )


def evalue(cat, X, cases_vraies, genres_vrais, nom: str):
    """Top-1 case, top-5 cases, et justesse du genre."""
    import torch

    bon1 = bon5 = bon_genre = 0
    t0 = time.perf_counter()
    for i in range(len(X)):
        e = X[i]
        e = e / e.norm()
        _, gen, cas = cat.classe(e, k=5, k_cases=5)
        ids = [c for c, _ in cas]
        if ids and ids[0] == cases_vraies[i]:
            bon1 += 1
        if cases_vraies[i] in ids:
            bon5 += 1
        if gen and genres_vrais[i] and gen[0][0] == genres_vrais[i]:
            bon_genre += 1
    n = len(X)
    duree = (time.perf_counter() - t0) / n * 1000
    print(f"  {nom:<28} top-1 {bon1 / n:6.1%}   top-5 {bon5 / n:6.1%}   "
          f"genre {bon_genre / n:6.1%}   {duree:5.1f} ms/photo")
    return bon1 / n, bon5 / n, bon_genre / n


def main() -> int:
    import torch
    from biodex.moteur import Catalogue

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--embeddings", type=pathlib.Path, required=True)
    ap.add_argument("--animal", type=pathlib.Path, default=config.CATALOGUE)
    ap.add_argument("--aquatique", type=pathlib.Path,
                    default=config.DONNEES / "catalogue_aquatique.pt")
    ap.add_argument("--avec-tete", type=pathlib.Path, default=None,
                    help="catalogue aquatique portant la tête genres")
    ap.add_argument("--combien", type=int, default=1500)
    ap.add_argument("--graine", type=int, default=7)
    a = ap.parse_args()

    X, cases, especes, genres, _ = echantillon(
        a.embeddings.expanduser(), a.combien, a.graine)
    print(f"{len(X)} images tirées, {len(set(especes))} espèces, "
          f"{len(set(genres))} genres\n")

    resultats = {}
    for nom, chemin in (("catalogue animal", a.animal),
                        ("aquatique seul", a.aquatique),
                        ("aquatique + tête", a.avec_tete)):
        if chemin is None:
            continue
        chemin = chemin.expanduser()
        if not chemin.exists():
            print(f"  {nom:<28} absent ({chemin.name})")
            continue
        regne = "animal" if nom == "catalogue animal" else "aquatique"
        cat = Catalogue(torch, chemin, regne)
        resultats[nom] = evalue(cat, X, cases, genres, nom)
        del cat

    if "catalogue animal" in resultats and len(resultats) > 1:
        base = resultats["catalogue animal"][0]
        print()
        for nom, (t1, _, _) in resultats.items():
            if nom == "catalogue animal":
                continue
            ecart = t1 - base
            print(f"  {nom} : {ecart:+.1%} de top-1 contre le catalogue animal"
                  f"  ({base:.1%} → {t1:.1%})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
