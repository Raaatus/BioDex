"""
Notifications.

Elles vivent en base et l'application vient les chercher : ce ne sont pas des
notifications système. En envoyer sur l'écran verrouillé demanderait de passer
par le service de messagerie de Google, donc un compte, des clés et un aller-
retour par leurs serveurs — beaucoup pour un jeu qui tourne sur le réseau de la
maison. Un badge et un écran dédié suffisent à ne rien manquer.
"""
import asyncio
import json

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .. import config, db, flux
from ..dependances import utilisateur

routeur = APIRouter(tags=["notifications"])


# Ce dont on peut être prévenu, et ce qu'on en dit dans les réglages.
#
# Le défaut est volontairement avare. Une application qui prévient de tout
# finit par ne plus prévenir de rien : on coupe la catégorie qui déborde, puis
# toutes, et le jour où quelque chose compte vraiment le message se perd avec
# le reste. On ne notifie donc par défaut que deux choses — ce qui s'adresse à
# quelqu'un personnellement, et ce qui va lui coûter s'il ne fait rien.
CATEGORIES = {
    "succes_debloque": {
        "nom": "Succès de mes amis",
        "detail": "Quand un ami décroche un succès.",
        # Faux par défaut : c'est la catégorie la plus bavarde des sept, et
        # celle dont l'absence ne prive de rien — les succès se voient sur le
        # profil de l'ami quand on va le regarder.
        "defaut": False,
    },
    "espece_ajoutee": {
        "nom": "Nouvelles espèces indexées",
        "detail": "Quand un ami ajoute au dex une espèce que GBIF ignore.",
        # Vrai par défaut, contrairement à « ami_actif » : ça n'arrive pas tous
        # les jours, et une case qui apparaît sans prévenir dans un dex partagé
        # se remarque plus qu'elle ne dérange.
        "defaut": True,
    },
    "reaction": {
        "nom": "Réactions à mes photos",
        "detail": "Quand un ami applaudit une de vos trouvailles.",
        "defaut": True,
    },
    "identifie": {
        "nom": "On m'identifie sur une photo",
        "detail": "La photo entre dans votre dex : vous devez le savoir.",
        "defaut": True,
    },
    "ami_demande": {
        "nom": "Demandes d'ami",
        "detail": "Une demande qu'on ne voit pas est une demande refusée.",
        "defaut": True,
    },
    "ami_accepte": {
        "nom": "Demandes acceptées",
        "detail": "Quand quelqu'un accepte la vôtre.",
        "defaut": True,
    },
    "purge": {
        "nom": "Photos sur le point d'être effacées",
        "detail": "Deux rappels par semaine au plus, et seulement s'il y a "
                  "quelque chose à sauver.",
        "defaut": True,
    },
    "ami_actif": {
        "nom": "Activité de mes amis",
        "detail": "Quand un ami partage de nouvelles photos. Éteint par "
                  "défaut : avec vingt amis, c'est vingt notifications par "
                  "jour, et le fil dit déjà tout cela sans réveiller personne.",
        "defaut": False,
    },
}


def reglages_de(utilisateur_id: int) -> dict[str, bool]:
    """Ce que ce joueur accepte, catégorie par catégorie.

    Les valeurs stockées ne couvrent que ce qu'il a explicitement changé : le
    reste suit les défauts, et suivra leurs évolutions. Enregistrer la carte
    complète figerait les choix d'aujourd'hui pour toujours.
    """
    brut = db.valeur(
        "SELECT reglages_notifs FROM utilisateurs WHERE id = ?",
        (utilisateur_id,), "")
    choisis = {}
    if brut:
        try:
            choisis = {k: bool(v) for k, v in json.loads(brut).items()}
        except (ValueError, AttributeError):
            choisis = {}
    return {cle: choisis.get(cle, d["defaut"]) for cle, d in CATEGORIES.items()}


def previens(destinataire: int, auteur: int, type_: str,
             capture: int | None = None, valeur: int | None = None) -> None:
    """Dépose une notification, sans jamais se notifier soi-même.

    Une même personne qui revient sur sa réaction ne produit pas une seconde
    ligne : elle remplace la sienne, et la notification redevient non lue —
    changer d'avis mérite d'être su.

    Le filtrage se fait ici, à l'écriture, et non à la lecture. Une
    notification qu'on n'a pas voulue ne doit pas exister : la garder en base
    « au cas où » ferait resurgir six mois de bruit le jour où quelqu'un
    rallume une catégorie par curiosité.
    """
    if destinataire == auteur:
        return
    if not reglages_de(destinataire).get(type_, True):
        return
    db.ecrit(
        """INSERT INTO notifications (destinataire, auteur, type, capture, valeur)
           VALUES (?,?,?,?,?)
           ON CONFLICT(destinataire, auteur, capture, type) DO UPDATE SET
               valeur = excluded.valeur, lu = 0, cree_le = datetime('now')""",
        (destinataire, auteur, type_, capture, valeur))
    # Après l'écriture, jamais avant : un client réveillé trop tôt rechargerait
    # ses notifications sans y trouver la nouvelle.
    flux.signale(destinataire)


