"""
Envoi d'une photo, suivi de son analyse, consultation des captures.

Le parcours normal : l'app poste la photo, reçoit aussitôt une capture à l'état
« attente », puis interroge `GET /captures/{id}` jusqu'à ce que l'état change.
Une quinzaine de secondes plus tard, la case est remplie.
"""
import datetime

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, UploadFile, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from .. import acces, auth, cache, config, db, images, moteur
from ..dependances import Pagination, utilisateur
from . import notifications
from .amis import sont_amis


def maintenant() -> str:
    """L'instant présent, au format des dates de la base.

    En UTC, comme `datetime('now')` de SQLite : `cree_le` et `prise_le` se
    comparent et se trient ensemble un peu partout, et mélanger deux fuseaux
    dans la même colonne ferait remonter des photos d'aujourd'hui après celles
    de demain.
    """
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M:%S")

routeur = APIRouter(tags=["captures"])

# Les règnes que le dex sait traiter, chacun avec son moteur.
#
# « aquatique » n'en est pas un au sens de la biologie : un poisson est un
# animal, et sa case est une case animale. C'est un aiguillage — il envoie la
# photo vers un catalogue réduit aux poissons — et la capture est enregistrée
# telle quelle, ce qui permet de savoir plus tard par quel chemin elle est
# passée sans que cela change où elle atterrit.
REGNES = ("animal", "plante", "champignon", "aquatique")

ETATS_FINIS = ("ok", "doute", "rejet", "erreur")


def _capture_sortie(r, avec_top: bool = False) -> dict:
    d = {
        "id": r["id"], "etat": r["etat"], "verdict": r["verdict"], "latin": r["latin"],
        "niveau": r["niveau"], "confiance": round(r["confiance"], 4), "note": r["note"],
        "duree": round(r["duree"], 2), "case_id": r["case_id"],
        "cree_le": r["cree_le"], "fini_le": r["fini_le"],
        "regne": r["regne"] if "regne" in r.keys() else "animal",
        "moteur": r["moteur"] if "moteur" in r.keys() else "",
        "lat": r["lat"], "lon": r["lon"], "prise_le": r["prise_le"],
        "source_position": r["source_position"] if "source_position" in r.keys() else "",
        "source_heure": r["source_heure"] if "source_heure" in r.keys() else "",
        "lieu": r["lieu"] if "lieu" in r.keys() else "",
        "titre": r["titre"] if "titre" in r.keys() else "",
        "partage": bool(r["partage"]), "utilisateur": r["utilisateur"],
        "photo": f"/captures/{r['id']}/photo",
        "vignette": f"/captures/{r['id']}/vignette",
        "corrigee": bool(r["corrigee"]) if "corrigee" in r.keys() else False,
        # Présente seulement si le détourage a donné quelque chose ; l'app
        # retombe sur la vignette carrée dans le cas contraire.
        "decoupe": f"/captures/{r['id']}/decoupe"
                   if "decoupe" in r.keys() and r["decoupe"] else None,
    }
    if "pseudo" in r.keys():
        d["pseudo"] = r["pseudo"]
    if "nom_fr" in r.keys():
        d["case"] = {"id": r["case_id"], "latin": r["case_latin"], "nom_fr": r["nom_fr"]} \
            if r["case_id"] else None
    if avec_top:
        # Les co-signataires, chargés seulement pour la vue détaillée : une
        # requête par ligne saborderait la galerie, qui en affiche quarante.
        d["participants"] = [
            {"id": x["id"], "pseudo": x["pseudo"],
             "avatar": f"/utilisateurs/{x['id']}/avatar" if x["avatar"] else None}
            for x in db.lit(
                """SELECT x.id, x.pseudo, x.avatar
                   FROM participants p JOIN utilisateurs x ON x.id = p.utilisateur
                   WHERE p.capture = ? ORDER BY p.cree_le""",
                (r["id"],))
        ]
        # La silhouette et l'illustration accompagnent chaque piste : devant
        # « Pica pica » contre « Corvus corone », un dessin tranche plus vite
        # qu'un binôme latin.
        d["top"] = [
            {"rang": t["rang"], "latin": t["latin"], "nom_fr": t["nom_fr"],
             "proba": round(t["proba"], 4), "case_id": t["case_id"],
             "visuel": f"/visuels/{t['visuel']}" if t["visuel"] else None,
             "image": t["image"] or None,
             "rarete": t["rarete"], "points": t["points"],
             "regne": t["regne"], "toxique": bool(t["toxique"]),
             "resume": (t["resume"] or "")[:400]}
            for t in db.lit(
                """SELECT t.rang, t.latin, t.nom_fr, t.proba, t.case_id,
                          v.fichier AS visuel, f.image, f.resume,
                          c.rarete, c.points, c.regne, c.toxique
                   FROM captures_top t
                   LEFT JOIN cases c ON c.id = t.case_id
                   LEFT JOIN visuels v ON v.id = c.visuel
                   LEFT JOIN fiches f ON f.case_id = t.case_id
                   WHERE t.capture = ? ORDER BY t.rang""",
                (r["id"],))
        ]
    return d


