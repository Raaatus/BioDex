"""
Le dex : la grille des cases, remplies ou non.

Les cases sont servies triées par nombre d'observations décroissant, c'est-à-dire
de l'animal qu'on croise tous les jours à celui que personne n'a jamais vu. C'est
l'ordre qui a du sens pour quelqu'un qui se promène : les premières pages sont
celles qu'il a une chance de remplir.
"""
import re

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from .. import acces, config, db, images, poissons, vitrine
from ..i18n import tr
from ..dependances import Pagination, utilisateur
from .amis import sont_amis

routeur = APIRouter(tags=["dex"])

TRIS = {
    "communes": "c.obs DESC, c.id",
    "rares": "c.obs ASC, c.id",
    "nom": "COALESCE(c.nom_fr, c.latin) COLLATE NOCASE, c.id",
    "recentes": "d.trouve_le DESC, c.id",
    # « varie » n'est pas un ORDER BY : il se construit à part, plus bas.
    "varie": None,
}

# Trier par observations donne douze oiseaux d'affilée : l'ornithologie amateur
# écrase tout sur GBIF, et le dex ressemblait à un guide des passereaux. Ce tri
# prend le plus commun de chaque classe, puis le deuxième de chaque classe, et
# ainsi de suite — un mésange, une abeille, un chêne, une amanite, plutôt que
# vingt piafs. Les classes restent ordonnées par abondance, si bien que les
# groupes qu'on croise vraiment passent devant les vers marins.
_SELECT_VARIE = """
    SELECT * FROM (
      SELECT c.id, c.latin, c.nom_fr, c.genre, c.famille, c.ordre, c.classe,
             c.regne, c.toxique, c.rarete, c.points, c.obs,
             v.fichier AS visuel_fichier,
             d.trouve_le, d.nb_captures, d.cadrage,
             COALESCE(cap_v.id, cap_p.id) AS vedette,
             COALESCE(cap_v.decoupe, cap_p.decoupe) AS decoupe_vedette,
             COALESCE(cap_v.utilisateur, cap_p.utilisateur) AS vedette_de,
             uv.pseudo AS vedette_pseudo,
             ROW_NUMBER() OVER (PARTITION BY c.classe ORDER BY c.obs DESC) AS rang_classe
      FROM cases c
      LEFT JOIN visuels v ON v.id = c.visuel
      LEFT JOIN decouvertes d ON d.case_id = c.id AND d.utilisateur = :u
      {jointures}
      {conditions}
    )
    ORDER BY rang_classe, obs DESC, id
    LIMIT :l OFFSET :o
"""


def _case_sortie(r) -> dict:
    d = {
        "id": r["id"], "latin": r["latin"], "nom_fr": r["nom_fr"],
        "nom": r["nom_fr"] or r["latin"],
        "genre": r["genre"], "famille": r["famille"], "ordre": r["ordre"],
        "classe": r["classe"], "rarete": r["rarete"], "points": r["points"], "obs": r["obs"],
        "regne": r["regne"] if "regne" in r.keys() else "animal",
        "toxique": bool(r["toxique"]) if "toxique" in r.keys() else False,
        "visuel": f"/visuels/{r['visuel_fichier']}" if r["visuel_fichier"] else None,
        "decouvert": r["trouve_le"] is not None,
        "trouve_le": r["trouve_le"],
        "nb_captures": r["nb_captures"] or 0,
        # Non nul quand un joueur a créé la case lui-même. L'application en
        # fait un bandeau : qui a écrit quoi doit toujours être visible, c'est
        # la contrepartie de n'avoir aucune modération.
        "ajoute_par": r["ajoute_par"] if "ajoute_par" in r.keys() else None,
        "ajoute_par_pseudo": (r["ajoute_par_pseudo"]
                              if "ajoute_par_pseudo" in r.keys() else None),
        "actif": bool(r["actif"]) if "actif" in r.keys() else True,
    }
    # La capture mise en avant remplace la silhouette une fois l'espèce trouvée.
    # On préfère la découpe — l'animal détouré, qui se pose dans la case comme
    # un autocollant — et on garde la vignette carrée en repli.
    if r["vedette"]:
        d["vignette"] = f"/captures/{r['vedette']}/vignette"
        # On envoie les deux cadrages dès qu'ils existent, et le client tranche.
        #
        # Le serveur décidait auparavant, en omettant la découpe quand la case
        # était en « entier ». C'était plus économe d'un champ, mais ça rendait
        # le réglage général impossible : basculer tout le dex d'un côté ou de
        # l'autre aurait demandé de réécrire chaque case en base, et un
        # changement d'avis un aller-retour réseau par case.
        cadrage = r["cadrage"] if "cadrage" in r.keys() else "auto"
        d["cadrage"] = cadrage
        if "decoupe_vedette" in r.keys() and r["decoupe_vedette"]:
            d["decoupe"] = f"/captures/{r['vedette']}/decoupe"
        # Qui a pris la photo. Ce n'est pas forcément le propriétaire de la
        # case : on peut mettre en avant le cliché d'un ami, et l'affichage
        # doit pouvoir le créditer plutôt que de le faire passer pour sien.
        if "vedette_de" in r.keys() and r["vedette_de"] is not None:
            d["vedette_de"] = r["vedette_de"]
            d["vedette_pseudo"] = r["vedette_pseudo"]
    return d