def previens_activite(auteur: int, capture_id: int) -> None:
    """« Un tel a partagé de nouvelles trouvailles » — une seule fois.

    **Le problème que ça résout.** Quelqu'un rentre de balade et vide sa
    pellicule : sept cents photos, sept cents analyses qui se terminent. Une
    notification par photo, pour chacun de ses amis, rendrait la catégorie
    inutilisable et ferait fuir tout le monde vers le bouton « éteindre ».

    **La règle.** Tant que la notification précédente n'a pas été lue, on ne
    crée rien de neuf : on incrémente son compteur, sans toucher à sa date et
    sans réveiller les connexions ouvertes. L'ami voit donc une seule ligne,
    « 700 trouvailles », qui grossit en silence. Une fois qu'il l'a lue, la
    publication suivante en ouvre une nouvelle — le signal redevient utile.

    C'est ce qui distingue cette fonction de `previens()`, dont l'upsert
    remonte la date et remet à non-lu à chaque appel : très bien pour une
    réaction qu'on retire et qu'on remet, catastrophique ici.
    """
    amis = db.lit(
        """SELECT CASE WHEN demandeur = ? THEN destinataire ELSE demandeur END AS id
             FROM amities
            WHERE etat = 'acceptee' AND (demandeur = ? OR destinataire = ?)""",
        (auteur, auteur, auteur))
    for a in amis:
        destinataire = a["id"]
        if destinataire == auteur:
            continue
        if not reglages_de(destinataire).get("ami_actif", True):
            continue
        # `capture` reste NULL : la notification parle de l'ami, pas d'une
        # photo. C'est ce qui fait tenir la clé unique sur un seul exemplaire
        # par couple (destinataire, auteur). `apercu`, lui, n'est pas dans
        # cette clé : on peut le faire pointer vers la dernière photo sans
        # jamais faire éclater le regroupement en plusieurs lignes.
        encours = db.lit_un(
            """SELECT id, valeur FROM notifications
                WHERE destinataire = ? AND auteur = ? AND type = 'ami_actif'
                  AND capture IS NULL AND lu = 0""",
            (destinataire, auteur))
        if encours:
            db.ecrit("UPDATE notifications SET valeur = ?, apercu = ? WHERE id = ?",
                     ((encours["valeur"] or 1) + 1, capture_id, encours["id"]))
            continue                      # surtout pas de `flux.signale` ici
        db.ecrit(
            """INSERT INTO notifications (destinataire, auteur, type, capture, apercu, valeur)
               VALUES (?,?,'ami_actif',NULL,?,1)
               ON CONFLICT(destinataire, auteur, capture, type) DO UPDATE SET
                   valeur = 1, apercu = excluded.apercu, lu = 0, cree_le = datetime('now')""",
            (destinataire, auteur, capture_id))
        flux.signale(destinataire)


def oublie(destinataire: int, auteur: int, capture: int, type_: str) -> None:
    """Retire la notification quand son motif disparaît — une réaction annulée
    ne doit pas laisser un badge derrière elle."""
    db.ecrit(
        """DELETE FROM notifications
           WHERE destinataire = ? AND auteur = ? AND capture = ? AND type = ?""",
        (destinataire, auteur, capture, type_))
    flux.signale(destinataire)


class ReglagesNotifs(BaseModel):
    """Ce qu'on accepte d'être notifié. Absent = on garde le défaut."""
    reglages: dict[str, bool]


@routeur.get("/notifications/reglages")
def lit_reglages(u=Depends(utilisateur)):
    """Les catégories, leur libellé, et l'état de chacune pour ce joueur."""
    actifs = reglages_de(u["id"])
    return {
        "categories": [
            {"cle": cle, "nom": d["nom"], "detail": d["detail"],
             "defaut": d["defaut"], "actif": actifs[cle]}
            for cle, d in CATEGORIES.items()
        ]
    }


@routeur.put("/notifications/reglages")
def change_reglages(corps: ReglagesNotifs, u=Depends(utilisateur)):
    """Change ce qu'on accepte.

    On n'enregistre que ce qui s'écarte du défaut : le reste suivra les
    évolutions de l'application au lieu d'être figé à ce qu'elle proposait le
    jour de l'installation.
    """
    ecarts = {
        cle: bool(valeur)
        for cle, valeur in corps.reglages.items()
        if cle in CATEGORIES and bool(valeur) != CATEGORIES[cle]["defaut"]
    }
    db.ecrit("UPDATE utilisateurs SET reglages_notifs = ? WHERE id = ?",
             (json.dumps(ecarts) if ecarts else "", u["id"]))
    return lit_reglages(u)


