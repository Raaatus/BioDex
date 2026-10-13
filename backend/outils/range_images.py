#!/usr/bin/env python3
"""
Range les images d'une installation ancienne dans l'arborescence courante.

Avant : trois dossiers plats — `photos/`, `vignettes/`, `decoupes/` — et des
découpes en PNG. Maintenant : `photos/<joueur>/<AAAA-MM>/<nom>.jpg`, pareil
pour les vignettes et les découpes, et les découpes en WebP (cinq fois plus
légères, même transparence).

    .venv/bin/python outils/range_images.py            # fait le travail
    .venv/bin/python outils/range_images.py --essai    # dit ce qu'il ferait
    .venv/bin/python outils/range_images.py --annule   # remet comme avant

**Services arrêtés.** Le script déplace des fichiers et réécrit la base dans
une seule transaction : si le serveur écrit pendant ce temps, l'un des deux a
tort. Il refuse de partir si la base est verrouillée.

Chaque déplacement est noté dans `donnees/range_images.journal.json` ; c'est
ce journal que `--annule` rejoue à l'envers. Une découpe convertie en WebP est
reconvertie en PNG au retour — à la qualité du WebP, pas à celle du PNG
d'origine, qui n'est pas gardé.

Relancer le script sur une installation déjà rangée ne fait rien : un chemin
qui contient déjà un dossier est laissé tel quel.
"""
import argparse
import json
import pathlib
import sqlite3
import sys

ICI = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ICI))
from biodex import config, images  # noqa: E402

JOURNAL = config.DONNEES / "range_images.journal.json"
COLONNES = ("fichier", "vignette", "fichier_analyse", "decoupe")
DOSSIERS = {"fichier": config.PHOTOS, "vignette": config.VIGNETTES,
            "fichier_analyse": config.PHOTOS, "decoupe": config.DECOUPES}


def plan(cx: sqlite3.Connection) -> list[dict]:
    """Ce qu'il y a à déplacer, ligne par ligne, sans rien toucher."""
    etapes = []
    for r in cx.execute("SELECT id, utilisateur, cree_le, fichier, vignette, fichier_analyse, decoupe FROM captures"):
        sous = f"{r['utilisateur']}/{(r['cree_le'] or '0000-00')[:7]}"
        nouveau = {}
        for col in COLONNES:
            v = r[col]
            if not v or "/" in v:
                continue
            cible = f"{sous}/{v}"
            if col == "decoupe" and v.lower().endswith(".png"):
                cible = images.nom_decoupe(cible)
            nouveau[col] = cible
        if nouveau:
            etapes.append({"id": r["id"], "avant": {c: r[c] for c in nouveau}, "apres": nouveau})
    return etapes


def deplace(source: pathlib.Path, cible: pathlib.Path, essai: bool) -> None:
    if essai or not source.exists():
        return
    cible.parent.mkdir(parents=True, exist_ok=True)
    if source.suffix.lower() == ".png" and cible.suffix.lower() == ".webp":
        from PIL import Image
        with Image.open(source) as img:
            img.save(cible, "WEBP", quality=86, method=6)
        source.unlink()
    elif source.suffix.lower() == ".webp" and cible.suffix.lower() == ".png":
        from PIL import Image
        with Image.open(source) as img:
            img.save(cible, "PNG", optimize=True)
        source.unlink()
    else:
        source.replace(cible)


def applique(cx: sqlite3.Connection, etapes: list[dict], sens: str, essai: bool) -> int:
    """`sens` : 'apres' pour ranger, 'avant' pour défaire."""
    de, vers = ("avant", "apres") if sens == "apres" else ("apres", "avant")
    n = 0
    for e in etapes:
        for col, cible in e[vers].items():
            source = e[de][col]
            deplace(DOSSIERS[col] / source, DOSSIERS[col] / cible, essai)
            n += 1
        if not essai:
            cx.execute(f"UPDATE captures SET {', '.join(f'{c} = ?' for c in e[vers])} WHERE id = ?",
                       [*e[vers].values(), e["id"]])
    return n


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--essai", action="store_true", help="n'écrit rien, dit ce qui serait fait")
    ap.add_argument("--annule", action="store_true", help="rejoue le journal à l'envers")
    args = ap.parse_args()

    cx = sqlite3.connect(config.BASE, timeout=1)
    cx.row_factory = sqlite3.Row
    try:
        cx.execute("BEGIN IMMEDIATE")
    except sqlite3.OperationalError as e:
        sys.exit(f"La base est verrouillée ({e}) : arrêtez le serveur d'abord.")

    if args.annule:
        if not JOURNAL.exists():
            sys.exit("Aucun journal : rien à annuler.")
        etapes = json.loads(JOURNAL.read_text(encoding="utf-8"))
        n = applique(cx, etapes, "avant", args.essai)
        if args.essai:
            cx.rollback()
            print(f"{n} fichiers reviendraient à plat (essai).")
            return
        cx.commit()
        JOURNAL.unlink()
        print(f"{n} fichiers remis à plat, découpes reconverties en PNG.")
        return

    etapes = plan(cx)
    if not etapes:
        cx.rollback()
        print("Rien à ranger : tout est déjà dans l'arborescence courante.")
        return
    if args.essai:
        cx.rollback()
        for e in etapes[:8]:
            for c, v in e["apres"].items():
                print(f"  {c}: {e['avant'][c]}  →  {v}")
        print(f"… {sum(len(e['apres']) for e in etapes)} fichiers sur {len(etapes)} captures (essai, rien n'a bougé).")
        return

    JOURNAL.write_text(json.dumps(etapes, ensure_ascii=False, indent=0), encoding="utf-8")
    n = applique(cx, etapes, "apres", False)
    cx.commit()
    # Le cache des miniatures se refait tout seul ; vidé, il ne pointera pas
    # vers des PNG qui n'existent plus.
    for f in (config.DONNEES / "miniatures").rglob("*"):
        if f.is_file():
            f.unlink()
    print(f"{n} fichiers rangés sur {len(etapes)} captures. Journal : {JOURNAL}")


if __name__ == "__main__":
    main()
