"""
Les trente succès, et comment on décide qu'une espèce y répond.

Le problème n'est pas de compter — c'est de dire, parmi 977 415 cases,
lesquelles « évoquent le feu ». Trois moyens, du plus sûr au plus douteux, et
c'est l'ordre qui compte :

**Le taxon.** Le piment est le genre *Capsicum* : tous les piments, aucun
intrus, aucun oubli. Quand un thème a une assise taxonomique, elle prime sur
tout le reste. C'est le cas de la cuisine, du jardin, des champignons.

**Le nom, avec des frontières de mots.** « Salamandre » attrape la salamandre
tachetée ; sans frontière, « lune » attrapait « Pélican à lune*ttes* ». On
cherche donc le mot entier, pas la suite de lettres.

**Une liste d'exclusion.** Écrite à la main, parce qu'aucune règle ne
distinguera « Piment royal » — une plante aromatique du Canada — d'un vrai
piment. C'est le prix de l'honnêteté : on regarde les résultats et on retire ce
qui ne va pas.

Le tout est **précalculé** par `outils/succes_especes.py`, qui écrit les cases
éligibles en base. Le serveur ne fait plus qu'une jointure, et la liste reste
relisible : c'est elle qu'on corrige quand un faux positif se montre, pas une
expression régulière enfouie dans une requête.

Un succès ne se débloque **qu'une fois**. La table porte la date d'obtention ;
retrouver la même espèce ensuite ne fait rien.
"""
import json
import pathlib

from .i18n import tr


# ── les thèmes ──────────────────────────────────────────────────────────────
#
# `genres` et `familles` sont des ancres taxonomiques : sûres, sans discussion.
# `fr` et `latin` sont des motifs cherchés entre frontières de mots.
# `exclus` retire nommément ce qui passe malgré tout.

