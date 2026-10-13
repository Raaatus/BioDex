#!/usr/bin/env python3
"""
Récupère les silhouettes de PhyloPic et les rattache aux cases du dex.

PhyloPic est une banque de silhouettes d'organismes, dessinées par des
naturalistes et versées pour l'essentiel au domaine public. Elles remplacent
avantageusement les formes que j'avais dessinées à la main : ce sont de vraies
silhouettes d'espèces, pas des approximations par grand groupe.

Le point qui rend l'affaire simple : PhyloPic sait résoudre un identifiant GBIF,
et chaque case porte le sien. Quand l'espèce exacte n'a pas d'image — c'est le
cas de la coccinelle — on remonte sa lignée : famille, puis ordre, puis classe.

Le script est incrémental : il note ce qu'il a déjà demandé et peut être
interrompu puis relancé sans tout refaire.

    python outils/phylopic.py                  # taxons + 3000 espèces
    python outils/phylopic.py --especes 12000  # descendre plus bas
    python outils/phylopic.py --taxons-seuls
"""
import argparse
import json
import pathlib
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db  # noqa: E402

UA = "biodex/0.1 (dex personnel; https://github.com/)"
ENTETES_API = {"User-Agent": UA, "Accept": "application/vnd.phylopic.v2+json"}
ENTETES_FICHIER = {"User-Agent": UA}

RESOLUTION = ("https://api.phylopic.org/resolve/gbif.org/species"
              "?objectIDs={cle}&embed_primaryImage=true")

# PhyloPic est un service bénévole : on reste courtois. Quatre requêtes en
# parallèle et une pause entre deux suffisent largement à faire le travail en
# une demi-heure.
OUVRIERS = 4
PAUSE = 0.08

DOSSIER = None          # rempli au démarrage : donnees/silhouettes/phylopic
CACHE = None            # les clés GBIF déjà demandées, pour pouvoir reprendre

_verrou = threading.Lock()
_deja = {}


def charge_cache() -> None:
    global _deja
    if CACHE.exists():
        try:
            _deja = json.loads(CACHE.read_text(encoding="utf-8"))
        except Exception:
            _deja = {}


def note(cle: int, valeur) -> None:
    with _verrou:
        _deja[str(cle)] = valeur


def sauve_cache() -> None:
    with _verrou:
        CACHE.write_text(json.dumps(_deja), encoding="utf-8")


def interroge(cle: int) -> dict | None:
    """Renvoie {uuid, url, attribution, licence} pour une clé GBIF, ou None.

    Le résultat, y compris l'absence d'image, est mémorisé : inutile de
    redemander mille fois une clé que PhyloPic ne connaît pas.
    """
    connu = _deja.get(str(cle))
    if connu is not None:
        return connu or None

    for essai in range(3):
        try:
            requete = urllib.request.Request(RESOLUTION.format(cle=cle),
                                             headers=ENTETES_API)
            with urllib.request.urlopen(requete, timeout=20) as r:
                d = json.load(r)
            break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                note(cle, False)
                return None
            time.sleep(1.5 * (essai + 1))
        except Exception:
            time.sleep(1.5 * (essai + 1))
    else:
        return None

    image = (d.get("_embedded") or {}).get("primaryImage") or {}
    liens = image.get("_links") or {}
    url = (liens.get("vectorFile") or {}).get("href")
    if not url:
        note(cle, False)
        return None

    resultat = {
        "uuid": (image.get("uuid") or url.rsplit("/", 2)[-2]),
        "url": url,
        "attribution": image.get("attribution") or "",
        "licence": (liens.get("license") or {}).get("href", ""),
    }
    note(cle, resultat)
    return resultat


def nettoie(contenu: bytes) -> bytes:
    """Allège le SVG avant de le ranger.

    Les fichiers de PhyloPic sortent de potrace avec une déclaration de type de
    document et un bloc de métadonnées qui ne servent qu'à l'archivage. Les
    retirer épargne quelques centaines d'octets par fichier et évite de faire
    lire à l'application un DOCTYPE qui pointe vers une DTD distante.
    """
    texte = contenu.decode("utf-8", "replace")
    texte = re.sub(r"<!DOCTYPE[^>]*>", "", texte, flags=re.S)
    texte = re.sub(r"<metadata>.*?</metadata>", "", texte, flags=re.S)
    texte = re.sub(r"<\?xml[^>]*\?>", "", texte, flags=re.S)
    return texte.strip().encode("utf-8")