# La photo mise en avant, avec repli.
#
# `vedette` peut désigner la photo d'un ami. Si l'amitié cesse, si l'autre
# retire le partage ou ferme son compte, cette photo redevient invisible — et
# une case gagnée de haute lutte se retrouverait grise, sans que le joueur
# comprenne pourquoi. La jointure teste donc la visibilité, et on retombe sur
# `premiere`, qui est toujours une photo à soi.
_JOINTURES_VEDETTE = f"""
    LEFT JOIN captures cap_v ON cap_v.id = d.vedette AND {acces.visible('cap_v', 'moi')}
    LEFT JOIN captures cap_p ON cap_p.id = d.premiere
    LEFT JOIN utilisateurs uv ON uv.id = COALESCE(cap_v.utilisateur, cap_p.utilisateur)
"""

_SELECT = f"""
    SELECT c.id, c.latin, c.nom_fr, c.genre, c.famille, c.ordre, c.classe,
           c.regne, c.toxique, c.rarete, c.points, c.obs, v.fichier AS visuel_fichier,
           d.trouve_le, d.nb_captures, d.cadrage,
           COALESCE(cap_v.id, cap_p.id) AS vedette,
           COALESCE(cap_v.decoupe, cap_p.decoupe) AS decoupe_vedette,
           COALESCE(cap_v.utilisateur, cap_p.utilisateur) AS vedette_de,
           uv.pseudo AS vedette_pseudo,
           c.ajoute_par, c.actif, ua.pseudo AS ajoute_par_pseudo
    FROM cases c
    LEFT JOIN visuels v ON v.id = c.visuel
    LEFT JOIN utilisateurs ua ON ua.id = c.ajoute_par
    LEFT JOIN decouvertes d ON d.case_id = c.id AND d.utilisateur = :u
    {_JOINTURES_VEDETTE}
"""


@routeur.get("/dex")
def grille(p: Pagination = Depends(),
           q: str | None = Query(default=None, max_length=64),
           regne: str | None = Query(default=None,
                                     pattern="^(animal|plante|champignon|aquatique)$"),
           classe: str | None = None,
           ordre: str | None = None,
           famille: str | None = None,
           rarete: int | None = Query(default=None, ge=1, le=5),
           etat: str = Query(default="tout", pattern="^(tout|decouvert|manquant)$"),
           tri: str = Query(default="communes"),
           joueur: int | None = Query(default=None,
                                      description="Voir le dex d'un ami plutôt que le sien"),
           u=Depends(utilisateur)):
    """Une page de la grille.

    `etat=manquant` sert à ne montrer que ce qu'il reste à trouver, `joueur`
    à regarder la collection d'un ami, `regne` à n'afficher qu'un règne. Sans
    `regne`, les trois se mélangent : c'est un dex du vivant, pas trois dex
    côte à côte.
    """
    if tri not in TRIS:
        raise HTTPException(400, f"Tri inconnu. Au choix : {', '.join(TRIS)}.")

    cible = u["id"]
    if joueur is not None and joueur != u["id"]:
        if not sont_amis(u["id"], joueur):
            raise HTTPException(403, "Vous n'êtes pas amis avec ce joueur.")
        cible = joueur

    sql = _SELECT
    params: dict = {"u": cible, "moi": u["id"], "l": p.limite, "o": p.depuis}
    # Les espèces retirées par leur auteur sortent du parcours et de la
    # recherche, mais pas des fiches : une photo déjà rangée dans une case
    # désactivée doit continuer de s'afficher, sinon on punirait celui qui a
    # fait confiance à l'espèce d'un autre.
    conditions = ["c.actif = 1"]

    if etat == "decouvert":
        conditions.append("d.trouve_le IS NOT NULL")
    elif etat == "manquant":
        conditions.append("d.trouve_le IS NULL")
    if regne == "aquatique":
        # « Aquatique » n'est pas une valeur de `cases.regne` : les poissons y
        # sont rangés sous « animal », puisque c'en sont. Le filtre se fait
        # donc sur la taxonomie, avec la même définition que le catalogue.
        sql_poi, p_poi = poissons.condition_nommee("c.")
        conditions.append(sql_poi)
        params.update(p_poi)
    elif regne:
        conditions.append("c.regne = :regne")
        params["regne"] = regne
    if classe:
        conditions.append("c.classe = :classe")
        params["classe"] = classe
    if ordre:
        conditions.append("c.ordre = :ordre")
        params["ordre"] = ordre
    if famille:
        conditions.append("c.famille = :famille")
        params["famille"] = famille
    if rarete:
        conditions.append("c.rarete = :rarete")
        params["rarete"] = rarete
    if q:
        # Recherche sur le nom français, le nom latin et les synonymes : taper
        # « zebu » doit ramener la case Vache, puisque c'est là qu'il atterrit.
        conditions.append("""(c.nom_fr LIKE :q OR c.latin LIKE :q
                              OR EXISTS (SELECT 1 FROM alias a
                                         WHERE a.case_id = c.id AND a.latin LIKE :q))""")
        params["q"] = f"%{q}%"

    ou = (" WHERE " + " AND ".join(conditions)) if conditions else ""
    if tri == "varie":
        # Le panachage se fait dans une sous-requête : la numérotation par
        # classe doit être calculée avant de trancher les cent premières.
        sql = _SELECT_VARIE.format(jointures=_JOINTURES_VEDETTE,
                                   conditions=ou)
    else:
        sql = _SELECT + ou + f" ORDER BY {TRIS[tri]} LIMIT :l OFFSET :o"

    lignes = db.lit(sql, params)
    return {"cases": [_case_sortie(r) for r in lignes],
            "depuis": p.depuis, "limite": p.limite, "fin": len(lignes) < p.limite}


