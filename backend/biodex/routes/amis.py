"""
Amis : recherche de joueurs, demandes, fil d'activité.

Une relation est une seule ligne pour une paire, quel que soit le sens de la
demande — l'index unique sur (min, max) l'impose. Ça évite le cas classique où
A demande B pendant que B demande A et où l'on se retrouve avec deux liens qui
se contredisent.
"""
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from .. import acces, auth, db
from ..dependances import Pagination, utilisateur
from . import notifications

routeur = APIRouter(tags=["amis"])


class Demande(BaseModel):
    pseudo: str


def sont_amis(a: int, b: int) -> bool:
    if a == b:
        return True
    return db.lit_un(
        """SELECT 1 FROM amities WHERE etat = 'acceptee'
           AND ((demandeur = ? AND destinataire = ?) OR (demandeur = ? AND destinataire = ?))""",
        (a, b, b, a)) is not None


def _lien(a: int, b: int):
    return db.lit_un(
        """SELECT * FROM amities
           WHERE (demandeur = ? AND destinataire = ?) OR (demandeur = ? AND destinataire = ?)""",
        (a, b, b, a))


def _relation(moi: int, autre: int) -> str:
    """État de la relation vu de `moi` : aucune | envoyee | recue | amis | bloquee."""
    if moi == autre:
        return "moi"
    l = _lien(moi, autre)
    if l is None:
        return "aucune"
    if l["etat"] == "acceptee":
        return "amis"
    if l["etat"] == "bloquee":
        return "bloquee"
    return "envoyee" if l["demandeur"] == moi else "recue"


def _joueur(r, moi: int) -> dict:
    return {
        "id": r["id"], "pseudo": r["pseudo"], "bio": r["bio"],
        "avatar": f"/utilisateurs/{r['id']}/avatar" if r["avatar"] else None,
        "cases": db.valeur("SELECT COUNT(*) FROM decouvertes WHERE utilisateur = ?",
                           (r["id"],), 0),
        "relation": _relation(moi, r["id"]),
    }


@routeur.get("/utilisateurs")
def cherche(q: str = Query(min_length=1, max_length=32),
            p: Pagination = Depends(), u=Depends(utilisateur)):
    """Recherche par pseudo, sur la forme normalisée : accents et casse ignorés."""
    motif = f"%{auth.normalise_pseudo(q)}%"
    lignes = db.lit(
        """SELECT * FROM utilisateurs
           WHERE pseudo_norm LIKE ? AND actif = 1 AND id <> ?
           ORDER BY LENGTH(pseudo_norm), pseudo_norm LIMIT ? OFFSET ?""",
        (motif, u["id"], p.limite, p.depuis))
    return {"utilisateurs": [_joueur(r, u["id"]) for r in lignes]}


@routeur.get("/utilisateurs/{utilisateur_id}")
def profil_public(utilisateur_id: int, u=Depends(utilisateur)):
    r = db.lit_un("SELECT * FROM utilisateurs WHERE id = ? AND actif = 1", (utilisateur_id,))
    if r is None:
        raise HTTPException(404, "Joueur introuvable.")
    d = _joueur(r, u["id"])
    # Les trouvailles ne partent plus avec le profil : elles ont leur route, qui
    # pagine. Douze lignes en dur allongeaient chaque ouverture de profil pour
    # une liste qu'on ne déroule pas toujours, et il n'y avait aucun moyen d'en
    # voir la treizième.
    d["nb_trouvailles"] = db.valeur(
        "SELECT COUNT(*) FROM decouvertes WHERE utilisateur = ?",
        (utilisateur_id,), 0)
    d["vitrine"] = _vitrine_de(utilisateur_id, u["id"])
    d["succes"] = _succes_de(utilisateur_id, u["id"])
    d["vitrine_max"] = VITRINE_MAX
    return d


