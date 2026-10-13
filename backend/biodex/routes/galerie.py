"""
La galerie : toutes les photos qu'on a le droit de voir, filtrables.

Les siennes sans restriction, celles des amis si elles sont partagées. Les
filtres se combinent librement — un ami sur une période, une zone de la carte
pour une espèce donnée — et rien n'est chargé d'avance : la galerie se déroule
par pages au fil du défilement, parce qu'à cinq mille photos on ne rapatrie pas
tout d'un coup.
"""
from fastapi import APIRouter, Depends, HTTPException, Query

from .. import acces, db, situation
from ..dependances import utilisateur

routeur = APIRouter(tags=["galerie"])

# Ce qu'on a le droit de voir : ses propres photos, et celles des amis qu'ils
# ont laissées partagées.
_VISIBLE = acces.visible()

# La date qui fait foi : celle de la prise de vue si on la connaît, sinon celle
# de l'envoi. C'est aussi l'ordre naturel de la galerie.
# Défini dans `acces` : la carte, la galerie et les succès doivent dire la
# même chose de la même photo.
_QUAND = acces.QUAND

TRIS = {
    "recent": f"{_QUAND} DESC, c.id DESC",
    "ancien": f"{_QUAND} ASC, c.id ASC",
    "espece": "COALESCE(d.nom_fr, d.latin) COLLATE NOCASE, " + _QUAND + " DESC",
    "qualite": "d.rarete DESC, " + _QUAND + " DESC",
    "auteur": "x.pseudo COLLATE NOCASE, " + _QUAND + " DESC",
    "lieu": "CASE WHEN c.lieu = '' THEN 1 ELSE 0 END, c.lieu COLLATE NOCASE, "
            + _QUAND + " DESC",
}


