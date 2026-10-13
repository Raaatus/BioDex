"""
Les succès : où on en est, et ce qui vient de tomber.

**Un succès ne s'obtient qu'une fois.** La clé primaire `(utilisateur, cle)`
l'impose en base, et l'évaluation n'écrit qu'avec `INSERT OR IGNORE` : retrouver
la même espèce le lendemain ne produit rien, et la date d'obtention ne bouge
plus. C'est ce qui permet de dire « débloqué le 26 août » des mois plus tard.

**Un ami identifié sur la photo décroche le succès comme s'il l'avait prise.**
C'est le principe posé par les participants — « on était là tous les deux » — et
il valait déjà pour les cases et les points. Il ne valait pas pour les succès
comptés sur les photos : deux personnes sorties à l'aube, une seule décrochait
« Lève-tôt ». Seul « Bon oeil » reste personnel, parce qu'il récompense un acte
— corriger une identification — et non le fait d'avoir été là.

**On évalue à la lecture, pas à l'écriture.** Un joueur qui n'ouvre jamais
l'écran ne coûte rien ; celui qui l'ouvre paie une poignée de comptages sur des
index. Accrocher l'évaluation à chaque photo obligerait à repasser trente
conditions à chaque analyse, dont vingt-neuf n'ont aucune chance d'avoir changé.

**Le spoiler.** Un succès verrouillé montre son nom et sa silhouette, jamais sa
condition — et le serveur ne l'envoie pas non plus. La cacher côté application
seulement laisserait le texte lisible dans la réponse, ce qui n'est pas un
secret gardé.
"""
from fastapi import APIRouter, Depends, HTTPException

from .. import acces, db, succes as cat
from ..dependances import utilisateur
from .amis import sont_amis
from .notifications import previens

routeur = APIRouter(tags=["succes"])


def _compte_theme(uid: int, theme: str) -> int:
    """Combien d'espèces du thème ce joueur a-t-il trouvées ?"""
    return db.valeur(
        """SELECT COUNT(DISTINCT d.case_id)
             FROM decouvertes d
             JOIN succes_especes s ON s.case_id = d.case_id
            WHERE d.utilisateur = ? AND s.succes = ?""",
        (uid, theme), 0)


def _couleurs_trouvees(uid: int) -> int:
    """Combien de couleurs différentes le joueur a-t-il rassemblées.

    On compte les couleurs, pas les espèces : « Mésange bleue » et
    « Merle-bleu » valent un seul bleu.
    """
    return len(db.lit(
        """SELECT DISTINCT s.succes
             FROM decouvertes d
             JOIN succes_especes s ON s.case_id = d.case_id
            WHERE d.utilisateur = ? AND s.succes LIKE 'couleur:%'""", (uid,)))