# ------------------------------------------------------- la vitrine de profil
#
# À ne pas confondre avec `biodex/vitrine.py`, qui calcule un rang à partir
# des trouvailles les plus rares. Celle-ci ne calcule rien : c'est une sélection
# à la main. Le classement montre ce qu'on a trouvé de plus rare, la galerie
# tout ce qu'on a pris ; ni l'un ni l'autre ne dit ce dont on est fier. La photo
# réussie d'un moineau ne vaut aucun point et vaut pourtant qu'on la montre.

# Six photos, pas plus. Une vitrine qui contient tout ne montre plus rien : la
# contrainte est ce qui oblige à choisir, et c'est le choix qu'on regarde.
VITRINE_MAX = 6


class ChoixVitrine(BaseModel):
    """Les captures à mettre en vitrine, dans l'ordre voulu."""
    captures: list[int]


def _vitrine_de(uid: int, moi: int) -> list[dict]:
    """Les photos qu'un joueur a choisi de montrer.

    On ne rend que ce que le regardeur a le droit de voir : la vitrine ne
    contourne pas le partage. Une photo repassée en privé après avoir été
    choisie disparaît d'elle-même de la vitrine des autres, sans qu'il faille y
    penser au moment de la rendre privée.
    """
    visible = "c.partage = 1" if uid != moi else "1=1"
    return [
        {"id": r["id"], "titre": r["titre"] or "",
         "nom": r["nom_fr"] or r["latin"] or "",
         "qualite": r["rarete"],
         "quand": r["prise_le"] or r["cree_le"],
         "lieu": r["lieu"] or "",
         "vignette": f"/captures/{r['id']}/vignette",
         "decoupe": f"/captures/{r['id']}/decoupe" if r["decoupe"] else None,
         "photo": f"/captures/{r['id']}/photo"}
        for r in db.lit(
            f"""SELECT c.id, c.titre, c.decoupe, c.cree_le, c.prise_le, c.lieu,
                       d.nom_fr, d.latin, d.rarete
                  FROM profil_vitrine v
                  JOIN captures c ON c.id = v.capture
                  LEFT JOIN cases d ON d.id = c.case_id
                 WHERE v.utilisateur = :u AND c.utilisateur = :u AND {visible}
                 ORDER BY v.rang, v.capture""",
            {"u": uid})
    ]


def _succes_de(uid: int, moi: int) -> list[dict]:
    """Les succès qu'un joueur a décrochés, tels que `moi` a le droit de les voir.

    **La règle du spoiler tient jusque sur le profil des autres.** On dit qu'un
    succès est débloqué — c'est une fierté, elle se montre — mais on ne montre
    la grenouille que si le regardeur l'a lui aussi décrochée. Sinon il
    apprendrait à quoi ressemble une récompense qu'il n'a pas gagnée, et ouvrir
    son propre cristal n'aurait plus rien à révéler.

    Le modèle et ses couleurs ne partent donc pas du serveur quand le regardeur
    n'y a pas droit. Les cacher à l'affichage seulement les laisserait lisibles
    dans la réponse, ce qui n'est pas un secret gardé.
    """
    from .. import succes as cat

    siens = {r["cle"]: r["obtenu_le"] for r in db.lit(
        """SELECT cle, obtenu_le FROM succes_obtenus
            WHERE utilisateur = ? AND obtenu = 1""", (uid,))}
    miens = set(siens) if uid == moi else {r["cle"] for r in db.lit(
        "SELECT cle FROM succes_obtenus WHERE utilisateur = ? AND obtenu = 1",
        (moi,))}

    sortie = []
    for s in cat.catalogue():
        if s["cle"] not in siens:
            continue
        montrable = s["cle"] in miens
        sortie.append({
            "cle": s["cle"], "nom": s["nom"], "emoji": s["emoji"],
            "difficulte": s["difficulte"],
            "obtenu_le": siens[s["cle"]],
            "montrable": montrable,
            "modele": cat.modele_de(s["modele"]) if montrable else None,
            "couleurs": cat.couleurs_de(s["modele"]) if montrable else None,
        })
    sortie.sort(key=lambda x: (x["obtenu_le"] or "", x["nom"]), reverse=True)
    return sortie


