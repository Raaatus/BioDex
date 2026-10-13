"""
Construire une case à partir d'un lien Wikipédia.

Oui, ça marche — mais pas toujours, et l'exception est précisément le cas qui a
motivé cette fonctionnalité.

Ce qu'on obtient en suivant la chaîne page → entité Wikidata → propriétés :

    Mésange bleue     P225 Cyanistes caeruleus · P846 GBIF 2487879 · résumé
    Rosa gallica      P225 Rosa gallica        · P846 GBIF 3002530 · résumé
    Rosier            P225 Rosa (genre)        · P846 GBIF 8395064 · résumé
    Rosa 'Peace'      aucune entité Wikidata

Les trois premiers se remplissent seuls : la clé GBIF de Wikidata est **la même**
que le `cle_gbif` du dex, vérifié sur la mésange bleue qui est la case 36. On
récupère donc le binôme, le rang, le taxon parent, le nom français et le résumé
sans rien demander à l'utilisateur.

Le quatrième est un cultivar. Sa page existe en français, mais elle n'a pas
d'entité Wikidata parce qu'un cultivar n'est pas un taxon. C'est le cas des
rosiers de jardin — « Sophie Vartan », « Peace » — que le moteur rend sous le
nom de l'espèce botanique la plus proche. Pour ceux-là, aucune résolution
automatique n'est possible : le joueur saisit le nom et la description à la
main, et c'est très bien ainsi.

D'où la règle : le lien est une **aide à la saisie**, jamais une condition.
"""
import json
import re
import urllib.error
import urllib.parse
import urllib.request

# Wikipédia refuse les requêtes sans agent identifiable, et c'est légitime.
AGENT = "Biodex/1.0 (dex naturaliste entre amis)"

DELAI = 12

# Largeur demandée pour l'illustration. 640 suffit à remplir la fiche sur un
# écran dense sans tirer l'original.
LARGEUR_IMAGE = 640

# Rangs Wikidata qu'on sait traduire. Au-delà — sous-espèce, variété, forme —
# on garde le nom sans prétendre le ranger.
RANGS = {
    "Q7432": "espece",
    "Q68947": "sousespece",
    "Q34740": "genre",
    "Q35409": "famille",
    "Q36602": "ordre",
    "Q37517": "classe",
    "Q38348": "embranchement",
}


class Introuvable(Exception):
    """Le lien ne mène à rien d'exploitable. Le message est montré au joueur."""


def _json(url: str):
    requete = urllib.request.Request(url, headers={"User-Agent": AGENT})
    with urllib.request.urlopen(requete, timeout=DELAI) as r:
        return json.load(r)


def titre_et_langue(lien: str) -> tuple[str, str]:
    """Extrait le titre et la langue d'une URL Wikipédia.

    Accepte aussi un titre nu : le joueur qui tape « Rosa gallica » plutôt que
    de coller une URL a raison de trouver ça naturel.
    """
    lien = lien.strip()
    if not lien:
        raise Introuvable("Aucun lien.")
    if not lien.startswith("http"):
        return lien, "fr"

    u = urllib.parse.urlparse(lien)
    m = re.match(r"^([a-z\-]+)\.(m\.)?wikipedia\.org$", u.netloc)
    if not m:
        raise Introuvable("Ce n'est pas un lien Wikipédia.")
    langue = m.group(1)

    chemin = urllib.parse.unquote(u.path)
    if chemin.startswith("/wiki/"):
        return chemin[len("/wiki/"):].replace("_", " "), langue
    # Forme ancienne : /w/index.php?title=…
    titre = urllib.parse.parse_qs(u.query).get("title", [""])[0]
    if titre:
        return titre.replace("_", " "), langue
    raise Introuvable("Lien Wikipédia sans titre d'article.")


def _propriete(claims: dict, code: str):
    if code not in claims:
        return None
    snak = claims[code][0]["mainsnak"].get("datavalue")
    if not snak:
        return None
    valeur = snak["value"]
    if isinstance(valeur, dict) and "id" in valeur:
        return valeur["id"]
    return valeur


def resout(lien: str) -> dict:
    """Tout ce qu'on peut tirer d'un lien, sans jamais lever pour un manque.

    Le dictionnaire renvoyé décrit ce qu'on a trouvé ; les clés absentes valent
    None. Seul un lien franchement invalide ou une page inexistante lève.
    """
    titre, langue = titre_et_langue(lien)
    api = (f"https://{langue}.wikipedia.org/w/api.php?action=query"
           f"&prop=pageprops|extracts|pageimages&exintro=1&explaintext=1"
           # `pithumbsize` et non `piprop=original` : l'original de la mésange
           # bleue pèse 1,2 Mo, celui du rosier 368 Ko. Sur une fiche affichée
           # à quelques centaines de pixels, c'est un mégaoctet de réseau pour
           # des pixels que personne ne verra — et c'est Wikimedia qui le sert,
           # à chaque ouverture, depuis un téléphone en 4G.
           f"&pithumbsize={LARGEUR_IMAGE}&redirects=1"
           f"&titles={urllib.parse.quote(titre)}&format=json")
    try:
        pages = _json(api)["query"]["pages"]
    except (urllib.error.URLError, KeyError, TimeoutError) as e:
        raise Introuvable("Wikipédia est injoignable.") from e

    page = next(iter(pages.values()))
    if "missing" in page:
        raise Introuvable(f"Aucun article « {titre} » sur {langue}.wikipedia.")

    resultat = {
        "titre": page.get("title") or titre,
        "langue": langue,
        "resume": (page.get("extract") or "").strip(),
        "image": (page.get("thumbnail") or {}).get("source"),
        "url": f"https://{langue}.wikipedia.org/wiki/"
               + urllib.parse.quote((page.get("title") or titre).replace(" ", "_")),
        "latin": None,
        "nom_fr": None,
        "rang": None,
        "cle_gbif": None,
        "parent": None,
    }

    qid = page.get("pageprops", {}).get("wikibase_item")
    if not qid:
        # Un cultivar, une page d'homonymie, un article de fond. On rend ce
        # qu'on a — titre, résumé, image — et le joueur complète.
        return resultat

    try:
        entite = _json(
            f"https://www.wikidata.org/wiki/Special:EntityData/{qid}.json"
        )["entities"][qid]
    except (urllib.error.URLError, KeyError, TimeoutError):
        return resultat

    claims = entite.get("claims", {})
    resultat["latin"] = _propriete(claims, "P225")
    resultat["rang"] = RANGS.get(_propriete(claims, "P105") or "")
    resultat["parent"] = _propriete(claims, "P171")
    gbif = _propriete(claims, "P846")
    if gbif and str(gbif).isdigit():
        resultat["cle_gbif"] = int(gbif)

    # Le libellé français, sauf quand Wikidata y met le binôme : « Rosa
    # gallica » n'est pas un nom vernaculaire, et l'afficher comme tel donnerait
    # une case dont les deux lignes disent la même chose.
    fr = entite.get("labels", {}).get("fr", {}).get("value")
    if fr and fr != resultat["latin"]:
        resultat["nom_fr"] = fr
    return resultat
