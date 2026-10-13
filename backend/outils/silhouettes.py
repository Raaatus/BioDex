#!/usr/bin/env python3
"""
Écrit le jeu de silhouettes et l'associe aux cases du dex.

Une silhouette par grand groupe, pas par espèce : il y a 376 000 cases, et un
lézard des murailles ressemble suffisamment à un lézard ocellé pour partager sa
forme. Chaque case reçoit la silhouette la plus précise disponible, en remontant
sa lignée — d'abord sa famille, sinon son ordre, sinon sa classe, sinon la forme
passe-partout.

Les formes sont volontairement schématiques et de face ou de profil, dans un
carré de 100 × 100, sans couleur : l'application les teinte elle-même en gris
pour les cases vides et peut les remplir pour les cases trouvées.

Pour ajouter une silhouette : une entrée dans FORMES, une ligne dans RATTACHEMENT,
et on relance le script.

    python outils/silhouettes.py
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db  # noqa: E402

# Deux couches distinctes, et c'est essentiel : le corps est un aplat sans
# contour, les appendices (pattes, antennes, nageoires) sont des traits sans
# remplissage. Tout tracer avec le même contour épais, comme dans la première
# version, épaississait les corps jusqu'à en faire des taches informes.
GABARIT = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" '
    'width="100" height="100">'
    '<g fill="currentColor" stroke="none">{corps}</g>'
    '<g fill="none" stroke="currentColor" stroke-width="4" '
    'stroke-linecap="round" stroke-linejoin="round">{traits}</g>'
    '{extra}</svg>')


def _oeil(x: float, y: float, r: float = 2.2) -> str:
    """Un œil évidé : le trou laisse voir le fond, ce qui rend la forme lisible
    même remplie d'une seule couleur."""
    return f'<circle cx="{x}" cy="{y}" r="{r}" fill="#fff" fill-opacity=".85"/>'


# Chaque forme : (corps plein, traits, ornements clairs).
#
# Les corps sont bâtis en primitives (ellipses, cercles, polygones) plutôt qu'en
# tracés à main levée : c'est nettement plus prévisible, et une silhouette ratée
# se corrige en déplaçant un cercle au lieu de relire trente commandes de Bézier.
# Les traits ne servent qu'aux appendices fins — pattes, antennes, queues.
# Les ornements sont clairs et translucides : ils creusent la forme (œil, rayure,
# spirale) et restent visibles quelle que soit la teinte appliquée.