@routeur.get("/utilisateurs/{utilisateur_id}/trouvailles")
def trouvailles(utilisateur_id: int, p: Pagination = Depends(),
                _=Depends(utilisateur)):
    """Ce qu'un joueur a trouvé, des plus récentes aux plus anciennes.

    Paginé : quelqu'un qui joue depuis six mois en a des centaines, et on ne
    déroule pas trois cents lignes pour regarder les cinq dernières.

    Les découvertes d'un joueur sont publiques entre joueurs connectés — c'est
    déjà ce que montre le classement, et c'est ce qui donne envie d'aller
    chercher la même bête.
    """
    lignes = db.lit(
        """SELECT d.case_id, d.trouve_le, c.latin, c.nom_fr, c.rarete,
                  v.fichier AS visuel
             FROM decouvertes d
             JOIN cases c ON c.id = d.case_id
             LEFT JOIN visuels v ON v.id = c.visuel
            WHERE d.utilisateur = ?
            ORDER BY d.trouve_le DESC, d.case_id DESC
            LIMIT ? OFFSET ?""",
        (utilisateur_id, p.limite + 1, p.depuis))
    # Une ligne de plus que demandé : sa présence dit qu'il en reste, sans
    # coûter un second comptage.
    fin = len(lignes) <= p.limite
    return {
        "trouvailles": [
            {"case_id": x["case_id"], "latin": x["latin"], "nom_fr": x["nom_fr"],
             "rarete": x["rarete"], "trouve_le": x["trouve_le"],
             "visuel": f"/visuels/{x['visuel']}" if x["visuel"] else None}
            for x in lignes[:p.limite]
        ],
        "fin": fin,
    }


@routeur.get("/moi/vitrine/choix")
def choix_possibles(u=Depends(utilisateur)):
    """Les photos parmi lesquelles composer sa vitrine, et celles déjà dedans.

    Ses propres photos identifiées, les plus récentes d'abord. On ne propose pas
    les photos non identifiées : une vitrine de silhouettes grises ne montre
    rien.
    """
    return {
        "max": VITRINE_MAX,
        "choisies": [r["capture"] for r in db.lit(
            "SELECT capture FROM profil_vitrine WHERE utilisateur = ? ORDER BY rang",
            (u["id"],))],
        "photos": [
            {"id": r["id"], "titre": r["titre"] or "",
             "nom": r["nom_fr"] or r["latin"] or "",
             "qualite": r["rarete"],
             "vignette": f"/captures/{r['id']}/vignette",
             "decoupe": f"/captures/{r['id']}/decoupe" if r["decoupe"] else None}
            for r in db.lit(
                """SELECT c.id, c.titre, c.decoupe, d.nom_fr, d.latin, d.rarete
                     FROM captures c JOIN cases d ON d.id = c.case_id
                    WHERE c.utilisateur = ? AND c.case_id IS NOT NULL
                    ORDER BY c.id DESC LIMIT 120""", (u["id"],))
        ],
    }


@routeur.put("/moi/vitrine")
def change_vitrine(corps: ChoixVitrine, u=Depends(utilisateur)):
    """Choisit les photos de sa vitrine, dans l'ordre donné.

    On remplace la liste entière plutôt que d'ajouter et de retirer une à une :
    l'ordre fait partie du choix, et le client l'a déjà sous la main.
    """
    lot = list(dict.fromkeys(corps.captures))[:VITRINE_MAX]
    if lot:
        # On ne met en vitrine que ses propres photos. Sans ce contrôle,
        # n'importe quel identifiant permettrait d'afficher la photo d'un autre
        # sur son profil, et de la rendre ainsi visible à des gens à qui son
        # auteur ne l'a jamais montrée.
        siennes = {r["id"] for r in db.lit(
            f"""SELECT id FROM captures
                 WHERE utilisateur = ? AND id IN ({','.join('?' * len(lot))})""",
            (u["id"], *lot))}
        if [c for c in lot if c not in siennes]:
            raise HTTPException(400, "Ces photos ne sont pas les vôtres.")

    with db.transaction() as cx:
        cx.execute("DELETE FROM profil_vitrine WHERE utilisateur = ?", (u["id"],))
        cx.executemany(
            "INSERT INTO profil_vitrine (utilisateur, capture, rang) VALUES (?,?,?)",
            [(u["id"], c, i) for i, c in enumerate(lot)])
    return {"vitrine": _vitrine_de(u["id"], u["id"])}