# Les cinquante rangs de collection.
#
# Ils montent d'abord très vite — la première espèce suffit — puis s'espacent
# d'environ 25 % à chaque palier. Le dernier se franchit à 150 000 espèces, sur
# les 977 000 du dex : atteignable en théorie, jamais en pratique, et c'est très
# bien ainsi. Ce qu'on affiche au joueur, c'est le rang suivant, toujours à
# portée, jamais le total.
PALIERS = [
    # Cinquante rangs, de la première trouvaille à cinquante mille
    # espèces. Le plafond est délibérément hors de portée sans être
    # absurde : le dex compte 977 000 cases, mais quelques dizaines de
    # milliers seulement sont assez observées pour qu'on les croise.
    # Les premiers rangs se moquent de celui qui ne sort pas encore —
    # c'est un dex entre amis, pas un diplôme.
    (1, "Larve"), (2, "Pantouflard"),
    (3, "Hikikomori"), (4, "Feignasse"),
    (6, "Sort du garage"), (8, "Prend l'air"),
    (11, "Touriste"), (14, "Promeneur du dimanche"),
    (18, "Fouineur"), (23, "Fouineur confirmé"),
    (29, "Traîne-buisson"), (36, "Renifleur de haies"),
    (45, "Chasseur de mouches"), (56, "Retourneur de cailloux"),
    (69, "Amateur"), (85, "Bon élève"),
    (105, "Fouille-tout"), (129, "Œil de lynx"),
    (158, "Connaisseur"), (194, "Fin connaisseur"),
    (237, "Grand curieux"), (289, "Expert"),
    (352, "Expert confirmé"), (428, "Spécialiste"),
    (520, "Vieux de la vieille"), (630, "Encyclopédie ambulante"),
    (763, "Sait tout, dit tout"), (923, "Terreur des fourrés"),
    (1115, "Pilleur de biotopes"), (1345, "Compte les pattes"),
    (1620, "Ne dort plus"), (1950, "Obsédé textuel"),
    (2350, "Cas désespéré"), (2830, "Sans vie sociale"),
    (3400, "Marié à son dex"), (4090, "Reconnaît tout"),
    (4910, "Bibliothèque vivante"), (5900, "Machine à cases"),
    (7080, "Phénomène"), (8500, "Monstre sacré"),
    (10200, "Légende urbaine"), (12200, "Mythe vivant"),
    (14600, "Oracle"), (17500, "Demi-dieu"),
    (21000, "Divinité mineure"), (25200, "Divinité majeure"),
    (30200, "Créateur du vivant"), (36200, "Rien à prouver"),
    (43400, "Va dehors, vraiment"), (50000, "Encyclopédie Vivante"),
]

def _version_badges() -> str:
    """Une empreinte des illustrations, glissée dans leur adresse.

    Les téléphones gardent ces images en cache pendant un mois, et l'adresse
    ne changeait pas quand on remplaçait les dessins : on continuait donc de
    voir les anciens. L'empreinte suit la date du dossier — remplacer les
    fichiers suffit à renouveler toutes les adresses.
    """
    dossier = config.SILHOUETTES / "badges"
    try:
        recent = max((f.stat().st_mtime for f in dossier.glob("*.png")),
                     default=0)
    except OSError:
        recent = 0
    return f"{int(recent):x}"


# Calculée une fois au démarrage : les illustrations ne changent pas en cours
# de route, et parcourir cent fichiers à chaque requête serait du gâchis.
VERSION_BADGES = _version_badges()


def _badge(numero: int) -> str:
    return f"/badges/{numero:02d}.png?v={VERSION_BADGES}"


# Avant la première espèce, on n'a pas encore de rang : le dex est vide et le
# joueur n'a rien à montrer, ce qui est une information en soi.
RANG_ZERO = {"numero": 0, "nom": "Sans rang", "depuis": 0,
             "badge": _badge(1)}


def palier_de(trouve: int) -> dict:
    """Le rang courant et celui qu'on vise."""
    atteint = None
    suivant = None
    for i, (seuil, nom) in enumerate(PALIERS, 1):
        if trouve >= seuil:
            atteint = (i, seuil, nom)
        else:
            suivant = (i, seuil, nom)
            break

    if atteint is None:
        d = dict(RANG_ZERO)
        d["nom"] = tr(d["nom"])
    else:
        d = {"numero": atteint[0], "nom": tr(atteint[2]), "depuis": atteint[1],
             "badge": _badge(atteint[0])}
    if suivant:
        d["suivant"] = tr(suivant[2])
        d["objectif"] = suivant[1]
        d["reste"] = suivant[1] - trouve
        d["badge_suivant"] = _badge(suivant[0])
    d["total_paliers"] = len(PALIERS)
    return d