def telecharge(info: dict) -> str | None:
    """Range le SVG et renvoie son nom de fichier, ou None."""
    nom = f"phylopic/{info['uuid']}.svg"
    cible = config.SILHOUETTES / nom
    if cible.exists():
        return nom
    try:
        requete = urllib.request.Request(info["url"], headers=ENTETES_FICHIER)
        with urllib.request.urlopen(requete, timeout=25) as r:
            contenu = r.read()
        if len(contenu) < 80 or b"<svg" not in contenu[:400]:
            return None
        cible.parent.mkdir(parents=True, exist_ok=True)
        cible.write_bytes(nettoie(contenu))
        return nom
    except Exception:
        return None


def recolte(taches: list[tuple[str, int, str]], etiquette: str) -> int:
    """`taches` = [(rang, clé GBIF, nom du taxon)]. Renvoie le nombre d'images
    effectivement obtenues."""
    if not taches:
        return 0
    print(f"\n{etiquette} : {len(taches)} taxons", flush=True)
    t0 = time.perf_counter()
    trouves = 0
    lignes = []

    def travaille(tache):
        rang, cle, nom = tache
        time.sleep(PAUSE)
        info = interroge(cle)
        if info is None:
            return None
        fichier = telecharge(info)
        if fichier is None:
            return None
        return (fichier, rang, cle, nom, info["attribution"], info["licence"])

    with ThreadPoolExecutor(max_workers=OUVRIERS) as pool:
        for i, resultat in enumerate(pool.map(travaille, taches), 1):
            if resultat:
                trouves += 1
                lignes.append(resultat)
            if i % 250 == 0:
                vitesse = i / max(time.perf_counter() - t0, 1e-9)
                reste = (len(taches) - i) / max(vitesse, 1e-9)
                print(f"  {i}/{len(taches)} — {trouves} images, "
                      f"{reste / 60:.0f} min restantes", flush=True)
                sauve_cache()

    if lignes:
        with db.transaction() as cx:
            cx.executemany(
                """INSERT INTO visuels (fichier, rang, cle_gbif, etiquette,
                                        source, licence)
                   VALUES (?,?,?,?,?,?)
                   ON CONFLICT(fichier, rang, cle_gbif)
                   DO UPDATE SET etiquette = excluded.etiquette""",
                [(f, r, c, n, f"PhyloPic — {a}" if a else "PhyloPic", l)
                 for f, r, c, n, a, l in lignes])
    sauve_cache()
    print(f"  {trouves}/{len(taches)} images en "
          f"{(time.perf_counter() - t0) / 60:.1f} min", flush=True)
    return trouves


def reinsere_depuis_cache() -> int:
    """Repeuple la table des visuels à partir du cache, sans réseau.

    Sert après une correction du schéma : tout ce que PhyloPic a déjà répondu
    est mémorisé, il serait absurde de le redemander.
    """
    lignes = []
    for cle, info in _deja.items():
        if not info:
            continue
        nom = f"phylopic/{info['uuid']}.svg"
        if not (config.SILHOUETTES / nom).exists():
            continue
        attribution = info.get("attribution") or ""
        lignes.append((nom, int(cle),
                       f"PhyloPic — {attribution}" if attribution else "PhyloPic",
                       info.get("licence", "")))
    if not lignes:
        return 0

    # Le rang de chaque clé se retrouve dans les cases : une clé est soit une
    # classe, soit un ordre, soit une famille, soit une espèce.
    rangs = {}
    for rang, colonne in (("classe", "cle_classe"), ("ordre", "cle_ordre"),
                          ("famille", "cle_famille"), ("espece", "cle_gbif")):
        for r in db.lit(f"SELECT DISTINCT {colonne} AS c FROM cases "
                        f"WHERE {colonne} IS NOT NULL"):
            rangs.setdefault(r["c"], []).append(rang)

    a_ecrire = []
    for nom, cle, source, licence in lignes:
        for rang in rangs.get(cle, []):
            a_ecrire.append((nom, rang, cle, str(cle), source, licence))

    with db.transaction() as cx:
        cx.executemany(
            """INSERT INTO visuels (fichier, rang, cle_gbif, etiquette, source, licence)
               VALUES (?,?,?,?,?,?)
               ON CONFLICT(fichier, rang, cle_gbif)
               DO UPDATE SET source = excluded.source, licence = excluded.licence""",
            a_ecrire)
    return len(a_ecrire)


