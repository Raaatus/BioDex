#!/usr/bin/env python3
"""
Sépare les animaux domestiques de leur ancêtre sauvage, et fait entrer les races.

Deux défauts se cumulaient sur les chiens.

**Le chien était rangé avec le loup.** GBIF tient `Canis lupus familiaris` pour
une sous-espèce de `Canis lupus` ; c'est défendable en taxonomie, mais dans le
dex cela donnait une case « Loup gris » classée rare à soixante points pour la
photo d'un labrador. On lui donne donc sa case, à partir de la clé GBIF de la
sous-espèce — qui existe bel et bien.

**Les races n'étaient nulle part.** Un labrador n'est pas un taxon : GBIF n'en
saura jamais rien. Mais le classificateur est un CLIP, et son catalogue n'a pas
à être de la taxonomie — on peut lui présenter n'importe quel libellé. Les races
du catalogue v2 deviennent donc des alias de leur espèce domestique, exactement
comme les synonymes latins. Le moteur somme les probabilités par case : cocker,
caniche et cavalier king-charles s'additionnent sur « Chien », au lieu de se
diviser et de laisser le loup passer devant.

Reste un piège propre à ce backend : les races arrivent avec zéro observation,
alors que l'a priori de fréquence donne au loup près de cent mille. Sans
correction, le loup l'emporterait malgré tout. On attribue donc aux races une
fréquence à la mesure de ce qu'on croise vraiment dans la rue.

    python outils/domestiques.py --catalogue ~/biodex/catalogue_v2.pt
"""
import argparse
import pathlib
import shutil
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db  # noqa: E402

# Cases à créer si elles manquent : (clé GBIF, latin, nom français, qualité).
# Les clés sont celles des sous-espèces domestiques dans le backbone GBIF.
CASES_A_CREER = [
    (6164210, "Canis lupus familiaris", "Chien", "Canis", "Canidae",
     "Carnivora", "Mammalia", 1),
    (11374585, "Sus scrofa domesticus", "Cochon domestique", "Sus", "Suidae",
     "Artiodactyla", "Mammalia", 1),
]

# Les noms latins qui doivent quitter la case du sauvage pour celle du domestique.
A_DEPLACER = {
    "Canis familiaris": "Canis lupus familiaris",
    "Canis lupus familiaris": "Canis lupus familiaris",
    "Sus scrofa domesticus": "Sus scrofa domesticus",
}

# Où atterrit chaque groupe de races du catalogue v2.
GROUPES = {
    "Chien domestique": "Canis lupus familiaris",
    "Chat domestique": "Felis catus",
    "Cheval domestique": "Equus caballus",
    "Bovin domestique": "Bos taurus",
    "Volaille domestique": "Gallus gallus",
}

# Le petit élevage est trop hétéroclite pour un groupe : chaque libellé a son
# espèce.
# Quelques libellés que leur groupe range mal : l'âne est une espèce à part
# entière, pas une race de cheval. Le mulet, lui, est un hybride sans espèce
# propre — on le laisse chez les chevaux.
EXCEPTIONS = {
    "Donkey": "Equus asinus",
}

PETIT_ELEVAGE = {
    "Domestic rabbit": "Oryctolagus cuniculus",
    "Guinea pig": "Cavia porcellus",
    "Domestic sheep": "Ovis aries",
    "Lamb": "Ovis aries",
    "Domestic goat": "Capra hircus",
    "Domestic pig": "Sus scrofa domesticus",
    "Piglet": "Sus scrofa domesticus",
    "Golden hamster": "Mesocricetus auratus",
    "Ferret": "Mustela putorius",
    "Domestic rat": "Rattus norvegicus",
    "Budgerigar": "Melopsittacus undulatus",
    "Cockatiel": "Nymphicus hollandicus",
    "Canary bird": "Serinus canaria",
    "Goldfish": "Carassius auratus",
}

# Fréquence attribuée à chaque race, faute d'observations GBIF. Ce ne sont pas
# des mesures mais des ordres de grandeur : on croise plus de chiens que de
# renards, et le loup plafonne à quatre-vingt-dix-huit mille observations.
FREQUENCE = {
    "Chien domestique": 400_000,
    "Chat domestique": 400_000,
    "Cheval domestique": 80_000,
    "Bovin domestique": 80_000,
    "Volaille domestique": 60_000,
    "Petit élevage": 40_000,
}


def case_de(latin: str) -> int | None:
    r = db.lit_un("SELECT id FROM cases WHERE latin = ?", (latin,))
    return r["id"] if r else None


