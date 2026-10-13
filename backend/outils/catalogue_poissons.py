#!/usr/bin/env python3
"""
Fabrique `catalogue_aquatique.pt` : le catalogue animal, réduit aux poissons.

Deux idées, et la première fait déjà l'essentiel du travail.

**Réduire le champ.** Le catalogue animal met 411 743 espèces en concurrence.
Quand le joueur photographie un poisson, 356 000 d'entre elles sont des
insectes, des oiseaux ou des escargots : autant de faux candidats qui peuvent
gagner sur un reflet. Les écarter ne coûte rien et supprime d'un coup les
erreurs les plus grossières.

**Ne rien réencoder.** Les vecteurs des poissons sont déjà dans le catalogue
animal, calculés par le même BioCLIP. On sélectionne des lignes, on ne
recalcule rien : le résultat est bit pour bit celui que le serveur utilise
aujourd'hui pour ces espèces, sans dérive possible entre les deux catalogues.

Ce que ce catalogue ne fait pas : créer des cases. Les poissons sont déjà au
dex sous le règne animal — le poisson-clown est la case 16397, avec son nom
français. « Aquatique » est une lentille, pas un dex parallèle : la capture
atterrit dans la case animale qui existe déjà. C'est pourquoi le catalogue est
construit avec `regne='animal'` pour l'indexation des cases.

Usage :
    python -m outils.catalogue_poissons
    python -m outils.catalogue_poissons --tete donnees/tete_genres.pt
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db, poissons  # noqa: E402

# Le périmètre « poisson » vit dans `biodex/poissons.py`, et nulle part
# ailleurs : le dex s'en sert pour son filtre « Aquatique ». Deux définitions
# qui divergeraient donneraient une espèce trouvable par la photo mais absente
# de la liste.


def cases_poissons() -> set[int]:
    ou, params = poissons.condition()
    return {r["id"] for r in db.lit(f"SELECT id FROM cases WHERE {ou}", params)}


def construit(source: pathlib.Path, sortie: pathlib.Path,
              tete: pathlib.Path | None) -> int:
    import torch

    if not source.exists():
        raise SystemExit(f"Catalogue animal introuvable : {source}")

    print(f"Lecture de {source.name}…", flush=True)
    d = torch.load(source, weights_only=False, map_location="cpu")
    noms, emb = d["noms"], d["emb"]
    obs = d.get("obs") or [0] * len(noms)
    genres = d.get("genres")
    print(f"  {len(noms)} entrées, {tuple(emb.shape)}")

    garde_cases = cases_poissons()
    print(f"  {len(garde_cases)} cases de poissons au dex")

    # Le catalogue ne connaît que des noms latins ; c'est la table `alias` qui
    # relie un nom à sa case. Un même nom peut être un synonyme : on prend la
    # case, quelle que soit la route.
    vers_case = dict(db.lit(
        """SELECT a.latin, a.case_id FROM alias a
           JOIN cases c ON c.id = a.case_id WHERE c.regne = 'animal'"""))

    indices = [i for i, n in enumerate(noms)
               if vers_case.get(n) in garde_cases]
    if not indices:
        raise SystemExit(
            "Aucune entrée retenue : le dex a-t-il été construit ?\n"
            "  python -m outils.construit_dex --regne animaux …")

    idx = torch.tensor(indices)
    paquet = {
        "noms": [noms[i] for i in indices],
        "emb": emb[idx],
        "obs": [obs[i] for i in indices],
    }
    if genres:
        paquet["genres"] = [genres[i] for i in indices]

    couvertes = {vers_case[noms[i]] for i in indices}
    print(f"  {len(indices)} entrées retenues "
          f"({100 * len(indices) / len(noms):.1f} % du catalogue animal)")
    print(f"  {len(couvertes)} cases couvertes")

    if tete is not None:
        if not tete.exists():
            raise SystemExit(f"Tête introuvable : {tete}")
        t = torch.load(tete, weights_only=False, map_location="cpu")
        paquet["tete_genres"] = t["poids"]
        paquet["tete_noms"] = t["genres"]
        paquet["tete_biais"] = t.get("biais")
        print(f"  tête genres greffée : {len(t['genres'])} genres, "
              f"{t['poids'].numel() * t['poids'].element_size() / 2**20:.1f} Mo")
    else:
        print("  sans tête genres — le catalogue marche quand même, "
              "il filtre seulement le champ")

    sortie.parent.mkdir(parents=True, exist_ok=True)
    torch.save(paquet, sortie)
    mo = sortie.stat().st_size / 2 ** 20
    print(f"\nÉcrit : {sortie}  ({mo:.0f} Mo)")

    manque = garde_cases - couvertes
    if manque:
        # Ce n'est pas une erreur : une case peut exister au dex sans qu'aucun
        # nom du catalogue n'y mène. Elle restera simplement introuvable par la
        # photo, comme aujourd'hui sous le règne animal.
        print(f"Note : {len(manque)} cases de poissons n'ont aucun nom au "
              f"catalogue — inatteignables par l'image, ici comme ailleurs.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", type=pathlib.Path, default=config.CATALOGUE,
                    help="catalogue animal dont on extrait les poissons")
    ap.add_argument("--sortie", type=pathlib.Path,
                    default=config.DONNEES / "catalogue_aquatique.pt")
    ap.add_argument("--tete", type=pathlib.Path, default=None,
                    help="tête genres produite par tete_poissons.py")
    a = ap.parse_args()
    return construit(a.source.expanduser(), a.sortie.expanduser(),
                     a.tete.expanduser() if a.tete else None)


if __name__ == "__main__":
    raise SystemExit(main())
