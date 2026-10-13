#!/usr/bin/env python3
"""
Récolte les noms vernaculaires français des cases, auprès de GBIF.

« Anas platyrhynchos » ne parle à personne : dans la grille on veut lire
« Canard colvert ». Comme chaque case porte déjà sa clé GBIF, une seule requête
suffit par espèce — inutile de repasser par la résolution de nom.

On ne traite que les cases assez communes pour qu'un joueur les croise : les
348 000 espèces vues moins de mille fois dans l'histoire n'ont de toute façon
presque jamais de nom français, et les interroger prendrait des jours.

    python outils/noms_francais.py --rarete-max 3

Le script reprend où il s'est arrêté et peut être interrompu sans dommage.
"""
import argparse
import json
import pathlib
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import db  # noqa: E402

UA = {"User-Agent": "biodex/0.1 (dex local)"}
OUVRIERS = 8
LOT = 200

_verrou = threading.Lock()


def _presente(nom: str) -> str:
    """Met une majuscule initiale sans toucher au reste.

    `str.capitalize()` abîmerait « Bernache du Canada » en « Bernache du canada ».
    """
    return nom[0].upper() + nom[1:] if nom else nom


def vernaculaire(cle: int) -> str | None:
    """Le meilleur nom français pour une clé GBIF, ou None.

    GBIF agrège plusieurs sources, qui ne s'accordent pas toujours. On retient
    le nom que le plus de sources confirment — un nom cité cinq fois vaut mieux
    qu'un nom isolé — et on départage les ex æquo par la brièveté, la forme
    usuelle étant presque toujours la plus courte.
    """
    url = f"https://api.gbif.org/v1/species/{cle}/vernacularNames?limit=100"
    for essai in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA),
                                        timeout=20) as r:
                resultats = json.load(r).get("results", [])
            break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            time.sleep(2 * (essai + 1))
        except Exception:
            time.sleep(2 * (essai + 1))
    else:
        return None

    noms = [x["vernacularName"].strip() for x in resultats
            if x.get("language") == "fra" and x.get("vernacularName")]
    if not noms:
        return None
    # Une virgule signale une liste de synonymes agglomérés : on garde le premier.
    noms = [n.split(",")[0].strip() for n in noms if n.strip()]
    if not noms:
        return None

    # On compte sur la forme repliée pour que « canard colvert » et
    # « Canard Colvert » soient reconnus comme un seul et même nom.
    comptes: dict[str, list] = {}
    for n in noms:
        cle_nom = n.casefold()
        entree = comptes.setdefault(cle_nom, [0, n])
        entree[0] += 1
        # On garde la graphie la plus soignée : celle qui a des majuscules
        # internes, donc la plus longue à casse égale de première lettre.
        if n[1:] != n[1:].lower() and entree[1][1:] == entree[1][1:].lower():
            entree[1] = n
    meilleur = max(comptes.values(), key=lambda e: (e[0], -len(e[1])))
    return _presente(meilleur[1])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rarete-max", type=int, default=3,
                    help="ne traiter que les cases jusqu'à cette rareté (1 = partout)")
    ap.add_argument("--limite", type=int, default=0, help="s'arrêter après N cases")
    a = ap.parse_args()

    db.initialise()
    cases = db.lit(
        """SELECT id, cle_gbif, latin FROM cases
           WHERE nom_fr IS NULL AND cle_gbif > 0 AND rarete <= ?
           ORDER BY obs DESC""", (a.rarete_max,))
    if a.limite:
        cases = cases[:a.limite]
    if not cases:
        print("Rien à récolter : toutes les cases visées ont déjà un nom.")
        return 0

    print(f"{len(cases)} cases sans nom français (rareté ≤ {a.rarete_max})", flush=True)
    t0 = time.perf_counter()
    trouves = 0
    tampon: list[tuple[str, int]] = []

    def ecrit(force=False):
        nonlocal tampon
        if not tampon or (len(tampon) < LOT and not force):
            return
        with db.transaction() as cx:
            cx.executemany("UPDATE cases SET nom_fr = ? WHERE id = ?", tampon)
        tampon = []

    with ThreadPoolExecutor(max_workers=OUVRIERS) as pool:
        for i, (case, nom) in enumerate(
                zip(cases, pool.map(vernaculaire, [c["cle_gbif"] for c in cases])), 1):
            if nom:
                trouves += 1
                with _verrou:
                    tampon.append((nom, case["id"]))
                    ecrit()
            if i % 500 == 0:
                vitesse = i / max(time.perf_counter() - t0, 1e-9)
                reste = (len(cases) - i) / max(vitesse, 1e-9)
                print(f"  {i}/{len(cases)} — {trouves} noms trouvés, "
                      f"{reste / 60:.0f} min restantes", flush=True)
    with _verrou:
        ecrit(force=True)

    print(f"\n{trouves} noms français ajoutés en {(time.perf_counter() - t0) / 60:.1f} min.")
    for r in db.lit("""SELECT latin, nom_fr, obs FROM cases
                       WHERE nom_fr IS NOT NULL ORDER BY obs DESC LIMIT 10"""):
        print(f"  {r['latin']:<32} {r['nom_fr']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
