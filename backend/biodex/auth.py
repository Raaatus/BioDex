"""
Comptes et sessions.

Inscription au pseudo seul, sans adresse mail : personne à vérifier, personne à
relancer. La contrepartie, c'est qu'un mot de passe perdu est perdu — il n'y a
aucun canal de récupération. C'est assumé pour le périmètre visé.

Le hachage utilise scrypt, qui est dans la bibliothèque standard : rien à
compiler, donc rien qui casse au moment de réinstaller les dépendances sur le
serveur. Les jetons de session ne sont stockés que sous forme d'empreinte.
"""
import hashlib
import hmac
import re
import secrets
import unicodedata
from datetime import UTC, datetime, timedelta

from . import config, db

# scrypt : ~32 Mo de mémoire et ~100 ms par vérification sur un CPU récent.
# Assez coûteux pour rendre une attaque hors-ligne pénible, assez rapide pour
# ne pas se sentir à la connexion.
_N, _R, _P = 2 ** 15, 8, 1
_LONGUEUR = 32

PSEUDO_MIN, PSEUDO_MAX = 3, 24
MDP_MIN, MDP_MAX = 8, 256
# Lettres, chiffres, tiret, tiret bas, point. Pas d'espace : ça évite les
# pseudos qui se ressemblent à un espace insécable près.
_PSEUDO_OK = re.compile(r"^[A-Za-z0-9._-]+$")


class ErreurAuth(Exception):
    """Erreur métier d'authentification, transformée en 4xx par l'API."""

    def __init__(self, message: str, code: int = 400):
        super().__init__(message)
        self.message = message
        self.code = code


# ------------------------------------------------------------------- pseudos

def normalise_pseudo(pseudo: str) -> str:
    """Forme servant à l'unicité : minuscules, sans accents.

    « Rémi » et « remi » sont donc le même compte, ce qui évite qu'on se fasse
    passer pour quelqu'un d'autre à un accent près.
    """
    p = unicodedata.normalize("NFKD", pseudo.strip())
    p = "".join(c for c in p if not unicodedata.combining(c))
    return p.casefold()


def valide_pseudo(pseudo: str) -> str:
    pseudo = pseudo.strip()
    if not PSEUDO_MIN <= len(pseudo) <= PSEUDO_MAX:
        raise ErreurAuth(f"Le pseudo doit faire entre {PSEUDO_MIN} et {PSEUDO_MAX} caractères.")
    if not _PSEUDO_OK.match(pseudo):
        raise ErreurAuth("Le pseudo ne peut contenir que des lettres, chiffres, «.», «_» et «-».")
    return pseudo


def valide_mdp(mdp: str) -> str:
    if not MDP_MIN <= len(mdp) <= MDP_MAX:
        raise ErreurAuth(f"Le mot de passe doit faire au moins {MDP_MIN} caractères.")
    return mdp


# ------------------------------------------------------------ mots de passe

def hache_mdp(mdp: str) -> str:
    sel = secrets.token_bytes(16)
    emp = hashlib.scrypt(mdp.encode(), salt=sel, n=_N, r=_R, p=_P, dklen=_LONGUEUR,
                         maxmem=64 * 1024 * 1024)
    return f"scrypt${_N}${_R}${_P}${sel.hex()}${emp.hex()}"


