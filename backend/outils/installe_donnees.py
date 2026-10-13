#!/usr/bin/env python3
"""
Installe le pack de données depuis une release GitHub (ou n'importe quelle
adresse qui sert les mêmes fichiers).

Le pack, c'est tout ce qui ne vit pas dans le dépôt : la base du dex (le
référentiel des espèces, sans aucun joueur), les catalogues encodés par règne,
les poids de MegaDetector, les silhouettes. Le manifeste
`backend/donnees.manifeste.json` en donne la liste, les tailles et les
empreintes SHA-256 ; ce script télécharge chaque fichier, vérifie l'empreinte,
et le pose au bon endroit dans `donnees/` (ou `BIODEX_DONNEES`).

    .venv/bin/python outils/installe_donnees.py https://github.com/COMPTE/biodex/releases/download/donnees-v1

Relancé, il ne retélécharge que ce qui manque ou dont l'empreinte diffère. La
base `biodex-dex.sqlite` devient `biodex.sqlite` **seulement si aucune base
n'existe encore** : on n'écrase jamais une base qui contient des joueurs.
"""
import hashlib
import json
import pathlib
import shutil
import sys
import tarfile
import urllib.error
import urllib.request

ICI = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ICI))
from biodex import config  # noqa: E402


def empreinte(p: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for bloc in iter(lambda: fh.read(1 << 20), b""):
            h.update(bloc)
    return h.hexdigest()


def telecharge(url: str, cible: pathlib.Path, octets: int) -> None:
    cible.parent.mkdir(parents=True, exist_ok=True)
    tmp = cible.with_suffix(cible.suffix + ".part")
    with urllib.request.urlopen(url) as r, open(tmp, "wb") as fh:
        lu = 0
        for bloc in iter(lambda: r.read(1 << 20), b""):
            fh.write(bloc)
            lu += len(bloc)
            print(f"\r  {cible.name}: {lu / 1e6:.0f} / {octets / 1e6:.0f} Mo", end="", flush=True)
    print()
    tmp.replace(cible)


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    base = sys.argv[1].rstrip("/")
    manifeste = json.loads((ICI / "donnees.manifeste.json").read_text(encoding="utf-8"))
    donnees = config.DONNEES
    donnees.mkdir(parents=True, exist_ok=True)
    print(f"Données dans {donnees}")

    for entree in manifeste["fichiers"]:
        nom = entree["fichier"]
        cible = donnees / nom
        if cible.exists() and empreinte(cible) == entree["sha256"]:
            print(f"  {nom}: déjà là")
            continue
        # Une release GitHub sert ses fichiers à plat ; un miroir peut garder
        # l'arborescence du pack. On essaie le chemin complet, puis le nom seul.
        try:
            telecharge(f"{base}/{nom}", cible, entree["octets"])
        except urllib.error.HTTPError:
            telecharge(f"{base}/{pathlib.Path(nom).name}", cible, entree["octets"])
        if empreinte(cible) != entree["sha256"]:
            cible.unlink()
            sys.exit(f"Empreinte inattendue pour {nom} : téléchargement corrompu ou pack différent.")

    # Les archives se déplient sur place.
    for archive in ("silhouettes.tar", "sources-dex.tar"):
        p = donnees / archive
        if p.exists():
            with tarfile.open(p) as t:
                t.extractall(donnees, filter="data")
            print(f"  {archive}: déplié")

    # La base du dex, seulement s'il n'y en a pas.
    dex = donnees / "biodex-dex.sqlite"
    if dex.exists() and not config.BASE.exists():
        shutil.copy(dex, config.BASE)
        print(f"  base créée : {config.BASE}")
    elif config.BASE.exists():
        print(f"  base existante conservée : {config.BASE}")
    print("Terminé.")


if __name__ == "__main__":
    main()
