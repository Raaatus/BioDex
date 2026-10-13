"""Dépendances FastAPI partagées : authentification et pagination."""
import sqlite3

from fastapi import Depends, Header, HTTPException, Query

from . import auth


def _jeton(entete: str | None) -> str | None:
    if not entete:
        return None
    morceaux = entete.split(None, 1)
    if len(morceaux) == 2 and morceaux[0].lower() == "bearer":
        return morceaux[1].strip()
    return None


def utilisateur(authorization: str | None = Header(default=None)) -> sqlite3.Row:
    """Exige une session valide. Lève 401 sinon."""
    jeton = _jeton(authorization)
    if not jeton:
        raise HTTPException(401, "Jeton manquant.")
    u = auth.utilisateur_du_jeton(jeton)
    if u is None:
        raise HTTPException(401, "Session expirée ou invalide.")
    return u


def utilisateur_optionnel(authorization: str | None = Header(default=None)):
    """Pour les routes qui s'enrichissent quand on est connecté sans l'exiger."""
    jeton = _jeton(authorization)
    return auth.utilisateur_du_jeton(jeton) if jeton else None


class Pagination:
    def __init__(self,
                 limite: int = Query(60, ge=1, le=300),
                 depuis: int = Query(0, ge=0)):
        self.limite = limite
        self.depuis = depuis


Utilisateur = Depends(utilisateur)
UtilisateurOptionnel = Depends(utilisateur_optionnel)