FORMES: dict[str, tuple[str, str, str]] = {

    # ------------------------------------------------------------- mammifères
    "mammifere": (
        '<rect x="22" y="44" width="42" height="26" rx="13"/>'
        '<circle cx="74" cy="42" r="14"/>'
        '<ellipse cx="90" cy="46" rx="8" ry="5"/>'
        '<polygon points="66,30 63,15 78,27"/>',
        "M32 68v16 M46 68v16 M56 68v16 M64 66v18 M22 52c-9-1-14-7-15-14",
        _oeil(76, 38, 2)),
    "cervide": (
        '<rect x="24" y="50" width="40" height="24" rx="12"/>'
        '<polygon points="57,62 65,28 76,30 69,64"/>'
        '<ellipse cx="77" cy="24" rx="13" ry="9"/>',
        "M71 16l-7-13 M71 16l-13-5 M84 16l7-13 M84 16l13-5 "
        "M32 72v18 M44 72v18 M54 72v18 M62 70v20",
        _oeil(82, 22, 1.9)),
    "felin": (
        '<rect x="20" y="48" width="44" height="26" rx="13"/>'
        '<circle cx="72" cy="44" r="15"/>'
        '<polygon points="60,32 57,15 72,27"/><polygon points="84,32 87,15 72,27"/>',
        "M30 72v14 M44 72v14 M56 72v14 M64 70v16 M20 56c-11 1-15-8-10-17",
        _oeil(66, 42, 2) + _oeil(78, 42, 2)),
    "rongeur": (
        '<ellipse cx="42" cy="58" rx="24" ry="18"/>'
        '<polygon points="62,45 94,57 62,69"/>'
        '<circle cx="56" cy="34" r="13"/>',
        "M19 62c-16 3-21 15-13 27 M32 75v11 M50 75v11",
        '<circle cx="56" cy="34" r="6" fill="#fff" fill-opacity=".8"/>'
        + _oeil(72, 55, 1.9)),
    "chauve_souris": (
        '<ellipse cx="50" cy="52" rx="10" ry="17"/>'
        '<circle cx="50" cy="32" r="10"/>'
        '<polygon points="42,26 37,10 50,22"/><polygon points="58,26 63,10 50,22"/>'
        '<path d="M41 44 6 32l12 15L4 50l17 13-7 9 27-9z"/>'
        '<path d="M59 44 94 32 82 47l14 3-17 13 7 9-27-9z"/>',
        "",
        _oeil(45, 31, 1.8) + _oeil(55, 31, 1.8)),
    "primate": (
        '<ellipse cx="50" cy="69" rx="22" ry="19"/>'
        '<circle cx="50" cy="36" r="17"/>'
        '<circle cx="29" cy="34" r="8"/><circle cx="71" cy="34" r="8"/>',
        "M30 64c-9 8-11 17-7 25 M70 64c9 8 11 17 7 25",
        '<ellipse cx="50" cy="45" rx="10" ry="7" fill="#fff" fill-opacity=".8"/>'
        + _oeil(43, 32, 2.2) + _oeil(57, 32, 2.2)),
    "cetace": (
        '<ellipse cx="46" cy="52" rx="36" ry="17"/>'
        '<polygon points="79,52 98,35 94,52 98,69"/>'
        '<polygon points="42,36 50,21 57,38"/>'
        '<polygon points="38,64 25,79 49,68"/>',
        "M27 34v-9",
        _oeil(20, 48, 2.2)),

    # ---------------------------------------------------------------- oiseaux
    "oiseau": (
        '<ellipse cx="44" cy="58" rx="24" ry="18"/>'
        '<circle cx="70" cy="34" r="13"/>'
        '<polygon points="80,29 97,35 80,41"/>'
        '<polygon points="22,52 3,43 10,67"/>',
        "M32 54c9-7 19-6 25 2 M44 76v12 M56 74v14",
        _oeil(73, 31, 2.2)),
    "canard": (
        '<ellipse cx="42" cy="62" rx="26" ry="16"/>'
        '<circle cx="70" cy="38" r="12"/>'
        '<ellipse cx="88" cy="43" rx="10" ry="5"/>'
        '<polygon points="18,54 1,47 12,67"/>',
        "M32 60c9-7 19-6 24 1",
        _oeil(73, 35, 2.1)),
    "rapace": (
        '<ellipse cx="46" cy="58" rx="22" ry="20"/>'
        '<circle cx="66" cy="32" r="13"/>'
        '<path d="M76 25l15 5-7 4 3 9-9-7z"/>'
        '<polygon points="26,68 11,85 35,77"/>',
        "M46 78v9 M46 87l-7 5 M46 87l7 5 M59 76v9 M59 85l-7 5 M59 85l7 5",
        _oeil(68, 28, 2.1)),
    "echassier": (
        '<ellipse cx="40" cy="52" rx="22" ry="13"/>'
        '<polygon points="53,48 62,15 73,17 64,52"/>'
        '<circle cx="70" cy="14" r="8"/>'
        '<polygon points="78,11 99,17 78,20"/>'
        '<polygon points="20,48 3,41 12,59"/>',
        "M38 64v25 M38 89h11 M51 64v25 M51 89h11",
        _oeil(72, 12, 1.8)),

    # --------------------------------------------------------------- poissons
    "poisson": (
        '<path d="M10 52c8-16 26-26 46-26 14 0 26 5 34 14l8-12c2-3 6-1 5 2l-5 22 5 22'
        'c1 3-3 5-5 2l-8-12c-8 9-20 14-34 14-20 0-38-10-46-26z"/>'
        '<polygon points="46,28 52,12 62,30"/>',
        "M30 40c-5 7-5 17 0 24",
        _oeil(24, 47, 2.6)),
    "requin": (
        '<path d="M6 58c10-14 26-23 44-25l6-20c1-3 5-2 5 1l1 20c10 2 19 7 26 14l10-8'
        'c3-2 6 1 4 4l-8 12 6 14c1 3-3 5-5 2l-9-10c-9 8-22 12-36 12-17 0-33-6-44-16z"/>'
        '<path d="M44 74l-6 16c-1 3-5 2-5-1l1-16z"/>',
        "M62 56h14",
        _oeil(70, 50, 2.3)),

    # -------------------------------------------------------------- reptiles
    "lezard": (
        '<ellipse cx="48" cy="48" rx="21" ry="11"/>'
        '<ellipse cx="74" cy="43" rx="13" ry="9"/>'
        # La queue en bande courbe qui s'affine se lit bien mieux qu'un zigzag :
        # c'est elle qui distingue un lézard d'un gros insecte.
        '<path d="M30 54c-9 5-17 13-21 25-1 4 4 6 6 2 4-10 10-16 18-21z"/>',
        "M38 56l-8 13 M58 56l8 13 M38 40l-8-11 M58 40l8-11",
        _oeil(79, 40, 1.9)),
    "serpent": (
        '<path d="M14 76c-3 0-5-2-5-5 0-9 6-16 14-19l30-11c5-2 8-6 8-11 0-6-5-11-11-11'
        '-5 0-9 3-10 8-1 3-5 2-4-1 2-7 8-11 15-11 9 0 16 7 16 16 0 8-5 14-12 17'
        'l-30 11c-6 2-10 7-10 12 0 3-2 5-5 5z"/>'
        '<ellipse cx="63" cy="21" rx="11" ry="8"/>',
        "M74 21h10 M84 21l6-4 M84 21l6 4",
        _oeil(66, 18, 1.7)),
    "tortue": (
        '<ellipse cx="48" cy="56" rx="30" ry="22"/>'
        '<circle cx="84" cy="47" r="9"/>'
        '<ellipse cx="26" cy="76" rx="11" ry="6"/><ellipse cx="66" cy="76" rx="11" ry="6"/>'
        '<ellipse cx="21" cy="39" rx="9" ry="6"/>'
        '<polygon points="18,58 4,63 18,66"/>',
        "",
        '<path d="M48 35v42 M20 52h56 M28 68h40" fill="none" stroke="#fff" '
        'stroke-opacity=".8" stroke-width="3"/>' + _oeil(87, 44, 1.7)),

    # ------------------------------------------------------------ amphibiens
    "grenouille": (
        '<path d="M50 34c12 0 21 8 21 19 0 4-1 8-4 11l10 8c3 2 0 6-3 4l-11-8c-4 2-8 3-13 3'
        's-9-1-13-3l-11 8c-3 2-6-2-3-4l10-8c-3-3-4-7-4-11 0-11 9-19 21-19z"/>'
        '<circle cx="40" cy="29" r="9"/><circle cx="60" cy="29" r="9"/>',
        "M32 72l-9 9 M68 72l9 9",
        _oeil(40, 28, 3) + _oeil(60, 28, 3)),
    "salamandre": (
        '<ellipse cx="48" cy="50" rx="21" ry="11"/>'
        '<ellipse cx="74" cy="46" rx="13" ry="9"/>'
        '<path d="M30 56c-10 4-19 12-23 24-2 4 4 6 6 2 4-10 11-16 19-20z"/>',
        "M38 58l-9 12 M58 58l9 12 M38 42l-9-10 M58 42l9-10",
        '<circle cx="42" cy="49" r="3" fill="#fff" fill-opacity=".8"/>'
        '<circle cx="54" cy="54" r="3" fill="#fff" fill-opacity=".8"/>'
        + _oeil(77, 45, 1.8)),

    # --------------------------------------------------------------- insectes
    "insecte": (
        '<circle cx="50" cy="24" r="10"/>'
        '<ellipse cx="50" cy="45" rx="13" ry="11"/>'
        '<ellipse cx="50" cy="70" rx="15" ry="18"/>',
        "M44 16l-9-11 M56 16l9-11 "
        "M38 39l-17-9 M37 47l-19 2 M38 54l-17 11 "
        "M62 39l17-9 M63 47l19 2 M62 54l17 11",
        _oeil(45, 22, 2) + _oeil(55, 22, 2)),
    "papillon": (
        '<path d="M50 34c2 0 3 2 3 4l-1 30c0 2-4 2-4 0l-1-30c0-2 1-4 3-4z"/>'
        '<path d="M46 40c-4-10-14-18-25-18-6 0-10 5-9 11 2 12 14 21 27 22 5 1 9-2 9-7'
        ' 0-3-1-6-2-8z"/>'
        '<path d="M54 40c4-10 14-18 25-18 6 0 10 5 9 11-2 12-14 21-27 22-5 1-9-2-9-7'
        ' 0-3 1-6 2-8z"/>'
        '<path d="M46 60c-3-6-11-10-19-10-5 0-8 4-7 9 2 9 12 15 22 15 4 0 6-3 6-7'
        ' 0-2-1-5-2-7z"/>'
        '<path d="M54 60c3-6 11-10 19-10 5 0 8 4 7 9-2 9-12 15-22 15-4 0-6-3-6-7'
        ' 0-2 1-5 2-7z"/>',
        "M47 32l-7-9 M53 32l7-9",
        '<circle cx="30" cy="38" r="4" fill="#fff" fill-opacity=".75"/>'
        '<circle cx="70" cy="38" r="4" fill="#fff" fill-opacity=".75"/>'),
    "coleoptere": (
        '<ellipse cx="50" cy="60" rx="25" ry="28"/>'
        '<ellipse cx="50" cy="31" rx="16" ry="10"/>'
        '<circle cx="50" cy="18" r="8"/>',
        "M44 12l-11-8 M56 12l11-8 "
        "M27 46l-15-9 M25 60H9 M27 74l-15 9 "
        "M73 46l15-9 M75 60h16 M73 74l15 9",
        '<path d="M50 34v52" fill="none" stroke="#fff" stroke-opacity=".85" stroke-width="3"/>'),
    "abeille": (
        '<ellipse cx="50" cy="62" rx="17" ry="22"/>'
        '<ellipse cx="50" cy="36" rx="13" ry="11"/>'
        '<circle cx="50" cy="19" r="9"/>'
        '<ellipse cx="26" cy="40" rx="16" ry="8" transform="rotate(-25 26 40)"/>'
        '<ellipse cx="74" cy="40" rx="16" ry="8" transform="rotate(25 74 40)"/>',
        "M44 12l-9-8 M56 12l9-8",
        '<path d="M35 55h30 M35 67h30 M39 77h22" fill="none" stroke="#fff" '
        'stroke-opacity=".85" stroke-width="4"/>'
        + _oeil(45, 17, 1.8) + _oeil(55, 17, 1.8)),
    "mouche": (
        '<ellipse cx="50" cy="61" rx="15" ry="20"/>'
        '<ellipse cx="50" cy="38" rx="12" ry="10"/>'
        '<circle cx="50" cy="22" r="11"/>'
        '<ellipse cx="21" cy="46" rx="18" ry="8" transform="rotate(-22 21 46)"/>'
        '<ellipse cx="79" cy="46" rx="18" ry="8" transform="rotate(22 79 46)"/>',
        "M40 46l-13 13 M40 55l-15 7 M60 46l13 13 M60 55l15 7",
        _oeil(44, 20, 4) + _oeil(56, 20, 4)),
    "libellule": (
        '<path d="M50 22c3 0 5 2 5 5 0 2-1 4-3 5l1 8c4 1 6 4 6 8l-4 44c0 3-4 3-4 0l-4-44'
        'c0-4 2-7 6-8l1-8c-2-1-3-3-3-5 0-3 2-5 5-5z"/>'
        '<ellipse cx="26" cy="40" rx="20" ry="6" transform="rotate(-12 26 40)"/>'
        '<ellipse cx="74" cy="40" rx="20" ry="6" transform="rotate(12 74 40)"/>'
        '<ellipse cx="28" cy="54" rx="18" ry="5" transform="rotate(10 28 54)"/>'
        '<ellipse cx="72" cy="54" rx="18" ry="5" transform="rotate(-10 72 54)"/>',
        "",
        _oeil(46, 25, 2) + _oeil(54, 25, 2)),
    "criquet": (
        '<ellipse cx="46" cy="52" rx="26" ry="13"/>'
        '<circle cx="74" cy="46" r="11"/>'
        '<polygon points="34,58 21,29 32,25 45,54"/>',
        "M26 27l-9 46 M85 39l13-13 M84 46l15-5 M42 63l-6 15 M57 61l5 17",
        _oeil(78, 42, 2)),

    # --------------------------------------------------------- autres bêtes
    "araignee": (
        '<ellipse cx="50" cy="58" rx="16" ry="18"/>'
        '<circle cx="50" cy="33" r="11"/>',
        "M36 48 20 32 M35 56H15 M36 64 18 74 M40 72 32 90 "
        "M64 48 80 32 M65 56h20 M64 64 82 74 M60 72 68 90",
        _oeil(45, 30, 2) + _oeil(55, 30, 2)),
    "escargot": (
        # Le pied s'étale bien en bas et déborde à gauche sous la tête ; la
        # coquille se pose dessus. Superposés comme dans la version précédente,
        # les deux se confondaient en une tache.
        '<path d="M8 82c-4 0-6-3-5-7 2-9 10-15 20-15h48v22z"/>'
        '<ellipse cx="14" cy="66" rx="12" ry="10"/>'
        '<circle cx="62" cy="46" r="25"/>',
        "M8 57V40 M19 56l3-16",
        '<path d="M62 46m-15 0a15 15 0 1 1 9 13.7a9 9 0 1 1-5-17.4" fill="none" '
        'stroke="#fff" stroke-opacity=".85" stroke-width="3.4"/>'
        + _oeil(8, 39, 2.4) + _oeil(22, 39, 2.4)),
    "crabe": (
        '<ellipse cx="50" cy="56" rx="26" ry="18"/>'
        '<polygon points="24,44 8,30 4,42 16,50"/><polygon points="76,44 92,30 96,42 84,50"/>',
        "M28 66 14 78 M34 72 26 88 M72 66 86 78 M66 72 74 88 "
        "M26 52 10 46 M74 52 90 46",
        _oeil(42, 48, 2.4) + _oeil(58, 48, 2.4)),
    "coquillage": (
        '<path d="M50 16c19 0 34 17 34 37 0 11-4 21-11 28H27c-7-7-11-17-11-28 0-20 15-37 34-37z"/>',
        "",
        '<path d="M50 18v62 M38 20 30 79 M62 20l8 59 M28 28 19 76 M72 28l9 48" '
        'fill="none" stroke="#fff" stroke-opacity=".8" stroke-width="2.6"/>'),
    "ver": (
        '<path d="M22 40c0-8 7-14 16-14s16 6 16 14c0 6-4 10-10 12-5 2-8 5-8 9 0 5 5 9 12 9'
        'l14-1c8 0 14 5 14 12 0 6-5 11-12 11-3 0-3-4 0-4 4 0 7-3 7-7 0-4-4-7-9-7'
        'l-14 1c-9 0-16-6-16-13 0-6 4-11 11-13 4-2 6-4 6-7 0-5-4-9-11-9s-11 4-11 9'
        'c0 3-4 3-4-2z"/>',
        "",
        _oeil(33, 34, 1.8)),
    "meduse": (
        '<path d="M50 22c17 0 30 12 30 27 0 3-2 5-5 5H25c-3 0-5-2-5-5 0-15 13-27 30-27z"/>',
        "M30 56c0 12-2 22-6 30 M41 56c0 14-1 24-3 32 M50 56v34 "
        "M59 56c0 13 1 23 3 31 M70 56c0 11 2 20 6 28",
        '<path d="M32 40c4-8 12-13 20-13" fill="none" stroke="#fff" stroke-opacity=".7" '
        'stroke-width="3"/>'),
    "mille_pattes": (
        # Un corps unique bien allongé, hérissé de pattes : le serpentin replié
        # de la version précédente se lisait comme un circuit imprimé.
        '<ellipse cx="48" cy="50" rx="42" ry="13"/>'
        '<circle cx="86" cy="48" r="11"/>',
        "M16 62v13 M28 63v14 M40 63v14 M52 63v14 M64 62v13 M74 60v12 "
        "M16 38V25 M28 37V23 M40 37V23 M52 37V23 M64 38V25 "
        "M94 40l8-10 M94 56l8 10",
        '<path d="M22 39v22 M34 38v24 M46 38v24 M58 38v24 M70 40v20" fill="none" '
        'stroke="#fff" stroke-opacity=".8" stroke-width="2.6"/>' + _oeil(89, 45, 2)),
    "etoile_mer": (
        '<path d="M50 14l12 27 29 2-22 20 6 29-25-15-25 15 6-29-22-20 29-2z"/>',
        "",
        '<circle cx="50" cy="55" r="7" fill="#fff" fill-opacity=".75"/>'),

    # ------------------------------------------------------------ forme de repli
    # Une empreinte de patte, qui dit « une bête, on ne sait pas laquelle »
    # bien mieux qu'une silhouette vague.
    "vivant": (
        '<ellipse cx="50" cy="68" rx="22" ry="17"/>'
        '<ellipse cx="24" cy="44" rx="8" ry="11" transform="rotate(-22 24 44)"/>'
        '<ellipse cx="41" cy="31" rx="8" ry="12"/>'
        '<ellipse cx="59" cy="31" rx="8" ry="12"/>'
        '<ellipse cx="76" cy="44" rx="8" ry="11" transform="rotate(22 76 44)"/>',
        "",
        ""),
}


