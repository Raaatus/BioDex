"""
Les espèces que les joueurs ajoutent eux-mêmes.

Le moteur ne connaît que ce que GBIF lui a appris. Devant une roseraie, il rend
« Rosa gallica » pour tous les cultivars — « Sophie Vartan », « Peace » — parce
que ces plantes n'existent pas dans son catalogue, et n'y existeront pas : un
cultivar n'est pas un taxon.

Ces routes ouvrent une porte : **on ajoute à la base, jamais au modèle.** La
case apparaît au dex, tout le monde la voit, on peut y ranger ses photos à la
main — mais aucune analyse ne la proposera jamais. C'est une distinction qui
tient tout le reste : le moteur reste ce qu'il est, et le dex devient ce que les
joueurs en font.

La confiance est le second principe. Personne ne valide, personne ne modère. En
échange, l'auteur peut retirer ce qu'il a ajouté, et la case porte son nom :
qui a écrit quoi est toujours visible.
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import db, wikitaxon
from ..dependances import utilisateur
from .notifications import previens

routeur = APIRouter(tags=["especes"])

REGNES = ("animal", "plante", "champignon")

# Les clés GBIF des espèces des joueurs. Très bas, et à part : les orphelins du
# backbone descendent jusqu'à environ -3 000 000, et les faire se croiser
# donnerait une collision silencieuse sur une contrainte d'unicité.
BASE_CLE = -100_000_000

# Une case ajoutée à la main n'a aucune observation GBIF, donc aucune rareté
# calculable. On la place au milieu — « peu commun », 25 points. La donner pour
# légendaire serait un cadeau, pour commune une punition, et rien ne permet de
# trancher.
RARETE = 3
POINTS = 25

LONGUEUR_MAX = 4000


class Proposition(BaseModel):
    nom: str = Field(min_length=2, max_length=120)
    regne: str = "plante"
    latin: str = Field(default="", max_length=160)
    description: str = Field(default="", max_length=LONGUEUR_MAX)
    wikipedia: str = Field(default="", max_length=500)
    # La case dont celle-ci est une variante, quand le joueur le sait : c'est
    # elle qui donne le genre et la famille, faute de backbone.
    parente: int | None = None


class Retouche(BaseModel):
    nom: str | None = Field(default=None, min_length=2, max_length=120)
    description: str | None = Field(default=None, max_length=LONGUEUR_MAX)
    wikipedia: str | None = Field(default=None, max_length=500)


_SELECT = """
    SELECT c.id, c.latin, c.nom_fr, c.regne, c.genre, c.famille, c.actif,
           c.ajoute_par, u.pseudo, f.resume, f.url,
           (SELECT COUNT(*) FROM captures x WHERE x.case_id = c.id) AS captures
      FROM cases c
      LEFT JOIN utilisateurs u ON u.id = c.ajoute_par
      LEFT JOIN fiches f ON f.case_id = c.id
