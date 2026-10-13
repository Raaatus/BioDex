#!/usr/bin/env python3
"""
Marque les champignons signalés toxiques.

La liste vient du jeu de données FungiTastic, qui annote une cinquantaine
d'espèces. Elle ne prétend pas à l'exhaustivité, et c'est important : une case
non marquée n'est pas une case sûre. L'application n'affiche donc l'alerte que
lorsqu'elle est positive, jamais l'inverse — un « non toxique » serait une
promesse que personne ne peut tenir.

    python -m outils.toxiques
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db  # noqa: E402


def main() -> int:
    db.initialise()
    classes = json.loads(config.FUNGI_CLASSES.read_text(encoding="utf-8"))
    indices = json.loads(config.FUNGI_TOXIQUES.read_text(encoding="utf-8"))
    noms = sorted({classes[str(i)] for i in indices if str(i) in classes})
    print(f"{len(noms)} espèces signalées toxiques dans FungiTastic")

    marquees, absentes = 0, []
    with db.transaction() as cx:
        cx.execute("UPDATE cases SET toxique = 0 WHERE regne = 'champignon'")
        for nom in noms:
            cur = cx.execute(
                """UPDATE cases SET toxique = 1
                   WHERE regne = 'champignon' AND id IN (
                       SELECT case_id FROM alias
                       WHERE latin = ? AND regne = 'champignon')""", (nom,))
            if cur.rowcount:
                marquees += cur.rowcount
            else:
                absentes.append(nom)

    print(f"  {marquees} cases marquées")
    if absentes:
        print(f"  {len(absentes)} espèces sans case : {', '.join(absentes[:5])}")
    for r in db.lit("""SELECT latin, nom_fr FROM cases
                       WHERE toxique = 1 ORDER BY obs DESC LIMIT 6"""):
        print(f"    {r['latin']:<28} {r['nom_fr'] or ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