THEMES = {
    "feu": {
        # Capsicum : tous les piments. Le reste évoque le feu par le nom —
        # salamandre de feu, sizerin flammé, renoncule flammette.
        "genres": ["Capsicum"],
        "fr": ["feu", "flamme", "flammé", "flammée", "flammette", "ardent",
               "ardente", "brasier", "incendie", "salamandre", "braise",
               "phénix", "volcan", "ignée"],
        "latin": ["ignis", "ignea", "igneus", "flammea", "flammeus", "pyro",
                  "vulcan", "phoenix", "salamandra", "incendia"],
        # « Piment royal » est un myrique, pas un piment.
        "exclus": ["Piment royal"],
    },
    "cuisine": {
        # Les grands genres aromatiques. Bien plus sûr que de chercher
        # « thym » dans les noms, qui attrape des mousses.
        "genres": ["Thymus", "Rosmarinus", "Salvia", "Ocimum", "Origanum",
                   "Mentha", "Laurus", "Foeniculum", "Allium", "Petroselinum",
                   "Coriandrum", "Anethum", "Satureja"],
        # `Artemisia` a été retiré : 531 espèces au dex, presque toutes des
        # armoises et des absinthes. Seul l'estragon se mange, et il se
        # rattrape par son nom.
        "fr": ["estragon"],
        "latin": ["dracunculus"], "exclus": [],
    },
    "jardin": {
        "genres": ["Rosa", "Tulipa", "Paeonia", "Hydrangea", "Pelargonium",
                   "Lavandula", "Convallaria", "Wisteria", "Dahlia", "Iris",
                   "Narcissus", "Camellia", "Syringa", "Clematis"],
        "fr": [], "latin": [], "exclus": [],
    },
    "ciel": {
        "fr": ["étoile", "étoilé", "étoilée", "lune", "lunaire", "soleil",
               "comète", "astre", "céleste", "aurore", "zénith", "nébuleuse"],
        "latin": ["stella", "stellaris", "stellata", "lunaris", "solaris",
                  "astro", "caelestis", "aurora"],
        "genres": [], "exclus": [],
    },
    "armure": {
        "fr": ["cuirassé", "cuirassée", "casqué", "casquée", "bouclier",
               "armé", "armée", "épineux", "épineuse", "blindé", "carapace",
               "heaume", "lance"],
        "latin": ["armata", "armatus", "loricata", "loricatus", "spinosa",
                  "spinosus", "clypeata", "galeata"],
        "genres": [], "exclus": [],
    },
    "mythologie": {
        "fr": ["dragon", "licorne", "griffon", "phénix", "sirène", "cyclope",
               "méduse", "hydre", "chimère", "harpie", "basilic", "titan",
               "centaure"],
        "latin": ["draco", "unicornis", "gryphus", "phoenix", "sirena",
                  "medusa", "hydra", "chimaera", "harpia", "basiliscus",
                  "titan"],
        # Le basilic aromatique n'est pas le serpent de légende.
        #
        # « Sphinx » a été retiré des motifs après relecture : les Sphingidae
        # sont vingt-neuf papillons de nuit au dex. On aurait décroché
        # « Bestiaire fabuleux » avec trois moro-sphinx, sans jamais croiser
        # la moindre créature de légende.
        "exclus": ["Basilic commun"],
        "genres": [],
    },
    "musique": {
        "fr": ["trompette", "trompettiste", "harpe", "violon", "tambour",
               "flûte", "flûteur", "lyre", "cymbale", "cymbalaire", "clairon",
               "fifre", "musicien", "musicienne", "chanteur", "siffleur"],
        "latin": ["tuba", "lyra", "citharoides", "musica", "cantor",
                  "cantans", "tympani"],
        "genres": [], "exclus": [],
    },
    "metaux": {
        "fr": ["doré", "dorée", "argenté", "argentée", "cuivré", "cuivrée",
               "bronzé", "bronzée", "métallique", "acier", "plombé", "ferreux"],
        "latin": ["aurata", "auratus", "argentea", "argenteus", "cuprea",
                  "aenea", "aeneus", "metallica", "chalybea"],
        "genres": [], "exclus": [],
    },
    "ville": {
        "fr": ["des villes", "domestique", "urbain", "urbaine", "des maisons",
               "des jardins", "des toits", "des murs"],
        "latin": ["urbana", "urbanus", "domestica", "domesticus", "urbica"],
        "genres": [], "exclus": [],
    },
    "ailleurs": {
        "fr": ["de Chine", "du Japon", "d'Amérique", "d'Afrique", "d'Asie",
               "des Indes", "du Canada", "d'Australie", "du Brésil",
               "de Sibérie", "d'Égypte", "du Sénégal", "de Madagascar"],
        "latin": ["sinensis", "japonica", "japonicus", "americana",
                  "americanus", "africana", "africanus", "indica", "indicus",
                  "canadensis", "australis", "brasiliensis", "sibirica",
                  "aegyptiaca", "senegalensis", "madagascariensis"],
        "genres": [], "exclus": [],
    },
    "vitesse": {
        "fr": ["rapide", "véloce", "flèche", "éclair", "vif", "vive",
               "fusée", "foudre"],
        "latin": ["velox", "celer", "rapida", "rapidus", "sagitta", "fulgur"],
        "genres": [], "exclus": [],
    },
    "champignons": {
        # Pas de motif : c'est un règne entier.
        "regne": "champignon",
        "fr": [], "latin": [], "genres": [], "exclus": [],
    },

    # ---- les treize thèmes ajoutés ------------------------------------------
    #
    # Les ancres taxonomiques portent l'essentiel : elles attrapent les espèces
    # sans nom français, que les motifs de nom rateraient toujours.
    "royaute": {
        # Pas de « couronne » : les oiseaux à calotte colorée sont légion
        # — roitelet à couronne rubis, bruant à couronne blanche — et n'ont
        # rien de royal. Mesuré : la retirer fait tomber 924 espèces à 380.
        "fr": ["reine", "royal", "royale", "majestueux", "majestueuse",
               "empereur", "impérial", "impériale", "prince", "princesse"],
        "latin": ["regina", "reginae", "regalis", "imperialis", "imperator",
                  "majestica", "principalis"],
        "genres": [], "exclus": [],
    },
    "froid": {
        # « alpina » n'est pas ici : c'est l'altitude, pas le froid, et elle
        # sert au succès des sommets.
        "fr": ["neige", "neiges", "givre", "givré", "givrée", "glacier",
               "glaciaire", "polaire", "hivernal", "hivernale", "boréal",
               "boréale"],
        "latin": ["nivalis", "nivea", "niveus", "niveum", "glacialis",
                  "hyperborea", "hyperboreus", "borealis", "frigida",
                  "frigidus", "gelida", "gelidus"],
        "genres": [], "exclus": [],
    },
    "mineral": {
        "fr": ["quartz", "granit", "améthyste", "jaspe", "opale", "marbre",
               "ardoise", "silex", "calcaire", "cristal", "obsidienne"],
        "latin": ["saxatilis", "saxatile", "rupestris", "rupestre", "petraea",
                  "petraeus", "lapideus", "silicea", "siliceus"],
        "genres": [], "exclus": [],
    },
    "marin": {
        "fr": ["marin", "marine", "maritime", "océanique", "matelot",
               "corsaire", "pirate"],
        "latin": ["marina", "marinus", "maritima", "maritimus", "oceanica",
                  "oceanicus", "pelagica", "pelagicus", "nauticus"],
        "genres": [], "exclus": [],
    },
    "pollinisateur": {
        "genres": ["Apis", "Bombus", "Andrena", "Anthophora", "Osmia",
                   "Xylocopa", "Halictus", "Megachile", "Eristalis",
                   "Syrphus", "Episyrphus", "Volucella"],
        "familles": ["Apidae", "Andrenidae", "Halictidae", "Megachilidae",
                     "Syrphidae", "Colletidae"],
        "fr": [], "latin": [], "exclus": [],
    },
    "coquillage": {"classes": ["Gastropoda", "Bivalvia"],
                   "fr": [], "latin": [], "genres": [], "exclus": []},
    "moisson": {
        "familles": ["Poaceae"],
        "genres": ["Papaver", "Centaurea", "Agrostemma", "Bromus"],
        "fr": [], "latin": [], "exclus": [],
    },
    "arachnide": {"classes": ["Arachnida"],
                  "fr": [], "latin": [], "genres": [], "exclus": []},
    "reptile": {"classes": ["Reptilia", "Squamata", "Testudines", "Crocodylia"],
                "fr": [], "latin": [], "genres": [], "exclus": []},
    "sommets": {
        "fr": ["des alpes", "alpin", "alpine", "des montagnes", "montagnard",
               "montagnarde"],
        "latin": ["alpina", "alpinus", "alpestris", "montana", "montanus",
                  "oreophila", "oreophilus", "nivicola"],
        "genres": [],
        # `montanus` et `alpina` sont trompeurs chez quelques espèces communes :
        # le moineau friquet (Passer montanus) niche dans les haies, et le
        # bécasseau variable (Calidris alpina) sur les vasières. Le nom dit la
        # montagne, la bête n'y va pas.
        "exclus": ["Moineau friquet", "Bécasseau variable",
                   "Alouette hausse-col"],
    },
    "carnivore": {
        # Plantes carnivores et parasites strictes : des genres entiers, ce qui
        # évite d'avoir à nommer chaque espèce.
        "genres": ["Drosera", "Dionaea", "Nepenthes", "Sarracenia",
                   "Pinguicula", "Utricularia", "Cephalotus", "Darlingtonia",
                   "Viscum", "Orobanche", "Cuscuta", "Lathraea", "Monotropa",
                   "Hydnora", "Rafflesia"],
        "fr": [], "latin": [], "exclus": [],
    },
    "bois_mort": {
        "genres": ["Lucanus", "Dorcus", "Cerambyx", "Rhagium", "Rosalia",
                   "Fomes", "Fomitopsis", "Trametes", "Ganoderma", "Pleurotus",
                   "Xylaria", "Stereum", "Polyporus", "Laetiporus", "Piptoporus"],
        "fr": [], "latin": [], "exclus": [],
    },
    "minuscule": {
        # Lichens et mousses : ce que l'œil distingue à peine, et qu'on ne
        # regarde qu'en s'accroupissant.
        "genres": ["Cladonia", "Xanthoria", "Parmelia", "Usnea", "Evernia",
                   "Ramalina", "Lecanora", "Peltigera", "Physcia", "Hypogymnia"],
        "embranchements": ["Bryophyta", "Marchantiophyta", "Anthocerotophyta"],
        "fr": [], "latin": [], "exclus": [],
    },
    "champignon_toxique": {
        "regne": "champignon", "toxique": True,
        "fr": [], "latin": [], "genres": [], "exclus": [],
    },

    # ---- les quatre thèmes des succès repensés -------------------------------
    "lepidoptere": {
        # La métamorphose se voit chez les papillons mieux que partout ailleurs.
        # On ne peut pas compter les chenilles — le dex indexe des espèces, pas
        # des stades, et une chenille est la même case que son papillon — mais
        # on peut compter les espèces qui font ce voyage.
        "ordres": ["Lepidoptera"],
        "fr": [], "latin": [], "genres": [], "exclus": [],
    },
    "arbre": {
        # L'âge d'un arbre n'est nulle part dans la base. Ce qu'on peut compter,
        # ce sont les arbres : les genres qui en portent, ancrés une fois pour
        # toutes plutôt que devinés sur des noms.
        "genres": ["Quercus", "Fagus", "Castanea", "Carpinus", "Betula", "Alnus",
                   "Salix", "Populus", "Acer", "Tilia", "Fraxinus", "Ulmus",
                   "Juglans", "Platanus", "Pinus", "Abies", "Picea", "Larix",
                   "Cedrus", "Taxus", "Sequoia", "Sequoiadendron", "Olea",
                   "Cupressus", "Juniperus", "Sorbus", "Aesculus"],
        "fr": [], "latin": [], "exclus": [],
    },
    "mammifere": {
        # Un pisteur suit des mammifères : ce sont eux qui laissent des traces,
        # et eux qu'on ne voit qu'en les cherchant.
        "classes": ["Mammalia"],
        "fr": [], "latin": [], "genres": [], "exclus": [],
    },
    "danger": {
        # Aucune liste d'espèces invasives n'existe dans la base, et elle
        # dépendrait du pays. Ce que le catalogue sait dire, c'est ce que les
        # noms annoncent : le venin, le poison, la menace.
        "fr": ["venimeux", "venimeuse", "vénéneux", "vénéneuse", "mortel",
               "mortelle", "poison", "tue-mouches", "tueur", "tueuse",
               "assassin", "destructeur", "destructrice", "vipère", "guêpe",
               "frelon", "scorpion"],
        "latin": ["venenata", "venenatus", "venenosa", "venenosus",
                  "toxicaria", "toxicarius", "toxica", "toxicus", "mortifera",
                  "mortiferus", "letalis", "virosa", "virosus", "necator",
                  "perniciosa", "perniciosus", "destructor"],
        "genres": [], "exclus": [],
    },

    # ---- quatorze groupes, ancrés sur la taxonomie ---------------------------
    #
    # Une ancre sur une classe ou une famille ne se discute pas : c'est de la
    # taxonomie, pas de l'interprétation. Elle attrape surtout les espèces sans
    # nom français — 944 000 des 977 000 cases — que les motifs de nom rateraient
    # toutes. Aucune relecture nécessaire, aucun faux positif possible.
    "fougere": {"classes": ["Polypodiopsida"],
                "fr": [], "latin": [], "genres": [], "exclus": []},
    "crustace": {"classes": ["Malacostraca"],
                 "fr": [], "latin": [], "genres": [], "exclus": []},
    "amphibien": {"classes": ["Amphibia"],
                  "fr": [], "latin": [], "genres": [], "exclus": []},
    "corail": {"classes": ["Anthozoa"],
               "fr": [], "latin": [], "genres": [], "exclus": []},
    "mille_pattes": {"classes": ["Chilopoda", "Diplopoda"],
                     "fr": [], "latin": [], "genres": [], "exclus": []},
    "orchidee": {"familles": ["Orchidaceae"],
                 "fr": [], "latin": [], "genres": [], "exclus": []},
    "composee": {"familles": ["Asteraceae"],
                 "fr": [], "latin": [], "genres": [], "exclus": []},
    "legumineuse": {"familles": ["Fabaceae"],
                    "fr": [], "latin": [], "genres": [], "exclus": []},
    "longicorne": {"familles": ["Cerambycidae"],
                   "fr": [], "latin": [], "genres": [], "exclus": []},
    "charancon": {"familles": ["Curculionidae"],
                  "fr": [], "latin": [], "genres": [], "exclus": []},
    "fourmi": {"familles": ["Formicidae"],
               "fr": [], "latin": [], "genres": [], "exclus": []},
    "coccinelle": {"familles": ["Coccinellidae"],
                   "fr": [], "latin": [], "genres": [], "exclus": []},
    "bolet": {"familles": ["Boletaceae"],
              "fr": [], "latin": [], "genres": [], "exclus": []},
    "russule": {"familles": ["Russulaceae"],
                "fr": [], "latin": [], "genres": [], "exclus": []},
}