@routeur.post("/amis/demandes", status_code=201)
def demande(corps: Demande, u=Depends(utilisateur)):
    cible = db.lit_un("SELECT * FROM utilisateurs WHERE pseudo_norm = ? AND actif = 1",
                      (auth.normalise_pseudo(corps.pseudo),))
    if cible is None:
        raise HTTPException(404, "Joueur introuvable.")
    if cible["id"] == u["id"]:
        raise HTTPException(400, "On ne peut pas s'ajouter soi-même.")

    l = _lien(u["id"], cible["id"])
    if l is not None:
        if l["etat"] == "acceptee":
            raise HTTPException(409, "Vous êtes déjà amis.")
        if l["etat"] == "bloquee":
            raise HTTPException(403, "Demande impossible.")
        if l["demandeur"] == u["id"]:
            raise HTTPException(409, "Demande déjà envoyée.")
        # L'autre nous avait déjà demandé : sa demande vaut acceptation.
        db.ecrit("""UPDATE amities SET etat = 'acceptee', repondu_le = datetime('now')
                    WHERE id = ?""", (l["id"],))
        # Chacun avait demandé l'autre : c'est accepté des deux côtés d'un coup.
        notifications.previens(cible["id"], u["id"], "ami_accepte")
        return {"etat": "acceptee", "utilisateur": _joueur(cible, u["id"])}

    db.ecrit("INSERT INTO amities (demandeur, destinataire) VALUES (?,?)",
             (u["id"], cible["id"]))
    # Une demande qu'on ne voit pas est une demande refusée.
    notifications.previens(cible["id"], u["id"], "ami_demande")
    return {"etat": "attente", "utilisateur": _joueur(cible, u["id"])}


@routeur.get("/amis/demandes")
def demandes(u=Depends(utilisateur)):
    # `a.id AS demande_id` et non `a.id` : avec `x.*`, deux colonnes
    # s'appelaient `id`, et une ligne SQLite rend la première. `_joueur` lisait
    # donc l'identifiant de la *demande* là où il attendait celui du joueur —
    # d'où un avatar pointant vers le mauvais compte, un compte d'espèces pris
    # à un tiers, et une relation calculée de travers.
    recues = db.lit(
        """SELECT a.id AS demande_id, a.cree_le, x.* FROM amities a
           JOIN utilisateurs x ON x.id = a.demandeur
           WHERE a.destinataire = ? AND a.etat = 'attente' ORDER BY a.cree_le DESC""",
        (u["id"],))
    envoyees = db.lit(
        """SELECT a.id AS demande_id, a.cree_le, x.* FROM amities a
           JOIN utilisateurs x ON x.id = a.destinataire
           WHERE a.demandeur = ? AND a.etat = 'attente' ORDER BY a.cree_le DESC""",
        (u["id"],))
    return {
        "recues": [{"demande_id": r["demande_id"], "cree_le": r["cree_le"],
                    **_joueur(r, u["id"])} for r in recues],
        "envoyees": [{"demande_id": r["demande_id"], "cree_le": r["cree_le"],
                      **_joueur(r, u["id"])} for r in envoyees],
    }


@routeur.post("/amis/demandes/{demande_id}/{reponse}")
def repond(demande_id: int, reponse: str, u=Depends(utilisateur)):
    if reponse not in ("accepter", "refuser"):
        raise HTTPException(400, "Réponse attendue : accepter ou refuser.")
    l = db.lit_un("SELECT * FROM amities WHERE id = ? AND etat = 'attente'", (demande_id,))
    if l is None:
        raise HTTPException(404, "Demande introuvable.")
    if l["destinataire"] != u["id"]:
        raise HTTPException(403, "Cette demande ne vous est pas adressée.")
    if reponse == "accepter":
        db.ecrit("""UPDATE amities SET etat = 'acceptee', repondu_le = datetime('now')
                    WHERE id = ?""", (demande_id,))
        notifications.previens(l["demandeur"], u["id"], "ami_accepte")
        return {"etat": "acceptee"}
    # Un refus efface la ligne : le demandeur pourra retenter plus tard.
    db.ecrit("DELETE FROM amities WHERE id = ?", (demande_id,))
    return {"etat": "refusee"}


