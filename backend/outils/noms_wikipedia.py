#!/usr/bin/env python3
"""
Récolte les noms français par les redirections de Wikipédia.

C'est de loin la meilleure source, et la plus simple. Wikipédia range ses
articles sous le nom vernaculaire quand il existe, et laisse une redirection
depuis le nom scientifique : « Bellis perennis » mène à « Pâquerette »,
« Capreolus capreolus » à « Chevreuil d'Europe ». Suivre la redirection revient
donc à lire le nom français, sans rien analyser.

Comparaison des sources, mesurée sur le même dex :

    GBIF vernacularNames    3,6 %   une requête par espèce
    Wikidata rdfs:label      18 %   quatre cents par requête
    Wikipédia redirections   ~65 %  cinquante par requête, en 0,2 s

Wikipédia accepte cinquante titres par appel et répond en deux dixièmes de
seconde, ce qui met le dex entier à portée d'une heure de récolte là où GBIF
demandait trois heures pour un vingtième du résultat.

    python -m outils.noms_wikipedia --regne animal
    python -m outils.noms_wikipedia --rarete-max 5 --limite 900000

Le travail reprend où il s'est arrêté et peut être interrompu sans dommage.
"""
import argparse
import json
import pathlib
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db  # noqa: E402

API = "https://fr.wikipedia.org/w/api.php"
UA = {"User-Agent": "biodex/0.2 (dex naturaliste local; usage personnel)"}

PAR_LOT = 50            # maximum admis pour un compte ordinaire
OUVRIERS = 5            # au-delà, Wikipédia commence à refuser

# Un binôme latin : deux mots, le second en minuscules. Attention, « Moineau
# domestique » a exactement cette forme : la règle seule rejetait des milliers
# de vrais noms français — renard roux, pigeon biset, chèvre domestique. Ce
# qu'on veut écarter, c'est un renvoi d'un binôme vers un autre binôme, et
# celui-là garde le même genre en tête (« Bos primigenius » -> « Bos taurus »).
BINOME = re.compile(r"^[A-Z][a-z]+ [a-z][a-z\-]+$")

# Terminaisons qui trahissent un mot latin. Elles suffisent à reconnaître un
# second binôme même quand le genre a changé de nom.
# « is » seul est exclu : le français en est plein — gris, requis, taillis — et
# le retenir faisait rejeter « Loup gris ».
LATIN = re.compile(r"(us|um|ii|ae|ensis|alis|ilis|atus|ata|atum|icus|ica|icum|"
                   r"oides|iformis|ostris|ophora|opsis|ogaster|ophylla)$")

# « Pic vert (oiseau) » : la parenthèse ne sert qu'à distinguer deux articles.
PARENTHESE = re.compile(r"\s*\([^)]*\)\s*$")

_verrou = threading.Lock()


def utile(latin: str, titre: str) -> str | None:
    """Le nom français à retenir, ou None si le titre n'apprend rien."""
    fr = PARENTHESE.sub("", titre).strip()
    if not fr or len(fr) > 80:
        return None
    if fr.lower() == latin.lower():
        return None
    if BINOME.match(fr):
        genre_demande = latin.split(" ")[0].lower()
        premier, second = fr.split(" ")
        # Même genre en tête : c'est un renvoi vers un autre binôme.
        if premier.lower() == genre_demande:
            return None
        # Sinon on regarde la forme du second mot : « domestique » n'est pas du
        # latin, « vulgaris » si.
        if LATIN.search(second.lower()):
            return None
    # Les titres à trois mots dont les derniers sonnent latin — « Bos taurus
    # indicus » — restent de la nomenclature. « Paon du jour » et « Petite
    # tortue de Corse », eux, sont bien français.
    mots = fr.split(" ")
    if (len(mots) >= 3 and mots[0][:1].isupper()
            and all(LATIN.search(m.lower()) for m in mots[1:])):
        return None
    if not re.search(r"[A-Za-zÀ-ÿ]{3}", fr):
        return None
    return fr


