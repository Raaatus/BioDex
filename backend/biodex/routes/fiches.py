"""
Fiches encyclopédiques et photos de profil.

Les fiches viennent de Wikipédia, interrogée avec le nom latin de l'espèce :
leurs redirections font le travail, « Capreolus capreolus » mène à l'article
« Chevreuil d'Europe ». On garde le résultat en base — inutile de les solliciter
à chaque ouverture d'une case, et ça continue de fonctionner quand le téléphone
n'a pas d'accès direct à Wikipédia.
"""
import json
import urllib.error
import urllib.parse
import urllib.request

from concurrent.futures import ThreadPoolExecutor

from fastapi import (APIRouter, Depends, File, HTTPException, Query,
                     UploadFile)
from fastapi.responses import FileResponse

from .. import config, db, images
from ..dependances import utilisateur

routeur = APIRouter(tags=["fiches"])

UA = {"User-Agent": "biodex/0.1 (dex local)"}
RESUME = "https://{langue}.wikipedia.org/api/rest_v1/page/summary/{titre}"

# On tente le français d'abord, l'anglais ensuite : beaucoup d'espèces n'ont
# d'article que sur la Wikipédia anglophone.
LANGUES = ("fr", "en")


class Indisponible(Exception):
    """Wikipédia n'a pas répondu.

    Ce n'est pas la même chose qu'une absence d'article, et la confusion coûte
    cher : un simple « trop de requêtes » retenu comme « pas d'article »
    condamne la fiche pour toujours, puisqu'on ne la redemande plus jamais.
    """


def _interroge(latin: str) -> dict | None:
    indisponible = False
    for langue in LANGUES:
        url = RESUME.format(langue=langue,
                            titre=urllib.parse.quote(latin.replace(" ", "_")))
        try:
            with urllib.request.urlopen(
                    urllib.request.Request(url, headers=UA), timeout=12) as r:
                d = json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                continue            # pas d'article dans cette langue
            # 429 : trop de requêtes. 5xx : panne passagère. L'article existe
            # peut-être très bien — on ne conclut rien.
            indisponible = True
            continue
        except (urllib.error.URLError, TimeoutError, ValueError):
            indisponible = True
            continue

        # Les pages d'homonymie n'apprennent rien : autant ne rien montrer.
        if d.get("type") == "disambiguation" or not d.get("extract"):
            continue
        return {
            "titre": d.get("title", ""),
            "resume": d.get("extract", ""),
            "url": (d.get("content_urls", {}).get("desktop", {}).get("page", "")),
            "image": (d.get("thumbnail") or {}).get("source", ""),
            "langue": langue,
        }
    if indisponible:
        raise Indisponible(latin)
    return None


def _fiche_de(case_id: int, rafraichir: bool = False) -> dict:
    """Le corps de la recherche, hors couche HTTP.

    Isolé pour que la version groupée puisse l'appeler sur plusieurs espèces à
    la fois sans repasser par le routeur.
    """
    c = db.lit_un("SELECT id, latin, nom_fr, genre FROM cases WHERE id = ?",
                  (case_id,))
    if c is None:
        raise HTTPException(404, "Espèce introuvable.")

    connue = db.lit_un("SELECT * FROM fiches WHERE case_id = ?", (case_id,))
    if connue is not None and not rafraichir:
        if connue["vide"]:
            return {"case_id": case_id, "trouvee": False}
        return {
            "case_id": case_id, "trouvee": True,
            "titre": connue["titre"], "resume": connue["resume"],
            "url": connue["url"], "image": connue["image"],
            "langue": connue["langue"],
            "approximation": connue["approximation"]
                if "approximation" in connue.keys() else "",
        }

    # Trois tentatives, de la plus précise à la plus large. Une espèce sans
    # article a souvent un genre qui en a un : mieux vaut la fiche du genre,
    # signalée comme approximative, que rien du tout.
    replis: list[tuple[str, str]] = [(c["latin"], "")]
    if c["nom_fr"]:
        # « Chevreuil » aboutit là où « Capreolus capreolus » n'a pas de
        # redirection.
        replis.append((c["nom_fr"], ""))
    genre = (c["genre"] or c["latin"].split(" ")[0]).strip()
    if genre and genre != c["latin"]:
        replis.append((genre, "genre"))

    trouvee, approximation = None, ""
    try:
        for terme, niveau in replis:
            trouvee = _interroge(terme)
            if trouvee is not None:
                approximation = niveau
                break
    except Indisponible as e:
        # Rien n'est retenu : la prochaine ouverture de la fiche retentera.
        raise HTTPException(
            503, "Wikipédia est momentanément indisponible, réessayez.") from e

    if trouvee is None:
        db.ecrit(
            """INSERT INTO fiches (case_id, vide, maj_le)
               VALUES (?, 1, datetime('now'))
               ON CONFLICT(case_id) DO UPDATE SET vide = 1, maj_le = datetime('now')""",
            (case_id,))
        return {"case_id": case_id, "trouvee": False}

    db.ecrit(
        """INSERT INTO fiches (case_id, titre, resume, url, image, langue, vide,
                              maj_le, approximation)
           VALUES (:c, :titre, :resume, :url, :image, :langue, 0, datetime('now'),
                   :approximation)
           ON CONFLICT(case_id) DO UPDATE SET
               titre = :titre, resume = :resume, url = :url, image = :image,
               langue = :langue, vide = 0, maj_le = datetime('now'),
               approximation = :approximation""",
        {"c": case_id, "approximation": approximation, **trouvee})
    return {"case_id": case_id, "trouvee": True,
            "approximation": approximation, **trouvee}