"""


def _sortie(r) -> dict:
    return {
        "id": r["id"],
        "latin": r["latin"],
        "nom": r["nom_fr"] or r["latin"],
        "regne": r["regne"],
        "genre": r["genre"],
        "famille": r["famille"],
        "actif": bool(r["actif"]),
        "ajoute_par": r["ajoute_par"],
        "ajoute_par_pseudo": r["pseudo"],
        "resume": r["resume"] or "",
        "wikipedia": r["url"] or "",
        "captures": r["captures"],
    }


@routeur.get("/especes/apercu")
def apercu(lien: str, u=Depends(utilisateur)):
    """Ce qu'un lien Wikipédia donnerait, sans rien créer.

    Le formulaire s'en sert pour se pré-remplir sous les yeux du joueur : il
    voit ce qui a été trouvé, et corrige avant de valider. Coller un lien ne
    doit jamais créer quelque chose qu'on n'a pas relu.
    """
    del u
    try:
        return wikitaxon.resout(lien)
    except wikitaxon.Introuvable as e:
        raise HTTPException(404, str(e)) from e


@routeur.post("/especes", status_code=201)
def ajoute_espece(p: Proposition, u=Depends(utilisateur)):
    if p.regne not in REGNES:
        raise HTTPException(400, f"Règne inconnu : {p.regne!r}.")

    fiche = None
    if p.wikipedia.strip():
        try:
            fiche = wikitaxon.resout(p.wikipedia)
        except wikitaxon.Introuvable as e:
            raise HTTPException(400, str(e)) from e

    nom = p.nom.strip()
    # Le binôme vient de Wikidata s'il en a un, sinon du joueur, sinon c'est le
    # nom lui-même. Une case doit toujours avoir un `latin` : c'est par lui que
    # passent les alias et les recherches.
    latin = p.latin.strip() or (fiche or {}).get("latin") or nom

    if db.valeur("SELECT COUNT(*) FROM cases WHERE latin = ? AND regne = ?",
                 (latin, p.regne), 0):
        raise HTTPException(409, f"« {latin} » existe déjà au dex.")

    genre = famille = ""
    if p.parente is not None:
        mere = db.lit_un("SELECT genre, famille FROM cases WHERE id = ?",
                         (p.parente,))
        if mere is None:
            raise HTTPException(404, "Espèce parente introuvable.")
        genre, famille = mere["genre"], mere["famille"]
    elif " " in latin:
        # À défaut de parenté déclarée, le premier mot d'un binôme est le genre.
        # C'est une convention, pas une vérité : d'où le repli silencieux.
        genre = latin.split(" ")[0]

    description = p.description.strip() or (fiche or {}).get("resume") or ""

    with db.transaction() as cx:
        # La clé se calcule dans la transaction : deux joueurs qui ajoutent en
        # même temps prendraient sinon la même.
        basse = cx.execute(
            "SELECT MIN(cle_gbif) FROM cases WHERE cle_gbif <= ?",
            (BASE_CLE,)).fetchone()[0]
        cle = (basse - 1) if basse is not None else BASE_CLE

        cx.execute(
            """INSERT INTO cases (cle_gbif, regne, latin, nom_fr, genre, famille,
                                  obs, rarete, points, nb_alias, ajoute_par, actif)
               VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, 1, ?, 1)""",
            (cle, p.regne, latin, nom if nom != latin else None, genre, famille,
             RARETE, POINTS, u["id"]))
        case_id = cx.execute("SELECT id FROM cases WHERE cle_gbif = ?",
                             (cle,)).fetchone()[0]
        cx.execute(
            "INSERT INTO alias (latin, regne, case_id, accepte) VALUES (?, ?, ?, 1)",
            (latin, p.regne, case_id))
        if description or fiche:
            cx.execute(
                """INSERT INTO fiches (case_id, titre, resume, url, image, langue)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (case_id, (fiche or {}).get("titre") or nom, description,
                 (fiche or {}).get("url") or "",
                 (fiche or {}).get("image") or "",
                 (fiche or {}).get("langue") or "fr"))

    _previens_les_amis(u, case_id)
    return _lit(case_id)


@routeur.get("/especes/miennes")
def les_miennes(u=Depends(utilisateur)):
    """Ce que j'ai indexé, actif ou non.

    Les désactivées restent listées : c'est le seul endroit d'où on peut les
    remettre en service, et les faire disparaître donnerait l'impression
    qu'elles sont perdues.
    """
    lignes = db.lit(
        _SELECT + " WHERE c.ajoute_par = ? ORDER BY c.actif DESC, c.id DESC",
        (u["id"],))
    return {"especes": [_sortie(r) for r in lignes]}