# Deux jours entre deux rappels de purge.
#
# Assez rare pour qu'on ne s'en agace pas, assez fréquent pour qu'un délai de
# sept jours en porte trois — la première avant qu'on ait oublié la photo, la
# dernière quand il est encore temps.
JOURS_ENTRE_RAPPELS = 2


def _rappelle_la_purge(utilisateur_id: int) -> None:
    """Prévient que des photos vont être effacées, si c'est le cas.

    Calculée à la lecture plutôt que par une tâche planifiée : le serveur n'a
    pas d'ordonnanceur, et lui en ajouter un pour une notification tous les
    deux jours serait une pièce mobile de plus à surveiller. Le joueur ouvre
    l'écran, on regarde.

    Le message dit un délai quand toutes les photos ont le même, et reste vague
    quand ils diffèrent : annoncer « 2 jours » alors que la moitié en a six
    ferait courir pour rien.
    """
    if config.JOURS_AVANT_PURGE <= 0 or not reglages_de(utilisateur_id)["purge"]:
        return

    dernier = db.valeur(
        """SELECT MAX(cree_le) FROM notifications
           WHERE destinataire = ? AND type = 'purge'""", (utilisateur_id,), None)
    if dernier:
        recent = db.valeur(
            "SELECT ? > datetime('now', ?)",
            (dernier, f"-{JOURS_ENTRE_RAPPELS} days"), 0)
        if recent:
            return

    jours = config.JOURS_AVANT_PURGE
    restants = [r["jours"] for r in db.lit(
        f"""SELECT CAST(julianday(cree_le, '+{int(jours)} days')
                        - julianday('now') AS INTEGER) AS jours
            FROM captures
            WHERE utilisateur = ? AND case_id IS NULL
              AND etat NOT IN ('attente', 'analyse')""",
        (utilisateur_id,))]
    if not restants:
        return

    ensemble = set(restants)
    if len(ensemble) == 1:
        j = max(0, restants[0])
        valeur = j
    else:
        valeur = -1                      # plusieurs délais : on reste vague

    db.ecrit(
        """INSERT INTO notifications (destinataire, auteur, type, valeur)
           VALUES (?, NULL, 'purge', ?)""",
        (utilisateur_id, valeur))


@routeur.get("/notifications")
def liste(limite: int = Query(default=50, ge=1, le=200),
          u=Depends(utilisateur)):
    _rappelle_la_purge(u["id"])
    from .reactions import EMOJIS, NOMS, POINTS

    lignes = db.lit(
        """SELECT n.id, n.type, n.valeur, n.lu, n.cree_le, n.capture, n.apercu,
                  x.id AS auteur_id, x.pseudo, x.avatar,
                  c.titre, c.decoupe, c.case_id, c.prise_le,
                  ap.decoupe AS apercu_decoupe, ap.prise_le AS apercu_prise_le,
                  d.latin, d.nom_fr, d.rarete
           FROM notifications n
           LEFT JOIN utilisateurs x ON x.id = n.auteur
           LEFT JOIN captures c ON c.id = n.capture
           -- La photo représentative d'une notification groupée (`ami_actif`) :
           -- `capture` y reste NULL exprès, voir `previens_activite`.
           LEFT JOIN captures ap ON ap.id = n.apercu
           LEFT JOIN cases d ON d.id = c.case_id
           WHERE n.destinataire = ?
           ORDER BY n.lu, n.cree_le DESC
           LIMIT ?""",
        (u["id"], limite))

    def sortie(r):
        # La photo à montrer : la sienne si la notification en parle
        # directement (réaction, identification), sinon celle qui la
        # représente (une trouvaille parmi celles qu'on annonce).
        photo = r["capture"] or r["apercu"]
        decoupe = r["decoupe"] if r["capture"] else r["apercu_decoupe"]
        prise_le = r["prise_le"] if r["capture"] else r["apercu_prise_le"]
        return {
            "id": r["id"], "type": r["type"], "lu": bool(r["lu"]),
            "cree_le": r["cree_le"],
            # Le moment où la photo a été prise, quand on le connaît — distinct
            # de `cree_le`, qui est celui où la notification est née (proche de
            # la mise en ligne). Les deux sont exposés : c'est au client de
            # choisir lequel afficher et trier.
            "prise_le": prise_le,
            # Une alerte de purge ne vient de personne : elle décrit un
            # délai qui court, pas quelqu'un qui a agi.
            "auteur": r["auteur_id"], "pseudo": r["pseudo"] or "",
            "jours_restants": r["valeur"] if r["type"] == "purge" else None,
            # `valeur` sert à chaque type ce dont il a besoin : un délai
            # pour la purge, une réaction pour un applaudissement, et ici
            # le nombre de trouvailles regroupées sous une seule ligne.
            "nb_trouvailles": (r["valeur"] or 1)
                              if r["type"] == "ami_actif" else None,
            "avatar": f"/utilisateurs/{r['auteur_id']}/avatar" if r["avatar"] else None,
            # La photo précise sur laquelle agir — nulle pour `ami_actif`, qui
            # n'en désigne aucune en particulier : cliquer y mène au profil de
            # l'ami, pas à une photo choisie au hasard parmi les siennes.
            "capture_id": r["capture"],
            # `espece_ajoutee` ne porte pas de capture — l'espèce, elle,
            # voyage dans `valeur` (voir `especes.py`) plutôt que dans une
            # jointure. Sans ce repli, la notification n'avait aucune case à
            # proposer et restait sans effet au clic, côté app comme web.
            "case_id": r["valeur"] if r["type"] == "espece_ajoutee" else r["case_id"],
            "titre": r["titre"] or "",
            "espece": r["nom_fr"] or r["latin"] or "",
            "qualite": r["rarete"] or 0,
            "emoji": EMOJIS.get(r["valeur"], ""),
            "reaction": NOMS.get(r["valeur"], ""),
            "points": POINTS.get(r["valeur"], 0),
            "vignette": f"/captures/{photo}/vignette" if photo else None,
            "decoupe": f"/captures/{photo}/decoupe" if photo and decoupe else None,
        }

    return {
        "notifications": [sortie(r) for r in lignes],
        "non_lues": db.valeur(
            "SELECT COUNT(*) FROM notifications WHERE destinataire = ? AND lu = 0",
            (u["id"],), 0),
    }