def _etat(uid: int) -> dict[str, int]:
    """L'avancement de chaque succès."""
    v = {}
    for s in cat.catalogue():
        t, p, cle = s["type"], s["parametre"], s["cle"]
        if t == "theme":
            v[cle] = _compte_theme(uid, p)
        elif t == "couleurs":
            v[cle] = _couleurs_trouvees(uid)
        elif t == "compte":
            v[cle] = db.valeur(
                "SELECT COUNT(*) FROM decouvertes WHERE utilisateur = ?", (uid,), 0)
        elif t == "classe":
            v[cle] = db.valeur(
                """SELECT COUNT(DISTINCT d.case_id) FROM decouvertes d
                     JOIN cases c ON c.id = d.case_id
                    WHERE d.utilisateur = ? AND c.classe = ?""", (uid, p), 0)
        elif t == "classes":
            v[cle] = db.valeur(
                """SELECT COUNT(DISTINCT c.classe) FROM decouvertes d
                     JOIN cases c ON c.id = d.case_id
                    WHERE d.utilisateur = ? AND c.classe <> ''""", (uid,), 0)
        elif t == "rarete":
            v[cle] = db.valeur(
                """SELECT COUNT(*) FROM decouvertes d JOIN cases c ON c.id = d.case_id
                    WHERE d.utilisateur = ? AND c.rarete >= ?""", (uid, p), 0)
        elif t == "toxique":
            v[cle] = db.valeur(
                """SELECT COUNT(*) FROM decouvertes d JOIN cases c ON c.id = d.case_id
                    WHERE d.utilisateur = ? AND c.toxique = 1""", (uid,), 0)
        elif t == "regne":
            v[cle] = db.valeur(
                f"""SELECT COUNT(DISTINCT c.case_id) FROM captures c
                     WHERE {acces.sienne()} AND c.regne = :regne
                       AND c.case_id IS NOT NULL""",
                {"u": uid, "regne": p}, 0)
        elif t == "corrigee":
            # Le seul qui reste strictement personnel, et c'est voulu : corriger
            # une identification est un acte, pas un fait d'avoir été là. On ne
            # décerne pas « bon oeil » à quelqu'un qui n'a rien corrigé.
            v[cle] = db.valeur(
                "SELECT COUNT(*) FROM captures WHERE utilisateur = ? AND corrigee = 1",
                (uid,), 0)
        elif t == "sans_faute":
            v[cle] = db.valeur(
                f"""SELECT COUNT(DISTINCT c.case_id) FROM captures c
                     WHERE {acces.sienne()} AND c.corrigee = 0 AND c.etat = 'ok'
                       AND c.case_id IS NOT NULL""", {"u": uid}, 0)
        elif t == "premiere":
            # Premier de ses amis : aucun ami n'a trouvé la case avant nous.
            v[cle] = db.valeur(
                """SELECT COUNT(*) FROM decouvertes d
                    WHERE d.utilisateur = :u AND NOT EXISTS (
                      SELECT 1 FROM decouvertes a
                        JOIN amities m ON m.etat = 'acceptee'
                         AND ((m.demandeur = :u AND m.destinataire = a.utilisateur)
                           OR (m.destinataire = :u AND m.demandeur = a.utilisateur))
                       WHERE a.case_id = d.case_id AND a.trouve_le < d.trouve_le)""",
                {"u": uid}, 0)
        elif t == "heure":
            debut, fin = p
            # `source_heure` doit valoir « exif » ou « manuel » : sinon
            # quelqu'un qui vide sa pellicule à 23 h décrocherait « Noctambule »
            # sans être sorti de chez lui.
            plage = (f"CAST(strftime('%H', c.prise_le) AS INTEGER) >= {debut} "
                     f"OR CAST(strftime('%H', c.prise_le) AS INTEGER) < {fin}"
                     if debut > fin else
                     f"CAST(strftime('%H', c.prise_le) AS INTEGER) >= {debut} "
                     f"AND CAST(strftime('%H', c.prise_le) AS INTEGER) < {fin}")
            v[cle] = db.valeur(
                f"""SELECT COUNT(DISTINCT c.case_id) FROM captures c
                     WHERE {acces.sienne()} AND c.case_id IS NOT NULL
                       AND c.source_heure IN ('exif', 'manuel')
                       AND c.prise_le IS NOT NULL AND ({plage})""", {"u": uid}, 0)
        elif t == "saisons":
            v[cle] = db.valeur(
                """SELECT COUNT(DISTINCT
                     CASE
                       WHEN CAST(strftime('%m', trouve_le) AS INTEGER) IN (3,4,5) THEN 'p'
                       WHEN CAST(strftime('%m', trouve_le) AS INTEGER) IN (6,7,8) THEN 'e'
                       WHEN CAST(strftime('%m', trouve_le) AS INTEGER) IN (9,10,11) THEN 'a'
                       ELSE 'h' END)
                   FROM decouvertes WHERE utilisateur = ?""", (uid,), 0)
        elif t == "cosigne":
            v[cle] = db.valeur(
                "SELECT COUNT(*) FROM participants WHERE utilisateur = ?", (uid,), 0)
        elif t == "lieux":
            # Combien d'endroits nommés différents. Le lieu vient du géocodage
            # ou de la saisie : deux photos au même parc ne comptent qu'une
            # fois, ce qui est tout l'intérêt.
            v[cle] = db.valeur(
                f"""SELECT COUNT(DISTINCT c.lieu) FROM captures c
                     WHERE {acces.sienne()} AND c.lieu <> ''""", {"u": uid}, 0)
        elif t == "jours_suite":
            # La plus longue série de jours consécutifs avec au moins une photo.
            #
            # L'astuce tient en une ligne : on retire à chaque date son rang
            # dans la suite. Deux jours qui se suivent donnent le même reste ;
            # il suffit alors de compter le plus gros groupe. Ramener toutes les
            # dates au client pour les parcourir coûterait bien plus.
            v[cle] = db.valeur(
                f"""SELECT COALESCE(MAX(n), 0) FROM (
                      SELECT COUNT(*) AS n FROM (
                        SELECT DATE({acces.QUAND}) AS j,
                               ROW_NUMBER() OVER (ORDER BY DATE({acces.QUAND})) AS r
                          FROM captures c
                         WHERE {acces.sienne()}
                         GROUP BY DATE({acces.QUAND}))
                      GROUP BY DATE(j, '-' || r || ' days'))""",
                {"u": uid}, 0)
        elif t == "rafale":
            # Le plus d'espèces différentes trouvées dans une même heure. C'est
            # la sortie fructueuse : on tombe sur un coin qui grouille.
            v[cle] = db.valeur(
                f"""SELECT COALESCE(MAX(n), 0) FROM (
                      SELECT COUNT(DISTINCT c.case_id) AS n
                        FROM captures c
                       WHERE {acces.sienne()} AND c.case_id IS NOT NULL
                       GROUP BY strftime('%Y-%m-%d %H', {acces.QUAND}))""",
                {"u": uid}, 0)
        elif t == "mienne":
            # Les espèces que ce joueur a lui-même ajoutées au dex — les
            # cultivars et variétés que le catalogue mondial ignore.
            v[cle] = db.valeur(
                "SELECT COUNT(*) FROM cases WHERE ajoute_par = ? AND actif = 1",
                (uid,), 0)
        elif t == "flair":
            # Une identification que le moteur donnait pour douteuse, et qu'on a
            # retenue quand même — après avoir regardé la bête, pas l'écran.
            v[cle] = db.valeur(
                f"""SELECT COUNT(DISTINCT c.case_id) FROM captures c
                     WHERE {acces.sienne()} AND c.case_id IS NOT NULL
                       AND c.confiance > 0 AND c.confiance < 0.35""",
                {"u": uid}, 0)
        elif t == "titres":
            # Les photos auxquelles on a donné un titre. L'espèce dit ce qu'on a
            # vu, le titre dit ce qu'on a vécu.
            v[cle] = db.valeur(
                f"""SELECT COUNT(*) FROM captures c
                     WHERE {acces.sienne()} AND c.titre <> ''""", {"u": uid}, 0)
        elif t == "reactions":
            v[cle] = db.valeur(
                """SELECT COUNT(*) FROM reactions r
                     JOIN captures c ON c.id = r.capture
                    WHERE c.utilisateur = ?""", (uid,), 0)
        else:
            v[cle] = 0
    return v


