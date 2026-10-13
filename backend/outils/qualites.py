#!/usr/bin/env python3
"""
Attribue à chaque case sa qualité et ses points.

Cinq qualités, du plus banal au plus improbable : commun, basique, peu commun,
rare, légendaire. Le nombre d'observations GBIF en est la matière première, mais
il ne suffit pas — il porte deux biais qu'il faut corriger, sans quoi le
classement est absurde.

**Biais n°1 : l'obscurité n'est pas un exploit.** Les insectes ont huit
observations médianes, les oiseaux cinq mille. Sur des seuils bruts, le moindre
charançon inconnu deviendrait « légendaire » et la distinction ne voudrait plus
rien. On exige donc, pour accéder aux hautes qualités, que l'espèce soit parmi
les mieux observées *de son propre groupe* : une bête que personne ne voit dans
un groupe que personne ne regarde relève de l'obscurité, pas de la prouesse.

**Biais n°2 : le bétail ne s'observe pas.** Personne ne déclare sa vache ni son
chat à GBIF, ce qui les faisait passer pour rares alors qu'on en croise tous les
jours. Une liste d'espèces domestiques et urbaines les ramène au rang de
communes.

Reste un troisième biais qu'on ne corrige pas : les espèces suivies par des
programmes scientifiques (loup, lynx, ours) sont sur-représentées par rapport à
la chance qu'on a de les croiser. Elles ressortent « rares » plutôt que
« légendaires », ce qui reste défendable.

    python outils/qualites.py
"""
import argparse
import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import db  # noqa: E402

# (numéro, nom, seuil minimal d'observations, points)
# Les seuils sont calés sur des espèces repères : le pigeon et le merle sont
# communs, le chevreuil et l'écureuil basiques, l'aigle royal peu commun, le
# loup et le lynx rares, le tigre légendaire.
QUALITES = [
    (1, "commun",     1_000_000,   5),
    (2, "basique",      100_000,  10),
    (3, "peu commun",    10_000,  25),
    (4, "rare",           1_000,  60),
    (5, "legendaire",         0, 150),
]

# Pour prétendre à une qualité, il faut être au moins dans ce centile
# d'observations de son groupe. Sans cette barrière, l'obscurité taxonomique
# vaudrait médaille d'or.
CENTILE_MINIMAL = {5: 0.90, 4: 0.75, 3: 0.50}

# Et il faut un minimum d'observations dans l'absolu. Une bête vue deux cents
# fois dans toute l'histoire de la biologie n'est pas une prise de choix : c'est
# une espèce que personne n'a jamais regardée. Ce plancher évite que le moindre
# charançon jamais décrit vaille plus qu'un tigre.
PLANCHER = {5: 200, 4: 50}

# Espèces que GBIF sur-représente parce qu'elles font l'objet de programmes de
# suivi — pièges photographiques, comptages officiels. Les observations disent
# l'effort scientifique, pas la chance d'en croiser un en promenade. On leur
# impose donc une qualité minimale.
#
# C'est aussi le levier pour corriger l'exotisme, que les observations ne
# mesurent pas : un koala très photographié en réserve ressort « basique » alors
# qu'en croiser un relève de l'expédition. Cette liste n'a pas à être complète,
# elle se complète au fil des trouvailles qui semblent mal notées.
EMBLEMATIQUES = {
    "Panthera tigris": 5, "Phascolarctos cinereus": 4, "Vombatus ursinus": 4,
    "Macropus rufus": 4, "Ornithorhynchus anatinus": 5, "Tachyglossus aculeatus": 5,
    "Giraffa giraffa": 4, "Giraffa camelopardalis": 4, "Equus quagga": 4,
    "Equus grevyi": 5, "Bison bonasus": 5, "Bison bison": 4, "Alces alces": 3,
    "Rangifer tarandus": 3, "Ovibos moschatus": 5, "Vulpes lagopus": 4,
    "Ursus maritimus": 5, "Odobenus rosmarus": 5, "Monachus monachus": 5,
    "Canis lupus": 4, "Lynx lynx": 4, "Lynx pardinus": 5, "Ursus arctos": 4,
    "Gulo gulo": 4, "Panthera pardus": 5, "Panthera leo": 5, "Panthera onca": 5,
    "Acinonyx jubatus": 5, "Ailuropoda melanoleuca": 5, "Gorilla gorilla": 5,
    "Pan troglodytes": 5, "Pongo pygmaeus": 5, "Loxodonta africana": 4,
    "Elephas maximus": 5, "Diceros bicornis": 5, "Ceratotherium simum": 5,
    "Hippopotamus amphibius": 4, "Crocuta crocuta": 4, "Rupicapra rupicapra": 3,
    "Capra ibex": 3, "Lutra lutra": 4, "Castor fiber": 3, "Felis silvestris": 4,
    "Martes martes": 3, "Meles meles": 3, "Genetta genetta": 4,
    "Gypaetus barbatus": 5, "Aquila chrysaetos": 4, "Ciconia nigra": 4,
    "Bubo bubo": 4, "Tetrao urogallus": 4, "Alcedo atthis": 3,
    "Vipera aspis": 3, "Emys orbicularis": 4, "Proteus anguinus": 5,
}

