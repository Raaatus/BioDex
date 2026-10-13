#!/usr/bin/env python3
"""
Fabrique les découpes des captures qui n'en ont pas encore.

Le détourage est arrivé après coup : les photos analysées avant lui remplissent
leur case avec une vignette carrée au lieu de l'animal détouré. Ce script
rattrape le retard, sans rien réanalyser — la boîte de détection est déjà en
base pour les captures récentes, et à défaut on détoure la photo entière.

    python outils/decoupes_manquantes.py
    python outils/decoupes_manquantes.py --refais    # y compris celles qui en ont
"""
import argparse
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db, images  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--refais", action="store_true",
                    help="refaire aussi les découpes déjà présentes")
    a = ap.parse_args()

    if not config.DETOURAGE:
        raise SystemExit("Le détourage est désactivé (BIODEX_DETOURAGE=0).")

    db.initialise()
    condition = "" if a.refais else "AND decoupe IS NULL"
    lignes = db.lit(
        f"""SELECT id, fichier, bbox FROM captures
            WHERE case_id IS NOT NULL {condition} ORDER BY id""")
    if not lignes:
        print("Toutes les captures rangées dans une case ont déjà leur découpe.")
        return 0

    print(f"{len(lignes)} capture(s) à détourer…", flush=True)
    t0 = time.perf_counter()
    faits = 0
    for r in lignes:
        bbox = None
        if r["bbox"]:
            try:
                bbox = tuple(float(v) for v in r["bbox"].split(","))
            except ValueError:
                bbox = None
        nom = images.decoupe(r["fichier"], bbox)
        if nom:
            db.ecrit("UPDATE captures SET decoupe = ? WHERE id = ?", (nom, r["id"]))
            faits += 1
            print(f"  capture {r['id']} : {nom}", flush=True)
        else:
            print(f"  capture {r['id']} : rien d'exploitable, vignette conservée",
                  flush=True)

    print(f"\n{faits}/{len(lignes)} découpes produites "
          f"en {time.perf_counter() - t0:.1f} s.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
