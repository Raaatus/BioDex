#!/usr/bin/env python3
"""
Construit les cases du dex à partir du backbone taxonomique GBIF.

Le problème à résoudre : le catalogue du classificateur contient 411 626 noms
latins, dont beaucoup désignent la même bête. « Bos indicus » (le zébu),
« Bos primigenius » (l'aurochs), « Bos taurus taurus » et « Bos taurus indicus »
sont quatre entrées distinctes qui, dans le backbone GBIF, portent toutes le
même `species_key` 2441022 : Bos taurus. On veut une case Vache, pas quatre.

C'est exactement ce que fait ce script : il lit le backbone, regroupe chaque nom
sur le `species_key` de son espèce acceptée, et écrit une case par espèce plus
une table d'alias qui ramène n'importe quel nom latin vers sa case.

Tout se fait hors ligne, en une seule passe sur le fichier : aucune requête vers
GBIF, sinon il faudrait 411 626 appels.

Usage :
    python -m outils.construit_dex \\
        --backbone ~/biodex/backbone_simple.txt.gz \\
        --catalogue ~/biodex/catalogue_vivant.pt
"""
import argparse
import gzip
import json
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db  # noqa: E402

# Colonnes du fichier `simple.txt` du backbone GBIF (30 colonnes, séparées par
# des tabulations, « \N » pour les valeurs nulles). Les indices sont vérifiés
# au démarrage par _controle_format() : si GBIF change son format, on plante
# avec un message clair plutôt que de produire un dex silencieusement faux.
C_ID = 0
C_SYNONYME = 3
C_STATUT = 4
C_RANG = 5
C_REGNE = 10
C_EMBRANCHEMENT = 11
C_CLASSE = 12
C_ORDRE = 13
C_FAMILLE = 14
C_GENRE = 15
C_ESPECE = 16
C_CANONIQUE = 19
NB_COLONNES = 30

# Clés de règne du backbone GBIF. Chaque règne a son catalogue, son moteur et
# ses cases : une photo de plante ne doit jamais atterrir dans une case animale.
REGNES = {"animaux": 1, "champignons": 5, "plantes": 6}

# Nom du règne tel qu'il est écrit dans la table `cases`.
ETIQUETTE = {"animaux": "animal", "champignons": "champignon", "plantes": "plante"}

# Les noms que le backbone ne reconnaît pas reçoivent une clé négative, propre à
# leur règne : sans ce décalage, l'orphelin nº 3 des plantes écraserait
# l'orphelin nº 3 des animaux, puisque `cle_gbif` est unique.
DECALAGE_ORPHELINS = {"animaux": 0, "champignons": 1_000_000, "plantes": 2_000_000}

RANGS_SUP = {"GENUS", "FAMILY", "ORDER", "CLASS", "PHYLUM"}

# Paliers de rareté, façon pokédex : lus sur le nombre d'observations GBIF
# agrégé de la case. Le canard colvert est à 33 millions d'observations, la
# grande majorité des espèces sont sous le millier.
PALIERS_RARETE = [(1_000_000, 1), (100_000, 2), (10_000, 3), (1_000, 4)]


def _cle(champ: str) -> int | None:
    return None if champ == "\\N" or not champ else int(champ)


def _controle_format(ligne: list[str]) -> None:
    if len(ligne) != NB_COLONNES:
        raise SystemExit(
            f"Backbone inattendu : {len(ligne)} colonnes au lieu de {NB_COLONNES}. "
            "Le format GBIF a dû changer, il faut réviser les indices en tête de ce script."
        )
    if ligne[C_RANG] not in {"SPECIES", "GENUS", "FAMILY", "ORDER", "CLASS", "PHYLUM",
                             "KINGDOM", "SUBSPECIES", "VARIETY", "FORM", "UNRANKED"}:
        raise SystemExit(f"Colonne de rang inattendue : {ligne[C_RANG]!r}.")
    if ligne[C_SYNONYME] not in {"t", "f"}:
        raise SystemExit(f"Colonne « est un synonyme » inattendue : {ligne[C_SYNONYME]!r}.")