# Rattachement d'une forme à un taxon. Le rang est celui du backbone GBIF, et la
# recherche va du plus précis au plus général : famille, puis ordre, puis classe,
# puis embranchement. La première correspondance gagne.
RATTACHEMENT: list[tuple[str, str, str]] = [
    # (rang, nom du taxon, forme)
    ("famille", "Cervidae", "cervide"),
    ("famille", "Bovidae", "mammifere"),
    ("famille", "Felidae", "felin"),
    ("famille", "Canidae", "mammifere"),
    ("famille", "Anatidae", "canard"),
    ("famille", "Accipitridae", "rapace"),
    ("famille", "Falconidae", "rapace"),
    ("famille", "Strigidae", "rapace"),
    ("famille", "Ardeidae", "echassier"),
    ("famille", "Ciconiidae", "echassier"),
    ("famille", "Scolopacidae", "echassier"),
    ("famille", "Laridae", "echassier"),

    ("ordre", "Primates", "primate"),
    ("ordre", "Chiroptera", "chauve_souris"),
    ("ordre", "Rodentia", "rongeur"),
    ("ordre", "Lagomorpha", "rongeur"),
    ("ordre", "Cetacea", "cetace"),
    ("ordre", "Carnivora", "mammifere"),
    ("ordre", "Artiodactyla", "cervide"),
    ("ordre", "Perissodactyla", "mammifere"),

    ("ordre", "Lepidoptera", "papillon"),
    ("ordre", "Coleoptera", "coleoptere"),
    ("ordre", "Hymenoptera", "abeille"),
    ("ordre", "Diptera", "mouche"),
    ("ordre", "Odonata", "libellule"),
    ("ordre", "Orthoptera", "criquet"),
    ("ordre", "Hemiptera", "insecte"),
    ("ordre", "Decapoda", "crabe"),

    ("ordre", "Anura", "grenouille"),
    ("ordre", "Caudata", "salamandre"),
    ("ordre", "Testudines", "tortue"),
    ("ordre", "Serpentes", "serpent"),
    ("ordre", "Crocodylia", "lezard"),

    ("classe", "Mammalia", "mammifere"),
    ("classe", "Aves", "oiseau"),
    ("classe", "Squamata", "lezard"),
    ("classe", "Reptilia", "lezard"),
    ("classe", "Amphibia", "grenouille"),
    ("classe", "Actinopterygii", "poisson"),
    ("classe", "Actinopteri", "poisson"),
    ("classe", "Chondrichthyes", "requin"),
    ("classe", "Elasmobranchii", "requin"),
    ("classe", "Sarcopterygii", "poisson"),
    ("classe", "Myxini", "poisson"),
    ("classe", "Petromyzonti", "poisson"),
    ("classe", "Insecta", "insecte"),
    ("classe", "Arachnida", "araignee"),
    ("classe", "Gastropoda", "escargot"),
    ("classe", "Bivalvia", "coquillage"),
    ("classe", "Cephalopoda", "meduse"),
    ("classe", "Malacostraca", "crabe"),
    ("classe", "Maxillopoda", "crabe"),
    ("classe", "Hexanauplia", "crabe"),
    ("classe", "Branchiopoda", "crabe"),
    ("classe", "Ostracoda", "crabe"),
    ("classe", "Chilopoda", "mille_pattes"),
    ("classe", "Diplopoda", "mille_pattes"),
    ("classe", "Clitellata", "ver"),
    ("classe", "Polychaeta", "ver"),
    ("classe", "Oligochaeta", "ver"),
    ("classe", "Scyphozoa", "meduse"),
    ("classe", "Hydrozoa", "meduse"),
    ("classe", "Anthozoa", "meduse"),
    ("classe", "Asteroidea", "etoile_mer"),
    ("classe", "Echinoidea", "etoile_mer"),
    ("classe", "Ophiuroidea", "etoile_mer"),
    ("classe", "Holothuroidea", "ver"),

    ("embranchement", "Arthropoda", "insecte"),
    ("embranchement", "Mollusca", "escargot"),
    ("embranchement", "Annelida", "ver"),
    ("embranchement", "Cnidaria", "meduse"),
    ("embranchement", "Echinodermata", "etoile_mer"),
    ("embranchement", "Platyhelminthes", "ver"),
    ("embranchement", "Nematoda", "ver"),
    ("embranchement", "Chordata", "vivant"),
]