@routeur.get("/badges/{fichier}")
def badge(fichier: str,
          taille: int = Query(default=256, description="256 ou 512"),
          v: str | None = Query(default=None,
                                description="empreinte des illustrations"),
          _=Depends(utilisateur)):
    """L'illustration d'un rang.

    Deux tailles sont préparées : 256 pixels pour les listes, 512 pour l'écran
    des rangs. Les originaux font 1024 et pèsent 1,7 Mo — inutilisables sur un
    réseau mobile pour une vignette de quarante-cinq pixels.
    """
    if not re.fullmatch(r"\d{2}\.png", fichier):
        raise HTTPException(404, "Badge introuvable.")
    rang = fichier[:2]
    chemin = config.SILHOUETTES / "badges" / f"{rang}-{512 if taille > 256 else 256}.png"
    if not chemin.exists():
        raise HTTPException(404, "Badge introuvable.")
    # Une illustration de rang ne change jamais : un mois de cache.
    return FileResponse(chemin, media_type="image/png",
                        headers={"Cache-Control": "private, max-age=2592000"})


@routeur.get("/paliers")
def paliers(u=Depends(utilisateur)):
    """La liste des rangs, avec celui qu'on a atteint.

    Voir la suite donne un horizon : on sait ce qu'on vise, et de loin en loin
    ce qui reste. C'est ce que le rapport au total ne donnait pas.
    """
    trouve = db.valeur(
        "SELECT COUNT(*) FROM decouvertes WHERE utilisateur = ?", (u["id"],), 0)
    return {
        "trouve": trouve,
        "atteint": palier_de(trouve)["numero"],
        "paliers": [
            {"numero": i, "seuil": seuil, "nom": tr(nom),
             "badge": _badge(i), "atteint": trouve >= seuil}
            for i, (seuil, nom) in enumerate(PALIERS, 1)
        ],
    }


@routeur.get("/dex/resume")
def resume(joueur: int | None = None,
           regne: str | None = Query(default=None,
                                     pattern="^(animal|plante|champignon|aquatique)$"),
           u=Depends(utilisateur)):
    """Progression : combien de cases remplies, au total et par grand groupe.

    La ventilation par règne alimente les trois entrées du dex. Les classes,
    elles, restent filtrées sur le règne demandé : mélanger Aves et Agaricomycetes
    dans une même liste n'aiderait personne à s'y retrouver.
    """
    cible = u["id"]
    if joueur is not None and joueur != u["id"]:
        if not sont_amis(u["id"], joueur):
            raise HTTPException(403, "Vous n'êtes pas amis avec ce joueur.")
        cible = joueur

    ou_regne = "WHERE c.regne = :r" if regne else ""
    par = {"u": cible, "r": regne}

    total = db.valeur(
        f"SELECT COUNT(*) FROM cases c {ou_regne}", par, 0)
    trouve = db.valeur(
        f"""SELECT COUNT(*) FROM decouvertes d
            JOIN cases c ON c.id = d.case_id
            WHERE d.utilisateur = :u {'AND c.regne = :r' if regne else ''}""", par, 0)

    # Les trois règnes, avec leur part remplie : c'est ce que le dex affiche en
    # tête, avant d'entrer dans le détail.
    regnes = db.lit(
        """SELECT c.regne, COUNT(*) AS total, COUNT(d.case_id) AS trouve
           FROM cases c
           LEFT JOIN decouvertes d ON d.case_id = c.id AND d.utilisateur = ?
           GROUP BY c.regne ORDER BY total DESC""", (cible,))

    # Les grandes classes, avec la part déjà remplie. On écarte les cases sans
    # classe renseignée, qui n'ont pas de place naturelle dans la navigation.
    groupes = db.lit(
        """SELECT c.classe, COUNT(*) AS total,
                  COUNT(d.case_id) AS trouve
           FROM cases c
           LEFT JOIN decouvertes d ON d.case_id = c.id AND d.utilisateur = :u
           WHERE c.classe <> '' """ + ("AND c.regne = :r" if regne else "") + """
           GROUP BY c.classe ORDER BY total DESC LIMIT 40""", par)
    raretes = db.lit(
        """SELECT c.rarete, COUNT(*) AS total, COUNT(d.case_id) AS trouve
           FROM cases c
           LEFT JOIN decouvertes d ON d.case_id = c.id AND d.utilisateur = :u """
        + ("WHERE c.regne = :r" if regne else "") + """
           GROUP BY c.rarete ORDER BY c.rarete""", par)

    # Les points et le palier atteint remplacent le rapport au total : personne
    # ne remplira 977 000 cases, et l'afficher ne fait que décourager. Ce qui
    # compte est ce qu'on a trouvé, et le prochain jalon à portée.
    # Deux compteurs bien distincts, parce qu'ils ne servent pas à la même
    # chose : le rang se gagne en **espèces** trouvées, les points s'accumulent
    # en plus, et les applaudissements des amis n'entrent que dans les points.
    # Les mélanger donnait un total qui ne correspondait à rien de visible.
    points = db.valeur(
        """SELECT COALESCE(SUM(c.points), 0) FROM decouvertes d
           JOIN cases c ON c.id = d.case_id WHERE d.utilisateur = ?""", (cible,), 0)
    from .reactions import points_recus
    applaudissements = points_recus(cible)

    return {
        "total": total, "trouve": trouve,
        "points": points + applaudissements,
        "points_decouvertes": points,
        "points_reactions": applaudissements,
        "palier": palier_de(trouve),
        "part": round(trouve / total, 6) if total else 0.0,
        "regnes": [dict(r) for r in regnes],
        "classes": [dict(r) for r in groupes],
        "raretes": [dict(r) for r in raretes],
    }


# Descente taxonomique : chaque niveau ouvre le suivant, et la famille est la
# dernière étape avant les espèces elles-mêmes.
SUIVANT = {None: "classe", "classe": "ordre", "ordre": "famille", "famille": None}


