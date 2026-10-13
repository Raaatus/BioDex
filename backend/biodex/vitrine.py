"""
La vitrine : un second rang, qui ne compte pas la même chose que le premier.

Le rang du dex mesure une **quantité** — combien d'espèces vous avez trouvées,
de la première à cinquante mille. C'est un bon compteur, mais il ne dit rien de
la difficulté : deux cents pigeons y valent deux cents raretés.

La vitrine mesure ce que vous avez rapporté de **mieux**. Son score est la somme
des points de vos dix plus belles trouvailles, et de celles-là seulement.

Ce plafond de dix est tout le mécanisme. Sans lui, le score suivrait le nombre
de trouvailles et l'on aurait peint deux fois la même jauge. Avec lui, la
onzième espèce commune n'apporte rien : seule une prise **meilleure** que la
dixième fait monter la vitrine. Un joueur à douze espèces dont trois légendaires
passe devant un joueur à deux cents banalités, ce qui est exactement ce qu'on
veut dire.

    barème des points, calculé par outils/qualites.py
    rareté 1  commun         5 pts
    rareté 2  basique       10
    rareté 3  peu commun    25
    rareté 4  rare          60
    rareté 5  légendaire   150

Le score va donc de 5 (une seule espèce, commune) à 1500 (dix légendaires). Les
cinquante paliers s'échelonnent linéairement entre les deux, à trente points
l'un — voir `_seuils`, qui explique pourquoi la progression géométrique du rang
du dex ne convenait pas ici.

Les noms sont ceux des paliers du dex — recyclés en attendant les leurs.
"""

# Combien de trouvailles comptent. Dix : assez pour qu'un coup de chance ne
# fasse pas le classement, assez peu pour que la quantité ne reprenne pas le
# dessus.
TAILLE = 10

# Ce qu'une seule espèce commune rapporte, et ce que dix légendaires
# rapporteraient. Bornes du barème, pas des objectifs.
PLANCHER = 5
PLAFOND = 150 * TAILLE


def _seuils(noms: list[str]) -> list[tuple[int, str]]:
    """Répartit les paliers linéairement entre le plancher et le plafond.

    J'avais d'abord pris une progression géométrique, comme pour le rang du
    dex. Mesurée sur la base réelle, elle était absurde :

        score                        géométrique   linéaire
        60    une seule espèce rare      rang 22    rang  2
        150   une seule légendaire       rang 30    rang  5
        425   la collection d'un joueur     rang 39    rang 14
        1500  dix légendaires            rang 50    rang 50

    Le plafond de la vitrine n'est que trois cents fois son plancher, là où le
    rang du dex couvre un facteur cinquante mille. Sur une plage aussi courte,
    une courbe géométrique tasse tout au début : une seule bonne prise mettait
    la vitrine à moitié pleine, et il ne restait plus rien à viser.

    Linéaire, chaque palier coûte trente points — l'équivalent d'une espèce peu
    commune de plus dans les dix. Son rang 14 se compare honnêtement à
    son rang 10 au dex : un peu devant, parce que ses prises sont bonnes.
    """
    n = len(noms)
    if n < 2:
        return [(PLANCHER, noms[0])] if noms else []
    paliers = []
    precedent = 0
    for i, nom in enumerate(noms):
        # `precedent + 1` empêche deux paliers de partager un seuil : deux
        # rangs consécutifs tomberaient sur le même entier et l'un des deux
        # serait inatteignable.
        seuil = max(precedent + 1,
                    round(PLANCHER + (PLAFOND - PLANCHER) * i / (n - 1)))
        paliers.append((seuil, nom))
        precedent = seuil
    return paliers


def score_sql(parametre: str = ":u") -> str:
    """Le score d'un joueur, en une requête.

    On trie ses trouvailles par points décroissants et on somme les dix
    premières. `LIMIT` dans une sous-requête plutôt qu'en Python : la liste
    complète d'un gros joueur n'a aucune raison de traverser le réseau pour
    qu'on n'en garde que dix.
    """
    return f"""
        SELECT COALESCE(SUM(points), 0) FROM (
            SELECT c.points AS points
              FROM decouvertes d JOIN cases c ON c.id = d.case_id
             WHERE d.utilisateur = {parametre}
             ORDER BY c.points DESC, c.id ASC
             LIMIT {TAILLE}
        )"""


def rang_de(score: int, noms: list[str]) -> dict:
    """Le rang atteint et celui qu'on vise, à la manière de `palier_de`."""
    paliers = _seuils(noms)
    atteint = suivant = None
    for i, (seuil, nom) in enumerate(paliers, 1):
        if score >= seuil:
            atteint = (i, seuil, nom)
        else:
            suivant = (i, seuil, nom)
            break

    if atteint is None:
        d = {"numero": 0, "nom": "Vitrine vide", "depuis": 0}
    else:
        d = {"numero": atteint[0], "nom": atteint[2], "depuis": atteint[1]}
    if suivant:
        d["suivant"] = suivant[2]
        d["objectif"] = suivant[1]
        d["reste"] = suivant[1] - score
    d["total_paliers"] = len(paliers)
    return d