@routeur.get("/dex/{case_id}/fiche")
def fiche(case_id: int, rafraichir: bool = False, _=Depends(utilisateur)):
    """Le résumé encyclopédique d'une espèce.

    Cherché à la première demande, puis servi du cache. Une espèce sans article
    est marquée comme telle pour ne pas relancer la recherche à chaque fois.
    """
    return _fiche_de(case_id, rafraichir)


@routeur.get("/fiches")
def vignettes(cases: str = Query(max_length=200), _=Depends(utilisateur)):
    """Les illustrations d'un lot d'espèces, pour aider à choisir.

    Devant une liste de binômes latins, une photo tranche bien plus vite qu'un
    nom. Les articles manquants sont cherchés en parallèle : en série, une
    dizaine d'espèces inconnues feraient attendre plusieurs secondes.
    """
    ids = []
    for morceau in cases.split(","):
        morceau = morceau.strip()
        if morceau.isdigit() and len(ids) < 20:
            ids.append(int(morceau))
    if not ids:
        return {"fiches": {}}

    marques = ",".join("?" * len(ids))
    connues = {
        r["case_id"]: r for r in db.lit(
            f"SELECT * FROM fiches WHERE case_id IN ({marques})", ids)
    }
    manquantes = [i for i in ids if i not in connues]

    resultats: dict[int, dict] = {}
    if manquantes:
        with ThreadPoolExecutor(max_workers=6) as pool:
            for case_id, fiche in zip(
                    manquantes, pool.map(_fiche_prudente, manquantes)):
                if fiche is not None:
                    resultats[case_id] = fiche

    for case_id, r in connues.items():
        if not r["vide"]:
            resultats[case_id] = {
                "case_id": case_id, "trouvee": True, "titre": r["titre"],
                "resume": r["resume"], "url": r["url"], "image": r["image"],
                "langue": r["langue"],
            }

    return {"fiches": {str(k): v for k, v in resultats.items()}}


def _fiche_prudente(case_id: int) -> dict | None:
    """Comme [_fiche_de], mais une espèce en échec n'entraîne pas les autres."""
    try:
        d = _fiche_de(case_id)
        return d if d.get("trouvee") else None
    except Exception:
        return None


# ------------------------------------------------------------------- avatars

@routeur.post("/moi/avatar")
async def envoie_avatar(photo: UploadFile = File(...), u=Depends(utilisateur)):
    """Change sa photo de profil.

    Elle est recadrée en carré et réduite : elle ne sert qu'en médaillon, sur la
    carte et dans les listes.
    """
    blob = await photo.read()
    try:
        nom = images.avatar(blob)
    except images.ImageInvalide as e:
        raise HTTPException(400, str(e)) from e

    ancien = db.valeur("SELECT avatar FROM utilisateurs WHERE id = ?", (u["id"],))
    db.ecrit("UPDATE utilisateurs SET avatar = ? WHERE id = ?", (nom, u["id"]))
    if ancien and ancien != nom:
        images.supprime_avatar(ancien)
    return {"avatar": f"/utilisateurs/{u['id']}/avatar"}


@routeur.delete("/moi/avatar", status_code=204)
def retire_avatar(u=Depends(utilisateur)):
    ancien = db.valeur("SELECT avatar FROM utilisateurs WHERE id = ?", (u["id"],))
    db.ecrit("UPDATE utilisateurs SET avatar = NULL WHERE id = ?", (u["id"],))
    if ancien:
        images.supprime_avatar(ancien)


@routeur.get("/utilisateurs/{utilisateur_id}/avatar")
def avatar(utilisateur_id: int, _=Depends(utilisateur)):
    """La photo de profil d'un joueur. Visible de tous les joueurs connectés :
    c'est ce qui permet de reconnaître l'auteur d'une photo sur la carte."""
    nom = db.valeur("SELECT avatar FROM utilisateurs WHERE id = ? AND actif = 1",
                    (utilisateur_id,))
    if not nom:
        raise HTTPException(404, "Pas de photo de profil.")
    return FileResponse(images.chemin_sur(config.AVATARS, nom),
                        media_type="image/jpeg",
                        headers={"Cache-Control": "private, max-age=3600"})


@routeur.get("/credits")
def credits(_=Depends(utilisateur)):
    """Les auteurs des silhouettes et leurs licences.

    PhyloPic verse l'essentiel de son fonds au domaine public, mais pas tout :
    certaines images sont sous CC-BY, qui impose de citer l'auteur. Cet écran
    est ce qui rend cette obligation tenable.
    """
    lignes = db.lit(
        """SELECT source, licence, COUNT(*) AS n FROM visuels
           WHERE source <> '' GROUP BY source, licence ORDER BY n DESC""")
    return {
        "silhouettes": [
            {"auteur": r["source"], "licence": r["licence"], "images": r["n"]}
            for r in lignes
        ],
        "sources": [
            {"nom": "PhyloPic", "url": "https://www.phylopic.org",
             "role": "silhouettes des espèces"},
            {"nom": "GBIF", "url": "https://www.gbif.org",
             "role": "taxonomie et fréquences d'observation"},
            {"nom": "Wikipédia", "url": "https://fr.wikipedia.org",
             "role": "fiches des espèces"},
            {"nom": "BioCLIP 2 et MegaDetector", "url": "",
             "role": "reconnaissance des animaux"},
            {"nom": "OpenStreetMap, Esri", "url": "https://www.openstreetmap.org",
             "role": "fonds de carte"},
        ],
    }