@routeur.get("/dex/arbre")
def arbre(classe: str | None = None, ordre: str | None = None,
          joueur: int | None = None, u=Depends(utilisateur)):
    """Un niveau de l'arbre du vivant, avec l'avancement à chaque branche.

    Sans paramètre, renvoie les grands groupes. Avec `classe`, ses ordres ; avec
    `classe` et `ordre`, ses familles. Une fois arrivé à la famille, on passe la
    main à `/dex?famille=…` qui rend les cases.
    """
    cible = u["id"]
    if joueur is not None and joueur != u["id"]:
        if not sont_amis(u["id"], joueur):
            raise HTTPException(403, "Vous n'êtes pas amis avec ce joueur.")
        cible = joueur

    if ordre is not None:
        niveau, colonne = "famille", "c.famille"
        conditions = ["c.ordre = :ordre", "c.famille <> ''"]
    elif classe is not None:
        niveau, colonne = "ordre", "c.ordre"
        conditions = ["c.classe = :classe", "c.ordre <> ''"]
    else:
        niveau, colonne = "classe", "c.classe"
        conditions = ["c.classe <> ''"]

    lignes = db.lit(
        f"""SELECT {colonne} AS nom, COUNT(*) AS total, COUNT(d.case_id) AS trouve
            FROM cases c
            LEFT JOIN decouvertes d ON d.case_id = c.id AND d.utilisateur = :u
            WHERE {' AND '.join(conditions)}
            GROUP BY {colonne}
            ORDER BY trouve DESC, total DESC
            LIMIT 400""",
        {"u": cible, "classe": classe, "ordre": ordre})

    return {
        "niveau": niveau,
        "enfant": SUIVANT[niveau],
        "classe": classe,
        "ordre": ordre,
        "noeuds": [
            {"nom": r["nom"], "total": r["total"], "trouve": r["trouve"]}
            for r in lignes
        ],
    }


# ------------------------------------------------- la disposition libre du dex
#
# **Pourquoi seulement les espèces trouvées.**
#
# Le catalogue compte 977 416 cases. Une page de soixante pèse 25 Ko, soit
# 425 octets par case : tout envoyer ferait 396 Mo. La grille ordinaire s'en
# sort parce qu'elle pagine — soixante cases à la fois, et on ne sait jamais ce
# qu'il y a plus bas.
#
# Une disposition libre, elle, ne peut pas paginer : déplacer une vignette
# suppose de savoir où sont les autres, donc de les avoir toutes. C'est
# irréconciliable avec un million de cases.
#
# Mais on n'arrange pas ce qu'on n'a pas trouvé. Les espèces découvertes se
# comptent en dizaines, au pire en milliers — mille cases font 415 Ko, ce qui se
# charge d'un coup sans y penser. La zone libre porte donc sur elles seules, et
# le reste du catalogue garde sa grille paginée, qui n'a rien à personnaliser.
#
# **Ce qu'on stocke.** Les exceptions, rien d'autre. Une case absente de la
# table suit la disposition automatique. Quelqu'un qui n'arrange rien ne coûte
# pas une ligne.
#
# **En cellules, jamais en pixels.** Un arrangement fait sur un téléphone doit se
# retrouver identique sur une tablette. La grille logique fait toujours
# `COLONNES_LIBRES` colonnes ; c'est la taille des cellules qui s'adapte.

# Cinq colonnes, exactement comme la grille ordinaire du dex.
#
# Ce n'est pas un chiffre choisi pour lui-même : c'est celui de `.grille-dex`.
# Une cellule vaut donc une vignette d'origine, et un dex qu'on n'a jamais rangé
# est rigoureusement identique a ce qu'il etait avant que ce mode existe. Avec
# six colonnes, tout devenait plus petit sans que personne l'ait demande.
COLONNES_LIBRES = 5

# Une vignette ne dépasse pas la moitié de la largeur. Au-delà, elle chasse tout
# le reste de l'écran et l'arrangement n'a plus rien à arranger.
TAILLE_MAX = 3

# Les formes proposées. Servies plutôt que codées dans chaque client : les deux
# doivent offrir les mêmes, et une liste tenue à deux endroits diverge.
FORMES = ["arrondi", "carre", "rond", "hexagone", "losange", "goutte"]


class PlaceCase(BaseModel):
    """Où poser une case, et quelle place elle prend."""
    case_id: int
    colonne: int = Field(ge=0, le=COLONNES_LIBRES - 1)
    rangee: int = Field(ge=0, le=999)
    largeur: int = Field(default=1, ge=1, le=TAILLE_MAX)
    hauteur: int = Field(default=1, ge=1, le=TAILLE_MAX)
    forme: str = Field(default="arrondi", pattern="^(arrondi|carre|rond|hexagone|losange|goutte)$")
    masque: bool = False


class CaseVide(BaseModel):
    """Un trou posé à la main : ni silhouette, ni cadre, juste de la place."""
    colonne: int = Field(ge=0, le=COLONNES_LIBRES - 1)
    rangee: int = Field(ge=0, le=999)
    largeur: int = Field(default=1, ge=1, le=TAILLE_MAX)
    hauteur: int = Field(default=1, ge=1, le=TAILLE_MAX)


