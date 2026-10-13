#!/usr/bin/env python3
"""
Distribue les dictionnaires de traduction aux trois composants.

La source est `i18n/<code>.json` : un objet dont les clés sont les textes
français tels qu'ils apparaissent dans le code, et les valeurs leur
traduction. Ce script en tire :

    backend/web/lang/<code>.json   et   backend/web/lang/<code>.js
    backend/biodex/lang/<code>.json
    app/assets/lang/<code>.json

Lancer après chaque modification d'un dictionnaire :

    python3 i18n/genere.py

Avec `--manquantes <code>`, il liste les textes du code qui n'ont pas encore
de traduction dans cette langue (voir `i18n/extrait.py` pour la liste des
clés).
"""
import json
import pathlib
import sys

RACINE = pathlib.Path(__file__).resolve().parent.parent
SOURCE = RACINE / "i18n"
CIBLES = [
    RACINE / "backend" / "web" / "lang",
    RACINE / "backend" / "biodex" / "lang",
    RACINE / "app" / "assets" / "lang",
]


def main() -> None:
    for fichier in sorted(SOURCE.glob("*.json")):
        code = fichier.stem
        if code == "cles":          # la liste des textes du code, pas une langue
            continue
        dico = json.loads(fichier.read_text(encoding="utf-8"))
        if not isinstance(dico, dict):
            sys.exit(f"{fichier}: un objet JSON est attendu")
        compact = json.dumps(dico, ensure_ascii=False, separators=(",", ":"))
        for cible in CIBLES:
            cible.mkdir(parents=True, exist_ok=True)
            (cible / f"{code}.json").write_text(compact, encoding="utf-8")
        # Le site charge un script synchrone : le même objet, affecté.
        (CIBLES[0] / f"{code}.js").write_text(
            f"window.BIODEX_DICO = {compact};\n", encoding="utf-8")
        print(f"{code}: {len(dico)} textes")

    if "--manquantes" in sys.argv:
        code = sys.argv[sys.argv.index("--manquantes") + 1]
        dico = json.loads((SOURCE / f"{code}.json").read_text(encoding="utf-8"))
        cles = json.loads((SOURCE / "cles.json").read_text(encoding="utf-8"))
        manquantes = [k for k in cles if k not in dico]
        print(f"{len(manquantes)} textes sans traduction en {code}")
        for k in manquantes:
            print("  ", k)


if __name__ == "__main__":
    main()
