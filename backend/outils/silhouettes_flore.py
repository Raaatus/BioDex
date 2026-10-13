#!/usr/bin/env python3
"""
Formes de repli pour les cases de flore et de champignons.

PhyloPic couvre la plupart des familles, mais pas toutes. Les cases qu'aucune
silhouette ne couvre tombaient jusqu'ici sur l'empreinte générique — une patte
d'animal, ce qui n'a aucun sens devant une orchidée. Ce script dessine deux
formes neutres, une par règne, et les affecte aux cases restées sans image.

Les tracés sont volontairement simples : une silhouette de case fait 40 pixels
de côté à l'écran, tout détail y disparaît. Ce qui doit se lire à cette taille,
c'est la découpe générale — un chapeau sur un pied, une tige et des feuilles.

    python -m outils.silhouettes_flore
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db  # noqa: E402

# Un champignon vu de profil : chapeau large, lamelles suggérées, pied bulbeux.
# La forme la plus reconnaissable du règne, à toute taille.
CHAMPIGNON = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
<path d="M50 14c-19 0-33 11-33 23 0 3 2 5 5 5h56c3 0 5-2 5-5 0-12-14-23-33-23z"/>
<path d="M28 46c1 4 4 6 8 6h28c4 0 7-2 8-6z" opacity=".55"/>
<path d="M42 52v22c0 6-2 9-5 12h26c-3-3-5-6-5-12V52z"/>
<path d="M35 86c0-3 7-5 15-5s15 2 15 5c0 2-7 3-15 3s-15-1-15-3z" opacity=".7"/>
</svg>
"""

# Une plante : tige centrale, deux feuilles opposées, une pousse au sommet.
PLANTE = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
<path d="M47 92V38h6v54z"/>
<path d="M47 46c-14-2-24-9-27-21 14-2 24 5 27 17z"/>
<path d="M53 58c14-2 24-9 27-21-14-2-24 5-27 17z"/>
<path d="M50 36c-5-7-5-16 0-24 5 8 5 17 0 24z"/>
<path d="M38 92h24c0 3-5 4-12 4s-12-1-12-4z" opacity=".7"/>
</svg>
"""

FORMES = {"champignon": ("champignon_repli.svg", CHAMPIGNON),
          "plante": ("plante_repli.svg", PLANTE)}


def main() -> int:
    db.initialise()
    config.SILHOUETTES.mkdir(parents=True, exist_ok=True)

    for regne, (fichier, svg) in FORMES.items():
        (config.SILHOUETTES / fichier).write_text(svg, encoding="utf-8")
        # Rang « regne » : une forme qui ne vaut que faute de mieux, et que
        # n'importe quelle silhouette PhyloPic doit pouvoir remplacer.
        db.ecrit(
            """INSERT INTO visuels (fichier, rang, cle_gbif, etiquette, source, licence)
               VALUES (?, 'regne', NULL, ?, 'dessin maison', 'CC0')
               ON CONFLICT(fichier, rang, cle_gbif) DO UPDATE SET
                   etiquette = excluded.etiquette""",
            (fichier, regne))

        visuel = db.valeur(
            "SELECT id FROM visuels WHERE fichier = ? AND rang = 'regne'", (fichier,))
        n = db.ecrit(
            "UPDATE cases SET visuel = ? WHERE regne = ? AND visuel IS NULL",
            (visuel, regne)).rowcount
        total = db.valeur("SELECT COUNT(*) FROM cases WHERE regne = ?", (regne,), 0)
        print(f"  {regne:<11} {n:>7} cases sur {total} prennent la forme de repli")

    for r in db.lit(
            """SELECT c.regne,
                      COUNT(*) AS total,
                      SUM(CASE WHEN v.rang = 'regne' THEN 1 ELSE 0 END) AS repli,
                      SUM(CASE WHEN c.visuel IS NULL THEN 1 ELSE 0 END) AS sans
               FROM cases c LEFT JOIN visuels v ON v.id = c.visuel
               GROUP BY c.regne ORDER BY total DESC"""):
        print(f"  {r['regne']:<11} {r['total']:>7} cases | {r['repli'] or 0:>7} sur "
              f"la forme de repli | {r['sans'] or 0:>7} sans image")
    return 0


if __name__ == "__main__":
    sys.exit(main())
