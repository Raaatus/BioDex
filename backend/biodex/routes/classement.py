"""
Points et classement.

Une case rapporte des points selon sa qualité, une fois — c'est la découverte
qui compte, pas le nombre de photos. Le classement se joue entre amis : à cette
échelle, un tableau mondial n'aurait aucun sens, alors qu'un ami qu'on dépasse
de dix points, si.
"""
from fastapi import APIRouter, Depends, HTTPException, Query

from .. import db
from ..dependances import utilisateur
from .dex import palier_de

routeur = APIRouter(tags=["classement"])

NOMS_QUALITE = {1: "commun", 2: "basique", 3: "peu commun", 4: "rare",
                5: "légendaire"}

# Somme des points des cases découvertes par un joueur donné.
_POINTS = """SELECT COALESCE(SUM(c.points), 0)
             FROM decouvertes d JOIN cases c ON c.id = d.case_id
             WHERE d.utilisateur = ?"""


def points_de(utilisateur_id: int) -> int:
    return db.valeur(_POINTS, (utilisateur_id,), 0)


def _detail(utilisateur_id: int) -> dict:
    """Le compte par qualité, pour montrer d'où viennent les points."""
    lignes = db.lit(
        """SELECT c.rarete, COUNT(*) AS n, SUM(c.points) AS pts
           FROM decouvertes d JOIN cases c ON c.id = d.case_id
           WHERE d.utilisateur = ?
           GROUP BY c.rarete ORDER BY c.rarete DESC""",
        (utilisateur_id,))
    return {
        "total": sum(r["pts"] for r in lignes),
        "cases": sum(r["n"] for r in lignes),
        "par_qualite": [
            {"qualite": r["rarete"], "nom": NOMS_QUALITE.get(r["rarete"], ""),
             "cases": r["n"], "points": r["pts"]}
            for r in lignes
        ],
    }


@routeur.get("/classement")
def classement(u=Depends(utilisateur)):
    """Le tableau des amis, moi compris, du plus de points au moins.

    Les égalités se départagent par le nombre d'espèces rares : à points égaux,
    celui qui a trouvé les plus belles bêtes passe devant.
    """
    # Points de réaction reçus, comptés à part : ils viennent des photos, pas
    # des espèces, et une même photo peut plaire à plusieurs amis.
    lignes = db.lit(
        """SELECT x.id, x.pseudo, x.avatar,
                  COALESCE(SUM(c.points), 0)                       AS points,
                  COUNT(c.id)                                      AS cases,
                  SUM(CASE WHEN c.rarete >= 4 THEN 1 ELSE 0 END)   AS belles,
                  SUM(CASE WHEN c.rarete = 5 THEN 1 ELSE 0 END)    AS legendaires
           FROM utilisateurs x
           LEFT JOIN decouvertes d ON d.utilisateur = x.id
           LEFT JOIN cases c ON c.id = d.case_id
           WHERE x.actif = 1 AND (
                 x.id = :u
              OR EXISTS (SELECT 1 FROM amities a
                         WHERE a.etat = 'acceptee'
                           AND ((a.demandeur = :u AND a.destinataire = x.id)
                             OR (a.destinataire = :u AND a.demandeur = x.id))))
           GROUP BY x.id""",
        {"u": u["id"]})

    from .reactions import points_recus

    joueurs = []
    for r in lignes:
        applaudissements = points_recus(r["id"])
        joueurs.append({
            "id": r["id"], "pseudo": r["pseudo"],
            "avatar": f"/utilisateurs/{r['id']}/avatar" if r["avatar"] else None,
            "moi": r["id"] == u["id"],
            "points": r["points"] + applaudissements,
            "points_especes": r["points"],
            "points_reactions": applaudissements,
            "cases": r["cases"], "belles": r["belles"] or 0,
            # Le rang du joueur, pour que le classement dise autre chose qu'un
            # total de points : « Fouineur » se compare mieux que « 340 ».
            "palier": palier_de(r["cases"]),
            "legendaires": r["legendaires"] or 0,
        })
    joueurs.sort(key=lambda j: (-j["points"], -j["belles"], -j["cases"], j["pseudo"]))
    for i, j in enumerate(joueurs, 1):
        j["rang"] = i
    return {"joueurs": joueurs}


@routeur.get("/classement/moi")
def mes_points(u=Depends(utilisateur)):
    """Mon total, le détail par qualité, et mon rang parmi mes amis."""
    from .reactions import points_recus

    d = _detail(u["id"])
    d["points_especes"] = d["total"]
    d["points_reactions"] = points_recus(u["id"])
    d["total"] += d["points_reactions"]
    tableau = classement(u)["joueurs"]
    d["rang"] = next((j["rang"] for j in tableau if j["moi"]), 1)
    d["sur"] = len(tableau)
    return d