class Disposition(BaseModel):
    """L'arrangement complet. On remplace tout d'un coup.

    Envoyer les déplacements un par un demanderait d'arbitrer les conflits entre
    deux appareils ; ici le dernier qui enregistre a raison, ce qui est le
    comportement attendu d'un bureau qu'on range.
    """
    cases: list[PlaceCase] = Field(default_factory=list, max_length=2000)
    vides: list[CaseVide] = Field(default_factory=list, max_length=200)

    # Vrai quand le client n'envoie qu'une partie des cases — parce qu'il n'a
    # chargé qu'une page du dex. Sans ce drapeau, enregistrer effacerait la
    # position de tout ce qui n'était pas à l'écran.
    partiel: bool = False


@routeur.get("/dex/disposition")
def lit_disposition(u=Depends(utilisateur)):
    """L'arrangement du joueur : les positions qu'il a choisies.

    Seules les exceptions sont rendues. Le client place d'office, à la suite,
    les trouvailles qui n'ont pas de position — c'est ce qui permet à un
    arrangement de survivre à une nouvelle découverte sans qu'on y touche.
    """
    places = {
        str(r["case_id"]): {"colonne": r["colonne"], "rangee": r["rangee"],
                            "largeur": r["largeur"], "hauteur": r["hauteur"],
                            "forme": r["forme"], "masque": bool(r["masque"])}
        for r in db.lit(
            """SELECT case_id, colonne, rangee, largeur, hauteur, forme, masque
                 FROM dex_disposition WHERE utilisateur = ?""", (u["id"],))
    }
    vides = [
        {"colonne": r["colonne"], "rangee": r["rangee"],
         "largeur": r["largeur"], "hauteur": r["hauteur"]}
        for r in db.lit(
            """SELECT colonne, rangee, largeur, hauteur FROM dex_vides
                WHERE utilisateur = ? ORDER BY rang""", (u["id"],))
    ]
    return {
        "colonnes": COLONNES_LIBRES,
        "taille_max": TAILLE_MAX,
        "formes": FORMES,
        "places": places,
        "vides": vides,
    }


@routeur.put("/dex/disposition")
def change_disposition(corps: Disposition, u=Depends(utilisateur)):
    """Enregistre l'arrangement.

    On n'accepte que des cases réellement découvertes : accepter n'importe quel
    identifiant laisserait quelqu'un épingler une espèce qu'il n'a pas, et le
    dex afficherait une vignette qu'aucun autre écran ne connaît.
    """
    lot = {c.case_id: c for c in corps.cases}
    if lot:
        connues = {r["case_id"] for r in db.lit(
            f"""SELECT case_id FROM decouvertes
                 WHERE utilisateur = ?
                   AND case_id IN ({','.join('?' * len(lot))})""",
            (u["id"], *lot))}
        if inconnues := set(lot) - connues:
            raise HTTPException(
                400, f"{len(inconnues)} espèce(s) ne sont pas dans votre dex.")

    with db.transaction() as cx:
        if corps.partiel:
            # Le client n'avait qu'une partie du dex sous la main : on ne
            # remplace que ce qu'il a envoyé. Effacer le reste ferait perdre
            # l'arrangement des espèces qui n'étaient pas à l'écran, sans que
            # personne ne comprenne pourquoi.
            if lot:
                cx.executemany(
                    "DELETE FROM dex_disposition WHERE utilisateur = ? AND case_id = ?",
                    [(u["id"], c) for c in lot])
        else:
            cx.execute("DELETE FROM dex_disposition WHERE utilisateur = ?", (u["id"],))
            cx.execute("DELETE FROM dex_vides WHERE utilisateur = ?", (u["id"],))
            cx.executemany(
                """INSERT INTO dex_vides
                       (utilisateur, rang, colonne, rangee, largeur, hauteur)
                   VALUES (?,?,?,?,?,?)""",
                [(u["id"], i, v.colonne, v.rangee, v.largeur, v.hauteur)
                 for i, v in enumerate(corps.vides)])
        cx.executemany(
            """INSERT INTO dex_disposition
                   (utilisateur, case_id, colonne, rangee, largeur, hauteur,
                    forme, masque)
               VALUES (?,?,?,?,?,?,?,?)""",
            [(u["id"], c.case_id, c.colonne, c.rangee, c.largeur, c.hauteur,
              c.forme, int(c.masque)) for c in lot.values()])
    return {"places": len(lot), "vides": len(corps.vides)}


@routeur.delete("/dex/disposition", status_code=204)
def oublie_disposition(u=Depends(utilisateur)):
    """Revient à la disposition automatique.

    Une sortie de secours explicite : un arrangement raté sur soixante vignettes
    ne se défait pas à la main.
    """
    with db.transaction() as cx:
        cx.execute("DELETE FROM dex_disposition WHERE utilisateur = ?", (u["id"],))
        cx.execute("DELETE FROM dex_vides WHERE utilisateur = ?", (u["id"],))