# Espèces domestiques et urbaines : on les croise partout, GBIF les ignore.
DOMESTIQUES = {
    "Bos taurus", "Ovis aries", "Capra hircus", "Sus scrofa domesticus",
    "Equus caballus", "Equus asinus", "Gallus gallus", "Anas platyrhynchos domesticus",
    "Meleagris gallopavo", "Anser anser", "Cairina moschata", "Numida meleagris",
    "Felis catus", "Canis familiaris", "Canis lupus familiaris",
    "Oryctolagus cuniculus", "Cavia porcellus", "Mesocricetus auratus",
    "Rattus norvegicus", "Mus musculus", "Rattus rattus",
    "Columba livia", "Passer domesticus", "Sturnus vulgaris",
    "Apis mellifera", "Bombyx mori",
    "Carassius auratus", "Cyprinus carpio",
    "Lama glama", "Vicugna pacos", "Bubalus bubalis", "Camelus dromedarius",
}


def centiles_par_classe() -> dict[str, dict[int, float]]:
    """Pour chaque classe, le seuil d'observations de chaque centile utile."""
    seuils: dict[str, dict[int, float]] = {}
    classes = [r["classe"] for r in
               db.lit("SELECT DISTINCT classe FROM cases WHERE classe <> ''")]
    for cl in classes:
        obs = [r["obs"] for r in
               db.lit("SELECT obs FROM cases WHERE classe = ? ORDER BY obs", (cl,))]
        if not obs:
            continue
        n = len(obs)
        seuils[cl] = {
            q: obs[min(n - 1, int(part * n))] for q, part in CENTILE_MINIMAL.items()
        }
    return seuils


def qualite_de(obs: int, latin: str, classe: str,
               seuils: dict[str, dict[int, float]]) -> tuple[int, int]:
    """Renvoie (numéro de qualité, points)."""
    if latin in DOMESTIQUES:
        return 1, QUALITES[0][3]

    # Qualité brute, d'après les observations mondiales.
    niveau = next(q for q, _, mini, _ in QUALITES if obs >= mini)

    # Puis on redescend tant que l'espèce ne mérite pas son rang : ni assez en
    # vue dans son groupe, ni assez observée dans l'absolu.
    par_classe = seuils.get(classe)
    while niveau > 1 and (
            (par_classe and niveau in CENTILE_MINIMAL and obs < par_classe[niveau])
            or obs < PLANCHER.get(niveau, 0)):
        niveau -= 1

    # Les espèces que le suivi scientifique fausse dans l'autre sens.
    niveau = max(niveau, EMBLEMATIQUES.get(latin, 0))

    points = next(p for q, _, _, p in QUALITES if q == niveau)
    return niveau, points


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--essai", action="store_true",
                    help="montrer le résultat sans rien écrire")
    a = ap.parse_args()

    db.initialise()
    print("Calcul des centiles par groupe…", flush=True)
    seuils = centiles_par_classe()
    print(f"  {len(seuils)} groupes", flush=True)

    lignes = db.lit("SELECT id, latin, obs, classe FROM cases")
    maj = [(*qualite_de(r["obs"], r["latin"], r["classe"], seuils), r["id"])
           for r in lignes]

    if not a.essai:
        with db.transaction() as cx:
            cx.executemany(
                "UPDATE cases SET rarete = ?, points = ? WHERE id = ?", maj)
        print(f"{len(maj)} cases mises à jour.\n")

    print("Répartition :")
    compte: dict[int, int] = {}
    for niveau, _, _ in maj:
        compte[niveau] = compte.get(niveau, 0) + 1
    total = len(maj)
    for q, nom, _, points in QUALITES:
        n = compte.get(q, 0)
        print(f"  {q} {nom:<12} {n:>7} cases  ({n / total:5.1%})  {points:>3} pts")

    print("\nEspèces repères :")
    reperes = ["Columba livia", "Turdus merula", "Cyanistes caeruleus", "Bos taurus",
               "Felis catus", "Capreolus capreolus", "Sciurus vulgaris",
               "Vulpes vulpes", "Coccinella septempunctata", "Aquila chrysaetos",
               "Salamandra salamandra", "Sus scrofa", "Canis lupus", "Lynx lynx",
               "Ursus arctos", "Panthera tigris", "Phascolarctos cinereus",
               "Giraffa giraffa"]
    noms = {q: nom for q, nom, _, _ in QUALITES}
    for latin in reperes:
        r = db.lit_un("SELECT obs, classe FROM cases WHERE latin = ?", (latin,))
        if not r:
            continue
        niveau, points = qualite_de(r["obs"], latin, r["classe"], seuils)
        print(f"  {latin:<28} {r['obs']:>9} obs  ->  "
              f"{noms[niveau]:<11} {points:>3} pts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
