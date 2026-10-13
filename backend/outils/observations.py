#!/usr/bin/env python3
"""
Récolte le nombre d'observations GBIF par espèce, pour un règne donné.

À quoi ça sert : le classificateur ne sait pas ce qui est fréquent. Sans cet
a priori, il met la pâquerette (23 millions d'observations) au coude à coude
avec une orchidée bolivienne connue par trois herbiers. Sur les animaux, la
correction a fait passer la reconnaissance de 3/10 à 10/10 sur les images de
référence. Les paliers de rareté du jeu s'en servent aussi : sans compteur,
toutes les espèces seraient « légendaires ».

La récolte passe par les facettes de l'API GBIF : une requête ramène mille
espèces avec leur compte, donc quelques centaines de requêtes suffisent pour un
règne entier. Interrogée espèce par espèce, la même récolte demanderait des
heures.

    python -m outils.observations --regne plantes
    python -m outils.observations --regne champignons

Le travail reprend où il s'est arrêté : le fichier d'état garde l'offset, et
Ctrl-C laisse tout en place.
"""
import argparse
import json
import pathlib
import re
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config  # noqa: E402

UA = {"User-Agent": "biodex/0.2 (dex local)"}

# Clés de règne du backbone GBIF.
REGNES = {"animaux": 1, "champignons": 5, "plantes": 6}

PAS = 1000              # espèces par requête (maximum accepté par GBIF)
OUVRIERS = 10           # requêtes simultanées
VAGUE = 20              # requêtes par vague avant sauvegarde
# GBIF cesse de rendre des facettes passé un demi-million d'entrées : au-delà,
# les requêtes échouent en boucle. Les espèces manquantes sont les moins
# observées — elles tombent à zéro, donc au palier le plus rare, ce qui est
# exactement leur place.
PLAFOND = 520_000
ECHECS_MAX = 3          # vagues entièrement en échec avant d'abandonner

# GBIF renvoie le nom d'auteur avec le nom scientifique (« Bellis perennis L. »).
# Le catalogue, lui, ne contient que le binôme.
BINOME = re.compile(r"^([A-Z][a-z]+) ([a-z][a-z\-]+)(?:\s|$)")


def recolte(offset: int, cle_regne: int) -> tuple[int, list | None]:
    url = (f"https://api.gbif.org/v1/occurrence/search?kingdomKey={cle_regne}"
           f"&facet=scientificName&facetLimit={PAS}&facetOffset={offset}&limit=0")
    for essai in range(4):
        try:
            with urllib.request.urlopen(
                    urllib.request.Request(url, headers=UA), timeout=180) as r:
                comptes = json.load(r)["facets"][0]["counts"]
            return offset, [(c["name"], c["count"]) for c in comptes]
        except Exception:
            time.sleep(3 * (essai + 1))
    return offset, None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--regne", required=True, choices=sorted(REGNES))
    ap.add_argument("--sortie", type=pathlib.Path, default=None,
                    help="par défaut donnees/observations-<regne>.json")
    a = ap.parse_args()

    cle = REGNES[a.regne]
    sortie = a.sortie or config.DONNEES / f"observations-{a.regne}.json"
    etat = sortie.with_suffix(".etat.json")

    especes: dict[str, int] = {}
    depart = 0
    if sortie.exists():
        especes = json.loads(sortie.read_text(encoding="utf-8"))
    if etat.exists():
        depart = json.loads(etat.read_text(encoding="utf-8"))["offset"]
    print(f"Règne {a.regne} (kingdomKey={cle})", flush=True)
    print(f"  reprise : {len(especes)} espèces connues, offset {depart}", flush=True)

    t0 = time.perf_counter()
    offset, fini, echecs = depart, False, 0
    with ThreadPoolExecutor(max_workers=OUVRIERS) as pool:
        while not fini and offset < PLAFOND:
            lot = [offset + i * PAS for i in range(VAGUE)]
            offset += VAGUE * PAS
            neufs, rendus = 0, 0
            for off, comptes in pool.map(lambda o: recolte(o, cle), lot):
                if comptes is None:
                    continue
                rendus += 1
                if not comptes:
                    fini = True
                    continue
                for nom, n in comptes:
                    m = BINOME.match(nom)
                    if not m:
                        continue
                    canon = f"{m.group(1)} {m.group(2)}"
                    # Un même binôme revient sous plusieurs graphies d'auteur :
                    # on garde le compte le plus élevé plutôt que le dernier vu.
                    if n > especes.get(canon, 0):
                        if canon not in especes:
                            neufs += 1
                        especes[canon] = n

            # Une vague entièrement muette signifie que GBIF ne rend plus rien :
            # insister ne ferait que marteler l'API.
            echecs = echecs + 1 if rendus == 0 else 0
            if echecs >= ECHECS_MAX:
                print(f"  GBIF ne rend plus de facettes à l'offset {offset} — "
                      f"récolte close", flush=True)
                fini = True

            sortie.write_text(json.dumps(especes, ensure_ascii=False),
                              encoding="utf-8")
            etat.write_text(json.dumps({"offset": offset}), encoding="utf-8")
            print(f"  offset {offset:>9} | {len(especes):>8} espèces (+{neufs}) "
                  f"| {(time.perf_counter() - t0) / 60:.1f} min", flush=True)

    print(f"\n{len(especes)} espèces observées -> {sortie}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