@routeur.get("/dex/{case_id}")
def une_case(case_id: int, joueur: int | None = None, u=Depends(utilisateur)):
    """Le détail d'une case : ses noms, et toutes les photos qu'on y a rangées.

    C'est l'écran qui s'ouvre quand on tape sur une case de la grille — s'il y a
    plusieurs vaches, on les voit toutes ici.
    """
    cible = u["id"]
    if joueur is not None and joueur != u["id"]:
        if not sont_amis(u["id"], joueur):
            raise HTTPException(403, "Vous n'êtes pas amis avec ce joueur.")
        cible = joueur

    r = db.lit_un(_SELECT + " WHERE c.id = :id",
                  {"u": cible, "moi": u["id"], "id": case_id})
    if r is None:
        raise HTTPException(404, "Case introuvable.")

    d = _case_sortie(r)
    d["alias"] = [x["latin"] for x in db.lit(
        "SELECT latin FROM alias WHERE case_id = ? ORDER BY accepte DESC, latin", (case_id,))]
    d["captures"] = [
        {"id": x["id"], "cree_le": x["cree_le"], "verdict": x["verdict"],
         "titre": x["titre"] or "",
         "confiance": round(x["confiance"], 4), "lat": x["lat"], "lon": x["lon"],
         "decoupe": f"/captures/{x['id']}/decoupe" if x["decoupe"] else None,
         "vignette": f"/captures/{x['id']}/vignette", "photo": f"/captures/{x['id']}/photo"}
        for x in db.lit(
            """SELECT id, cree_le, verdict, confiance, lat, lon, titre, decoupe
               FROM captures
               WHERE utilisateur = ? AND case_id = ? ORDER BY id DESC LIMIT 60""",
            (cible, case_id))
    ]

    # Les photos des amis sur la même espèce. C'est là que la case prend son
    # intérêt : deux personnes qui ont trouvé le même bœuf voient leurs clichés
    # côte à côte, et peuvent se congratuler sans quitter l'écran.
    amies = db.lit(
        """SELECT c.id, c.cree_le, c.titre, c.decoupe, c.utilisateur,
                  c.prise_le, c.lat, c.lon, c.lieu,
                  x.pseudo, x.avatar,
                  EXISTS (SELECT 1 FROM favoris f
                          WHERE f.capture = c.id AND f.utilisateur = :u) AS favori
           FROM captures c
           JOIN utilisateurs x ON x.id = c.utilisateur
           WHERE c.case_id = :case AND c.partage = 1 AND c.utilisateur <> :u
             AND EXISTS (SELECT 1 FROM amities a
                         WHERE a.etat = 'acceptee'
                           AND ((a.demandeur = :u AND a.destinataire = c.utilisateur)
                             OR (a.destinataire = :u AND a.demandeur = c.utilisateur)))
           ORDER BY c.id DESC LIMIT 60""",
        {"case": case_id, "u": u["id"]})

    from .reactions import resume_pour
    resumes = resume_pour([r["id"] for r in amies], u["id"])
    d["chez_les_amis"] = [
        {"id": r["id"], "cree_le": r["cree_le"], "titre": r["titre"] or "",
         "utilisateur": r["utilisateur"], "pseudo": r["pseudo"],
         "avatar": f"/utilisateurs/{r['utilisateur']}/avatar" if r["avatar"] else None,
         "decoupe": f"/captures/{r['id']}/decoupe" if r["decoupe"] else None,
         "vignette": f"/captures/{r['id']}/vignette",
         "photo": f"/captures/{r['id']}/photo",
         # De quoi ouvrir la photo en grand sans repasser par le serveur : la
         # visionneuse affiche le lieu, la date et le favori comme pour les
         # siennes.
         "quand": r["prise_le"] or r["cree_le"],
         "heure_sure": r["prise_le"] is not None,
         "lat": r["lat"], "lon": r["lon"], "lieu": r["lieu"] or "",
         "favori": bool(r["favori"]),
         "reactions": resumes.get(r["id"], {})}
        for r in amies
    ]
    return d


@routeur.post("/dex/{case_id}/cadrage/{mode}")
def choisit_cadrage(case_id: int, mode: str, u=Depends(utilisateur)):
    """Photo détourée ou photo entière pour l'image de la case.

    MegaDetector recadre parfois de travers — une patte, un bout de branche —
    et la case hérite d'une découpe ratée. Le joueur doit pouvoir reprendre la
    photo telle qu'il l'a prise.

    Trois modes, et le troisième n'est pas une redondance :

      auto     suit le réglage général de l'application
      entier   cette case montre la photo entière, quoi qu'on règle ailleurs
      decoupe  cette case montre l'animal détouré, idem

    Sans « decoupe », un joueur qui bascule tout son dex en photos entières ne
    pourrait plus revenir en arrière sur une seule case : « auto » l'y
    ramènerait, mais en la soumettant de nouveau au réglage général.
    """
    if mode not in ("auto", "entier", "decoupe"):
        raise HTTPException(400, "Cadrage attendu : auto, entier ou decoupe.")
    fait = db.ecrit(
        "UPDATE decouvertes SET cadrage = ? WHERE utilisateur = ? AND case_id = ?",
        (mode, u["id"], case_id))
    if not fait.rowcount:
        raise HTTPException(404, "Cette espèce n'est pas dans votre dex.")
    return {"cadrage": mode}