def _capture_ou_404(capture_id: int, uid: int, lecture: bool = False):
    """Récupère une capture. En lecture, un ami y a accès si elle est partagée.

    Être identifié sur une photo donne le droit de la voir, jamais celui de la
    modifier ni de l'effacer : le fichier reste à son auteur. Un participant
    peut seulement se retirer, ce qui passe par sa propre route.
    """
    r = db.lit_un(
        """SELECT c.*, u.pseudo, d.latin AS case_latin, d.nom_fr
           FROM captures c
           JOIN utilisateurs u ON u.id = c.utilisateur
           LEFT JOIN cases d ON d.id = c.case_id
           WHERE c.id = ?""", (capture_id,))
    if r is None:
        raise HTTPException(404, "Capture introuvable.")
    if r["utilisateur"] != uid:
        autorise = lecture and (
            _participe(capture_id, uid)
            or (r["partage"] and sont_amis(uid, r["utilisateur"])))
        if not autorise:
            raise HTTPException(403, "Cette capture ne vous appartient pas.")
    return r


def _participe(capture_id: int, uid: int) -> bool:
    """Ce joueur est-il identifié sur cette photo ?"""
    return db.lit_un(
        "SELECT 1 FROM participants WHERE capture = ? AND utilisateur = ?",
        (capture_id, uid)) is not None


def _signataires(cx, capture_id: int, auteur: int) -> list[int]:
    """Tous ceux à qui cette photo compte : l'auteur et les identifiés.

    L'auteur d'abord, parce que c'est lui qui garde la case si les autres se
    retirent, et que `premiere` doit pointer vers quelqu'un de stable.
    """
    autres = [r["utilisateur"] for r in cx.execute(
        "SELECT utilisateur FROM participants WHERE capture = ?", (capture_id,))]
    return [auteur, *(a for a in autres if a != auteur)]


def _donne_decouverte(cx, utilisateur: int, case_id: int, capture_id: int) -> None:
    """Range une capture dans le dex d'un joueur.

    Première découverte ou capture supplémentaire sur une case déjà remplie :
    une seule requête pour les deux. Les points suivent d'eux-mêmes, puisqu'ils
    se calculent en sommant les cases de `decouvertes` — un participant est
    donc payé exactement comme s'il avait pris la photo, ce qui est le sujet.
    """
    cx.execute(
        """INSERT INTO decouvertes (utilisateur, case_id, premiere, vedette)
           VALUES (?,?,?,?)
           ON CONFLICT(utilisateur, case_id) DO UPDATE SET
               nb_captures = nb_captures + 1""",
        (utilisateur, case_id, capture_id, capture_id))