@routeur.get("/classement/joueur/{joueur_id}")
def detail_joueur(joueur_id: int, u=Depends(utilisateur)):
    """La fiche d'un joueur du cercle : sa répartition par qualité et ses
    meilleures prises."""
    from .amis import sont_amis
    from .reactions import points_recus

    if joueur_id != u["id"] and not sont_amis(u["id"], joueur_id):
        raise HTTPException(403, "Vous n'êtes pas amis avec ce joueur.")

    j = db.lit_un("SELECT id, pseudo, avatar, cree_le FROM utilisateurs "
                  "WHERE id = ? AND actif = 1", (joueur_id,))
    if j is None:
        raise HTTPException(404, "Joueur introuvable.")

    d = _detail(joueur_id)
    d["points_especes"] = d["total"]
    d["points_reactions"] = points_recus(joueur_id)
    d["total"] += d["points_reactions"]

    # On complète les qualités absentes : un tableau à trous se lit mal.
    presentes = {q["qualite"] for q in d["par_qualite"]}
    for niveau in range(5, 0, -1):
        if niveau not in presentes:
            d["par_qualite"].append(
                {"qualite": niveau, "nom": NOMS_QUALITE[niveau],
                 "cases": 0, "points": 0})
    d["par_qualite"].sort(key=lambda q: -q["qualite"])

    meilleures = db.lit(
        """SELECT c.id AS case_id, c.latin, c.nom_fr, c.rarete, c.points,
                  dd.trouve_le, COALESCE(dd.vedette, dd.premiere) AS capture,
                  cap.decoupe
           FROM decouvertes dd
           JOIN cases c ON c.id = dd.case_id
           LEFT JOIN captures cap ON cap.id = COALESCE(dd.vedette, dd.premiere)
           WHERE dd.utilisateur = ?
           ORDER BY c.rarete DESC, c.points DESC, dd.trouve_le
           LIMIT 12""",
        (joueur_id,))

    return {
        "id": j["id"], "pseudo": j["pseudo"],
        "avatar": f"/utilisateurs/{j['id']}/avatar" if j["avatar"] else None,
        "moi": j["id"] == u["id"],
        "depuis": j["cree_le"],
        "photos": db.valeur("SELECT COUNT(*) FROM captures WHERE utilisateur = ?",
                            (joueur_id,), 0),
        **d,
        "meilleures": [
            {"case_id": r["case_id"], "nom": r["nom_fr"] or r["latin"],
             "latin": r["latin"], "qualite": r["rarete"], "points": r["points"],
             "trouve_le": r["trouve_le"],
             "vignette": f"/captures/{r['capture']}/vignette" if r["capture"] else None,
             "decoupe": f"/captures/{r['capture']}/decoupe" if r["decoupe"] else None}
            for r in meilleures
        ],
    }


@routeur.get("/classement/trouvailles")
def trouvailles(limite: int = Query(default=30, ge=1, le=100), u=Depends(utilisateur)):
    """Le palmarès des plus belles prises du cercle d'amis.

    Trié par qualité puis par ancienneté : la première personne à trouver une
    espèce garde la vedette dessus.
    """
    lignes = db.lit(
        """SELECT d.utilisateur, d.trouve_le, x.pseudo, c.id AS case_id,
                  c.latin, c.nom_fr, c.rarete, c.points,
                  COALESCE(d.vedette, d.premiere) AS capture,
                  cap.decoupe
           FROM decouvertes d
           JOIN utilisateurs x ON x.id = d.utilisateur
           JOIN cases c ON c.id = d.case_id
           LEFT JOIN captures cap ON cap.id = COALESCE(d.vedette, d.premiere)
           WHERE x.actif = 1 AND (
                 d.utilisateur = :u
              OR EXISTS (SELECT 1 FROM amities a
                         WHERE a.etat = 'acceptee'
                           AND ((a.demandeur = :u AND a.destinataire = d.utilisateur)
                             OR (a.destinataire = :u AND a.demandeur = d.utilisateur))))
           ORDER BY c.rarete DESC, c.points DESC, d.trouve_le
           LIMIT :l""",
        {"u": u["id"], "l": limite})

    return {
        "trouvailles": [
            {"case_id": r["case_id"], "nom": r["nom_fr"] or r["latin"],
             "latin": r["latin"], "qualite": r["rarete"], "points": r["points"],
             "pseudo": r["pseudo"], "moi": r["utilisateur"] == u["id"],
             "trouve_le": r["trouve_le"],
             "capture_id": r["capture"],
             "vignette": f"/captures/{r['capture']}/vignette" if r["capture"] else None,
             "decoupe": f"/captures/{r['capture']}/decoupe" if r["decoupe"] else None}
            for r in lignes
        ],
    }