def _debloque(uid: int, avancement: dict[str, int]) -> list[str]:
    """Enregistre ce qui vient d'être atteint. Ne rend que les nouveaux.

    `INSERT OR IGNORE` porte tout le « une seule fois » : un succès déjà en
    base n'est pas réécrit, donc sa date ne bouge pas et aucune notification ne
    repart. Un succès seulement révélé a déjà une ligne — on la complète.
    """
    seuils = {s["cle"]: s["seuil"] for s in cat.catalogue()}
    deja = {r["cle"] for r in db.lit(
        """SELECT cle FROM succes_obtenus
            WHERE utilisateur = ? AND obtenu = 1""", (uid,))}
    # `(n or 0)` : une requête qui rend NULL — un MAX sur rien, une colonne
    # vide — ne doit pas faire échouer l'évaluation des quatre-vingt-deux autres.
    neufs = [c for c, n in avancement.items()
             if c not in deja and (n or 0) >= seuils[c]]
    if neufs:
        with db.transaction() as cx:
            cx.executemany(
                """INSERT INTO succes_obtenus (utilisateur, cle, obtenu, obtenu_le)
                   VALUES (?,?,1,datetime('now'))
                   ON CONFLICT(utilisateur, cle) DO UPDATE SET
                       obtenu = 1,
                       obtenu_le = COALESCE(succes_obtenus.obtenu_le, datetime('now'))
                   WHERE succes_obtenus.obtenu = 0""",
                [(uid, c) for c in neufs])
    return neufs