# « Bos spec », « Larus indet » : des noms GBIF qui veulent dire « un bovin
# quelconque », « un goéland quelconque ». Ce ne sont pas des espèces, donc pas
# des cases à remplir, et le moteur les écarte aussi de son côté.
SUFFIXES_VAGUES = (" spec", " indet", " sp", " cf")


def charge_catalogue(chemin: pathlib.Path) -> dict[str, int]:
    """Renvoie {nom latin: nombre d'observations} depuis le catalogue encodé."""
    if chemin.suffix == ".json":
        brut = json.loads(chemin.read_text(encoding="utf-8"))
        tout = {e["nom"]: int(e.get("obs", 0)) for e in brut}
    else:
        import torch  # importé ici seulement : la lecture d'un .json n'en a pas besoin
        d = torch.load(chemin, weights_only=False)
        obs = d.get("obs") or [0] * len(d["noms"])
        tout = {n: int(o) for n, o in zip(d["noms"], obs)}

    retenus = {n: o for n, o in tout.items() if not n.endswith(SUFFIXES_VAGUES)}
    if len(retenus) < len(tout):
        print(f"  {len(tout) - len(retenus)} noms non spécifiques écartés", flush=True)
    return retenus


def scanne_backbone(chemin: pathlib.Path, cherches: set[str],
                    cle_regne: int) -> tuple[dict, dict, dict, dict]:
    """Une passe sur le backbone.

    Renvoie :
      vers_espece   {nom latin cherché: species_key}
      hierarchie    {species_key: (genre, famille, ordre, classe, embranchement)} en clés
      noms_especes  {species_key: nom canonique de l'espèce acceptée}
      noms_taxons   {clé: nom canonique} pour les genres, familles, ordres, classes
    """
    vers_espece: dict[str, int] = {}
    hierarchie: dict[int, tuple] = {}
    noms_especes: dict[int, str] = {}
    noms_taxons: dict[int, str] = {}

    ouvre = gzip.open if chemin.suffix == ".gz" else open
    t0 = time.perf_counter()
    controle = False
    with ouvre(chemin, "rt", encoding="utf-8", errors="replace") as f:
        for n, brut in enumerate(f):
            ligne = brut.rstrip("\n").split("\t")
            if not controle:
                _controle_format(ligne)
                controle = True
            # Un seul règne à la fois : le reste du fichier ne nous concerne
            # pas, et l'écarter tout de suite épargne l'essentiel du travail.
            if ligne[C_REGNE] != str(cle_regne):
                continue
            rang, canonique = ligne[C_RANG], ligne[C_CANONIQUE]
            if not canonique or canonique == "\\N":
                continue
            synonyme = ligne[C_SYNONYME] == "t"

            if not synonyme:
                if rang in RANGS_SUP:
                    noms_taxons.setdefault(int(ligne[C_ID]), canonique)
                elif rang == "SPECIES":
                    noms_especes.setdefault(int(ligne[C_ID]), canonique)

            if canonique in cherches:
                sk = _cle(ligne[C_ESPECE])
                if sk is None:
                    continue
                # Premier trouvé qui gagne : le backbone liste parfois plusieurs
                # homonymes, et l'ordre du fichier met l'accepté en premier.
                vers_espece.setdefault(canonique, sk)
                hierarchie.setdefault(sk, (
                    _cle(ligne[C_GENRE]), _cle(ligne[C_FAMILLE]), _cle(ligne[C_ORDRE]),
                    _cle(ligne[C_CLASSE]), _cle(ligne[C_EMBRANCHEMENT]),
                ))

            if n % 1_000_000 == 0 and n:
                print(f"  {n // 1_000_000} M lignes… {len(vers_espece)} noms reconnus "
                      f"({time.perf_counter() - t0:.0f} s)", flush=True)

    print(f"  terminé : {n + 1} lignes en {time.perf_counter() - t0:.0f} s", flush=True)
    return vers_espece, hierarchie, noms_especes, noms_taxons


def rarete(obs: int) -> int:
    for seuil, niveau in PALIERS_RARETE:
        if obs >= seuil:
            return niveau
    return 5


