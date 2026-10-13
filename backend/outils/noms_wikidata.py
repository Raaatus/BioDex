#!/usr/bin/env python3
"""
Récolte les noms français depuis Wikidata.

GBIF, qu'on interrogeait jusqu'ici espèce par espèce, est pauvre en noms
vernaculaires : 20 000 noms pour 618 000 demandes, soit 3,6 % de rendement en
trois heures. Wikidata porte les mêmes taxons avec leurs libellés dans toutes
les langues, et rend **18 %** sur le même périmètre — cinq fois mieux, et de
meilleurs noms : coquelicot, pissenlit, fraisier des bois.

Deux choses rendent la récolte praticable :

  on interroge par lots     quatre cents binômes par requête, via `VALUES`, ce
                            qui utilise l'index de Wikidata au lieu de lui
                            faire balayer ses quatre millions de taxons ;
  on passe en POST          la même requête en URL dépasse la longueur admise
                            et se fait refuser d'un « 414 URI Too Long ».

Tout n'est pas bon à prendre : Wikidata renvoie souvent le nom latin comme
libellé français, parfois une désambiguïsation entre parenthèses. On ne garde
que ce qui ressemble à un nom vernaculaire.

    python -m outils.noms_wikidata --regne animal
    python -m outils.noms_wikidata --limite 50000

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

POINT = "https://query.wikidata.org/sparql"
UA = {"User-Agent": "biodex/0.2 (dex naturaliste local)",
      "Accept": "application/sparql-results+json"}

PAR_LOT = 400           # au-delà, la requête devient longue et le gain s'aplatit
OUVRIERS = 4            # Wikidata tolère mal davantage depuis une seule adresse

# Un binôme latin : deux mots, le second en minuscules. Wikidata donne souvent
# le nom scientifique comme libellé français, ce qui n'apprend rien.
BINOME = re.compile(r"^[A-Z][a-z]+ [a-z][a-z\-]+$")

# « Anisoptera (végétal) » : la parenthèse ne distingue que deux articles.
PARENTHESE = re.compile(r"\s*\([^)]*\)\s*$")

_verrou = threading.Lock()


def utile(latin: str, brut: str) -> str | None:
    """Le nom français à garder, ou None s'il n'apprend rien."""
    fr = PARENTHESE.sub("", brut).strip()
    if not fr or len(fr) > 80:
        return None
    if fr.lower() == latin.lower() or BINOME.match(fr):
        return None
    if not re.search(r"[A-Za-zÀ-ÿ]{3}", fr):
        return None
    # Wikidata écrit tantôt « coquelicot », tantôt « Coquelicot ». On tranche
    # pour la majuscule, comme le reste du dex.
    return fr[0].upper() + fr[1:]


def interroge(lot: list[str]) -> dict[str, str]:
    valeurs = " ".join('"%s"' % n.replace('"', '') for n in lot)
    requete = (f'SELECT ?nom ?fr WHERE {{ VALUES ?nom {{ {valeurs} }} '
               f'?t wdt:P225 ?nom . ?t rdfs:label ?fr . FILTER(LANG(?fr)="fr") }}')
    corps = urllib.parse.urlencode({"query": requete}).encode()

    for essai in range(4):
        try:
            with urllib.request.urlopen(
                    urllib.request.Request(POINT, data=corps, headers=UA),
                    timeout=180) as r:
                lignes = json.load(r)["results"]["bindings"]
            trouves = {}
            for l in lignes:
                bon = utile(l["nom"]["value"], l["fr"]["value"])
                if bon:
                    trouves[l["nom"]["value"]] = bon
            return trouves
        except urllib.error.HTTPError as e:
            # 429 : Wikidata demande de lever le pied.
            time.sleep(15 * (essai + 1) if e.code == 429 else 5 * (essai + 1))
        except Exception:
            time.sleep(5 * (essai + 1))
    return {}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--regne", choices=("animal", "plante", "champignon"))
    ap.add_argument("--rarete-max", type=int, default=3,
                    help="ne traiter que les espèces assez communes (défaut 3)")
    ap.add_argument("--limite", type=int, default=60_000,
                    help="nombre de cases à traiter dans cette passe")
    a = ap.parse_args()

    db.initialise()
    fichier = config.DONNEES / "noms-wikidata.json"
    noms: dict[str, str] = {}
    if fichier.exists():
        noms = json.loads(fichier.read_text(encoding="utf-8"))
        print(f"{len(noms)} noms déjà récoltés", flush=True)

    # Les plus observées d'abord : ce sont celles qu'on croise, donc celles
    # dont le nom manque le plus.
    conditions = ["c.nom_fr IS NULL", "c.rarete <= ?"]
    params: list = [a.rarete_max]
    if a.regne:
        conditions.append("c.regne = ?")
        params.append(a.regne)
    params.append(a.limite)
    latins = [r["latin"] for r in db.lit(
        f"""SELECT a.latin FROM alias a JOIN cases c ON c.id = a.case_id
            WHERE {' AND '.join(conditions)}
            ORDER BY c.obs DESC LIMIT ?""", params)]
    restants = [n for n in latins if n not in noms]
    print(f"{len(latins)} noms à couvrir, {len(restants)} pas encore demandés",
          flush=True)

    lots = [restants[i:i + PAR_LOT] for i in range(0, len(restants), PAR_LOT)]
    t0 = time.perf_counter()
    faits = 0
    with ThreadPoolExecutor(max_workers=OUVRIERS) as pool:
        for trouves in pool.map(interroge, lots):
            with _verrou:
                noms.update(trouves)
                faits += 1
                if faits % 5 == 0 or faits == len(lots):
                    fichier.write_text(json.dumps(noms, ensure_ascii=False),
                                       encoding="utf-8")
                    ecoule = (time.perf_counter() - t0) / 60
                    reste = ecoule / faits * (len(lots) - faits)
                    print(f"  {faits}/{len(lots)} lots | {len(noms)} noms "
                          f"| {ecoule:.1f} min, ~{reste:.0f} min restantes",
                          flush=True)

    fichier.write_text(json.dumps(noms, ensure_ascii=False), encoding="utf-8")
    applique(noms)
    return 0


def applique(noms: dict[str, str]) -> None:
    avant = db.valeur("SELECT COUNT(*) FROM cases WHERE nom_fr IS NOT NULL", (), 0)
    with db.transaction() as cx:
        # On ne remplace jamais un nom déjà en place : ceux de GBIF viennent de
        # la référence taxonomique et priment.
        cx.executemany(
            """UPDATE cases SET nom_fr = ?
               WHERE nom_fr IS NULL AND id IN (
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