@routeur.get("/succes")
def liste(joueur: int | None = None, u=Depends(utilisateur)):
    """Les trente succès, leur avancement, et ce qui vient de tomber.

    Chez un ami, on ne montre que ce qu'il a obtenu — pas son avancement.
    Voir qu'il est à 9/10 d'un succès qu'il ignore reviendrait à le lui
    souffler.
    """
    cible, chez_soi = u["id"], True
    if joueur is not None and joueur != u["id"]:
        if not sont_amis(u["id"], joueur):
            raise HTTPException(403, "Vous n'êtes pas amis avec ce joueur.")
        cible, chez_soi = joueur, False

    avancement = _etat(cible)
    neufs = _debloque(cible, avancement) if chez_soi else []

    lignes = {r["cle"]: r for r in db.lit(
        """SELECT cle, obtenu, obtenu_le, revele FROM succes_obtenus
            WHERE utilisateur = ?""", (cible,))}

    if neufs:
        amis = db.lit(
            """SELECT CASE WHEN demandeur = ? THEN destinataire ELSE demandeur END AS id
                 FROM amities WHERE etat = 'acceptee'
                  AND (demandeur = ? OR destinataire = ?)""",
            (cible, cible, cible))
        for a in amis:
            previens(a["id"], cible, "succes_debloque", valeur=len(neufs))

    sortie = []
    for s in cat.catalogue():
        r = lignes.get(s["cle"])
        acquis = bool(r and r["obtenu"])
        montrable = acquis or bool(r and r["revele"])
        sortie.append({
            "cle": s["cle"], "nom": s["nom"], "emoji": s["emoji"],
            "difficulte": s["difficulte"],
            # Le modèle réel, pas celui déclaré : vingt-neuf n'existent
            # pas encore et donneraient un 404 dans la fiche.
            "modele": cat.modele_de(s["modele"]),
            # Les couleurs de la gemme, tirées du modèle qu'elle enferme. Le
            # serveur les donne pour que l'application et le site montrent la
            # même : deux tables tenues à la main divergeraient.
            "couleurs": cat.couleurs_de(s["modele"]),
            "seuil": s["seuil"],
            "obtenu": acquis,
            "obtenu_le": r["obtenu_le"] if acquis else None,
            "revele": montrable,
            "comment": s["comment"] if montrable else None,
            "avancement": avancement.get(s["cle"], 0) if chez_soi else None,
            "neuf": s["cle"] in neufs,
        })

    sortie.sort(key=lambda x: (cat.ORDRE_DIFFICULTE[x["difficulte"]], x["nom"]))
    return {
        "joueur": cible,
        "obtenus": sum(1 for s in sortie if s["obtenu"]),
        "total": len(sortie),
        "succes": sortie,
        "nouveaux": neufs,
    }


@routeur.post("/succes/{cle}/reveler")
def revele(cle: str, u=Depends(utilisateur)):
    """Montrer la condition d'un succès qu'on n'a pas.

    On pose une ligne avec `obtenu = 0` : c'est ce drapeau, et non la présence
    de la ligne, qui dit si le succès est acquis. Confondre les deux ferait
    décrocher tous les succès qu'on a simplement regardés.
    """
    if cle not in cat.par_cle():
        raise HTTPException(404, "Succès inconnu.")
    db.ecrit(
        """INSERT INTO succes_obtenus (utilisateur, cle, obtenu, revele)
           VALUES (?,?,0,1)
           ON CONFLICT(utilisateur, cle) DO UPDATE SET revele = 1""",
        (u["id"], cle))
    return {"cle": cle, "comment": cat.par_cle()[cle]["comment"]}
