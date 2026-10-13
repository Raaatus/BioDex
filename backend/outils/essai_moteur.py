#!/usr/bin/env python3
"""
Passe des images au moteur sans démarrer le serveur, et affiche la case visée.

Sert à vérifier le portage et à recaler les seuils :

    python outils/essai_moteur.py ~/biodex/images/*.jpg
"""
import argparse
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import db, moteur  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("images", nargs="+", type=pathlib.Path)
    a = ap.parse_args()

    db.initialise()
    if not db.valeur("SELECT COUNT(*) FROM cases", (), 0):
        raise SystemExit("Aucune case en base : lancer outils/construit_dex.py d'abord.")

    from PIL import Image

    m = moteur.Moteur()
    t0 = time.perf_counter()
    m.charge()
    print(f"Modèles chargés en {time.perf_counter() - t0:.0f} s\n")
    print("=" * 78)

    for chemin in a.images:
        if not chemin.exists():
            print(f"{chemin} : introuvable")
            continue
        with Image.open(chemin) as img:
            r = m.analyse(img)

        case = None
        if r.case_id:
            case = db.lit_un("SELECT latin, nom_fr, famille, classe, rarete FROM cases WHERE id = ?",
                             (r.case_id,))

        print(f"\n{chemin.name}")
        print(f"  {r.etat.upper():6} {r.verdict}")
        if case:
            print(f"  case   {case['latin']} · {case['famille']} · {case['classe']} "
                  f"· rareté {case['rarete']}")
        print(f"  {r.note}")
        print("  top : " + " | ".join(f"{l} {p:.3f}" for l, p in r.top[:4]))
        print(f"  {r.duree:.1f} s")

    return 0


if __name__ == "__main__":
    sys.exit(main())
