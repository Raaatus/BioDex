"""
La carte : où les bêtes ont été vues, par soi et par ses amis.

Les points viennent des captures géolocalisées. Le regroupement en bulles se
fait dans l'application, qui sait à quel niveau de zoom elle est ; le serveur se
contente de livrer les points d'une zone, avec de quoi les afficher.
"""
import json
import urllib.error
import urllib.parse
import urllib.request

from fastapi import APIRouter, Depends, HTTPException, Query

from .. import acces, db, situation
from ..dependances import utilisateur

routeur = APIRouter(tags=["carte"])

UA = {"User-Agent": "biodex/0.1 (dex local)"}

# Plafond de points renvoyés d'un coup. Au-delà, la carte devient illisible et
# la réponse pèse pour rien : on rend les plus récents.
PLAFOND = 2000


# Sous-requête d'amitié, écrite une fois : `c.utilisateur` est-il un ami de :u ?
_condition_ami = acces.amis()


@routeur.get("/carte")
def points(
    qui: str = Query(default="tous", pattern="^(moi|amis|tous)$"),
    espece: int | None = Query(default=None, description="limiter à une case du dex"),
    regne: str | None = Query(default=None, pattern="^(animal|plante|champignon)$",
                              description="n'afficher qu'un règne"),
    depuis: str | None = Query(default=None, description="date minimale, AAAA-MM-JJ"),
    nouvelles: bool = Query(default=False,
                            description="seulement les photos d'amis jamais ouvertes"),
    limite: int = Query(default=PLAFOND, ge=1, le=PLAFOND),
    u=Depends(utilisateur),
):
    """Les captures situées, prêtes à être posées sur la carte.

    Par défaut on voit les siennes et celles de ses amis. Une capture d'ami
    n'apparaît que si elle est partagée — c'est le même réglage qui commande le
    fil d'activité.
    """
    # Une photo que le moteur n'a pas su identifier, et que le joueur n'a pas
    # rattachée à une espèce, n'a rien à faire sur la carte : ce serait un point
    # qui ne dit rien.
    conditions = ["c.lat IS NOT NULL", "c.lon IS NOT NULL", "c.case_id IS NOT NULL"]
    params: dict = {"u": u["id"], "l": limite}

    # « Les miennes » comprend celles où un ami m'a identifié : j'y étais, la
    # bête est dans mon dex, elle doit être sur ma carte.
    if qui == "moi":
        conditions.append(acces.sienne())
    elif qui == "amis":
        conditions.append("c.utilisateur <> :u")
        conditions.append(_condition_ami)
        conditions.append("c.partage = 1")
    else:
        # Les miennes sans condition, celles des amis si elles sont partagées.
        conditions.append(
            f"({acces.sienne()} OR ({_condition_ami} AND c.partage = 1))")

    if espece is not None:
        conditions.append("c.case_id = :espece")
        params["espece"] = espece
    if regne:
        # Le règne se lit sur la case, pas sur la capture : c'est l'espèce
        # retenue qui compte, y compris quand le joueur l'a corrigée.
        conditions.append("""EXISTS (SELECT 1 FROM cases d
                                     WHERE d.id = c.case_id AND d.regne = :regne)""")
        params["regne"] = regne
    if depuis:
        conditions.append("COALESCE(c.prise_le, c.cree_le) >= :depuis")
        params["depuis"] = depuis
    # Ce que je n'ai pas encore ouvert chez les autres. Mes photos ne sont
    # jamais « nouvelles » : je les ai prises.
    deja_vue = "EXISTS (SELECT 1 FROM photos_vues v WHERE v.utilisateur = :u AND v.capture = c.id)"
    if nouvelles:
        conditions.append("c.utilisateur <> :u")
        conditions.append(f"NOT {deja_vue}")

    lignes = db.lit(
        f"""SELECT c.id, c.lat, c.lon, c.utilisateur, c.case_id, c.verdict,
                   c.prise_le, c.cree_le, c.lieu, c.decoupe, c.source_position, c.titre,
                   x.pseudo, x.avatar, d.latin, d.nom_fr, d.rarete, d.regne,
                   {deja_vue} AS vue
            FROM captures c
            JOIN utilisateurs x ON x.id = c.utilisateur
            LEFT JOIN cases d ON d.id = c.case_id
            WHERE {' AND '.join(conditions)}
            ORDER BY COALESCE(c.prise_le, c.cree_le) DESC
            LIMIT :l""",
        params)

    return {
        "points": [
            {
                "capture_id": r["id"],
                "lat": r["lat"],
                "lon": r["lon"],
                "utilisateur": r["utilisateur"],
                "pseudo": r["pseudo"],
                "avatar": f"/utilisateurs/{r['utilisateur']}/avatar" if r["avatar"] else None,
                "moi": r["utilisateur"] == u["id"],
                "case_id": r["case_id"],
                "nom": r["nom_fr"] or r["latin"] or r["verdict"],
                "latin": r["latin"] or "",
                "rarete": r["rarete"] or 3,
                "regne": r["regne"] or "animal",
                # Vue si je l'ai ouverte — ou si elle est à moi.
                "vue": bool(r["vue"]) or r["utilisateur"] == u["id"],
                # L'heure de prise de vue si on la connaît, sinon celle de
                # l'envoi : mieux vaut une date approchée que pas de date.
                "quand": r["prise_le"] or r["cree_le"],
                "heure_sure": bool(r["prise_le"]),
                "lieu": r["lieu"],
                "titre": r["titre"] or "",
                "position_manuelle": r["source_position"] == "manuel",
                "vignette": f"/captures/{r['id']}/vignette",
                "decoupe": f"/captures/{r['id']}/decoupe" if r["decoupe"] else None,
            }
            for r in lignes
        ]
    }



