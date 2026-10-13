"""
Réactions sur les photos des amis.

Cinq degrés, de l'indifférence à l'admiration, et chacun vaut des points pour
celui qui a pris la photo. Une seule réaction par personne et par photo, qu'on
peut changer : on a le droit de se raviser, pas de voter deux fois.
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import db
from ..dependances import utilisateur
from .amis import sont_amis

routeur = APIRouter(tags=["reactions"])

# (valeur, emoji, nom, points). L'échelle monte de trois en trois : « bof » ne
# rapporte rien, ce qui laisse la possibilité de dire poliment que ce n'est pas
# la photo du siècle.
REACTIONS = [
    (0, "😐", "Bof", 0),
    (1, "🙂", "Sympa", 3),
    (2, "😮", "Beau", 6),
    (3, "🤩", "Superbe", 9),
    (4, "🏆", "Incroyable", 12),
]

POINTS = {v: p for v, _, _, p in REACTIONS}
EMOJIS = {v: e for v, e, _, _ in REACTIONS}
NOMS = {v: n for v, _, n, _ in REACTIONS}


class Choix(BaseModel):
    valeur: int = Field(ge=0, le=4)


def points_recus(utilisateur_id: int) -> int:
    """Points gagnés grâce aux réactions des amis sur ses photos."""
    return db.valeur(
        """SELECT COALESCE(SUM(CASE r.valeur
                  WHEN 1 THEN 3 WHEN 2 THEN 6 WHEN 3 THEN 9 WHEN 4 THEN 12
                  ELSE 0 END), 0)
           FROM reactions r JOIN captures c ON c.id = r.capture
           WHERE c.utilisateur = ?""",
        (utilisateur_id,), 0)


def resume_pour(capture_ids: list[int], moi: int) -> dict[int, dict]:
    """Pour chaque capture : le compte par réaction, le total de points, et ce
    que j'ai moi-même mis."""
    if not capture_ids:
        return {}
    marques = ",".join("?" * len(capture_ids))
    lignes = db.lit(
        f"""SELECT capture, valeur, COUNT(*) AS n,
                   SUM(CASE WHEN auteur = ? THEN 1 ELSE 0 END) AS mienne
            FROM reactions WHERE capture IN ({marques})
            GROUP BY capture, valeur""",
        [moi, *capture_ids])

    sortie: dict[int, dict] = {
        c: {"compte": {}, "points": 0, "total": 0, "ma_reaction": None}
        for c in capture_ids
    }
    for r in lignes:
        d = sortie[r["capture"]]
        d["compte"][r["valeur"]] = r["n"]
        d["points"] += POINTS[r["valeur"]] * r["n"]
        d["total"] += r["n"]
        if r["mienne"]:
            d["ma_reaction"] = r["valeur"]
    return sortie


@routeur.get("/reactions")
def catalogue():
    """La liste des réactions possibles, pour que l'app n'ait pas à la coder."""
    return {"reactions": [
        {"valeur": v, "emoji": e, "nom": n, "points": p} for v, e, n, p in REACTIONS
    ]}


@routeur.put("/captures/{capture_id}/reaction")
def reagit(capture_id: int, corps: Choix, u=Depends(utilisateur)):
    """Poser ou changer sa réaction sur la photo d'un ami."""
    c = db.lit_un("SELECT utilisateur, partage FROM captures WHERE id = ?",
                  (capture_id,))
    if c is None:
        raise HTTPException(404, "Capture introuvable.")
    if c["utilisateur"] == u["id"]:
        raise HTTPException(400, "On ne réagit pas à ses propres photos.")
    if not c["partage"] or not sont_amis(u["id"], c["utilisateur"]):
        raise HTTPException(403, "Cette photo ne vous est pas accessible.")

    db.ecrit(
        """INSERT INTO reactions (capture, auteur, valeur) VALUES (?,?,?)
           ON CONFLICT(capture, auteur) DO UPDATE SET
               valeur = excluded.valeur, cree_le = datetime('now')""",
        (capture_id, u["id"], corps.valeur))

    from .notifications import previens
    previens(c["utilisateur"], u["id"], "reaction", capture_id, corps.valeur)
    return resume_pour([capture_id], u["id"])[capture_id]


@routeur.delete("/captures/{capture_id}/reaction", status_code=204)
def retire(capture_id: int, u=Depends(utilisateur)):
    db.ecrit("DELETE FROM reactions WHERE capture = ? AND auteur = ?",
             (capture_id, u["id"]))
    # La notification n'a plus lieu d'être : on ne laisse pas un badge derrière
    # une réaction annulée.
    proprietaire = db.valeur("SELECT utilisateur FROM captures WHERE id = ?",
                             (capture_id,))
    if proprietaire is not None:
        from .notifications import oublie
        oublie(proprietaire, u["id"], capture_id, "reaction")


@routeur.get("/captures/{capture_id}/reactions")
def detail(capture_id: int, u=Depends(utilisateur)):
    """Qui a réagi quoi. Réservé aux personnes qui voient déjà la photo."""
    c = db.lit_un("SELECT utilisateur, partage FROM captures WHERE id = ?",
                  (capture_id,))
    if c is None:
        raise HTTPException(404, "Capture introuvable.")
    if c["utilisateur"] != u["id"] and not (
            c["partage"] and sont_amis(u["id"], c["utilisateur"])):
        raise HTTPException(403, "Cette photo ne vous est pas accessible.")

    lignes = db.lit(
        """SELECT r.valeur, r.cree_le, x.pseudo, x.id, x.avatar
           FROM reactions r JOIN utilisateurs x ON x.id = r.auteur
           WHERE r.capture = ? ORDER BY r.valeur DESC, r.cree_le""",
        (capture_id,))
    return {
        **resume_pour([capture_id], u["id"])[capture_id],
        "detail": [
            {"utilisateur": r["id"], "pseudo": r["pseudo"],
             "avatar": f"/utilisateurs/{r['id']}/avatar" if r["avatar"] else None,
             "valeur": r["valeur"], "emoji": EMOJIS[r["valeur"]],
             "nom": NOMS[r["valeur"]], "points": POINTS[r["valeur"]]}
            for r in lignes
        ],
    }