@routeur.post("/notifications/lues", status_code=204)
def marque_lues(u=Depends(utilisateur)):
    db.ecrit("UPDATE notifications SET lu = 1 WHERE destinataire = ?", (u["id"],))


@routeur.delete("/notifications", status_code=204)
def vide(u=Depends(utilisateur)):
    db.ecrit("DELETE FROM notifications WHERE destinataire = ?", (u["id"],))


@routeur.get("/notifications/flux")
async def fil(requete: Request, u=Depends(utilisateur)):
    """Reste ouvert et dit « du neuf » quand il y en a.

    **Pas de sondage.** La connexion dort tant que rien n'arrive ; c'est
    `previens()` qui la réveille, au moment exact de l'écriture. Voir
    `biodex/flux.py` pour le pourquoi.

    **Le battement de cœur.** Toutes les vingt-cinq secondes, un commentaire
    SSE (`: .`) part sur la ligne. Il ne sert à rien côté client — il sert à
    empêcher un intermédiaire de couper une connexion qu'il croit morte. Vingt-
    cinq secondes parce que le délai d'inactivité le plus court qu'on croise
    couramment, chez les hébergeurs comme chez les proxys mobiles, est de
    trente.

    **Le jeton reste dans l'en-tête.** `EventSource`, l'objet du navigateur
    prévu pour ça, ne sait pas en poser — il aurait fallu mettre le jeton dans
    l'URL, donc dans les journaux du serveur et dans l'historique. Le client
    lit ce flux avec `fetch()` à la place, qui accepte les en-têtes.
    """
    uid = u["id"]
    file = flux.abonne(uid)

    async def source():
        try:
            # Un premier message immédiat : il confirme au client que la
            # connexion est établie, ce qui lui permet de remettre son délai de
            # reconnexion à zéro sans attendre le premier vrai événement.
            yield b"event: ouvert\ndata: 1\n\n"
            while True:
                if await requete.is_disconnected():
                    return
                try:
                    quoi = await asyncio.wait_for(file.get(), timeout=25)
                except asyncio.TimeoutError:
                    yield b": .\n\n"
                    continue
                yield f"event: {quoi}\ndata: 1\n\n".encode()
        finally:
            # Quoi qu'il arrive — client parti, serveur qui s'arrête, erreur —
            # l'abonnement doit être rendu. C'est la seule fuite possible ici.
            flux.oublie(uid, file)

    return StreamingResponse(source(), media_type="text/event-stream", headers={
        # Un proxy qui met en tampon un flux d'événements le rend inutile :
        # tout arrive d'un coup à la fermeture. `X-Accel-Buffering` est ce que
        # nginx comprend, et nginx est devant en production.
        "Cache-Control": "no-cache, no-transform",
        "X-Accel-Buffering": "no",
        "Connection": "keep-alive",
    })