# Les couleurs, pour « Palette » et « Arc-en-ciel ». Chacune doit être trouvée
# sur une espèce différente.
COULEURS = {
    "rouge": ["rouge", "écarlate", "pourpre", "vermillon", "rubis"],
    "orange": ["orangé", "orangée", "orange", "safran", "roux", "rousse"],
    "jaune": ["jaune", "doré", "dorée", "citrin", "ocre"],
    "vert": ["vert", "verte", "verdâtre", "olive", "émeraude"],
    "bleu": ["bleu", "bleue", "azuré", "azurée", "outremer", "cyan"],
    "indigo": ["indigo", "violet", "violette", "lilas", "mauve"],
    "blanc": ["blanc", "blanche", "neigeux", "neigeuse", "ivoire"],
}

# ── les trente succès ───────────────────────────────────────────────────────
#
# `type` dit comment on évalue ; `seuil` combien il en faut. `modele` est le
# fichier 3D — le même partout pour l'instant, il suffira d'en changer le nom.

SUCCES = [
    # ---- faciles ----------------------------------------------------------
    ("premier_pas", "Premier pas", "📸", "facile",
     "Trouve ta toute première espèce.", "compte", 1, None, "grenouille"),
    ("feu", "Feu", "🔥", "facile",
     "Photographie une espèce qui évoque le feu.", "theme", 1, "feu", "pompier"),
    ("prise_du_jour", "Prise du jour", "🐟", "facile",
     "Identifie une espèce par le règne aquatique.", "regne", 1, "aquatique",
     "pecheur"),
    ("garde_manger", "Le garde-manger", "🌿", "facile",
     "Trouve une plante aromatique.", "theme", 1, "cuisine", "cooking"),
    ("au_jardin", "Au jardin", "🌷", "facile",
     "Trouve une fleur de jardin.", "theme", 1, "jardin", "jardinier"),
    ("bitume", "Bitume", "🏙", "facile",
     "Trouve une espèce des villes.", "theme", 1, "ville", "skateur"),
    ("depaysement", "Dépaysement", "🌍", "facile",
     "Trouve une espèce dont le nom vient d'ailleurs.", "theme", 1, "ailleurs",
     "touriste"),
    ("cache_cache", "Cache-cache", "🔍", "facile",
     "Le moteur sèche, tu tranches : corrige une identification.",
     "corrigee", 1, None, "detective"),
    ("premier_temoin", "Premier témoin", "🥇", "facile",
     "Sois le premier de tes amis à trouver une espèce.", "premiere", 1, None,
     "podium"),
    ("leve_tot", "Lève-tôt", "☀️", "facile",
     "Prends une photo avant 7 h du matin.", "heure", 1, (4, 7), "matinale"),

    # ---- moyens -----------------------------------------------------------
    ("etoiles", "Tête dans les étoiles", "⭐", "moyen",
     "Trouve 3 espèces au nom céleste.", "theme", 3, "ciel", "astronaute"),
    ("en_armure", "En armure", "🛡", "moyen",
     "Trouve 3 espèces cuirassées.", "theme", 3, "armure", "chevalier"),
    ("palette", "Palette", "🎨", "moyen",
     "Trouve 5 espèces de 5 couleurs différentes.", "couleurs", 5, None,
     "peintre"),
    ("bestiaire", "Bestiaire fabuleux", "🐉", "moyen",
     "Trouve 3 espèces nommées d'après une créature mythique.", "theme", 3,
     "mythologie", "dragon"),
    ("fanfare", "Fanfare", "🎺", "moyen",
     "Trouve 3 espèces qui évoquent un instrument.", "theme", 3, "musique",
     "musicienne"),
    ("arche", "L'Arche", "🚢", "moyen",
     "Trouve une espèce dans 8 classes différentes.", "classes", 8, None,
     "noe"),
    ("sous_bois", "Sous-bois", "🍄", "moyen",
     "Trouve 5 champignons.", "theme", 5, "champignons", "cueilleuse"),
    ("ornithologue", "Ornithologue", "🐦", "moyen",
     "Trouve 15 oiseaux.", "classe", 15, "Aves", "jumelles"),
    ("six_pattes", "Six pattes", "🐛", "moyen",
     "Trouve 15 insectes.", "classe", 15, "Insecta", "entomologiste"),
    ("bonne_compagnie", "Bonne compagnie", "👥", "moyen",
     "Sois identifié sur 5 photos d'amis.", "cosigne", 5, None, "duo"),
    ("applaudimetre", "Applaudimètre", "👏", "moyen",
     "Reçois 25 réactions sur tes photos.", "reactions", 25, None, "scene"),
    ("quatre_saisons", "Les quatre saisons", "🗓", "moyen",
     "Trouve une espèce à chacune des quatre saisons.", "saisons", 4, None,
     "saisons"),

    # ---- difficiles -------------------------------------------------------
    ("ne_pas_toucher", "Ne pas toucher", "☠", "difficile",
     "Trouve 5 espèces signalées toxiques.", "toxique", 5, None, "apothicaire"),
    ("arc_en_ciel", "Arc-en-ciel", "🌈", "difficile",
     "Trouve une espèce pour chacune des 7 couleurs.", "couleurs", 7, None,
     "arcenciel"),
    ("noctambule", "Noctambule", "🌙", "difficile",
     "Photographie 10 espèces entre 22 h et 5 h.", "heure", 10, (22, 5),
     "lampe"),
    ("orfevre", "Orfèvre", "🥈", "difficile",
     "Trouve 8 espèces aux reflets métalliques.", "theme", 8, "metaux",
     "orfevre"),
    ("vif_argent", "Vif-argent", "⚡", "difficile",
     "Trouve une espèce dont le nom dit la vitesse.", "theme", 1, "vitesse",
     "eclair"),
    ("sans_faute", "Sans faute", "🎯", "difficile",
     "Fais identifier 10 espèces juste du premier coup.", "sans_faute", 10,
     None, "archere"),
    ("encyclopediste", "Encyclopédiste", "📚", "difficile",
     "Atteins 250 espèces.", "compte", 250, None, "bibliothecaire"),
    ("legendes", "Chasseur de légendes", "🏆", "difficile",
     "Trouve 3 espèces légendaires.", "rarete", 3, 5, "couronne"),

    # ═══ les quinze succès ajoutés ═══════════════════════════════════════════
    #

    # ---- faciles ------------------------------------------------------------
    ("sang_royal", "Sang royal", "👑", "facile",
     "Trouve une espèce au nom royal.", "theme", 1, "royaute", "reine"),
    ("grand_froid", "Grand froid", "❄️", "facile",
     "Trouve une espèce dont le nom évoque la neige ou le froid.",
     "theme", 1, "froid", "skieuse"),
    ("taille_pierre", "Taille de pierre", "🪨", "facile",
     "Trouve une espèce nommée d'après une pierre ou un rocher.",
     "theme", 1, "mineral", "geologue"),
    ("vieux_marin", "Vieux marin", "⚓", "facile",
     "Trouve une espèce dont le nom évoque la mer.", "theme", 1, "marin",
     "capitaine"),
    ("butineuse", "Butineuse", "🐝", "facile",
     "Photographie un pollinisateur : abeille, bourdon ou syrphe.",
     "theme", 1, "pollinisateur", "apicultrice"),
    ("coquillages", "Coquillages", "🐚", "facile",
     "Trouve un mollusque à coquille : escargot, buccin ou bivalve.",
     "theme", 1, "coquillage", "bernard-lhermite"),

    # ---- moyens -------------------------------------------------------------
    ("recette_grand_mere", "Recette de grand-mère", "🧄", "moyen",
     "Trouve 5 plantes aromatiques différentes.", "theme", 5, "cuisine",
     "chef"),
    ("moissons", "Les moissons", "🌾", "moyen",
     "Trouve 5 graminées ou fleurs des champs.", "theme", 5, "moisson",
     "fermiere"),
    ("fils_argent", "Fils d'argent", "🕸️", "moyen",
     "Trouve 5 arachnides.", "theme", 5, "arachnide", "arachnologue"),
    ("des_sommets", "Des sommets", "🧗", "moyen",
     "Trouve 5 espèces au nom de montagne.", "theme", 5, "sommets",
     "alpiniste"),

    # ---- difficiles ---------------------------------------------------------
    ("sang_froid", "Sang-froid", "🦎", "difficile",
     "Trouve 10 reptiles.", "theme", 10, "reptile", "herpetologue"),
    ("plante_hote", "Plante hôte", "🪴", "difficile",
     "Trouve 5 plantes carnivores ou parasites.", "theme", 5, "carnivore",
     "carnivore"),
    ("saproxylo", "Saproxylo", "🪵", "difficile",
     "Trouve 5 espèces du bois mort.", "theme", 5, "bois_mort", "bucheronne"),
    ("invisible", "Invisible à l'œil nu", "🦠", "difficile",
     "Trouve 5 lichens ou mousses.", "theme", 5, "minuscule",
     "scientifique"),
    ("pharmacie_sorcier", "Pharmacie du sorcier", "🧙", "difficile",
     "Trouve 3 champignons toxiques.", "theme", 3, "champignon_toxique",
     "alchimiste"),

    # ═══ les cinq succès repensés ════════════════════════════════════════════
    #
    # Ils gardent leur grenouille et leur intention ; seule la condition change,
    # parce que la première était invérifiable avec ce que contient le
    # catalogue. Chaque écart est dit sur place.
    #
    # Modèles à venir, dans l'ordre : cocon, druide, pisteresse, biohazard,
    # urbaine. En attendant, un modèle existant qui ne jure pas.

    ("metamorphose", "Métamorphose", "🦋", "moyen",
     # Voulu : « 5 espèces au stade larvaire ». Impossible — le dex indexe des
     # espèces, et une chenille est la même case que son papillon.
     "Trouve 5 papillons.", "theme", 5, "lepidoptere", "cocon"),

    ("venerable", "Vénérable", "🌳", "moyen",
     # Voulu : « 3 arbres de plus de cent ans ». L'âge d'un individu n'existe
     # nulle part ; on compte les arbres, pas leurs anneaux.
     "Trouve 5 arbres différents.", "theme", 5, "arbre", "druide"),

    ("sur_la_piste", "Sur la piste", "🐾", "moyen",
     # Voulu : « 5 traces de présence ». Une empreinte n'est pas une espèce ;
     # le moteur identifie des êtres vivants. Restent ceux qui les laissent.
     "Trouve 5 mammifères.", "theme", 5, "mammifere", "pisteresse"),

    ("enfer_du_decor", "L'enfer du décor", "☣️", "difficile",
     # Voulu : « 5 espèces invasives ». Aucune liste d'invasives en base, et
     # elle dépendrait du pays. Le catalogue sait en revanche ce que les noms
     # annoncent.
     "Trouve 5 espèces au nom venimeux ou vénéneux.", "theme", 5, "danger",
     "biohazard"),

    ("sous_les_paves", "Sous les pavés", "🪨", "difficile",
     # Voulu : « 5 espèces poussant dans les fissures ». L'habitat n'est pas une
     # donnée du catalogue. On garde la ville, à un seuil qui demande d'y vivre
     # vraiment — « Bitume » n'en demande qu'une.
     "Trouve 3 espèces des villes.", "theme", 3, "ville", "urbaine"),

    # ═══ les trente-deux succès du grand élargissement ═══════════════════════
    #
    # Trois familles, de coût très différent :
    #
    #   — les paliers, qui ne demandent rien au moteur qu'il ne sache déjà ;
    #   — les groupes taxonomiques, ancrés sur une classe ou une famille, donc
    #     sans faux positif possible ;
    #   — les six qui exploitent des données que rien ne touchait : les lieux,
    #     les jours, la confiance du moteur, les titres.
    #
    # Modèles provisoires, réutilisés parmi ceux qui existent. Ils seront
    # remplacés quand les leurs arriveront.

    # ---- paliers : le moteur sait déjà les calculer -------------------------
    ("collectionneur", "Collectionneur", "🗂", "moyen",
     "Atteins 50 espèces.", "compte", 50, None, "archiviste"),
    ("grand_inventaire", "Grand inventaire", "🌍", "difficile",
     "Trouve une espèce dans 15 classes différentes.", "classes", 15, None, "encyclopedie"),
    ("plein_soleil", "Plein soleil", "🌞", "facile",
     "Prends une photo entre 11 h et 15 h.", "heure", 1, (11, 15), "estivante"),
    ("chien_et_loup", "Entre chien et loup", "🌆", "moyen",
     "Photographie 5 espèces entre 19 h et 22 h.", "heure", 5, (19, 22), "veilleuse"),
    ("chasseur_aguerri", "Chasseur aguerri", "💎", "difficile",
     "Trouve 20 espèces rares ou mieux.", "rarete", 20, 4, "joailliere"),
    ("ovation", "Ovation", "🎉", "difficile",
     "Reçois 100 réactions sur tes photos.", "reactions", 100, None, "vedette"),
    ("inseparables", "Inséparables", "🤝", "difficile",
     "Sois identifié sur 20 photos d'amis.", "cosigne", 20, None, "jumeaux"),
    ("eclaireur", "Éclaireur", "🧭", "difficile",
     "Sois le premier de tes amis sur 10 espèces.", "premiere", 10, None, "boussole"),
    ("bon_oeil", "Bon œil", "👁", "moyen",
     "Corrige 25 identifications.", "corrigee", 25, None, "opticienne"),
    ("le_moteur_et_moi", "Le moteur et moi", "🎯", "difficile",
     "Fais identifier 50 espèces juste du premier coup.", "sans_faute", 50, None,
     "duelliste"),

    # ---- groupes taxonomiques : aucune interprétation --------------------------
    ("fougeres", "Sous la fronde", "🌿", "moyen",
     "Trouve 5 fougères.", "theme", 5, "fougere", "fougere"),
    ("crustaces", "Pinces et carapaces", "🦀", "moyen",
     "Trouve 5 crustacés.", "theme", 5, "crustace", "crabe"),
    ("amphibiens", "Entre deux eaux", "🐸", "moyen",
     "Trouve 5 amphibiens.", "theme", 5, "amphibien", "tetard"),
    ("coraux", "Jardin de corail", "🪸", "difficile",
     "Trouve 3 coraux ou anémones.", "theme", 3, "corail", "plongeuse"),
    ("mille_pattes", "Cent pattes", "🐛", "moyen",
     "Trouve 3 mille-pattes ou scolopendres.", "theme", 3, "mille_pattes",
     "myriapode"),
    ("orchidees", "Chasseur d'orchidées", "🌺", "difficile",
     "Trouve 10 orchidées.", "theme", 10, "orchidee", "orchidophile"),
    ("composees", "Le grand capitule", "🌼", "moyen",
     "Trouve 15 composées : marguerites, pissenlits, chardons.", "theme", 15,
     "composee", "fleuriste"),
    ("legumineuses", "Gousses et vesces", "🫛", "moyen",
     "Trouve 10 légumineuses.", "theme", 10, "legumineuse", "maraichere"),
    ("longicornes", "Longues antennes", "🪲", "moyen",
     "Trouve 5 longicornes.", "theme", 5, "longicorne", "capricorne"),
    ("charancons", "Museau pointu", "🐘", "moyen",
     "Trouve 5 charançons.", "theme", 5, "charancon", "charancon"),
    ("fourmis", "La fourmilière", "🐜", "moyen",
     "Trouve 5 espèces de fourmis.", "theme", 5, "fourmi", "fourmiliere"),
    ("coccinelles", "Bêtes à bon Dieu", "🐞", "moyen",
     "Trouve 3 coccinelles.", "theme", 3, "coccinelle", "coccinelle"),
    ("bolets", "Le panier du bolet", "🍄‍🟫", "moyen",
     "Trouve 5 bolets.", "theme", 5, "bolet", "mycologue"),
    ("russules", "Rouge et blanc", "🍄", "moyen",
     "Trouve 5 russules ou lactaires.", "theme", 5, "russule", "russule"),

    # ---- ce que personne n'avait encore regardé ------------------------------
    ("nomade", "Nomade", "🧳", "moyen",
     "Photographie dans 5 lieux différents.", "lieux", 5, None, "nomade"),
    ("grand_voyageur", "Grand voyageur", "🗺", "difficile",
     "Photographie dans 20 lieux différents.", "lieux", 20, None, "exploratrice"),
    ("assidu", "Assidu", "📅", "moyen",
     "Prends une photo trois jours d'affilée.", "jours_suite", 3, None,
     "calendrier"),
    ("increvable", "Increvable", "🔥", "difficile",
     "Prends une photo dix jours d'affilée.", "jours_suite", 10, None, "marathonienne"),
    ("belle_sortie", "Belle sortie", "🌄", "moyen",
     "Trouve 5 espèces différentes dans la même heure.", "rafale", 5, None,
     "randonneuse"),
    ("mon_espece", "De ma main", "✍️", "moyen",
     "Ajoute une espèce au dex toi-même.", "mienne", 1, None, "botaniste"),
    ("flair", "Du flair", "👃", "difficile",
     "Retiens 3 espèces que le moteur donnait à moins de 35 %.", "flair", 3,
     None, "limier"),
    ("conteuse", "Conteuse", "📝", "moyen",
     "Donne un titre à 20 de tes photos.", "titres", 20, None, "conteuse"),
]

