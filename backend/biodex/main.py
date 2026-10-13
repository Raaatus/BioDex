"""
Point d'entrée de l'API.

    uvicorn biodex.main:app --host 0.0.0.0 --port 8077

Le moteur démarre en arrière-plan et charge ses modèles à la première photo :
l'API répond donc tout de suite, même si la première analyse attend une trentaine
de secondes de chargement.
"""
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from . import auth, config, db, moteur, i18n
from .routes import (amis, captures, carte, classement, comptes, dex, especes,
                     fiches, galerie, notifications, reactions, succes)


def _prepare_succes_especes(nb_cases: int) -> None:
    """Bâtit la table des espèces par thème si elle est vide.

    **Pourquoi au démarrage et non à la main.** Les quarante-quatre succès à
    thème — « Butineuse », « Sous-bois », « Sang royal » — comptent les espèces
    trouvées en joignant `succes_especes`. Cette table est dérivée du
    catalogue, pas saisie : `outils/succes_especes.py` la reconstruit. Or
    `outils/base_neuve.py`, qui refait la base à chaque mise à jour, la recrée
    **vide** : elle ne contient aucune donnée de joueur, donc rien à recopier.

    Résultat en production : tous les succès à thème restaient bloqués à zéro,
    sans erreur ni message. On photographiait une abeille et « Butineuse » ne
    tombait pas. Une étape oubliée dans une procédure ne se voit pas ; une
    table vide, si. C'est donc ici que ça se répare, une fois pour toutes.

    Quinze secondes, et seulement quand il y a quelque chose à faire.
    """
    if not nb_cases:
        return                        # sans catalogue, il n'y a rien à classer
    if db.valeur("SELECT COUNT(*) FROM succes_especes", (), 0):
        return
    print("succes_especes vide : classement des espèces par thème…", flush=True)
    try:
        from outils import succes_especes
        total = succes_especes.ecrit(succes_especes.calcule(),
                                     succes_especes.couleurs())
        print(f"  {total} espèces classées.", flush=True)
    except Exception as e:
        # Non bloquant : le reste de l'application marche, et seuls les succès
        # à thème resteront à zéro — exactement l'état d'avant.
        print(f"!! classement impossible ({type(e).__name__}: {e}) — "
              f"lancer « python -m outils.succes_especes » à la main.", flush=True)


@asynccontextmanager
async def cycle(app: FastAPI):
    config.prepare_dossiers()
    db.initialise()
    auth.purge_sessions()
    # Les photos que rien n'identifie n'apparaissent nulle part ; passé le
    # délai, on ne les garde pas.
    jetees = captures.purge_non_identifiees()
    if jetees:
        print(f"{jetees} photo(s) non identifiée(s) effacée(s).", flush=True)
    moteur.file.demarre()
    n = db.valeur("SELECT COUNT(*) FROM cases", (), 0)
    if not n:
        print("!! Aucune case en base : lancer outils/construit_dex.py avant de jouer.",
              flush=True)
    _prepare_succes_especes(n)
    print(f"Biodex prêt — {n} cases, base {config.BASE}", flush=True)
    yield
    moteur.file.arrete()


app = FastAPI(
    title="Biodex",
    description="Prends une photo d'un animal, remplis ta case.",
    version="0.1.0",
    lifespan=cycle,
)

# L'app mobile n'est pas un navigateur et se moque de CORS ; c'est ouvert pour
# pouvoir tester depuis une page web pendant le développement.
@app.middleware("http")
async def langue_de_la_requete(request, call_next):
    # La langue annoncée par le client, pour les données qu'on traduit à la
    # sortie (succès, rangs). Voir `i18n.py`.
    i18n.pose_langue(request.headers.get("accept-language"))
    return await call_next(request)


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_methods=["*"], allow_headers=["*"],
)


@app.exception_handler(auth.ErreurAuth)
async def erreur_auth(_: Request, e: auth.ErreurAuth):
    return JSONResponse({"detail": e.message}, status_code=e.code)


@app.get("/", tags=["service"])
def sante():
    return {
        "service": "biodex",
        "cases": db.valeur("SELECT COUNT(*) FROM cases", (), 0),
        "joueurs": db.valeur("SELECT COUNT(*) FROM utilisateurs WHERE actif = 1", (), 0),
        "captures": db.valeur("SELECT COUNT(*) FROM captures", (), 0),
        "en_attente": moteur.file.en_attente(),
        "moteur": "actif" if not config.SANS_MOTEUR else "désactivé",
    }


app.include_router(comptes.routeur)
app.include_router(captures.routeur)
app.include_router(dex.routeur)
app.include_router(amis.routeur)
app.include_router(carte.routeur)
app.include_router(classement.routeur)
app.include_router(reactions.routeur)
app.include_router(fiches.routeur)
app.include_router(galerie.routeur)
app.include_router(notifications.routeur)
app.include_router(especes.routeur)
app.include_router(succes.routeur)


def main() -> None:
    import uvicorn
    uvicorn.run(app, host=config.HOTE, port=config.PORT)


if __name__ == "__main__":
    main()