def affecte() -> None:
    """Donne à chaque case la silhouette la plus précise dont on dispose.

    On applique du plus général au plus précis, si bien que l'espèce écrase la
    famille, qui a elle-même écrasé l'ordre. Les cases qu'aucune image PhyloPic
    ne couvre gardent la forme générique dessinée à la main.
    """
    print("\nAffectation aux cases…", flush=True)
    with db.transaction() as cx:
        for rang, colonne in (("classe", "cle_classe"), ("ordre", "cle_ordre"),
                              ("famille", "cle_famille"), ("espece", "cle_gbif")):
            cx.execute(
                f"""UPDATE cases SET visuel = (
                        SELECT v.id FROM visuels v
                        WHERE v.rang = ? AND v.cle_gbif = cases.{colonne})
                    WHERE EXISTS (
                        SELECT 1 FROM visuels v
                        WHERE v.rang = ? AND v.cle_gbif = cases.{colonne})""",
                (rang, rang))

    total = db.valeur("SELECT COUNT(*) FROM cases", (), 0)
    par_rang = db.lit(
        """SELECT v.rang, COUNT(*) AS n FROM cases c
           JOIN visuels v ON v.id = c.visuel
           GROUP BY v.rang ORDER BY n DESC""")
    print(f"\n{total} cases :")
    for r in par_rang:
        print(f"  {r['rang']:<10} {r['n']:>7}  ({r['n'] / total:5.1%})")
    orphelines = db.valeur("SELECT COUNT(*) FROM cases WHERE visuel IS NULL", (), 0)
    if orphelines:
        print(f"  {orphelines} cases sans silhouette — relancer outils/silhouettes.py")


def main() -> int:
    global DOSSIER, CACHE
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--especes", type=int, default=3000,
                    help="nombre d'espèces à couvrir, des plus observées aux moins")
    ap.add_argument("--taxons-seuls", action="store_true",
                    help="ne traiter que classes, ordres et familles")
    ap.add_argument("--sans-affectation", action="store_true")
    ap.add_argument("--depuis-cache", action="store_true",
                    help="repeupler la base avec ce qui est déjà téléchargé, "
                         "sans aucune requête réseau")
    a = ap.parse_args()

    config.prepare_dossiers()
    DOSSIER = config.SILHOUETTES / "phylopic"
    DOSSIER.mkdir(parents=True, exist_ok=True)
    CACHE = config.DONNEES / "phylopic.cache.json"
    charge_cache()
    db.initialise()
    print(f"{len(_deja)} clés déjà interrogées", flush=True)

    if a.depuis_cache:
        n = reinsere_depuis_cache()
        print(f"{n} rattachements taxon → silhouette réinscrits.", flush=True)
        affecte()
        return 0

    # Du plus général au plus précis : même interrompu tôt, le dex a déjà une
    # silhouette correcte partout.
    classes = db.lit("""SELECT DISTINCT cle_classe AS cle, classe AS nom FROM cases
                        WHERE cle_classe IS NOT NULL AND classe <> ''""")
    recolte([("classe", r["cle"], r["nom"]) for r in classes], "Classes")

    ordres = db.lit("""SELECT DISTINCT cle_ordre AS cle, ordre AS nom FROM cases
                       WHERE cle_ordre IS NOT NULL AND ordre <> ''""")
    recolte([("ordre", r["cle"], r["nom"]) for r in ordres], "Ordres")

    # Les familles de tout ce qui est un peu observé : inutile d'aller chercher
    # celles qui ne contiennent que des espèces vues trois fois.
    familles = db.lit("""SELECT DISTINCT cle_famille AS cle, famille AS nom
                         FROM cases
                         WHERE cle_famille IS NOT NULL AND famille <> ''
                           AND obs >= 500""")
    recolte([("famille", r["cle"], r["nom"]) for r in familles], "Familles")

    if not a.taxons_seuls and a.especes > 0:
        especes = db.lit(
            """SELECT cle_gbif AS cle, latin AS nom FROM cases
               WHERE cle_gbif > 0 ORDER BY obs DESC LIMIT ?""", (a.especes,))
        recolte([("espece", r["cle"], r["nom"]) for r in especes], "Espèces")

    if not a.sans_affectation:
        affecte()
    return 0


if __name__ == "__main__":
    sys.exit(main())