# Colonne de la table `cases` correspondant à chaque rang.
COLONNE = {"famille": "famille", "ordre": "ordre", "classe": "classe",
           "embranchement": "embranchement"}
# Du plus précis au plus général : c'est l'ordre dans lequel on affecte, chaque
# passe n'écrasant jamais une affectation plus précise déjà posée.
PRECISION = ["famille", "ordre", "classe", "embranchement"]


def ecrit_fichiers(dossier: pathlib.Path) -> None:
    dossier.mkdir(parents=True, exist_ok=True)
    for nom, (corps, traits, extra) in FORMES.items():
        # Les traits sont donnés comme une suite de commandes de tracé ; on les
        # enveloppe ici pour ne pas répéter la balise dans chaque définition.
        dessin = f'<path d="{traits}"/>' if traits else ""
        svg = GABARIT.format(corps=corps, traits=dessin, extra=extra)
        (dossier / f"{nom}.svg").write_text(svg, encoding="utf-8")
    print(f"{len(FORMES)} silhouettes écrites dans {dossier}")


def associe() -> None:
    db.initialise()
    with db.transaction() as cx:
        cx.executemany(
            """INSERT INTO visuels (fichier, rang, cle_gbif, etiquette, source, licence)
               VALUES (?, 'groupe', NULL, ?, 'Biodex', 'CC0')
               ON CONFLICT(fichier, rang, cle_gbif) DO NOTHING""",
            [(f"{n}.svg", n) for n in FORMES])

        ids = {r["fichier"]: r["id"] for r in db.lit("SELECT id, fichier FROM visuels")}

        # On ne touche qu'aux cases dépourvues de silhouette : depuis que
        # PhyloPic fournit l'essentiel du dex, ces formes-ci ne sont plus qu'un
        # filet de sécurité, et les écraser serait un recul.
        for rang in reversed(PRECISION):
            regles = [(t, f) for r, t, f in RATTACHEMENT if r == rang]
            colonne = COLONNE[rang]
            cx.executemany(
                f"UPDATE cases SET visuel = ? WHERE {colonne} = ? AND visuel IS NULL",
                [(ids[f"{forme}.svg"], taxon) for taxon, forme in regles])

        # Filet de sécurité : tout ce qui n'a rien reçu prend la forme générique.
        cx.execute("UPDATE cases SET visuel = ? WHERE visuel IS NULL",
                   (ids["vivant.svg"],))

    total = db.valeur("SELECT COUNT(*) FROM cases", (), 0)
    repli = db.valeur("SELECT COUNT(*) FROM cases WHERE visuel = ?",
                      (ids["vivant.svg"],), 0)
    print(f"\n{total} cases pourvues d'une silhouette "
          f"({repli} sur l'empreinte générique, soit {repli / max(total, 1):.1%})")
    print("\nRépartition :")
    for r in db.lit("""SELECT v.etiquette, COUNT(*) n FROM cases c
                       JOIN visuels v ON v.id = c.visuel
                       GROUP BY v.etiquette ORDER BY n DESC LIMIT 14"""):
        print(f"  {r['etiquette']:<16} {r['n']:>7}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sans-association", action="store_true",
                    help="écrire seulement les fichiers SVG")
    a = ap.parse_args()

    config.prepare_dossiers()
    ecrit_fichiers(config.SILHOUETTES)
    if not a.sans_association:
        associe()
    return 0


if __name__ == "__main__":
    sys.exit(main())
