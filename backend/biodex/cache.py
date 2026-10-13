"""
Servir un fichier sans le renvoyer quand le client l'a déjà.

Le serveur posait bien un `ETag` sur ses images — Starlette le fait tout seul —
mais il ne le **relisait** jamais. Mesuré sur une vignette de 42 Ko :

    requête nue                     200, 42 109 octets
    requête avec If-None-Match      200, 42 109 octets   ← devrait être 304, 0

Autrement dit, un client parfaitement discipliné, qui gardait l'image et
demandait poliment si elle avait changé, recevait quand même tout le fichier.
Sur une grille de dex qui défile, cela fait des mégaoctets pour rien, et c'est
un serveur sans GPU qui les pousse.

Deux corrections ici :

**On répond 304.** Si l'empreinte que le client annonce correspond à celle du
fichier, on renvoie une réponse vide. Le corps ne part pas.

**L'empreinte est calculée, pas devinée.** Elle vient de la date de
modification et de la taille, pas d'un hachage du contenu : lire quatre
mégaoctets pour décider qu'on n'a rien à envoyer serait absurde. Un fichier
réécrit change de date, donc d'empreinte, donc le client le retélécharge — ce
qui est exactement ce qu'on veut quand un joueur recadre sa photo.
"""
import pathlib

from fastapi import Request
from fastapi.responses import FileResponse, Response

# Un an. Réservé à ce qui ne change jamais sous la même adresse : silhouettes,
# écussons de rang, planches de modèles.
IMMUABLE = 31_536_000

# Un mois, pour ce qui pourrait changer un jour sans que ce soit grave.
LONG = 2_592_000

# Un jour, pour ce que le joueur peut retoucher — une découpe qu'il refait.
COURT = 86_400


def empreinte(chemin: pathlib.Path) -> str:
    s = chemin.stat()
    return f'"{s.st_mtime_ns:x}-{s.st_size:x}"'


def fichier(requete: Request, chemin: pathlib.Path, media_type: str,
            secondes: int = COURT, immuable: bool = False) -> Response:
    """Le fichier, ou une réponse vide si le client l'a déjà.

    `immuable` ajoute la directive du même nom : elle dit au client de ne même
    pas demander. À ne poser que sur une adresse dont le contenu ne changera
    jamais — sinon il faudra désinstaller l'application pour voir la mise à
    jour.
    """
    marque = empreinte(chemin)
    controle = f"private, max-age={secondes}"
    if immuable:
        controle += ", immutable"

    connu = requete.headers.get("if-none-match", "")
    # `If-None-Match` peut porter plusieurs empreintes séparées par des
    # virgules, et un client peut préfixer la sienne de « W/ » pour dire
    # qu'elle est approximative. On compare sans se formaliser.
    if any(e.strip().removeprefix("W/") == marque
           for e in connu.split(",") if e.strip()):
        return Response(status_code=304,
                        headers={"ETag": marque, "Cache-Control": controle})

    return FileResponse(chemin, media_type=media_type,
                        headers={"ETag": marque, "Cache-Control": controle})
