"""Inscription, connexion, profil."""
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field

from .. import auth, db
from ..dependances import utilisateur

routeur = APIRouter(tags=["comptes"])


class Identifiants(BaseModel):
    pseudo: str = Field(min_length=1, max_length=64)
    mdp: str = Field(min_length=1, max_length=256)
    appareil: str = ""


class ChangementMdp(BaseModel):
    ancien: str
    nouveau: str


class Profil(BaseModel):
    bio: str = Field(default="", max_length=280)


class ClePlantnet(BaseModel):
    # Les clés Pl@ntNet font une trentaine de caractères ; on laisse de la marge
    # sans pour autant accepter n'importe quel contenu.
    cle: str = Field(default="", max_length=120)


def _resume(uid: int) -> dict:
    """Compteurs affichés sur l'écran de profil."""
    r = db.lit_un(
        """SELECT
             (SELECT COUNT(*) FROM decouvertes WHERE utilisateur = :u)              AS cases,
             (SELECT COUNT(*) FROM captures WHERE utilisateur = :u)                 AS captures,
             (SELECT COUNT(*) FROM amities
                WHERE etat = 'acceptee' AND (:u IN (demandeur, destinataire)))       AS amis,
             (SELECT COUNT(*) FROM amities
                WHERE etat = 'attente' AND destinataire = :u)                        AS demandes,
             (SELECT COALESCE(SUM(c.points), 0) FROM decouvertes d
                JOIN cases c ON c.id = d.case_id WHERE d.utilisateur = :u)           AS points""",
        {"u": uid})
    return dict(r)


def _sortie(u, jeton: str | None = None, expire: str | None = None) -> dict:
    d = {
        "id": u["id"], "pseudo": u["pseudo"], "bio": u["bio"],
        "avatar": f"/utilisateurs/{u['id']}/avatar" if u["avatar"] else None,
        "cree_le": u["cree_le"], **_resume(u["id"]),
    }
    # La clé Pl@ntNet ne ressort jamais en clair : l'app a seulement besoin de
    # savoir s'il y en a une, et de quoi la reconnaître pour rassurer le joueur
    # sur celle qu'il a saisie.
    cle = u["cle_plantnet"] if "cle_plantnet" in u.keys() else ""
    d["plantnet"] = {"active": bool(cle),
                     "apercu": f"…{cle[-4:]}" if len(cle) >= 4 else ""}
    if jeton:
        d["jeton"] = jeton
        d["expire_le"] = expire
    return d


@routeur.post("/inscription", status_code=201)
def inscription(corps: Identifiants):
    """Crée un compte. Aucune adresse mail : le pseudo et le mot de passe
    suffisent, et il n'existe donc aucune procédure de récupération."""
    try:
        uid, jeton, expire = auth.inscrit(corps.pseudo, corps.mdp, corps.appareil)
    except auth.ErreurAuth as e:
        raise HTTPException(e.code, e.message) from e
    u = db.lit_un("SELECT * FROM utilisateurs WHERE id = ?", (uid,))
    return _sortie(u, jeton, expire)


@routeur.post("/connexion")
def connexion(corps: Identifiants):
    try:
        uid, jeton, expire = auth.connecte(corps.pseudo, corps.mdp, corps.appareil)
    except auth.ErreurAuth as e:
        raise HTTPException(e.code, e.message) from e
    u = db.lit_un("SELECT * FROM utilisateurs WHERE id = ?", (uid,))
    return _sortie(u, jeton, expire)


@routeur.post("/deconnexion", status_code=204)
def deconnexion(authorization: str | None = Header(default=None),
                _=Depends(utilisateur)):
    if authorization:
        auth.ferme_session(authorization.split(None, 1)[-1].strip())


@routeur.get("/moi")
def moi(u=Depends(utilisateur)):
    return _sortie(u)


@routeur.patch("/moi")
def modifie_profil(corps: Profil, u=Depends(utilisateur)):
    db.ecrit("UPDATE utilisateurs SET bio = ? WHERE id = ?", (corps.bio, u["id"]))
    return _sortie(db.lit_un("SELECT * FROM utilisateurs WHERE id = ?", (u["id"],)))


@routeur.put("/moi/plantnet")
def enregistre_cle_plantnet(corps: ClePlantnet, u=Depends(utilisateur)):
    """Enregistre la clé Pl@ntNet du joueur.

    Elle est personnelle parce que le quota gratuit l'est aussi : 500
    identifications par jour et par clé. Une clé partagée entre tous les joueurs
    serait épuisée en une après-midi, et plus personne ne pourrait identifier
    de plante. Sans clé, les plantes passent directement par BioCLIP.
    """
    cle = corps.cle.strip()
    db.ecrit("UPDATE utilisateurs SET cle_plantnet = ? WHERE id = ?", (cle, u["id"]))
    return _sortie(db.lit_un("SELECT * FROM utilisateurs WHERE id = ?", (u["id"],)))


@routeur.delete("/moi/plantnet", status_code=204)
def retire_cle_plantnet(u=Depends(utilisateur)):
    db.ecrit("UPDATE utilisateurs SET cle_plantnet = '' WHERE id = ?", (u["id"],))


@routeur.post("/moi/mot-de-passe", status_code=204)
def change_mdp(corps: ChangementMdp, u=Depends(utilisateur)):
    """Change le mot de passe et invalide toutes les sessions, y compris
    celle-ci : il faut se reconnecter."""
    try:
        auth.change_mdp(u["id"], corps.ancien, corps.nouveau)
    except auth.ErreurAuth as e:
        raise HTTPException(e.code, e.message) from e