@routeur.post("/dex/{case_id}/vedette/{capture_id}")
def choisit_vedette(case_id: int, capture_id: int, u=Depends(utilisateur)):
    """Choisit la photo qui représente la case dans la grille.

    La photo peut être celle d'un ami. C'est voulu : sur une espèce que deux
    personnes ont trouvée, l'une a souvent bien mieux réussi son cliché, et
    s'interdire de le mettre en avant n'avait aucune raison d'être. Il faut
    qu'elle soit partagée et que l'amitié soit établie — mêmes conditions que
    pour la voir dans la galerie.

    Si cette photo n'a pas encore été détourée — parce qu'elle date d'avant le
    détourage, ou que le moteur l'avait refusée — on la détoure maintenant.
    Aucune analyse n'est relancée : on ne fait que découper l'image et la rendre.
    """
    r = db.lit_un(
        f"""SELECT c.id, c.fichier, c.decoupe, c.bbox FROM captures c
            WHERE c.id = :id AND c.case_id = :case AND {acces.visible(qui='moi')}""",
        {"id": capture_id, "case": case_id, "moi": u["id"]})
    if r is None:
        raise HTTPException(
            404, "Cette photo n'est pas rangée dans cette case, "
                 "ou ne vous est pas accessible.")

    db.ecrit("UPDATE decouvertes SET vedette = ? WHERE utilisateur = ? AND case_id = ?",
             (capture_id, u["id"], case_id))

    decoupe = r["decoupe"]
    if not decoupe:
        bbox = None
        if r["bbox"]:
            try:
                bbox = tuple(float(v) for v in r["bbox"].split(","))
            except ValueError:
                bbox = None
        decoupe = images.decoupe(r["fichier"], bbox)
        if decoupe:
            db.ecrit("UPDATE captures SET decoupe = ? WHERE id = ?",
                     (decoupe, capture_id))

    return {
        "case_id": case_id,
        "capture_id": capture_id,
        # L'app remplace l'image de la case avec ce qu'on lui rend ici.
        "decoupe": f"/captures/{capture_id}/decoupe" if decoupe else None,
        "vignette": f"/captures/{capture_id}/vignette",
    }


# Les silhouettes sont en SVG, mais rien n'empêche d'en déposer en PNG : le type
# se déduit de l'extension plutôt que d'être supposé.
TYPES_VISUEL = {".svg": "image/svg+xml", ".png": "image/png",
                ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                ".webp": "image/webp"}


# `:path` est indispensable : les silhouettes de PhyloPic sont rangées dans un
# sous-dossier, et sans cela le slash de « phylopic/xxx.svg » ne correspondrait
# à rien.
@routeur.get("/visuels/{fichier:path}")
def visuel(fichier: str):
    """Sert une silhouette. Pas d'authentification : ce sont des illustrations
    génériques, identiques pour tout le monde, et l'app en charge des centaines
    dans la grille."""
    chemin = images.chemin_sur(config.SILHOUETTES, fichier)
    if not chemin.is_file():
        raise HTTPException(404, "Visuel introuvable.")
    type_mime = TYPES_VISUEL.get(chemin.suffix.lower())
    if type_mime is None:
        raise HTTPException(415, f"Format de visuel non servi : {chemin.suffix}")
    return FileResponse(chemin, media_type=type_mime,
                        headers={"Cache-Control": "public, max-age=604800"})


@routeur.get("/vitrine")
def vitrine_du_joueur(joueur: int | None = None, u=Depends(utilisateur)):
    """La vitrine : le rang tiré de la rareté, pour soi ou pour un ami.

    Même contrôle d'accès que le dex — on ne regarde la collection de quelqu'un
    que si l'amitié est acceptée des deux côtés. Un rang se montre, mais entre
    gens qui se connaissent.

    Le détail des dix pièces est renvoyé avec : c'est la vitrine elle-même, et
    c'est ce qui rend le score lisible. Un chiffre seul ne dit pas *pourquoi*
    on est à ce rang.
    """
    cible = u["id"]
    if joueur is not None and joueur != u["id"]:
        if not sont_amis(u["id"], joueur):
            raise HTTPException(403, "Vous n'êtes pas amis avec ce joueur.")
        cible = joueur

    score = db.valeur(vitrine.score_sql(), {"u": cible}, 0)
    # La photo qui va avec, pour que la vitrine montre les prises et pas une
    # liste de noms. On prend la vedette choisie par le joueur, à défaut sa
    # première capture — le même ordre de préférence que le dex.
    pieces = db.lit(
        f"""SELECT c.id, COALESCE(c.nom_fr, c.latin) AS nom, c.latin,
                   c.rarete, c.points, c.regne, d.trouve_le,
                   COALESCE(cap.id, 0) AS capture,
                   cap.decoupe AS decoupe
              FROM decouvertes d
              JOIN cases c ON c.id = d.case_id
              LEFT JOIN captures cap ON cap.id = COALESCE(d.vedette, d.premiere)
             WHERE d.utilisateur = :u
             ORDER BY c.points DESC, c.id ASC
             LIMIT {vitrine.TAILLE}""",
        {"u": cible})

    noms = [nom for _, nom in PALIERS]
    rang = vitrine.rang_de(score, noms)
    # Le même écusson que le rang du dex, en attendant les modèles 3D propres à
    # la vitrine. Le numéro suffit à les distinguer le jour où ils existeront.
    if rang["numero"]:
        rang["badge"] = _badge(rang["numero"])
    return {
        "joueur": cible,
        "score": score,
        "taille": vitrine.TAILLE,
        "rang": rang,
        "pieces": [
            {"case_id": r["id"], "nom": r["nom"], "latin": r["latin"],
             "qualite": r["rarete"], "points": r["points"],
             "regne": r["regne"], "trouve_le": r["trouve_le"],
             # Les deux versions sont servies : c'est l'application qui sait si
             # le joueur préfère la photo entière ou la bête détourée, et ce
             # réglage vit sur le téléphone, pas en base.
             "vignette": f"/captures/{r['capture']}/vignette" if r["capture"] else None,
             "decoupe": (f"/captures/{r['capture']}/decoupe"
                         if r["capture"] and r["decoupe"] else None)}
            for r in pieces
        ],
    }
