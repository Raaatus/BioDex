"""
Ce qu'on appelle une photo « sans lieu » ou « sans date », en un seul endroit.

La carte et la galerie répondaient à cette question chacune de son côté, et pas
de la même manière. La carte comptait comme mal située toute photo dont la
position venait d'un repli ; la galerie se contentait de regarder si la
latitude était nulle.

Sur la base de développement, l'écart n'est pas cosmétique :

    lat nulle                          5 photos
    source_position = 'defaut'        13 photos
    ------------------------------------------
    la carte en signale               18
    la galerie en montrait             5

Les treize du milieu sont les pires : elles **ont** des coordonnées, donc elles
apparaissent sur la carte, mais à un endroit que personne n'a choisi. Ce sont
exactement celles qu'on veut retrouver pour les corriger, et c'étaient les
seules qu'aucun écran ne savait désigner.

D'où ce module. Les deux routes lisent la même règle ; elles ne peuvent plus
diverger sans qu'on le fasse exprès.
"""

# Une position qui ne vient de nulle part. `'defaut'` est le repli appliqué
# quand la photo n'avait pas d'EXIF et que le téléphone n'a rien donné : les
# coordonnées existent, mais elles ne veulent rien dire.
SOURCES_VIDES = ("", "defaut")


def sans_position(prefixe: str = "c.") -> str:
    """Fragment SQL : la position est absente ou inventée."""
    return (f"({prefixe}lat IS NULL"
            f" OR {prefixe}source_position IN ('', 'defaut'))")


def sans_heure(prefixe: str = "c.") -> str:
    """Fragment SQL : la date est absente ou inventée."""
    return f"({prefixe}source_heure IN ('', 'defaut'))"


def a_situer(prefixe: str = "c.") -> str:
    """L'une ou l'autre manque : la photo mérite qu'on s'en occupe."""
    return f"({sans_position(prefixe)} OR {sans_heure(prefixe)})"


def lit_sans_position(ligne) -> bool:
    """La même règle, appliquée à une ligne déjà lue.

    Prend un `sqlite3.Row` ou un dictionnaire. Sert à remplir la réponse JSON
    sans refaire un tour de base.
    """
    return (ligne["lat"] is None
            or ligne["source_position"] in SOURCES_VIDES)


def lit_sans_heure(ligne) -> bool:
    return ligne["source_heure"] in SOURCES_VIDES