# Tant qu'un modèle manque, on retombe sur celui-ci — affiché en silhouette
# noire quand le succès n'est pas obtenu, comme les rangs non atteints.
MODELE_DEFAUT = "grenouille"

# Les modèles réellement présents, côté application comme côté site.
#
# Chaque succès déclare le sien dans la liste ci-dessus. Sans ce garde-fou, un
# succès dont le fichier manque ferait demander `media/pompier.glb` à la fiche,
# qui n'afficherait rien du tout — un trou silencieux plutôt qu'un repli.
#
# Les trente premières sont là depuis le 1er septembre 2026, vingt-six autres
# le 4, les vingt-six dernières le 6 : depuis, chaque succès a sa grenouille et
# plus aucun ne se replie sur `grenouille`. La liste reste explicite parce
# qu'elle est le contrat entre le serveur, l'APK et le site, et qu'aucun des
# trois ne peut vérifier les dossiers des deux autres. `outils/modeles_succes.py`
# la reconstruit, et refuse de tourner si elle ne couvre pas exactement le
# catalogue.
MODELES_PRESENTS = {
    "alchimiste", "alpiniste", "apicultrice",
    "apothicaire", "arachnologue", "arcenciel",
    "archere", "archiviste", "astronaute",
    "bernard-lhermite", "bibliothecaire", "biohazard",
    "botaniste", "boussole", "bucheronne",
    "calendrier", "capitaine", "capricorne",
    "carnivore", "charancon", "chef",
    "chevalier", "coccinelle", "cocon",
    "conteuse", "cooking", "couronne",
    "crabe", "cueilleuse", "detective",
    "dragon", "druide", "duelliste",
    "duo", "eclair", "encyclopedie",
    "entomologiste", "estivante", "exploratrice",
    "fermiere", "fleuriste", "fougere",
    "fourmiliere", "geologue", "grenouille",
    "herpetologue", "jardinier", "joailliere",
    "jumeaux", "jumelles", "lampe",
    "limier", "maraichere", "marathonienne",
    "matinale", "musicienne", "mycologue",
    "myriapode", "noe", "nomade",
    "opticienne", "orchidophile", "orfevre",
    "pecheur", "peintre", "pisteresse",
    "plongeuse", "podium", "pompier",
    "randonneuse", "reine", "russule",
    "saisons", "scene", "scientifique",
    "skateur", "skieuse", "tetard",
    "touriste", "urbaine", "vedette",
    "veilleuse",
}