def verifie_mdp(mdp: str, stocke: str) -> bool:
    try:
        algo, n, r, p, sel, emp = stocke.split("$")
        if algo != "scrypt":
            return False
        calcule = hashlib.scrypt(mdp.encode(), salt=bytes.fromhex(sel),
                                 n=int(n), r=int(r), p=int(p),
                                 dklen=len(emp) // 2, maxmem=64 * 1024 * 1024)
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(calcule.hex(), emp)


# ---------------------------------------------------------------- sessions

def _empreinte(jeton: str) -> str:
    """Le sel serveur fait que la seule base de données ne suffit pas à forger
    une empreinte valide à partir d'un jeton deviné."""
    return hashlib.sha256(config.sel_serveur() + jeton.encode()).hexdigest()


def ouvre_session(utilisateur_id: int, appareil: str = "") -> tuple[str, str]:
    """Crée une session et renvoie (jeton en clair, date d'expiration).

    Le jeton en clair n'existe qu'ici et dans la réponse HTTP : il n'est jamais
    écrit sur disque.
    """
    jeton = secrets.token_urlsafe(32)
    expire = datetime.now(UTC) + timedelta(days=config.DUREE_SESSION_JOURS)
    expire_txt = expire.strftime("%Y-%m-%d %H:%M:%S")
    db.ecrit(
        "INSERT INTO sessions (empreinte, utilisateur, expire_le, appareil) VALUES (?,?,?,?)",
        (_empreinte(jeton), utilisateur_id, expire_txt, appareil[:120]),
    )
    return jeton, expire_txt


def ferme_session(jeton: str) -> None:
    db.ecrit("DELETE FROM sessions WHERE empreinte = ?", (_empreinte(jeton),))


def ferme_toutes_sessions(utilisateur_id: int) -> None:
    db.ecrit("DELETE FROM sessions WHERE utilisateur = ?", (utilisateur_id,))


def utilisateur_du_jeton(jeton: str):
    """Renvoie la ligne utilisateur associée au jeton, ou None."""
    r = db.lit_un(
        """SELECT u.* FROM sessions s
           JOIN utilisateurs u ON u.id = s.utilisateur
           WHERE s.empreinte = ? AND s.expire_le > datetime('now') AND u.actif = 1""",
        (_empreinte(jeton),),
    )
    if r is not None:
        # `vu_le` sert au fil d'activité et au ménage des sessions mortes ;
        # une écriture par requête est indolore à cette échelle.
        db.ecrit("UPDATE sessions SET vu_le = datetime('now') WHERE empreinte = ?",
                 (_empreinte(jeton),))
        db.ecrit("UPDATE utilisateurs SET vu_le = datetime('now') WHERE id = ?", (r["id"],))
    return r


def purge_sessions() -> int:
    cur = db.ecrit("DELETE FROM sessions WHERE expire_le <= datetime('now')")
    return cur.rowcount


# ------------------------------------------------------------------ comptes

def inscrit(pseudo: str, mdp: str, appareil: str = "") -> tuple[int, str, str]:
    """Crée le compte et ouvre la session dans la foulée."""
    pseudo = valide_pseudo(pseudo)
    valide_mdp(mdp)
    norm = normalise_pseudo(pseudo)
    if db.lit_un("SELECT 1 FROM utilisateurs WHERE pseudo_norm = ?", (norm,)):
        raise ErreurAuth("Ce pseudo est déjà pris.", 409)
    empreinte = hache_mdp(mdp)
    with db.transaction() as cx:
        # Le UNIQUE sur pseudo_norm reste l'arbitre en cas d'inscription
        # simultanée du même pseudo : la vérification ci-dessus est du confort.
        try:
            cur = cx.execute(
                "INSERT INTO utilisateurs (pseudo_norm, pseudo, mdp) VALUES (?,?,?)",
                (norm, pseudo, empreinte),
            )
        except Exception as e:
            if "UNIQUE" in str(e):
                raise ErreurAuth("Ce pseudo est déjà pris.", 409) from e
            raise
        uid = cur.lastrowid
    jeton, expire = ouvre_session(uid, appareil)
    return uid, jeton, expire


def connecte(pseudo: str, mdp: str, appareil: str = "") -> tuple[int, str, str]:
    norm = normalise_pseudo(pseudo)
    u = db.lit_un("SELECT id, mdp, actif FROM utilisateurs WHERE pseudo_norm = ?", (norm,))
    # Même message et même coût que le pseudo existe ou non : sinon on offre un
    # oracle qui dit quels pseudos sont pris.
    if u is None:
        hache_mdp(mdp)
        raise ErreurAuth("Pseudo ou mot de passe incorrect.", 401)
    if not verifie_mdp(mdp, u["mdp"]) or not u["actif"]:
        raise ErreurAuth("Pseudo ou mot de passe incorrect.", 401)
    jeton, expire = ouvre_session(u["id"], appareil)
    return u["id"], jeton, expire


def change_mdp(utilisateur_id: int, ancien: str, nouveau: str) -> None:
    u = db.lit_un("SELECT mdp FROM utilisateurs WHERE id = ?", (utilisateur_id,))
    if u is None or not verifie_mdp(ancien, u["mdp"]):
        raise ErreurAuth("Mot de passe actuel incorrect.", 403)
    valide_mdp(nouveau)
    db.ecrit("UPDATE utilisateurs SET mdp = ? WHERE id = ?",
             (hache_mdp(nouveau), utilisateur_id))
    # On invalide tout : un changement de mot de passe sert souvent à couper
    # l'accès à quelqu'un d'autre.
    ferme_toutes_sessions(utilisateur_id)