def cree_cases_manquantes() -> None:
    for cle, latin, nom_fr, genre, famille, ordre, classe, qualite in CASES_A_CREER:
        if case_de(latin):
            print(f"  {latin} : déjà présente")
            continue
        # La silhouette et les points sont repris de l'espèce sauvage voisine,
        # puis la qualité est forcée : un chien n'est pas une trouvaille rare.
        parent = db.lit_un(
            "SELECT visuel, cle_genre, cle_famille, cle_ordre, cle_classe "
            "FROM cases WHERE latin = ?", (latin.rsplit(" ", 1)[0],))
        db.ecrit(
            """INSERT INTO cases (cle_gbif, latin, nom_fr, genre, famille, ordre,
                                  classe, obs, rarete, points, visuel, nb_alias,
                                  cle_genre, cle_famille, cle_ordre, cle_classe)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (cle, latin, nom_fr, genre, famille, ordre, classe,
             FREQUENCE["Chien domestique"], qualite, 5,
             parent["visuel"] if parent else None, 1,
             parent["cle_genre"] if parent else None,
             parent["cle_famille"] if parent else None,
             parent["cle_ordre"] if parent else None,
             parent["cle_classe"] if parent else None))
        print(f"  {latin} : case créée — « {nom_fr} »")


def deplace_alias() -> int:
    """Sort les noms domestiques de la case de leur ancêtre sauvage."""
    n = 0
    for latin, vers in A_DEPLACER.items():
        cible = case_de(vers)
        if cible is None:
            continue
        actuelle = db.lit_un(
            "SELECT a.case_id, c.latin FROM alias a JOIN cases c ON c.id = a.case_id "
            "WHERE a.latin = ?", (latin,))
        if actuelle and actuelle["case_id"] == cible:
            continue
        db.ecrit(
            """INSERT INTO alias (latin, case_id, accepte) VALUES (?,?,1)
               ON CONFLICT(latin) DO UPDATE SET case_id = excluded.case_id""",
            (latin, cible))
        if actuelle:
            print(f"  « {latin} » quitte « {actuelle['latin']} » pour « {vers} »")
        n += 1
    return n


def rattache_races(catalogue: pathlib.Path) -> tuple[int, dict[str, int]]:
    """Fait des races des alias de leur espèce, et renvoie leurs fréquences."""
    import torch

    d = torch.load(catalogue, weights_only=False)
    noms = d["noms"]
    groupes = d.get("genres") or []
    if not groupes:
        raise SystemExit("Ce catalogue ne porte pas de groupes : il faut la version 2.")

    lignes, frequences, inconnus = [], {}, []
    for nom, groupe in zip(noms, groupes):
        espece = GROUPES.get(groupe)
        if groupe == "Petit élevage":
            espece = PETIT_ELEVAGE.get(nom)
        espece = EXCEPTIONS.get(nom, espece)
        if espece is None:
            continue
        cible = case_de(espece)
        if cible is None:
            inconnus.append(f"{nom} → {espece}")
            continue
        lignes.append((nom, cible))
        frequences[nom] = FREQUENCE.get(groupe, 40_000)

    if lignes:
        with db.transaction() as cx:
            cx.executemany(
                """INSERT INTO alias (latin, case_id, accepte) VALUES (?,?,0)
                   ON CONFLICT(latin) DO UPDATE SET case_id = excluded.case_id""",
                lignes)
            # Le compteur d'alias sert à l'affichage de la fiche d'espèce.
            cx.execute("""UPDATE cases SET nb_alias =
                          (SELECT COUNT(*) FROM alias a WHERE a.case_id = cases.id)
                          WHERE id IN (SELECT DISTINCT case_id FROM alias)""")
    if inconnus:
        print(f"  !! {len(inconnus)} race(s) sans case : {inconnus[:3]}")
    return len(lignes), frequences


def ecrit_catalogue(source: pathlib.Path, frequences: dict[str, int]) -> None:
    """Copie le catalogue dans les données du serveur, avec les fréquences des
    races corrigées."""
    import torch

    d = torch.load(source, weights_only=False)
    obs = list(d.get("obs") or [0] * len(d["noms"]))
    touchees = 0
    for i, nom in enumerate(d["noms"]):
        if nom in frequences and obs[i] == 0:
            obs[i] = frequences[nom]
            touchees += 1
    d["obs"] = obs

    cible = config.DONNEES / "catalogue_v2.pt"
    torch.save(d, cible)
    print(f"  {touchees} races pourvues d'une fréquence, catalogue écrit dans "
          f"{cible.name} ({cible.stat().st_size / 2**20:.0f} Mo)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--catalogue", type=pathlib.Path,
                    default=pathlib.Path("~/biodex/catalogue_v2.pt").expanduser(),
                    help="catalogue v2, celui qui porte les races")
    ap.add_argument("--sans-catalogue", action="store_true",
                    help="ne toucher qu'à la base, sans réécrire le catalogue")
    a = ap.parse_args()

    if not a.catalogue.exists():
        raise SystemExit(f"Introuvable : {a.catalogue}")

    db.initialise()
    print("Cases domestiques :")
    cree_cases_manquantes()

    print("\nRattachements corrigés :")
    n = deplace_alias()
    if not n:
        print("  rien à déplacer")

    print("\nRaces :")
    combien, frequences = rattache_races(a.catalogue)
    print(f"  {combien} races rattachées à leur espèce")

    if not a.sans_catalogue:
        print("\nCatalogue :")
        ecrit_catalogue(a.catalogue, frequences)

    print("\nVérification :")
    for latin in ("Canis familiaris", "Labrador Retriever", "Cocker Spaniel",
                  "Bengal cat", "Holstein cattle"):
        r = db.lit_un(
            """SELECT c.latin, c.nom_fr, c.rarete, c.points FROM alias a
               JOIN cases c ON c.id = a.case_id WHERE a.latin = ?""", (latin,))
        if r:
            print(f"  {latin:24} → « {r['nom_fr'] or r['latin']} » "
                  f"(qualité {r['rarete']}, {r['points']} pts)")
        else:
            print(f"  {latin:24} → aucune case")
    return 0


if __name__ == "__main__":
    sys.exit(main())