def interroge(lot: list[str]) -> dict[str, str]:
    url = (f"{API}?action=query&format=json&redirects=1&titles="
           + urllib.parse.quote("|".join(lot)))
    for essai in range(4):
        try:
            with urllib.request.urlopen(
                    urllib.request.Request(url, headers=UA), timeout=60) as r:
                d = json.load(r)
            trouves = {}
            for red in d.get("query", {}).get("redirects", []):
                bon = utile(red["from"], red["to"])
                if bon:
                    trouves[red["from"]] = bon
            return trouves
        except urllib.error.HTTPError as e:
            # 429 : Wikipédia demande de lever le pied.
            time.sleep(20 * (essai + 1) if e.code == 429 else 3 * (essai + 1))
        except Exception:
            time.sleep(3 * (essai + 1))
    return {}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--regne", choices=("animal", "plante", "champignon"))
    ap.add_argument("--rarete-max", type=int, default=5)
    ap.add_argument("--limite", type=int, default=1_000_000)
    ap.add_argument("--obs-min", type=int, default=0,
                    help="ne traiter que les espèces assez observées")
    ap.add_argument("--remplace", action="store_true",
                    help="reprendre aussi les cases qui ont déjà un nom")
    ap.add_argument("--apercu", action="store_true",
                    help="montrer les changements sans rien écrire")
    a = ap.parse_args()

    db.initialise()
    fichier = config.DONNEES / "noms-wikipedia.json"
    noms: dict[str, str] = {}
    if fichier.exists():
        noms = json.loads(fichier.read_text(encoding="utf-8"))
        print(f"{len(noms)} noms déjà récoltés", flush=True)

    # Sans --remplace on ne comble que les trous. Avec, on reprend aussi les
    # noms déjà posés : ceux de GBIF viennent d'une liste de vernaculaires qui
    # mélange les espèces voisines, et donnent « Urial » pour le mouton ou
    # « Coq bankiva » pour la poule. Wikipédia, lui, range ses articles sous le
    # nom d'usage.
    conditions = ["c.rarete <= ?"] if a.remplace else ["c.nom_fr IS NULL", "c.rarete <= ?"]
    params: list = [a.rarete_max]
    if a.obs_min:
        conditions.append("c.obs >= ?")
        params.append(a.obs_min)
    if a.regne:
        conditions.append("c.regne = ?")
        params.append(a.regne)
    params.append(a.limite)
    # Les plus observées d'abord : ce sont celles qu'on croise, donc celles
    # dont le nom manque le plus.
    latins = [r["latin"] for r in db.lit(
        f"""SELECT a.latin FROM alias a JOIN cases c ON c.id = a.case_id
            WHERE {' AND '.join(conditions)}
            ORDER BY c.obs DESC LIMIT ?""", params)]
    restants = latins if a.remplace else [n for n in latins if n not in noms]
    print(f"{len(latins)} noms à couvrir, {len(restants)} pas encore demandés",
          flush=True)
    if not restants:
        applique(noms)
        return 0

    lots = [restants[i:i + PAR_LOT] for i in range(0, len(restants), PAR_LOT)]
    t0 = time.perf_counter()
    faits = 0
    with ThreadPoolExecutor(max_workers=OUVRIERS) as pool:
        for trouves in pool.map(interroge, lots):
            with _verrou:
                noms.update(trouves)
                faits += 1
                if faits % 25 == 0 or faits == len(lots):
                    fichier.write_text(json.dumps(noms, ensure_ascii=False),
                                       encoding="utf-8")
                    ecoule = (time.perf_counter() - t0) / 60
                    reste = ecoule / faits * (len(lots) - faits)
                    print(f"  {faits}/{len(lots)} lots | {len(noms)} noms "
                          f"| {ecoule:.1f} min, ~{reste:.0f} min restantes",
                          flush=True)

    fichier.write_text(json.dumps(noms, ensure_ascii=False), encoding="utf-8")
    applique(noms, remplace=a.remplace, apercu=a.apercu)
    return 0


def applique(noms: dict[str, str], remplace: bool = False,
             apercu: bool = False) -> None:
    if remplace:
        # Ce qui va réellement changer, pour qu'on puisse le relire avant de
        # l'écrire : remplacer un nom par un autre mérite d'être vu.
        marques = ",".join("?" * len(noms))
        actuels = {r["latin"]: r["nom_fr"] for r in db.lit(
            f"""SELECT a.latin, c.nom_fr FROM alias a JOIN cases c ON c.id = a.case_id
                WHERE a.latin IN ({marques}) AND c.nom_fr IS NOT NULL""",
            list(noms))}
        changes = [(l, actuels[l], noms[l]) for l in noms
                   if l in actuels and actuels[l] != noms[l]]
        print(f"\n{len(changes)} noms seraient remplacés. Échantillon :")
        for latin, ancien, neuf in sorted(changes)[:20]:
            print(f"  {latin:28} {ancien:26} -> {neuf}")
        if apercu:
            print("\nAperçu seulement : rien n'a été écrit.")
            return

    avant = db.valeur("SELECT COUNT(*) FROM cases WHERE nom_fr IS NOT NULL", (), 0)
    ou = "" if remplace else "nom_fr IS NULL AND "
    with db.transaction() as cx:
        cx.executemany(
            f"""UPDATE cases SET nom_fr = ?
                WHERE {ou}id IN (
                    SELECT case_id FROM alias WHERE latin = ?)""",
            [(fr, latin) for latin, fr in noms.items()])
    apres = db.valeur("SELECT COUNT(*) FROM cases WHERE nom_fr IS NOT NULL", (), 0)
    print(f"\n{apres - avant} noms posés sur les cases ({avant} -> {apres})")
    for r in db.lit("""SELECT regne, COUNT(*) t, SUM(nom_fr IS NOT NULL) fr
                       FROM cases GROUP BY regne ORDER BY t DESC"""):
        print(f"  {r['regne']:<12} {r['fr'] or 0:>7} / {r['t']} "
              f"({(r['fr'] or 0) * 100 / r['t']:.1f} %)")


if __name__ == "__main__":
    sys.exit(main())
