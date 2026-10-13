#!/usr/bin/env python3
"""
Le Biodex en navigateur — pour les iPhone, et pour tout ce qui n'a pas l'app.

Un serveur à part, qui ne touche ni au code ni à la base du serveur principal.
Il fait deux choses :

  1. il sert le dossier `web/` — la page et ses scripts ;
  2. il relaie `/api/…` vers le serveur principal.

**Il ne lit jamais la base directement**, et c'est le point important.

Passer par l'API plutôt que par SQLite évite trois ennuis d'un coup. D'abord
la duplication : l'authentification, les règles de dex, le calcul des points
et la validation des photos existent déjà, les réécrire en garantirait la
divergence. Ensuite les verrous : deux processus qui écrivent dans le même
fichier SQLite finissent par se marcher dessus, même en WAL. Enfin
l'évolution : quand une route change côté serveur, le site suit sans qu'on y
touche.

Le relais existe pour une seule raison : servir la page et l'API **depuis la
même origine**. Sans lui, le navigateur refuserait les requêtes au titre du
CORS, et il faudrait ouvrir le serveur principal aux origines étrangères —
c'est-à-dire l'affaiblir pour la commodité d'un client.

    python serveur_web.py                    écoute sur 8090
    python serveur_web.py --port 9000 --api http://127.0.0.1:8077

Derrière un proxy inverse, router `/web` ici et laisser le reste au serveur
principal.
"""
import argparse
import pathlib
import sys

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

ICI = pathlib.Path(__file__).resolve().parent
WEB = ICI / "web"

# L'adresse du serveur principal. Le relais s'y adresse en local : les deux
# tournent sur la même machine, la requête ne sort jamais.
API = "http://127.0.0.1:8077"

app = FastAPI(title="Biodex web", docs_url=None, redoc_url=None)


def regle_api(adresse: str) -> None:
    """Change l'amont visé. Une fonction plutôt qu'un `global` dans `main` :
    Python refuse de déclarer globale une variable déjà lue dans la même
    portée, et l'argument par défaut de l'analyseur la lit."""
    global API
    API = adresse.rstrip("/")


# Le nom du biscuit qui porte le jeton.
#
# Une balise `<img>` n'envoie aucun en-tête qu'on choisisse : les avatars, les
# vignettes et les badges arrivaient donc au serveur principal sans
# `Authorization`, et repartaient en 401. Mettre le jeton dans l'adresse
# marcherait, mais l'inscrirait dans les journaux du proxy, dans l'historique
# du navigateur et dans l'en-tête `Referer` de tout lien sortant.
#
# Le biscuit, lui, part tout seul sur chaque requête de même origine — y
# compris celles des images — et n'apparaît nulle part ailleurs. Le relais le
# convertit ici en `Authorization` ; le serveur principal ne sait même pas
# qu'il existe.
BISCUIT = "biodex_jeton"


