"""
La langue des données servies.

Les messages d'erreur sont traduits par les clients, qui ont le dictionnaire
complet. Mais certaines données sont du texte : le nom d'un succès, sa
condition, le nom d'un rang. Elles sont écrites en français dans le code, et
traduites ici, à la sortie, dans la langue que le client annonce par
`Accept-Language`.

Le dictionnaire est `biodex/lang/<code>.json`, généré depuis `i18n/<code>.json`
à la racine du dépôt — le même fichier que le site et l'application.
"""
import contextvars
import json
import pathlib

_LANGUE = contextvars.ContextVar("langue", default="fr")
_DOSSIER = pathlib.Path(__file__).resolve().parent / "lang"
_DICOS: dict[str, dict] = {}


def langues_disponibles() -> list[str]:
    return ["fr"] + sorted(p.stem for p in _DOSSIER.glob("*.json"))


def _dico(langue: str) -> dict:
    if langue not in _DICOS:
        chemin = _DOSSIER / f"{langue}.json"
        try:
            _DICOS[langue] = json.loads(chemin.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            _DICOS[langue] = {}
    return _DICOS[langue]


def pose_langue(accept_language: str | None) -> None:
    """Retient la langue de la requête en cours, à partir de l'en-tête."""
    code = (accept_language or "fr").split(",")[0].strip()[:2].lower()
    _LANGUE.set(code if code in langues_disponibles() else "fr")


def langue() -> str:
    return _LANGUE.get()


def tr(texte: str) -> str:
    """Le texte dans la langue de la requête, ou tel quel."""
    l = _LANGUE.get()
    if l == "fr":
        return texte
    return _dico(l).get(texte, texte)