@routeur.get("/galerie")
def galerie(
    qui: str = Query(default="tous",
                     description="tous, moi, amis, ou l'identifiant d'un joueur"),
    depuis: str | None = Query(default=None, description="date minimale AAAA-MM-JJ"),
    jusqua: str | None = Query(default=None, description="date maximale AAAA-MM-JJ"),
    espece: int | None = Query(default=None, description="limiter à une case"),
    regne: str | None = Query(default=None, pattern="^(animal|plante|champignon)$",
                              description="n'afficher qu'un règne"),
    qualite: int | None = Query(default=None, ge=1, le=5),
    lieu: str | None = Query(default=None, max_length=120,
                             description="fragment du nom de lieu"),
    # Zone rectangulaire, telle que la carte peut la fournir.
    lat_min: float | None = Query(default=None, ge=-90, le=90),
    lat_max: float | None = Query(default=None, ge=-90, le=90),
    lon_min: float | None = Query(default=None, ge=-180, le=180),
    lon_max: float | None = Query(default=None, ge=-180, le=180),
    situees: bool | None = Query(
        default=None,
        description="false : les photos sans position, ou posées par défaut"),
    datees: bool | None = Query(
        default=None,
        description="false : les photos sans date réelle"),
    favoris: bool = Query(default=False),
    tri: str = Query(default="recent"),
    limite: int = Query(default=60, ge=1, le=200),
    decalage: int = Query(default=0, ge=0),
    u=Depends(utilisateur),
):
    """Une page de la galerie. Tous les filtres se combinent."""
    if tri not in TRIS:
        raise HTTPException(400, f"Tri inconnu. Au choix : {', '.join(TRIS)}.")

    # Même règle que la carte : sans espèce rattachée, la photo n'entre pas
    # dans la galerie. Elle reste consultable dans « Mes photos », le temps que
    # le joueur la corrige ou la laisse partir.
    conditions = [_VISIBLE, "c.case_id IS NOT NULL"]
    params: dict = {"u": u["id"], "l": limite, "o": decalage}

    # « Moi » vaut aussi pour les photos où l'on m'a identifié : j'étais là.
    if qui == "moi":
        conditions.append(acces.sienne())
    elif qui == "amis":
        conditions.append("c.utilisateur <> :u")
    elif qui != "tous":
        # Une liste d'identifiants séparés par des virgules : « 3 » comme avant,
        # « 3,7,12 » pour trois amis à la fois. Choisir ses amis un par un
        # obligeait à refaire le tour de la galerie pour chacun, alors que ce
        # qu'on veut voir c'est la sortie de dimanche — celle qu'on a faite à
        # quatre.
        try:
            ids = [int(x) for x in qui.split(",") if x.strip()]
        except ValueError as e:
            raise HTTPException(400, "Filtre « qui » invalide.") from e
        if not ids:
            raise HTTPException(400, "Filtre « qui » vide.")
        # Borné : la clause est construite par formatage, et une liste sans fin
        # ferait une requête sans fin.
        ids = ids[:40]
        marques = ",".join(f":a{i}" for i in range(len(ids)))
        params |= {f"a{i}": v for i, v in enumerate(ids)}
        conditions.append(f"c.utilisateur IN ({marques})")

    if depuis:
        conditions.append(f"{_QUAND} >= :depuis")
        params["depuis"] = depuis
    if jusqua:
        # On complète la journée, sinon « jusqu'au 16 » exclurait le 16.
        conditions.append(f"{_QUAND} <= :jusqua")
        params["jusqua"] = f"{jusqua} 23:59:59"
    if espece is not None:
        conditions.append("c.case_id = :espece")
        params["espece"] = espece
    if regne:
        # « d » est déjà la case jointe : le règne s'y lit directement.
        conditions.append("d.regne = :regne")
        params["regne"] = regne
    if qualite is not None:
        conditions.append("d.rarete = :qualite")
        params["qualite"] = qualite
    if lieu:
        conditions.append("c.lieu LIKE :lieu")
        params["lieu"] = f"%{lieu}%"
    # `situees=false` doit ramener ce que la carte signale comme mal placé, pas
    # seulement ce qui n'a aucune coordonnée : les positions par défaut sont
    # justement celles qu'on cherche à corriger.
    if situees is True:
        conditions.append(f"NOT {situation.sans_position()}")
    elif situees is False:
        conditions.append(situation.sans_position())
    if datees is True:
        conditions.append(f"NOT {situation.sans_heure()}")
    elif datees is False:
        conditions.append(situation.sans_heure())
    # Zone rectangulaire : chaque borne est facultative, on n'ajoute que celles
    # qui sont fournies.
    for nom, valeur, expression in (
            ("lat_min", lat_min, "c.lat >= :lat_min"),
            ("lat_max", lat_max, "c.lat <= :lat_max"),
            ("lon_min", lon_min, "c.lon >= :lon_min"),
            ("lon_max", lon_max, "c.lon <= :lon_max")):
        if valeur is not None:
            conditions.append(expression)
            params[nom] = valeur
    if favoris:
        conditions.append(
            "EXISTS (SELECT 1 FROM favoris f WHERE f.capture = c.id AND f.utilisateur = :u)")

    where = " AND ".join(conditions)
    lignes = db.lit(
        f"""SELECT c.id, c.utilisateur, c.etat, c.verdict, c.case_id, c.decoupe,
                   c.lat, c.lon, c.lieu, c.prise_le, c.cree_le, c.corrigee,
                   c.source_position, c.source_heure, c.titre,
                   {_QUAND} AS quand,
                   x.pseudo, x.avatar,
                   d.latin, d.nom_fr, d.rarete,
                   EXISTS (SELECT 1 FROM favoris f
                           WHERE f.capture = c.id AND f.utilisateur = :u) AS favori
            FROM captures c
            JOIN utilisateurs x ON x.id = c.utilisateur
            LEFT JOIN cases d ON d.id = c.case_id
            WHERE {where}
            ORDER BY {TRIS[tri]}
            LIMIT :l OFFSET :o""",
        params)

    from .reactions import resume_pour
    resumes = resume_pour([r["id"] for r in lignes], u["id"])

    return {
        "photos": [
            {
                "capture_id": r["id"],
                "utilisateur": r["utilisateur"],
                "pseudo": r["pseudo"],
                "avatar": f"/utilisateurs/{r['utilisateur']}/avatar" if r["avatar"] else None,
                "moi": r["utilisateur"] == u["id"],
                "etat": r["etat"],
                "case_id": r["case_id"],
                "nom": r["nom_fr"] or r["latin"] or r["verdict"] or "Sans espèce",
                "latin": r["latin"] or "",
                "qualite": r["rarete"] or 0,
                "quand": r["quand"],
                "heure_sure": not situation.lit_sans_heure(r),
                # Ce que l'écran doit pouvoir montrer photo par photo. Sans
                # ces deux drapeaux, la galerie affichait le même carré pour
                # une photo bien située et pour une photo posée au hasard.
                "sans_position": situation.lit_sans_position(r),
                "sans_heure": situation.lit_sans_heure(r),
                "lat": r["lat"], "lon": r["lon"], "lieu": r["lieu"],
                "corrigee": bool(r["corrigee"]),
                "titre": r["titre"] or "",
                "favori": bool(r["favori"]),
                "photo": f"/captures/{r['id']}/photo",
                "vignette": f"/captures/{r['id']}/vignette",
                "decoupe": f"/captures/{r['id']}/decoupe" if r["decoupe"] else None,
                "reactions": resumes.get(r["id"], {}),
            }
            for r in lignes
        ],
        "decalage": decalage,
        "limite": limite,
        # Une page incomplète signale la fin : ça évite un COUNT(*) sur toute la
        # table à chaque appel.
        "fin": len(lignes) < limite,
    }