@routeur.patch("/especes/{case_id}")
def modifie(case_id: int, r: Retouche, u=Depends(utilisateur)):
    _mienne(case_id, u)

    fiche = None
    if r.wikipedia is not None and r.wikipedia.strip():
        try:
            fiche = wikitaxon.resout(r.wikipedia)
        except wikitaxon.Introuvable as e:
            raise HTTPException(400, str(e)) from e

    with db.transaction() as cx:
        if r.nom is not None:
            cx.execute("UPDATE cases SET nom_fr = ? WHERE id = ?",
                       (r.nom.strip(), case_id))
        if r.description is not None or fiche is not None:
            if not cx.execute("SELECT 1 FROM fiches WHERE case_id = ?",
                              (case_id,)).fetchone():
                cx.execute("INSERT INTO fiches (case_id) VALUES (?)", (case_id,))
            if r.description is not None:
                cx.execute(
                    "UPDATE fiches SET resume = ?, maj_le = datetime('now') "
                    "WHERE case_id = ?", (r.description.strip(), case_id))
            if fiche is not None:
                cx.execute(
                    """UPDATE fiches SET titre = ?, url = ?, image = ?,
                                         langue = ?, maj_le = datetime('now')
                       WHERE case_id = ?""",
                    (fiche["titre"], fiche["url"], fiche["image"] or "",
                     fiche["langue"], case_id))
                # Le résumé de Wikipédia ne remplace une description écrite à la
                # main que si le joueur n'en a pas fourni dans le même geste.
                if r.description is None and fiche["resume"]:
                    cx.execute("UPDATE fiches SET resume = ? WHERE case_id = ?",
                               (fiche["resume"], case_id))
    return _lit(case_id)


@routeur.delete("/especes/{case_id}")
def retire(case_id: int, u=Depends(utilisateur)):
    """Retirer une espèce qu'on a ajoutée.

    Deux comportements, et le choix ne nous appartient pas :

    - **personne n'y a rangé de photo** : la case part pour de bon, avec son
      alias et sa fiche. Rien ne la retenait.
    - **des captures s'y trouvent** : on la désactive. Elle disparaît du dex et
      des recherches, mais les photos restent où elles sont. Supprimer la case
      les rendrait orphelines — et elles appartiennent peut-être à quelqu'un
      d'autre, qui n'a rien demandé.
    """
    _mienne(case_id, u)
    utilisees = db.valeur(
        "SELECT COUNT(*) FROM captures WHERE case_id = ?", (case_id,), 0)
    with db.transaction() as cx:
        if utilisees:
            cx.execute("UPDATE cases SET actif = 0 WHERE id = ?", (case_id,))
        else:
            cx.execute("DELETE FROM fiches WHERE case_id = ?", (case_id,))
            cx.execute("DELETE FROM alias WHERE case_id = ?", (case_id,))
            cx.execute("DELETE FROM cases WHERE id = ?", (case_id,))
    return {"supprimee": not utilisees, "desactivee": bool(utilisees),
            "captures": utilisees}


@routeur.post("/especes/{case_id}/reactive")
def reactive(case_id: int, u=Depends(utilisateur)):
    _mienne(case_id, u, actives_seulement=False)
    db.ecrit("UPDATE cases SET actif = 1 WHERE id = ?", (case_id,))
    return _lit(case_id)


# ------------------------------------------------------------------ interne

def _lit(case_id: int) -> dict:
    r = db.lit_un(_SELECT + " WHERE c.id = ?", (case_id,))
    if r is None:
        raise HTTPException(404, "Espèce introuvable.")
    return _sortie(r)


def _mienne(case_id: int, u, actives_seulement: bool = True):
    r = db.lit_un("SELECT id, ajoute_par, actif FROM cases WHERE id = ?",
                  (case_id,))
    if r is None:
        raise HTTPException(404, "Espèce introuvable.")
    if r["ajoute_par"] is None:
        raise HTTPException(
            403, "Cette espèce vient de GBIF : elle n'appartient à personne.")
    if r["ajoute_par"] != u["id"]:
        raise HTTPException(403, "Seul son auteur peut la modifier.")
    if actives_seulement and not r["actif"]:
        raise HTTPException(410, "Cette espèce a été retirée.")
    return r


def _previens_les_amis(u, case_id: int) -> None:
    """Une case qui apparaît dans un dex partagé mérite un mot.

    L'identifiant de la case voyage dans `valeur` : la table des notifications
    n'a pas de colonne pour une case, seulement pour une capture, et lui en
    ajouter une pour ce seul usage coûterait une migration. `valeur` est déjà
    un entier libre dont le sens dépend du type.
    """
    amis = db.lit(
        """SELECT CASE WHEN demandeur = ? THEN destinataire ELSE demandeur END AS id
             FROM amities
            WHERE etat = 'acceptee' AND (demandeur = ? OR destinataire = ?)""",
        (u["id"], u["id"], u["id"]))
    for a in amis:
        previens(a["id"], u["id"], "espece_ajoutee", valeur=case_id)