def modele_de(nom: str) -> str:
    """Le modèle à servir : le sien s'il existe, la grenouille sinon."""
    return nom if nom in MODELES_PRESENTS else MODELE_DEFAUT


# Les deux couleurs de chaque gemme, tirées des pixels du modèle qu'elle
# enferme : le corps de la grenouille pour la matière, sa couleur d'accent —
# le chapeau, l'écharpe — pour la lumière qui sort des fissures.
#
# Le fichier est produit par `outils/couleurs_succes.py`, à partir des planches
# de rotation. Il est lu une fois au démarrage : trente couples de couleurs ne
# valent pas un accès disque par requête.
#
# Elles sont servies plutôt que codées dans chaque client, pour la même raison
# que le shader n'existe qu'en un exemplaire : l'application et le site doivent
# montrer la même gemme, et deux tables à tenir à jour divergent.
_COULEURS = json.loads(
    (pathlib.Path(__file__).parent / "couleurs_succes.json").read_text()
) if (pathlib.Path(__file__).parent / "couleurs_succes.json").exists() else {}

# Le repli quand un modèle n'a pas été analysé : un bleu de cristal et une
# lueur chaude. Neutre et lisible, plutôt qu'un gris qui aurait l'air cassé.
COULEURS_DEFAUT = {"corps": "#7fc7ff", "fissure": "#ffd27f"}


def couleurs_de(nom: str) -> dict:
    """Les couleurs de la gemme d'un modèle."""
    c = _COULEURS.get(modele_de(nom), COULEURS_DEFAUT)
    return {"corps": c["corps"], "fissure": c["fissure"]}

ORDRE_DIFFICULTE = {"facile": 0, "moyen": 1, "difficile": 2}


def catalogue() -> list[dict]:
    """Les succès, sous une forme que les routes et l'outil partagent."""
    return [
        {"cle": cle, "nom": tr(nom), "emoji": emoji, "difficulte": diff,
         "comment": tr(comment), "type": type_, "seuil": seuil, "parametre": param,
         "modele": modele}
        for cle, nom, emoji, diff, comment, type_, seuil, param, modele
        in SUCCES
    ]


def par_cle() -> dict[str, dict]:
    return {s["cle"]: s for s in catalogue()}