@routeur.get("/carte/orphelines")
def orphelines(u=Depends(utilisateur)):
    """Mes captures qui n'ont pas de position, ou pas d'heure.

    C'est la liste que l'application propose de compléter à la main : sans ça
    ces photos n'apparaîtraient jamais sur la carte.
    """
    lignes = db.lit(
        """SELECT c.id, c.verdict, c.cree_le, c.prise_le, c.lat, c.lon,
                  c.source_position, c.source_heure, c.decoupe,
                  d.latin, d.nom_fr
           FROM captures c
           LEFT JOIN cases d ON d.id = c.case_id
           WHERE c.utilisateur = ?
             AND ((c.lat IS NULL OR c.source_position IN ('', 'defaut')) OR (c.source_heure IN ('', 'defaut')))
           ORDER BY c.id DESC LIMIT 200""",
        (u["id"],))
    return {
        "captures": [
            {
                "capture_id": r["id"],
                "nom": r["nom_fr"] or r["latin"] or r["verdict"] or "Sans espèce",
                "cree_le": r["cree_le"],
                "prise_le": r["prise_le"],
                "lat": r["lat"],
                "lon": r["lon"],
                # « Sans » vaut aussi pour « rempli par défaut » : une photo de
                # la galerie à laquelle on a collé le lieu de l'envoi porte bien
                # des coordonnées, mais ce ne sont pas les siennes. C'est
                # justement elle qu'il faut proposer de situer.
                "sans_position": situation.lit_sans_position(r),
                "sans_heure": situation.lit_sans_heure(r),
                "vignette": f"/captures/{r['id']}/vignette",
                "decoupe": f"/captures/{r['id']}/decoupe" if r["decoupe"] else None,
            }
            for r in lignes
        ]
    }


@routeur.get("/geocodage")
def geocodage(q: str = Query(min_length=2, max_length=200), _=Depends(utilisateur)):
    """Cherche des coordonnées à partir d'une adresse, via Nominatim.

    La requête passe par le serveur plutôt que par le téléphone : Nominatim
    demande un agent identifiable et limite le débit, ce qui se tient mieux
    depuis un point unique que depuis chaque appareil.
    """
    url = ("https://nominatim.openstreetmap.org/search?format=jsonv2&limit=8&q="
           + urllib.parse.quote(q))
    try:
        with urllib.request.urlopen(
                urllib.request.Request(url, headers=UA), timeout=12) as r:
            resultats = json.load(r)
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        raise HTTPException(503, "Service d'adresses injoignable.") from e

    return {
        "lieux": [
            {
                "nom": x.get("display_name", ""),
                "lat": float(x["lat"]),
                "lon": float(x["lon"]),
            }
            for x in resultats
            if x.get("lat") and x.get("lon")
        ]
    }


@routeur.get("/geocodage/inverse")
def geocodage_inverse(lat: float = Query(ge=-90, le=90),
                      lon: float = Query(ge=-180, le=180),
                      _=Depends(utilisateur)):
    """Le nom du lieu correspondant à un point posé sur la carte."""
    url = (f"https://nominatim.openstreetmap.org/reverse?format=jsonv2&zoom=14"
           f"&lat={lat}&lon={lon}")
    try:
        with urllib.request.urlopen(
                urllib.request.Request(url, headers=UA), timeout=12) as r:
            d = json.load(r)
    except (urllib.error.URLError, TimeoutError, ValueError):
        # Un point sans nom reste un point valable : on ne bloque pas dessus.
        return {"nom": ""}
    return {"nom": d.get("display_name", "")}