@routeur.get("/galerie/reperes")
def reperes(u=Depends(utilisateur)):
    """De quoi remplir les menus de filtres : qui a des photos, quels lieux,
    quelles espèces, et sur quelle période."""
    auteurs = db.lit(
        f"""SELECT c.utilisateur AS id, x.pseudo, x.avatar, COUNT(*) AS photos
            FROM captures c JOIN utilisateurs x ON x.id = c.utilisateur
            WHERE {_VISIBLE} GROUP BY c.utilisateur ORDER BY photos DESC""",
        {"u": u["id"]})
    lieux = db.lit(
        f"""SELECT c.lieu, COUNT(*) AS photos FROM captures c
            WHERE {_VISIBLE} AND c.lieu <> ''
            GROUP BY c.lieu ORDER BY photos DESC LIMIT 40""",
        {"u": u["id"]})
    especes = db.lit(
        f"""SELECT c.case_id, COALESCE(d.nom_fr, d.latin) AS nom, d.rarete,
                   COUNT(*) AS photos
            FROM captures c JOIN cases d ON d.id = c.case_id
            WHERE {_VISIBLE} GROUP BY c.case_id ORDER BY photos DESC LIMIT 60""",
        {"u": u["id"]})
    bornes = db.lit_un(
        f"""SELECT MIN({_QUAND}) AS debut, MAX({_QUAND}) AS fin,
                   COUNT(*) AS total,
                   SUM(CASE WHEN NOT (c.lat IS NULL OR c.source_position IN ('', 'defaut')) THEN 1 ELSE 0 END) AS situees,
                   SUM(CASE WHEN NOT (c.source_heure IN ('', 'defaut')) THEN 1 ELSE 0 END) AS datees
            FROM captures c WHERE {_VISIBLE}""",
        {"u": u["id"]})

    return {
        "auteurs": [
            {"id": r["id"], "pseudo": r["pseudo"], "photos": r["photos"],
             "avatar": f"/utilisateurs/{r['id']}/avatar" if r["avatar"] else None,
             "moi": r["id"] == u["id"]}
            for r in auteurs
        ],
        "lieux": [{"lieu": r["lieu"], "photos": r["photos"]} for r in lieux],
        "especes": [
            {"case_id": r["case_id"], "nom": r["nom"], "qualite": r["rarete"],
             "photos": r["photos"]}
            for r in especes
        ],
        "debut": bornes["debut"], "fin": bornes["fin"],
        "total": bornes["total"], "situees": bornes["situees"] or 0,
        "datees": bornes["datees"] or 0,
        "favoris": db.valeur("SELECT COUNT(*) FROM favoris WHERE utilisateur = ?",
                             (u["id"],), 0),
    }


# ------------------------------------------------------------------- favoris

def _visible_pour(capture_id: int, uid: int) -> bool:
    return db.lit_un(
        f"SELECT 1 FROM captures c WHERE c.id = :id AND {_VISIBLE}",
        {"id": capture_id, "u": uid}) is not None


@routeur.put("/captures/{capture_id}/favori", status_code=204)
def ajoute_favori(capture_id: int, u=Depends(utilisateur)):
    if not _visible_pour(capture_id, u["id"]):
        raise HTTPException(404, "Photo introuvable.")
    db.ecrit("""INSERT INTO favoris (utilisateur, capture) VALUES (?,?)
                ON CONFLICT(utilisateur, capture) DO NOTHING""",
             (u["id"], capture_id))


@routeur.delete("/captures/{capture_id}/favori", status_code=204)
def retire_favori(capture_id: int, u=Depends(utilisateur)):
    db.ecrit("DELETE FROM favoris WHERE utilisateur = ? AND capture = ?",
             (u["id"], capture_id))
