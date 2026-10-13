"""
Ce qui compte comme un poisson, en un seul endroit.

Le périmètre sert à deux choses qui doivent absolument s'accorder : construire
le catalogue aquatique, et filtrer le dex quand le joueur demande à ne voir que
ses poissons. Deux définitions qui divergeraient donneraient un dex où une
espèce est trouvable par la photo mais introuvable dans la liste.

Pourquoi ce n'est pas un simple `classe = 'Actinopterygii'` : GBIF laisse la
classe **vide** pour les poissons à nageoires rayonnées. Le rang y est disputé —
Actinopterygii ou Actinopteri — et le backbone tranche en ne remplissant rien.
Sur 20 657 cases de poissons du dex, 19 618 n'ont aucune classe.

On prend donc les Chordata sans classe, plus les quelques classes que GBIF
renseigne pour les poissons sans nageoires rayonnées. Vérifié contre les 463
familles de FishNet : les deux définitions se recouvrent à 20 190 cases sur
20 210, et les écarts sont explicables des deux côtés — des escargots du côté
FishNet (Cepolidae est un homonyme : une famille de poissons-rubans *et* une
famille d'escargots terrestres), de vraies familles de poissons absentes de
FishNet de l'autre.
"""

# Les classes de poissons que GBIF renseigne : requins et raies, chimères,
# myxines, lamproies, cœlacanthes, dipneustes.
CLASSES = ("Elasmobranchii", "Holocephali", "Myxini",
           "Petromyzonti", "Coelacanthi", "Dipneusti")

# Les tuniciers sont eux aussi des Chordata sans classe, et ce ne sont pas des
# poissons. Copelata — les appendiculaires — est le seul ordre concerné dans le
# dex, 34 cases, mais le laisser passer les mettrait en concurrence avec un
# guppy.
ORDRES_EXCLUS = ("Copelata",)

# Fragment de clause WHERE. `prefixe` est l'alias de la table `cases` dans la
# requête appelante — « c. » dans le dex, vide dans les outils.
CONDITION = """(
       {p}regne = 'animal'
   AND ({p}ordre IS NULL OR {p}ordre NOT IN ({exclus}))
   AND ( ({p}embranchement = 'Chordata' AND ({p}classe IS NULL OR {p}classe = ''))
         OR {p}classe IN ({classes}) )
)"""


def condition(prefixe: str = "") -> tuple[str, tuple]:
    """Renvoie (fragment SQL, paramètres) pour filtrer les cases de poissons."""
    return (
        CONDITION.format(
            p=prefixe,
            exclus=",".join("?" * len(ORDRES_EXCLUS)),
            classes=",".join("?" * len(CLASSES)),
        ),
        ORDRES_EXCLUS + CLASSES,
    )


def condition_nommee(prefixe: str = "", suffixe: str = "poi") -> tuple[str, dict]:
    """Même chose avec des paramètres nommés, pour les requêtes qui en usent.

    Le dex construit ses filtres dans un dictionnaire ; y glisser des `?`
    positionnels casserait l'ordre des autres paramètres dès qu'on ajoute un
    critère.
    """
    exclus = {f"{suffixe}_o{i}": v for i, v in enumerate(ORDRES_EXCLUS)}
    classes = {f"{suffixe}_c{i}": v for i, v in enumerate(CLASSES)}
    sql = CONDITION.format(
        p=prefixe,
        exclus=",".join(f":{k}" for k in exclus),
        classes=",".join(f":{k}" for k in classes),
    )
    return sql, {**exclus, **classes}