@app.api_route("/api/{chemin:path}",
               methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def relais(chemin: str, requete: Request) -> Response:
    """Relaie une requête vers le serveur principal, telle quelle.

    On recopie les en-têtes du client — dont `Authorization`, qui porte le
    jeton — sauf `host`, qui désignerait le mauvais serveur. Le corps passe en
    octets bruts : ni JSON ni formulaire ne sont interprétés ici, ce serait
    autant d'occasions de les déformer.
    """
    entetes = {c: v for c, v in requete.headers.items()
               if c.lower() not in ("host", "content-length", "cookie")}
    # L'en-tête explicite gagne : une requête `fetch` sait ce qu'elle porte,
    # le biscuit n'est qu'un repli pour ce qui ne peut pas en poser.
    if "authorization" not in {c.lower() for c in entetes}:
        jeton = requete.cookies.get(BISCUIT)
        if jeton:
            entetes["authorization"] = f"Bearer {jeton}"
    corps = await requete.body()

    # Les flux d'événements ne se relaient pas comme le reste : ils n'ont pas
    # de fin. Les lire d'un bloc attendrait indéfiniment, et le client
    # n'aurait jamais rien. On les fait passer octet par octet.
    if chemin.rstrip("/").endswith("notifications/flux"):
        return await _relais_flux(chemin, requete, entetes)

    async with httpx.AsyncClient(timeout=120) as client:
        amont = await client.request(
            requete.method,
            f"{API}/{chemin}",
            params=requete.query_params,
            headers=entetes,
            content=corps or None,
        )

    return Response(content=amont.content, status_code=amont.status_code,
                    headers=_entetes_sortants(amont.headers),
                    media_type=amont.headers.get("content-type"))


def _entetes_sortants(entetes) -> dict:
    """Ce qu'on recopie de la réponse d'amont.

    Pas les en-têtes de transport : la longueur et l'encodage décrivent la
    réponse qu'on vient de lire, pas celle qu'on va réécrire.
    """
    return {c: v for c, v in entetes.items()
            if c.lower() not in ("content-length", "content-encoding",
                                 "transfer-encoding", "connection")}


async def _relais_flux(chemin: str, requete: Request, entetes: dict) -> Response:
    """Relaie un flux d'événements sans jamais le mettre en tampon.

    Trois précautions, chacune pour une panne vécue ailleurs :

    — **pas de délai d'expiration en lecture.** Un flux au repos ne dit rien
      pendant des minutes ; les 120 secondes du relais ordinaire le
      couperaient au milieu de la nuit.
    — **le client httpx vit aussi longtemps que le flux.** Le sortir d'un
      `async with` fermerait la connexion amont dès la première ligne rendue,
      et le navigateur verrait un flux qui se termine aussitôt.
    — **`X-Accel-Buffering: no` conservé.** Sans lui, un proxy inverse devant
      ce serveur remettrait en tampon ce qu'on vient de prendre soin de ne pas
      tamponner.
    """
    client = httpx.AsyncClient(timeout=httpx.Timeout(10, read=None))
    amont = client.stream(requete.method, f"{API}/{chemin}",
                          params=requete.query_params, headers=entetes)
    reponse = await amont.__aenter__()

    if reponse.status_code != 200:
        # Une erreur — jeton expiré, par exemple — se rend telle quelle : le
        # client doit pouvoir la lire plutôt que d'attendre un flux muet.
        contenu = await reponse.aread()
        await amont.__aexit__(None, None, None)
        await client.aclose()
        return Response(content=contenu, status_code=reponse.status_code,
                        headers=_entetes_sortants(reponse.headers),
                        media_type=reponse.headers.get("content-type"))

    async def octets():
        try:
            async for morceau in reponse.aiter_raw():
                yield morceau
        finally:
            # Le client s'en va, le serveur s'arrête, la connexion tombe :
            # dans tous les cas la connexion amont doit être rendue, sinon
            # elle s'accumule à chaque onglet ouvert puis fermé.
            await amont.__aexit__(None, None, None)
            await client.aclose()

    return StreamingResponse(
        octets(), status_code=reponse.status_code,
        headers=_entetes_sortants(reponse.headers),
        media_type=reponse.headers.get("content-type"))


@app.get("/ou")
async def ou() -> dict:
    """Vers quel serveur ce relais pointe, et ce que celui-ci répond.

    Une page qui refuse un mot de passe juste peut le faire pour deux raisons
    très différentes : le mot de passe est faux, ou le relais interroge le
    mauvais serveur. Cette route tranche en une seconde, sans avoir à lire les
    journaux ni à deviner les options de lancement.
    """
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.get(f"{API}/")
        return {"api": API, "joignable": True, "reponse": r.json()}
    except Exception as e:
        return {"api": API, "joignable": False,
                "erreur": f"{type(e).__name__}: {e}"}


@app.middleware("http")
async def revalide_les_fichiers(requete: Request, suite):
    """Impose au navigateur de vérifier avant de resservir la page.

    `StaticFiles` pose bien un `ETag`, mais aucun `Cache-Control`. Sans
    directive, un navigateur applique sa fraîcheur heuristique : il garde le
    fichier sans même demander s'il a changé, pour une durée qu'il choisit
    seul. Résultat concret — on modifie le site, on recharge, et rien ne
    bouge ; Safari sur iPhone est le plus tenace là-dessus.

    `no-cache` ne veut pas dire « ne garde rien » : le fichier reste en cache,
    mais le navigateur doit le revalider. Quand rien n'a changé, l'échange
    tient dans un 304 sans corps — quelques centaines d'octets, pas les 175 Ko
    du script. Le serveur n'y perd donc rien, et on ne peut plus servir du
    vieux code sans le savoir.

    Les photos gardent leurs propres en-têtes : elles viennent de l'API par le
    relais, qui les marque déjà pour un mois — une photo enregistrée ne change
    jamais.

    **`/media/` fait exception, et il l'a payé cher.** Ce dossier est servi
    d'ici, pas par l'API : la règle ci-dessus l'attrapait aussi. Or l'écran des
    succès y prend quatre-vingt-deux vignettes, et le dex une par espèce. Le
    site redessine tout son DOM à chaque geste — c'est ainsi qu'il est bâti —
    donc chaque déplacement d'une case recréait toutes les `<img>`, et
    `no-cache` obligeait à revalider chacune. Zéro octet de corps, mais un
    aller-retour par image et par geste : sur un téléphone, l'arrangement du
    dex en devenait inutilisable.

    Une heure de fraîcheur, un jour de sursis pendant la revalidation. Ces
    fichiers ne bougent qu'à une mise à jour, et le décalage se rattrape tout
    seul dans l'heure.
    """
    reponse = await suite(requete)
    if requete.url.path.startswith("/api/"):
        return reponse
    if requete.url.path.startswith("/media/"):
        reponse.headers.setdefault(
            "Cache-Control", "public, max-age=3600, stale-while-revalidate=86400")
        return reponse
    reponse.headers.setdefault("Cache-Control", "no-cache")
    return reponse


@app.get("/")
def accueil() -> FileResponse:
    return FileResponse(WEB / "index.html")


# Le reste du dossier : scripts, styles, manifeste. En dernier, pour que les
# routes ci-dessus gardent la priorité.
app.mount("/", StaticFiles(directory=WEB, html=True), name="web")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--hote", default="0.0.0.0")
    ap.add_argument("--api", default=API,
                    help="adresse du serveur principal")
    a = ap.parse_args()

    regle_api(a.api)

    import uvicorn
    print(f"Biodex web sur http://{a.hote}:{a.port}  →  API {API}")
    uvicorn.run(app, host=a.hote, port=a.port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