def construit(backbone: pathlib.Path, catalogue: pathlib.Path,
              noms_fr: pathlib.Path | None, regne: str,
              observations: pathlib.Path | None) -> None:
    etiquette = ETIQUETTE[regne]
    print(f"Règne : {etiquette}", flush=True)
    print(f"Catalogue : {catalogue}", flush=True)
    obs_par_nom = charge_catalogue(catalogue)
    print(f"  {len(obs_par_nom)} noms latins à regrouper", flush=True)

    # Les catalogues de flore ont été encodés sans compteur d'observations.
    # Sans lui, toutes les espèces tomberaient dans le palier « légendaire » et
    # la rareté ne voudrait plus rien dire : on les reprend du fichier récolté
    # séparément par outils/observations.py.
    if observations and observations.exists():
        comptes = json.loads(observations.read_text(encoding="utf-8"))
        repris = 0
        for nom in obs_par_nom:
            n = comptes.get(nom)
            if n:
                obs_par_nom[nom] = int(n)
                repris += 1
        print(f"  {repris} compteurs d'observations repris "
              f"({repris * 100 // max(len(obs_par_nom), 1)} % du catalogue)", flush=True)
    elif not any(obs_par_nom.values()):
        print("  ATTENTION : aucun compteur d'observations — toutes les cases "
              "seront classées au même palier de rareté.", flush=True)

    print(f"Backbone : {backbone}", flush=True)
    vers_espece, hierarchie, noms_especes, noms_taxons = scanne_backbone(
        backbone, set(obs_par_nom), REGNES[regne])
    print(f"  {len(noms_especes)} espèces acceptées dans ce règne, "
          f"{len(noms_taxons)} taxons supérieurs", flush=True)

    # ---- agrégation : un paquet de noms latins par species_key -------------
    paquets: dict[int, list[str]] = {}
    for nom in obs_par_nom:
        sk = vers_espece.get(nom)
        if sk is not None:
            paquets.setdefault(sk, []).append(nom)

    orphelins = [n for n in obs_par_nom if n not in vers_espece]
    print(f"  {len(paquets)} cases issues du backbone, "
          f"{len(orphelins)} noms sans correspondance", flush=True)

    fr = {}
    if noms_fr and noms_fr.exists():
        fr = {k: v for k, v in json.loads(noms_fr.read_text(encoding="utf-8")).items() if v}
        print(f"  {len(fr)} noms français repris du cache", flush=True)

    # ---- écriture ---------------------------------------------------------
    db.initialise()
    lignes_cases, lignes_alias = [], []

    for sk, noms in paquets.items():
        g, f_, o, c, p = hierarchie.get(sk, (None,) * 5)
        latin = noms_especes.get(sk)
        if latin is None:
            # L'espèce acceptée n'est pas elle-même dans le backbone animal
            # (cas rare) : on prend le plus observé de ses noms.
            latin = max(noms, key=lambda n: obs_par_nom[n])
        total = sum(obs_par_nom[n] for n in noms)
        lignes_cases.append((
            sk, etiquette, latin, fr.get(latin),
            noms_taxons.get(g, "") if g else "",
            noms_taxons.get(f_, "") if f_ else "",
            noms_taxons.get(o, "") if o else "",
            noms_taxons.get(c, "") if c else "",
            noms_taxons.get(p, "") if p else "",
            g, f_, o, c, total, rarete(total), len(noms),
        ))
        for n in noms:
            lignes_alias.append((n, sk, 1 if n == latin else 0))

    # Les orphelins gardent une case à eux, avec une clé négative pour ne pas
    # entrer en collision avec les clés GBIF. Sans ça, une photo classée sur un
    # de ces noms n'aurait aucune case où atterrir.
    decalage = DECALAGE_ORPHELINS[regne]
    for i, nom in enumerate(orphelins, 1):
        genre = nom.split(" ")[0]
        total = obs_par_nom[nom]
        cle = -(decalage + i)
        lignes_cases.append((cle, etiquette, nom, fr.get(nom), genre, "", "", "", "",
                             None, None, None, None, total, rarete(total), 1))
        lignes_alias.append((nom, cle, 1))

    print(f"Écriture de {len(lignes_cases)} cases et {len(lignes_alias)} alias…", flush=True)
    with db.transaction() as cx:
        # Seuls les alias de ce règne sont refaits : reconstruire les plantes ne
        # doit pas effacer les animaux déjà en place.
        cx.execute("""DELETE FROM alias WHERE case_id IN
                      (SELECT id FROM cases WHERE regne = ?)""", (etiquette,))
        # Les découvertes pointent vers les cases : on remplace en gardant les
        # identifiants, donc on ne touche pas aux clés étrangères existantes.
        cx.executemany(
            """INSERT INTO cases (cle_gbif, regne, latin, nom_fr, genre, famille, ordre,
                                  classe, embranchement, cle_genre, cle_famille,
                                  cle_ordre, cle_classe, obs, rarete, nb_alias)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(cle_gbif) DO UPDATE SET
                   regne=excluded.regne, latin=excluded.latin, nom_fr=COALESCE(cases.nom_fr, excluded.nom_fr),
                   genre=excluded.genre, famille=excluded.famille, ordre=excluded.ordre,
                   classe=excluded.classe, embranchement=excluded.embranchement,
                   cle_genre=excluded.cle_genre, cle_famille=excluded.cle_famille,
                   cle_ordre=excluded.cle_ordre, cle_classe=excluded.cle_classe,
                   obs=excluded.obs, rarete=excluded.rarete, nb_alias=excluded.nb_alias""",
            lignes_cases)
        cx.executemany(
            """INSERT INTO alias (latin, regne, case_id, accepte)
               SELECT ?, ?, id, ? FROM cases WHERE cle_gbif = ?""",
            [(nom, etiquette, acc, sk) for nom, sk, acc in lignes_alias])

    n_cases = db.valeur("SELECT COUNT(*) FROM cases WHERE regne = ?", (etiquette,), 0)
    n_alias = db.valeur("""SELECT COUNT(*) FROM alias WHERE case_id IN
                           (SELECT id FROM cases WHERE regne = ?)""", (etiquette,), 0)
    print(f"\nDex {etiquette} : {n_cases} cases pour {n_alias} noms latins.")
    for r in db.lit("SELECT regne, COUNT(*) n FROM cases GROUP BY regne ORDER BY n DESC"):
        print(f"  {r['regne']:<12} {r['n']:>7} cases")

    gros = db.lit("""SELECT latin, nom_fr, nb_alias, obs FROM cases
                     WHERE regne = ? ORDER BY nb_alias DESC LIMIT 8""", (etiquette,))
    print("\nLes cases qui regroupent le plus de noms :")
    for r in gros:
        print(f"  {r['latin']:<34} {r['nom_fr'] or '':<22} {r['nb_alias']:>4} noms")

    for r in db.lit("""SELECT rarete, COUNT(*) n FROM cases WHERE regne = ?
                       GROUP BY rarete ORDER BY rarete""", (etiquette,)):
        print(f"  rareté {r['rarete']} : {r['n']:>7} cases")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backbone", required=True, type=pathlib.Path,
                    help="simple.txt(.gz) du backbone GBIF")
    ap.add_argument("--catalogue", required=True, type=pathlib.Path,
                    help="catalogue_vivant.pt, ou un .json {nom, obs}")
    ap.add_argument("--noms-fr", type=pathlib.Path, default=None,
                    help="cache de noms vernaculaires à reprendre (noms_fr.json)")
    ap.add_argument("--regne", default="animaux", choices=sorted(REGNES),
                    help="quel règne construire (défaut : animaux)")
    ap.add_argument("--observations", type=pathlib.Path, default=None,
                    help="compteurs GBIF produits par outils/observations.py")
    a = ap.parse_args()

    for p in (a.backbone, a.catalogue):
        if not p.exists():
            raise SystemExit(f"Introuvable : {p}")

    config.prepare_dossiers()
    construit(a.backbone.expanduser(), a.catalogue.expanduser(),
              a.noms_fr.expanduser() if a.noms_fr else None, a.regne,
              a.observations.expanduser() if a.observations else None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
