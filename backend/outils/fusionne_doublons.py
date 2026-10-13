#!/usr/bin/env python3
"""
Fusionne les cases qui portent le même nom dans le même règne.

Le backbone GBIF attribue parfois deux `species_key` à une même espèce, faute
d'avoir fusionné un synonyme. On se retrouve alors avec deux cases « Fraxinus
excelsior », et c'est doublement ennuyeux :

  - la masse de probabilité se partage entre les deux, si bien qu'une espèce
    reconnue à 80 % peut sortir deux fois à 40 % et passer sous le seuil ;
  - le joueur voit deux cases identiques dans son dex, dont une qu'il ne
    remplira jamais.

Le phénomène est rare en proportion — deux dixièmes de pour cent — mais il
frappe des espèces très communes, donc souvent photographiées : le frêne, la
renoncule rampante, le lierre.

La case conservée est la mieux observée ; l'autre lui cède ses alias, ses
captures et ses découvertes, et ses observations s'additionnent.

    python -m outils.fusionne_doublons            # liste sans rien changer
    python -m outils.fusionne_doublons --appliquer
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import db  # noqa: E402


def doublons() -> list[dict]:
    return db.lit(
        """SELECT latin, regne, COUNT(*) AS n, SUM(obs) AS total
           FROM cases GROUP BY latin, regne HAVING n > 1
           ORDER BY total DESC""")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--appliquer", action="store_true",
                    help="sans cette option, on se contente de lister")
    a = ap.parse_args()

    db.initialise()
    groupes = doublons()
    if not groupes:
        print("Aucun doublon.")
        return 0

    print(f"{len(groupes)} noms portés par plusieurs cases :")
    for r in groupes[:8]:
        print(f"  {r['latin']:<32} {r['regne']:<11} {r['n']} cases, "
              f"{r['total']:>10,} obs")
    if len(groupes) > 8:
        print(f"  … et {len(groupes) - 8} autres")

    if not a.appliquer:
        print("\nRien n'a été touché. Relancer avec --appliquer pour fusionner.")
        return 0

    fusionnees = 0
    with db.transaction() as cx:
        for r in groupes:
            cases = cx.execute(
                """SELECT id, obs FROM cases WHERE latin = ? AND regne = ?
                   ORDER BY obs DESC, id""", (r["latin"], r["regne"])).fetchall()
            garde = cases[0]["id"]
            perdus = [c["id"] for c in cases[1:]]
            total = sum(c["obs"] for c in cases)

            for perdu in perdus:
                # Les alias basculent, sauf ceux qui existent déjà sur la case
                # conservée : la clé porte sur (latin, regne).
                cx.execute(
                    """UPDATE OR IGNORE alias SET case_id = ? WHERE case_id = ?""",
                    (garde, perdu))
                cx.execute("DELETE FROM alias WHERE case_id = ?", (perdu,))
                # Les captures et découvertes suivent, pour ne perdre aucune
                # trouvaille si la fusion arrive après coup.
                cx.execute("UPDATE captures SET case_id = ? WHERE case_id = ?",
                           (garde, perdu))
                cx.execute("UPDATE OR IGNORE decouvertes SET case_id = ? WHERE case_id = ?",
                           (garde, perdu))
                cx.execute("DELETE FROM decouvertes WHERE case_id = ?", (perdu,))
                cx.execute("UPDATE OR IGNORE captures_top SET case_id = ? WHERE case_id = ?",
                           (garde, perdu))
                cx.execute("DELETE FROM cases WHERE id = ?", (perdu,))
                fusionnees += 1

            cx.execute("""UPDATE cases SET obs = ?,
                             nb_alias = (SELECT COUNT(*) FROM alias WHERE case_id = ?)
                          WHERE id = ?""", (total, garde, garde))

    print(f"\n{fusionnees} cases fusionnées.")
    restants = doublons()
    print(f"Doublons restants : {len(restants)}")
    for r in db.lit("SELECT regne, COUNT(*) n FROM cases GROUP BY regne ORDER BY n DESC"):
        print(f"  {r['regne']:<12} {r['n']:>7} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