@routeur.get("/amis")
def liste(p: Pagination = Depends(), u=Depends(utilisateur)):
    lignes = db.lit(
        """SELECT x.* FROM amities a
           JOIN utilisateurs x
             ON x.id = CASE WHEN a.demandeur = :u THEN a.destinataire ELSE a.demandeur END
           WHERE a.etat = 'acceptee' AND :u IN (a.demandeur, a.destinataire)
           ORDER BY x.pseudo LIMIT :l OFFSET :o""",
        {"u": u["id"], "l": p.limite, "o": p.depuis})
    return {"amis": [_joueur(r, u["id"]) for r in lignes]}


@routeur.delete("/amis/{utilisateur_id}", status_code=204)
def retire(utilisateur_id: int, u=Depends(utilisateur)):
    l = _lien(u["id"], utilisateur_id)
    if l is None:
        raise HTTPException(404, "Vous n'êtes pas amis.")
    db.ecrit("DELETE FROM amities WHERE id = ?", (l["id"],))


@routeur.get("/fil")
def fil(p: Pagination = Depends(), u=Depends(utilisateur)):
    """Les trouvailles récentes des amis, **regroupées par sortie**.

    Le fil listait les photos une par une. Avec cent amis à trois photos par
    jour, cela fait trois cents cartes à faire défiler pour arriver à celle de
    la veille, et autant de gestes pour applaudir. Le regroupement rend l'écran
    parcourable : une carte par sortie, dépliable.

    Une « sortie » = les mêmes signataires, le même jour. C'est le découpage
    qui correspond à ce qui s'est passé — on ne mélange pas la balade du matin
    avec celle du lendemain, ni les photos de Paul avec celles de Paul et Marie.

    Le regroupement est **d'affichage seulement** : chaque photo garde ses
    propres réactions, et le dépliage rend la liste complète. Réagir en bloc
    aurait faussé le comptage des points, qui se fait photo par photo.
    """
    # On lit large, puis on regroupe : le nombre de groupes n'est pas
    # prévisible depuis le nombre de photos, et paginer sur les photos en
    # coupant une sortie en deux donnerait deux cartes pour une seule journée.
    lignes = db.lit(
        f"""SELECT c.id, c.cree_le, c.prise_le, c.verdict, c.case_id,
                   c.utilisateur, c.decoupe, c.titre, c.lieu,
                   x.pseudo, x.avatar, d.latin AS case_latin, d.nom_fr, d.rarete
            FROM captures c
            JOIN utilisateurs x ON x.id = c.utilisateur
            JOIN cases d ON d.id = c.case_id
            WHERE c.etat = 'ok' AND c.partage = 1
              AND c.utilisateur <> :u
              AND {acces.visible()}
            ORDER BY c.id DESC LIMIT :l OFFSET :o""",
        {"u": u["id"], "l": p.limite * 6, "o": p.depuis})

    if not lignes:
        return {"groupes": [], "fin": True}

    # Qui signe quoi, en une requête plutôt qu'une par photo.
    ids = [r["id"] for r in lignes]
    marques = ",".join("?" * len(ids))
    cosignataires: dict[int, list[dict]] = {i: [] for i in ids}
    for r in db.lit(
            f"""SELECT pa.capture, x.id, x.pseudo, x.avatar
                FROM participants pa JOIN utilisateurs x ON x.id = pa.utilisateur
                WHERE pa.capture IN ({marques})""", ids):
        cosignataires[r["capture"]].append(
            {"id": r["id"], "pseudo": r["pseudo"],
             "avatar": f"/utilisateurs/{r['id']}/avatar" if r["avatar"] else None})

    # Ceux que je peux nommer : mes amis, et moi.
    #
    # Moi n'est pas une évidence : je peux être co-signataire d'une photo prise
    # par un ami, et sans cette ligne je me comptais parmi les « autres
    # personnes » — la carte annonçait « Paul avec 2 autres » alors que l'un
    # des deux était moi.
    mes_amis = {u["id"]} | {r["id"] for r in db.lit(
        """SELECT CASE WHEN a.demandeur = :u THEN a.destinataire
                       ELSE a.demandeur END AS id
           FROM amities a
           WHERE a.etat = 'acceptee' AND :u IN (a.demandeur, a.destinataire)""",
        {"u": u["id"]})}

    from .reactions import resume_pour
    resumes = resume_pour(ids, u["id"])

    groupes: dict[tuple, dict] = {}
    for r in lignes:
        gens = [{"id": r["utilisateur"], "pseudo": r["pseudo"],
                 "avatar": f"/utilisateurs/{r['utilisateur']}/avatar"
                           if r["avatar"] else None,
                 "auteur": True, "moi": r["utilisateur"] == u["id"]},
                *({**g, "auteur": False, "moi": g["id"] == u["id"]}
                  for g in cosignataires[r["id"]])]
        quand = r["prise_le"] or r["cree_le"]
        cle = (frozenset(g["id"] for g in gens), quand[:10])

        groupe = groupes.get(cle)
        if groupe is None:
            connus = [g for g in gens if g["id"] in mes_amis]
            groupe = groupes[cle] = {
                "cle": quand[:10] + "-" + "-".join(
                    str(i) for i in sorted(g["id"] for g in gens)),
                "jour": quand[:10],
                "quand": quand,
                # Ceux que je connais, l'auteur d'abord : c'est lui qui a
                # partagé, c'est son nom qui ouvre la phrase.
                "gens": sorted(connus, key=lambda g: not g["auteur"]),
                # Les signataires que je ne connais pas : comptés, jamais
                # nommés. « avec 3 autres personnes » dit ce qu'il faut sans
                # livrer des pseudos auxquels je n'ai pas droit.
                "inconnus": len(gens) - len(connus),
                "photos": [],
                "reactions": 0,
                "rarete": 0,
            }
        groupe["photos"].append({
            "capture_id": r["id"],
            "utilisateur": r["utilisateur"],
            "pseudo": r["pseudo"],
            "case_id": r["case_id"],
            "latin": r["case_latin"],
            "nom_fr": r["nom_fr"],
            "nom": r["nom_fr"] or r["case_latin"] or r["verdict"],
            "rarete": r["rarete"],
            "titre": r["titre"] or "",
            "lieu": r["lieu"] or "",
            "quand": quand,
            "vignette": f"/captures/{r['id']}/vignette",
            "decoupe": f"/captures/{r['id']}/decoupe" if r["decoupe"] else None,
            "reactions": resumes.get(r["id"], {}),
        })
        groupe["reactions"] += resumes.get(r["id"], {}).get("total", 0)
        groupe["rarete"] = max(groupe["rarete"], r["rarete"] or 0)

    ordonnes = sorted(groupes.values(), key=lambda g: g["quand"], reverse=True)
    for g in ordonnes:
        g["nb_photos"] = len(g["photos"])
        # Les espèces distinctes de la sortie : « Renard roux, Mésange bleue
        # et 2 autres » se lit mieux qu'un simple compte de photos.
        vues = []
        for photo in g["photos"]:
            if photo["nom"] not in vues:
                vues.append(photo["nom"])
        g["especes"] = vues

    return {
        "groupes": ordonnes[:p.limite],
        # Une page incomplète signale la fin : on a lu six fois la limite en
        # photos, si ça ne donne pas même `limite` groupes, il n'y a plus rien
        # derrière.
        "fin": len(ordonnes) <= p.limite and len(lignes) < p.limite * 6,
    }
