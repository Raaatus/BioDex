#!/usr/bin/env python3
"""
Traduit le shader du cristal pour le navigateur.

Le même effet doit tourner dans l'application et sur le site. Écrire deux fois
le même lancer de rayon serait garantir qu'ils divergent : on corrigerait une
facette d'un côté sans y penser de l'autre, et six mois plus tard personne ne
saurait laquelle fait foi.

Il n'y a donc qu'une source — `app/assets/shaders/cristal.frag` — et cet outil
en tire la copie web. Le corps est recopié à l'octet près ; seul l'en-tête
change, parce que Flutter et WebGL ne nomment pas les mêmes choses :

    #version 460 core                       →  #version 300 es
    #include <flutter/runtime_effect.glsl>  →  (supprimé)
    FlutterFragCoord()                      →  gl_FragCoord

`--verifie` ne réécrit rien et signale si la copie a pris du retard sur
l'original — de quoi le voir avant que ça se voie à l'écran.

Usage :
    python -m outils.shader_web
    python -m outils.shader_web --verifie
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys

RACINE = pathlib.Path(__file__).resolve().parent.parent.parent
SOURCE = RACINE / "app" / "assets" / "shaders" / "cristal.frag"
SORTIE = RACINE / "backend" / "web" / "media" / "cristal.frag"

ENTETE = """// ─────────────────────────────────────────────────────────────────────────
// COPIE MÉCANIQUE de app/assets/shaders/cristal.frag — ne pas modifier ici.
//
// Le corps est rigoureusement identique : la gemme lancée au rayon, ses
// fissures de Voronoï, ses éclats. Seul l'en-tête diffère, Flutter et WebGL ne
// nommant pas les mêmes choses.
//
// Pour la régénérer après une retouche du shader Flutter :
//     python -m outils.shader_web
// ─────────────────────────────────────────────────────────────────────────
"""


def traduit(source: str) -> str:
    """Le shader Flutter, tel que WebGL l'accepte."""
    t = source.replace("#version 460 core", "#version 300 es", 1)
    t = re.sub(r"#include <flutter/runtime_effect\.glsl>\n", "", t, count=1)
    t = t.replace("FlutterFragCoord()", "gl_FragCoord")
    # La directive de version doit rester la toute première ligne du fichier :
    # le compilateur GLSL refuse quoi que ce soit avant elle, y compris un
    # commentaire.
    lignes = t.split("\n")
    return lignes[0] + "\n" + ENTETE + "\n".join(lignes[1:])


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verifie", action="store_true",
                    help="signaler une copie périmée, sans rien réécrire")
    a = ap.parse_args()

    if not SOURCE.exists():
        raise SystemExit(f"Introuvable : {SOURCE}")
    attendu = traduit(SOURCE.read_text())

    if a.verifie:
        if not SORTIE.exists():
            print("!! la copie web n'existe pas")
            return 1
        if SORTIE.read_text() != attendu:
            print("!! la copie web a pris du retard sur le shader Flutter")
            return 1
        print("La copie web est à jour.")
        return 0

    SORTIE.parent.mkdir(parents=True, exist_ok=True)
    SORTIE.write_text(attendu)
    print(f"{SORTIE.relative_to(RACINE)} — {len(attendu)} octets")

    # Un shader qui ne compile pas ne se voit qu'à l'exécution, dans une
    # console de navigateur que personne n'ouvre. Autant le savoir ici.
    if shutil.which("glslangValidator"):
        r = subprocess.run(["glslangValidator", "-S", "frag", str(SORTIE)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(r.stdout + r.stderr)
            raise SystemExit("Le shader traduit ne compile pas.")
        print("Compilation vérifiée.")
    else:
        print("glslangValidator absent : compilation non vérifiée.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