@routeur.post("/captures", status_code=202)
async def depose(photo: UploadFile = File(...),
                 analyse: UploadFile | None = File(default=None),
                 decoupe: UploadFile | None = File(default=None),
                 lat: float | None = Form(default=None),
                 lon: float | None = Form(default=None),
                 partage: bool = Form(default=True),
                 regne: str = Form(default="animal"),
                 titre: str = Form(default="", max_length=120),
                 instantanee: bool = Form(default=True),
                 u=Depends(utilisateur)):
    """Dépose une photo dans la file d'analyse.

    Répond 202 : la photo est acceptée et rangée, mais le verdict n'est pas
    encore connu. L'app suit l'avancement sur `GET /captures/{id}`.

    `regne` dit à quel moteur confier la photo — animal, plante ou champignon.
    Le deviner à partir de l'image reviendrait à faire tourner les trois chaînes
    sur chaque cliché, pour une information que le joueur connaît déjà.

    `instantanee` dit si la photo vient d'être prise. C'est ce qui sépare une
    position juste d'une position inventée : sur un cliché pris à l'instant,
    « ici » et « maintenant » sont la vérité ; sur une photo tirée de la
    galerie, ce ne sont qu'un pis-aller, et la capture est marquée comme telle
    pour qu'on propose de la corriger.

    ## Trois images pour une photo

    `photo` est l'originale, et c'est la seule qu'on garde. Elle sert à tout ce
    qui suit : la galerie, la carte, le dex, le partage.

    `analyse` est la version retouchée — éclaircie, recadrée, la bête entourée
    au doigt. C'est elle qu'on soumet au moteur, parce qu'elle pose la question
    plus clairement. Elle est effacée dès le verdict rendu.

    `decoupe` est le tracé du joueur, sur fond transparent. Il remplace le
    détourage automatique, qui garde souvent la branche ou coupe une patte.

    Les deux dernières sont facultatives : sans elles, on analyse et on détoure
    l'originale, comme avant.
    """
    if regne not in REGNES:
        raise HTTPException(400, f"Règne inconnu : {regne!r}.")
    blob = await photo.read()
    try:
        fichier, vignette, meta = images.enregistre(blob, u["id"])
    except images.ImageInvalide as e:
        raise HTTPException(400, str(e)) from e

    # La position inscrite dans la photo l'emporte sur celle du téléphone : la
    # première dit où la bête a été vue, la seconde seulement où l'on se
    # trouvait en vidant sa galerie, ce qui peut être très loin.
    #
    # À défaut d'EXIF on retient quand même le contexte de l'envoi, plutôt que
    # de laisser la photo sans date ni lieu : une valeur approchée vaut mieux
    # que rien, à condition de dire qu'elle est approchée. D'où « appareil »
    # pour une photo prise à l'instant — où « ici » est juste — et « defaut »
    # pour une photo tirée de la galerie, où ce n'est qu'une supposition.
    approche = "appareil" if instantanee else "defaut"
    if meta.lat is not None:
        lat, lon, source_position = meta.lat, meta.lon, "exif"
    elif lat is not None and lon is not None:
        source_position = approche
    else:
        source_position = ""

    if meta.prise_le:
        prise_le, source_heure = meta.prise_le, "exif"
    else:
        prise_le, source_heure = maintenant(), approche

    # La version à analyser, si le joueur en a préparé une.
    #
    # Elle est rangée à côté de l'originale plutôt que gardée en mémoire :
    # l'analyse est asynchrone, elle peut se produire une minute plus tard et
    # dans un autre fil.
    nom_analyse = None
    if analyse is not None:
        try:
            nom_analyse, _, _ = images.enregistre(await analyse.read(), u["id"])
        except images.ImageInvalide as e:
            raise HTTPException(400, f"Image d'analyse : {e}") from e

    nom_decoupe = None
    if decoupe is not None:
        try:
            nom_decoupe = images.decoupe_a_la_main(fichier, await decoupe.read())
        except images.ImageInvalide as e:
            raise HTTPException(400, f"Découpe : {e}") from e

    cur = db.ecrit(
        """INSERT INTO captures (utilisateur, fichier, fichier_analyse, vignette,
                                 decoupe, lat, lon, prise_le,
                                 source_position, source_heure, partage, regne, titre)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (u["id"], fichier, nom_analyse, vignette, nom_decoupe, lat, lon, prise_le,
         source_position, source_heure, int(partage), regne, titre.strip()))
    moteur.file.relance()

    r = db.lit_un("SELECT * FROM captures WHERE id = ?", (cur.lastrowid,))
    sortie = _capture_sortie(r)
    sortie["position_file"] = moteur.file.en_attente()
    return sortie


@routeur.get("/captures")
def mes_captures(p: Pagination = Depends(),
                 etat: str | None = Query(default=None),
                 case_id: int | None = Query(default=None),
                 u=Depends(utilisateur)):
    sql = """SELECT c.*, u.pseudo, d.latin AS case_latin, d.nom_fr
             FROM captures c
             JOIN utilisateurs u ON u.id = c.utilisateur
             LEFT JOIN cases d ON d.id = c.case_id
             WHERE c.utilisateur = ?"""
    params: list = [u["id"]]
    if etat:
        sql += " AND c.etat = ?"
        params.append(etat)
    if case_id:
        sql += " AND c.case_id = ?"
        params.append(case_id)
    sql += " ORDER BY c.id DESC LIMIT ? OFFSET ?"
    params += [p.limite, p.depuis]
    return {"captures": [_capture_sortie(r) for r in db.lit(sql, params)]}


def purge_non_identifiees(utilisateur_id: int | None = None) -> int:
    """Efface les photos que rien ne rattache à une espèce.

    Une photo dont le moteur n'a rien tiré, et que le joueur n'a pas corrigée,
    n'apparaît ni sur la carte ni dans la galerie : elle ne fait qu'occuper de
    la place. On lui laisse quelques jours — le temps que son auteur la range
    dans une case — puis elle s'en va.

    **Toutes** les photos sans espèce, y compris celles qu'on a détachées à la
    main et celles qui portent un lieu et une date. Elles étaient exemptées au
    motif qu'un détachement est une décision : c'était confondre deux choses.
    Décider qu'une identification était fausse ne dit rien de ce qu'il faut
    faire de la photo, et l'exemption laissait s'accumuler des clichés que rien
    n'atteignait plus. Le joueur est prévenu tous les deux jours ; passé le
    délai, il a choisi.
    """
    if config.JOURS_AVANT_PURGE <= 0:
        return 0

    conditions = ["case_id IS NULL",
                  "etat NOT IN ('attente', 'analyse')",
                  f"cree_le < datetime('now', '-{int(config.JOURS_AVANT_PURGE)} days')"]
    params: list = []
    if utilisateur_id is not None:
        conditions.append("utilisateur = ?")
        params.append(utilisateur_id)

    lignes = db.lit(
        f"SELECT id, fichier, fichier_analyse FROM captures "
        f"WHERE {' AND '.join(conditions)}", params)
    if not lignes:
        return 0

    marques = ",".join("?" * len(lignes))
    db.ecrit(f"DELETE FROM captures WHERE id IN ({marques})",
             [r["id"] for r in lignes])
    for r in lignes:
        images.supprime(r["fichier"])
        if r["fichier_analyse"]:
            images.supprime(r["fichier_analyse"])
    return len(lignes)


@routeur.get("/captures/non-identifiees")
def non_identifiees(u=Depends(utilisateur)):
    """Mes photos sans espèce : ni sur la carte, ni dans la galerie.

    L'application s'en sert pour proposer de les ranger ou de les jeter, plutôt
    que de les laisser s'accumuler sans que personne ne le sache.
    """
    lignes = db.lit(
        """SELECT id, etat, verdict, cree_le, note FROM captures
           WHERE utilisateur = ? AND case_id IS NULL
             AND etat NOT IN ('attente','analyse')
           ORDER BY id DESC LIMIT 200""", (u["id"],))
    return {
        "captures": [
            {"capture_id": r["id"], "etat": r["etat"],
             "verdict": r["verdict"] or "Non identifiée",
             "cree_le": r["cree_le"],
             "vignette": f"/captures/{r['id']}/vignette"}
            for r in lignes
        ],
        "jours_avant_purge": config.JOURS_AVANT_PURGE,
    }


@routeur.delete("/captures/non-identifiees")
def supprime_non_identifiees(u=Depends(utilisateur)):
    """Jette d'un coup toutes mes photos sans espèce."""
    lignes = db.lit(
        """SELECT id, fichier, fichier_analyse FROM captures
           WHERE utilisateur = ? AND case_id IS NULL
             AND etat NOT IN ('attente','analyse')""", (u["id"],))
    if lignes:
        marques = ",".join("?" * len(lignes))
        db.ecrit(f"DELETE FROM captures WHERE id IN ({marques})",
                 [r["id"] for r in lignes])
        for r in lignes:
            images.supprime(r["fichier"])
            if r["fichier_analyse"]:
                images.supprime(r["fichier_analyse"])
    return {"supprimees": len(lignes)}


class Lot(BaseModel):
    """Les photos qu'on jette d'un même geste."""
    ids: list[int] = []


@routeur.post("/captures/non-identifiees/suppression")
def supprime_lot(corps: Lot, u=Depends(utilisateur)):
    """Jette une sélection de photos sans espèce.

    **Pourquoi une route de plus** plutôt que d'appeler `DELETE /captures/{id}`
    en boucle. Vider vingt photos depuis un téléphone, ce sont vingt allers-
    retours dont chacun peut échouer séparément — on se retrouve avec une
    sélection à moitié effacée et rien pour dire laquelle. Ici c'est une seule
    requête, un seul verdict.

    **Le garde-fou.** La requête ne retient que ce qui est à la fois à cette
    personne et sans espèce. Un identifiant de capture rangée dans le dex passe
    donc à travers sans rien casser : impossible de perdre une découverte par
    une sélection mal fichue, même en fabriquant la liste à la main. C'est la
    raison pour laquelle ce filtre est dans le SQL et non côté client.
    """
    if not corps.ids:
        return {"supprimees": 0}

    # Bornée : une liste sans fin ferait une requête SQL sans fin.
    demandes = corps.ids[:500]
    marques = ",".join("?" * len(demandes))
    lignes = db.lit(
        f"""SELECT id, fichier, fichier_analyse FROM captures
            WHERE id IN ({marques}) AND utilisateur = ? AND case_id IS NULL
              AND etat NOT IN ('attente','analyse')""",
        [*demandes, u["id"]])
    if not lignes:
        return {"supprimees": 0}

    gardes = ",".join("?" * len(lignes))
    db.ecrit(f"DELETE FROM captures WHERE id IN ({gardes})",
             [r["id"] for r in lignes])
    # Les fichiers après la base : si l'effacement disque échoue, il reste une
    # image que plus rien ne réclame — ennuyeux mais sans gravité. L'inverse
    # laisserait une ligne pointant sur un fichier disparu.
    for r in lignes:
        images.supprime(r["fichier"])
        if r["fichier_analyse"]:
            images.supprime(r["fichier_analyse"])
    return {"supprimees": len(lignes)}


@routeur.get("/captures/{capture_id}")
def une_capture(capture_id: int, u=Depends(utilisateur)):
    r = _capture_ou_404(capture_id, u["id"], lecture=True)
    # Ouvrir la photo d'un autre, c'est l'avoir vue : la carte s'en sert pour
    # ne mettre en avant que ce qu'on n'a pas encore regardé. Marqué ici, au
    # détail, et non dans les listes — passer devant une vignette n'est pas
    # la voir.
    if r["utilisateur"] != u["id"]:
        marque_vues(u["id"], [capture_id])
    return _capture_sortie(r, avec_top=True)


def marque_vues(utilisateur_id: int, ids: list[int]) -> int:
    """Note que ce joueur a vu ces photos. Les siennes sont ignorées."""
    if not ids:
        return 0
    marques = ",".join("?" * len(ids))
    with db.transaction() as cx:
        cur = cx.execute(
            f"""INSERT OR IGNORE INTO photos_vues (utilisateur, capture)
                SELECT ?, id FROM captures
                 WHERE id IN ({marques}) AND utilisateur <> ?""",
            [utilisateur_id, *ids, utilisateur_id])
        return cur.rowcount


@routeur.post("/captures/vues")
def marque_lot_vu(corps: Lot, u=Depends(utilisateur)):
    """« Tout marquer comme vu » : la carte envoie d'un coup les photos qu'elle
    montre en nouveautés, et le fil repart à zéro."""
    return {"vues": marque_vues(u["id"], corps.ids[:2000])}


@routeur.delete("/captures/{capture_id}", status_code=204)
def supprime_capture(capture_id: int, u=Depends(utilisateur)):
    r = _capture_ou_404(capture_id, u["id"])
    with db.transaction() as cx:
        # Si c'était la seule capture de la case, la case redevient vide ;
        # sinon la découverte survit et perd juste une photo.
        #
        # Pour tous les signataires, pas seulement l'auteur : `decouvertes`
        # référence `premiere` en cascade, si bien qu'effacer la photo
        # effacerait d'un bloc la découverte de chaque participant — y compris
        # celui qui a dix autres clichés de l'espèce. On les fait donc passer
        # par le décompte ordinaire avant que la cascade ne s'en mêle.
        if r["case_id"]:
            for signataire in _signataires(cx, capture_id, r["utilisateur"]):
                _retire_decouverte(cx, signataire, r["case_id"], capture_id)
        cx.execute("DELETE FROM captures WHERE id = ?", (capture_id,))
    images.supprime(r["fichier"])
    # L'image d'analyse survit à une analyse qui a échoué : elle part avec la
    # capture, sinon elle resterait sur le disque sans que rien n'y renvoie.
    if "fichier_analyse" in r.keys() and r["fichier_analyse"]:
        images.supprime(r["fichier_analyse"])


class ChoixEspece(BaseModel):
    """Le joueur tranche lui-même. `case_id` à None détache la capture de toute
    espèce, pour revenir en arrière sur une reconnaissance erronée."""
    case_id: int | None = None


def _retire_decouverte(cx, utilisateur: int, case_id: int, capture_id: int) -> None:
    """Défait le rattachement d'une capture à une case.

    La découverte ne disparaît que si cette capture était la dernière de la
    case : on ne perd pas une espèce trouvée parce qu'on corrige une des photos.
    """
    d = cx.execute(
        "SELECT nb_captures, vedette FROM decouvertes WHERE utilisateur = ? AND case_id = ?",
        (utilisateur, case_id)).fetchone()
    if d is None:
        return
    if d["nb_captures"] <= 1:
        cx.execute("DELETE FROM decouvertes WHERE utilisateur = ? AND case_id = ?",
                   (utilisateur, case_id))
        return
    cx.execute(
        """UPDATE decouvertes SET nb_captures = nb_captures - 1,
               vedette = CASE WHEN vedette = ? THEN NULL ELSE vedette END
           WHERE utilisateur = ? AND case_id = ?""",
        (capture_id, utilisateur, case_id))
    # Si la capture retirée était aussi la « première », on réattribue le rôle.
    #
    # La relève se cherche parmi toutes les photos qui comptent pour ce joueur,
    # y compris celles où on l'a identifié. En ne regardant que les siennes on
    # laissait un participant avec un `premiere` pointant vers la capture qu'on
    # venait de lui retirer : sa case affichait alors une photo à laquelle il
    # n'avait plus droit.
    cx.execute(
        f"""UPDATE decouvertes
               SET premiere = COALESCE(
                     (SELECT MIN(c.id) FROM captures c
                       WHERE c.case_id = :c AND c.id <> :cap
                         AND {acces.sienne()}),
                     premiere)
             WHERE utilisateur = :u AND case_id = :c AND premiere = :cap""",
        {"u": utilisateur, "c": case_id, "cap": capture_id})


@routeur.post("/captures/{capture_id}/espece")
def corrige_espece(capture_id: int, corps: ChoixEspece, u=Depends(utilisateur)):
    """Assigne à la main l'espèce d'une capture.

    Le moteur se trompe, ou ne reconnaît rien : le joueur cherche l'espèce dans
    le dex et tranche. Sa décision fait autorité — la capture est marquée comme
    corrigée et ne sera plus rejugée.
    """
    r = _capture_ou_404(capture_id, u["id"])
    ancienne = r["case_id"]

    cible = None
    if corps.case_id is not None:
        cible = db.lit_un("SELECT id, latin, nom_fr FROM cases WHERE id = ?",
                          (corps.case_id,))
        if cible is None:
            raise HTTPException(404, "Espèce introuvable dans le dex.")
    if ancienne == (cible["id"] if cible else None):
        return _capture_sortie(_capture_ou_404(capture_id, u["id"]), avec_top=True)

    with db.transaction() as cx:
        if ancienne is not None:
            for signataire in _signataires(cx, capture_id, r["utilisateur"]):
                _retire_decouverte(cx, signataire, ancienne, capture_id)
        if cible is None:
            cx.execute(
                """UPDATE captures SET case_id = NULL, etat = 'doute', corrigee = 1,
                       verdict = 'Indéterminé', latin = '', niveau = '',
                       note = 'Espèce retirée par le joueur.'
                   WHERE id = ?""", (capture_id,))
        else:
            cx.execute(
                """UPDATE captures SET case_id = ?, etat = 'ok', corrigee = 1,
                       verdict = ?, latin = ?, niveau = 'manuel', confiance = 1.0,
                       note = 'Espèce choisie par le joueur.'
                   WHERE id = ?""",
                (cible["id"], cible["nom_fr"] or cible["latin"], cible["latin"],
                 capture_id))
            for signataire in _signataires(cx, capture_id, r["utilisateur"]):
                _donne_decouverte(cx, signataire, cible["id"], capture_id)

    # Une capture que le moteur avait rejetée n'a pas de découpe : maintenant
    # qu'elle porte une espèce, elle mérite son vignettage détouré.
    if cible is not None and not r["decoupe"]:
        bbox = None
        if r["bbox"]:
            try:
                bbox = tuple(float(v) for v in r["bbox"].split(","))
            except ValueError:
                bbox = None
        nom = images.decoupe(r["fichier"], bbox)
        if nom:
            db.ecrit("UPDATE captures SET decoupe = ? WHERE id = ?", (nom, capture_id))

    return _capture_sortie(_capture_ou_404(capture_id, u["id"]), avec_top=True)


class Titre(BaseModel):
    """Le nom que le joueur donne à sa photo."""
    titre: str = Field(default="", max_length=120)


@routeur.post("/captures/{capture_id}/reprise", status_code=202)
async def reprend(capture_id: int, photo: UploadFile = File(...),
                  u=Depends(utilisateur)):
    """Remplace l'image d'une photo non identifiée et relance l'analyse.

    Le moteur échoue souvent pour des raisons qu'un humain corrige en dix
    secondes : la bête occupe un dixième du cadre, la photo est sombre, une
    branche traverse le sujet. Recadrer et éclaircir vaut mieux que ressortir
    la photographier.

    **Réservé aux captures sans espèce.** Rejuger une photo déjà rangée
    poserait une question sans bonne réponse : que faire de la case, des points
    et des co-signataires pendant que le moteur réfléchit ? On l'évite au lieu
    d'y répondre mal — et c'est de toute façon le seul cas qui nous intéresse.

    La date, le lieu, le titre et les participants sont conservés : c'est la
    même observation, seule l'image change.
    """
    r = _capture_ou_404(capture_id, u["id"])
    if r["case_id"] is not None:
        raise HTTPException(
            409, "Cette photo est déjà rangée dans une espèce. "
                 "Détachez-la d'abord si vous voulez la faire réanalyser.")
    if r["etat"] in ("attente", "analyse"):
        raise HTTPException(409, "Cette photo est déjà en cours d'analyse.")

    blob = await photo.read()
    try:
        fichier, vignette, _ = images.enregistre(blob, u["id"])
    except images.ImageInvalide as e:
        raise HTTPException(400, str(e)) from e

    ancien = r["fichier"]
    with db.transaction() as cx:
        cx.execute("DELETE FROM captures_top WHERE capture = ?", (capture_id,))
        cx.execute(
            """UPDATE captures
                  SET fichier = ?, vignette = ?, decoupe = NULL, bbox = NULL,
                      etat = 'attente', verdict = '', latin = '', niveau = '',
                      confiance = 0, duree = 0, moteur = '', fini_le = NULL,
                      note = 'Photo retouchée par le joueur.'
                WHERE id = ?""",
            (fichier, vignette, capture_id))
    # L'ancienne image part seulement une fois la nouvelle en base : si
    # l'écriture échoue, on préfère un fichier orphelin à une capture qui
    # pointe vers un fichier disparu.
    images.supprime(ancien)
    moteur.file.relance()

    sortie = _capture_sortie(_capture_ou_404(capture_id, u["id"]), avec_top=True)
    sortie["position_file"] = moteur.file.en_attente()
    return sortie


@routeur.put("/captures/{capture_id}/decoupe")
async def redecoupe(capture_id: int, decoupe: UploadFile = File(...),
                    u=Depends(utilisateur)):
    """Remplace la vignette détourée par un tracé fait à la main.

    Le détourage automatique se trompe souvent : il garde la branche sur
    laquelle l'oiseau est perché, coupe une patte, ou n'attrape rien du tout
    sur une plante qui se confond avec son fond. Le joueur, lui, sait ce qu'il
    a photographié.

    **Rien d'autre ne bouge.** Ni l'espèce, ni la photo d'origine, ni la date,
    ni le lieu : on ne change que l'image qui représente la capture dans la
    grille. C'est une décision d'affichage, pas une correction de fond — et
    confondre les deux ferait perdre la photo à qui voulait juste une plus
    jolie vignette.
    """
    r = _capture_ou_404(capture_id, u["id"])   # l'auteur, et lui seul
    try:
        nom = images.decoupe_a_la_main(r["fichier"], await decoupe.read())
    except images.ImageInvalide as e:
        raise HTTPException(400, str(e)) from e

    db.ecrit("UPDATE captures SET decoupe = ? WHERE id = ?", (nom, capture_id))
    # La découpe porte le nom de la photo : le nouveau fichier a écrasé
    # l'ancien. Restent les miniatures déjà servies, qui montreraient encore le
    # tracé précédent.
    images.oublie_miniatures(nom)

    return _capture_sortie(_capture_ou_404(capture_id, u["id"]))


@routeur.delete("/captures/{capture_id}/decoupe")
def retire_decoupe(capture_id: int, u=Depends(utilisateur)):
    """Revient au détourage automatique.

    Le tracé du joueur est effacé, et le modèle reprend la main : c'est la
    porte de sortie quand on a raté son geste sur un écran de téléphone.
    """
    r = _capture_ou_404(capture_id, u["id"])
    nom = images.decoupe(r["fichier"], _bbox_de(r))
    if nom:
        images.oublie_miniatures(nom)
    db.ecrit("UPDATE captures SET decoupe = ? WHERE id = ?", (nom, capture_id))
    return _capture_sortie(_capture_ou_404(capture_id, u["id"]))


def _bbox_de(r) -> tuple[float, float, float, float] | None:
    """La boîte de MegaDetector telle qu'elle a été rangée, ou rien."""
    if "bbox" not in r.keys() or not r["bbox"]:
        return None
    try:
        return tuple(float(v) for v in r["bbox"].split(","))
    except ValueError:
        return None


class Identification(BaseModel):
    """Les amis présents au moment de la photo, par pseudo."""
    pseudos: list[str] = Field(default_factory=list, max_length=12)


@routeur.get("/captures/{capture_id}/participants")
def participants(capture_id: int, u=Depends(utilisateur)):
    """Qui est identifié sur cette photo, auteur compris."""
    r = _capture_ou_404(capture_id, u["id"], lecture=True)
    lignes = db.lit(
        """SELECT x.id, x.pseudo, x.avatar, p.cree_le, p.par
           FROM participants p JOIN utilisateurs x ON x.id = p.utilisateur
           WHERE p.capture = ? ORDER BY p.cree_le""",
        (capture_id,))
    return {
        "auteur": {
            "id": r["utilisateur"], "pseudo": r["pseudo"],
            "avatar": f"/utilisateurs/{r['utilisateur']}/avatar",
        },
        "participants": [
            {"id": x["id"], "pseudo": x["pseudo"],
             "avatar": f"/utilisateurs/{x['id']}/avatar" if x["avatar"] else None,
             "cree_le": x["cree_le"], "par": x["par"]}
            for x in lignes
        ],
    }


@routeur.post("/captures/{capture_id}/participants")
def identifie(capture_id: int, corps: Identification, u=Depends(utilisateur)):
    """Identifie des amis présents au moment de la photo.

    C'est l'inverse d'une duplication : au lieu que chacun photographie la même
    bête pour la compter, une seule photo vaut pour tout le monde. Un fichier,
    N comptes — le serveur ne stocke rien de plus, et le fil des amis ne montre
    pas trois fois le même renard.

    Chaque personne ajoutée reçoit la case et les points comme si elle avait
    pris la photo. C'est le principe : on était là tous les deux.

    Réservé à l'auteur, et aux seuls amis : identifier un inconnu reviendrait à
    lui imposer une photo dans son dex, et à lui donner accès à un cliché qu'il
    n'a pas demandé à voir.
    """
    r = _capture_ou_404(capture_id, u["id"])   # l'auteur, et lui seul
    ajoutes, refuses = [], []

    with db.transaction() as cx:
        for pseudo in corps.pseudos:
            cible = cx.execute(
                "SELECT id, pseudo FROM utilisateurs WHERE pseudo_norm = ? AND actif = 1",
                (auth.normalise_pseudo(pseudo),)).fetchone()
            if cible is None:
                refuses.append({"pseudo": pseudo, "raison": "introuvable"})
                continue
            if cible["id"] == u["id"]:
                refuses.append({"pseudo": pseudo, "raison": "c'est vous"})
                continue
            if not sont_amis(u["id"], cible["id"]):
                refuses.append({"pseudo": cible["pseudo"], "raison": "pas ami"})
                continue
            deja = cx.execute(
                "SELECT 1 FROM participants WHERE capture = ? AND utilisateur = ?",
                (capture_id, cible["id"])).fetchone()
            if deja:
                continue
            cx.execute(
                "INSERT INTO participants (capture, utilisateur, par) VALUES (?,?,?)",
                (capture_id, cible["id"], u["id"]))
            # La photo peut être déjà identifiée : dans ce cas la case tombe
            # tout de suite. Sinon elle tombera à la fin de l'analyse, qui
            # relit les participants.
            if r["case_id"] is not None:
                _donne_decouverte(cx, cible["id"], r["case_id"], capture_id)
            ajoutes.append({"id": cible["id"], "pseudo": cible["pseudo"]})

    for a in ajoutes:
        notifications.previens(a["id"], u["id"], "identifie", capture_id)

    return {"ajoutes": ajoutes, "refuses": refuses,
            **participants(capture_id, u)}


@routeur.delete("/captures/{capture_id}/participants/{utilisateur_id}",
                status_code=204)
def retire_participant(capture_id: int, utilisateur_id: int,
                       u=Depends(utilisateur)):
    """Retire quelqu'un d'une photo.

    Deux personnes peuvent le faire : l'auteur, qui s'est trompé d'ami, et
    l'intéressé lui-même, qui ne veut pas de cette photo dans son dex. Un tiers
    n'a rien à y faire, même s'il est identifié dessus.

    La case suit : elle disparaît si c'était la seule photo de l'espèce pour
    cette personne, et les points avec — sans quoi on garderait indéfiniment le
    bénéfice d'une photo dont on s'est retiré.
    """
    r = db.lit_un("SELECT utilisateur, case_id FROM captures WHERE id = ?",
                  (capture_id,))
    if r is None:
        raise HTTPException(404, "Capture introuvable.")
    if u["id"] not in (r["utilisateur"], utilisateur_id):
        raise HTTPException(403, "Vous ne pouvez retirer que vous-même.")

    with db.transaction() as cx:
        fait = cx.execute(
            "DELETE FROM participants WHERE capture = ? AND utilisateur = ?",
            (capture_id, utilisateur_id))
        if not fait.rowcount:
            raise HTTPException(404, "Cette personne n'est pas sur la photo.")
        if r["case_id"] is not None:
            _retire_decouverte(cx, utilisateur_id, r["case_id"], capture_id)
    notifications.oublie(utilisateur_id, r["utilisateur"], capture_id, "identifie")


@routeur.patch("/captures/{capture_id}/titre")
def renomme(capture_id: int, corps: Titre, u=Depends(utilisateur)):
    """Donne un titre à une photo, ou l'efface.

    L'espèce dit ce qu'on a vu, le titre dit ce qu'on a vécu : « le héron du
    canal, un matin de brume » n'est pas remplaçable par un nom latin.
    """
    _capture_ou_404(capture_id, u["id"])
    db.ecrit("UPDATE captures SET titre = ? WHERE id = ?",
             (corps.titre.strip(), capture_id))
    return _capture_sortie(_capture_ou_404(capture_id, u["id"]))


class Situation(BaseModel):
    """Le joueur situe lui-même sa photo : où, et quand.

    Chaque champ est facultatif — on peut corriger l'heure sans toucher au lieu.
    """
    lat: float | None = None
    lon: float | None = None
    prise_le: str | None = None
    lieu: str | None = None


@routeur.patch("/captures/{capture_id}/lieu")
def situe(capture_id: int, corps: Situation, u=Depends(utilisateur)):
    """Place une photo sur la carte, ou corrige sa date.

    Beaucoup de photos arrivent sans coordonnées : appareil sans GPS, position
    désactivée, ou métadonnées effacées par une messagerie. Plutôt que de les
    laisser hors du monde, le joueur pose le point lui-même.
    """
    _capture_ou_404(capture_id, u["id"])

    champs, params = [], {"id": capture_id}
    if corps.lat is not None and corps.lon is not None:
        if not (-90 <= corps.lat <= 90 and -180 <= corps.lon <= 180):
            raise HTTPException(400, "Coordonnées hors du monde.")
        champs += ["lat = :lat", "lon = :lon", "source_position = 'manuel'"]
        params |= {"lat": corps.lat, "lon": corps.lon}
    if corps.lieu is not None:
        champs.append("lieu = :lieu")
        params["lieu"] = corps.lieu[:200]
    if corps.prise_le is not None:
        # On accepte « 2026-08-16 14:30:00 » comme « 2026-08-16T14:30:00 ».
        texte = corps.prise_le.strip().replace("T", " ")
        try:
            datetime.datetime.fromisoformat(texte)
        except ValueError as e:
            raise HTTPException(400, "Date invalide (attendu AAAA-MM-JJ HH:MM:SS).") from e
        champs += ["prise_le = :prise_le", "source_heure = 'manuel'"]
        params["prise_le"] = texte

    if not champs:
        raise HTTPException(400, "Rien à modifier.")
    db.ecrit(f"UPDATE captures SET {', '.join(champs)} WHERE id = :id", params)
    return _capture_sortie(_capture_ou_404(capture_id, u["id"]))


@routeur.get("/captures/{capture_id}/decoupe")
def decoupe(requete: Request, capture_id: int, taille: int | None = Query(default=None, ge=32, le=512),
            u=Depends(utilisateur)):
    """L'animal détouré sur fond transparent.

    `taille` sert aux marqueurs de la carte, qui n'ont que faire d'une image de
    512 pixels : la version réduite est fabriquée une fois puis servie du cache.
    """
    r = _capture_ou_404(capture_id, u["id"], lecture=True)
    if not r["decoupe"]:
        raise HTTPException(404, "Pas de découpe pour cette capture.")
    chemin = images.chemin_sur(config.DECOUPES, r["decoupe"])
    if taille:
        chemin = images.miniature(chemin, taille)
    # Une découpe se refait : le joueur peut reprendre son tracé au doigt. Un
    # jour de cache, et l'empreinte change dès que le fichier est réécrit, donc
    # le nouveau tracé s'affiche immédiatement.
    type_ = "image/webp" if chemin.suffix.lower() == ".webp" else "image/png"
    return cache.fichier(requete, chemin, type_, cache.COURT)


@routeur.get("/captures/{capture_id}/photo")
def photo(requete: Request, capture_id: int, u=Depends(utilisateur)):
    """L'originale, la plus lourde de toutes — et la seule qui n'avait aucun
    en-tête de cache. Elle repartait en entier à chaque ouverture de la
    visionneuse. Une photo envoyée n'est jamais réécrite : un mois de cache."""
    r = _capture_ou_404(capture_id, u["id"], lecture=True)
    return cache.fichier(requete, images.chemin_sur(config.PHOTOS, r["fichier"]),
                         "image/jpeg", cache.LONG)


@routeur.get("/captures/{capture_id}/vignette")
def vignette(requete: Request, capture_id: int, taille: int | None = Query(default=None, ge=32, le=512),
             u=Depends(utilisateur)):
    r = _capture_ou_404(capture_id, u["id"], lecture=True)
    nom = r["vignette"] or r["fichier"]
    chemin = images.chemin_sur(config.VIGNETTES, nom)
    if taille:
        chemin = images.miniature(chemin, taille)
    return cache.fichier(requete, chemin, "image/jpeg", cache.LONG)


@routeur.get("/file")
def etat_file(_=Depends(utilisateur)):
    """Combien de photos attendent leur tour, et le moteur est-il chargé."""
    return {"en_attente": moteur.file.en_attente(),
            "moteur_pret": moteur.file.moteur._pret,
            "actif": not config.SANS_MOTEUR}
