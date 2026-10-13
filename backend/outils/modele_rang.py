#!/usr/bin/env python3
"""
Réduit un modèle 3D pour qu'il tienne dans l'APK.

Ce qui sort d'un générateur comme Meshy pèse 131 Mo : trois millions de faces
et des textures en 4096². C'est fait pour un rendu de cinéma, pas pour une
vignette de deux cent cinquante pixels sur un téléphone. Tel quel, cinquante
rangs feraient six gigaoctets.

Après passage : **548 Ko**, dix mille triangles, textures en 1024². Deux cent
quarante fois moins, sans différence visible à la taille où on le regarde.

Trois décisions, dont une contre-intuitive.

**On garde les trois textures.** La tentation est de jeter la carte de normales
et la carte métallique-rugosité, qui ne servent qu'à l'éclairage. Mesuré :
elles ne pèsent que 24 Ko des 548 une fois en WebP, et c'est précisément ce qui
empêche l'objet d'avoir l'air d'un autocollant quand il tourne.

**On ne compresse pas la géométrie.** `--compress meshopt` ferait tomber le
fichier à 202 Ko, mais un maillage meshopt réclame un décodeur au chargement,
et `model-viewer` va le chercher là où on le lui dit — un CDN par défaut. Un
badge qui ne s'affiche qu'avec du réseau serait absurde : on paie 346 Ko pour
n'avoir à demander la permission de personne.

**La simplification est bornée par l'erreur, pas par un nombre de faces.**
`--simplify-error 0.001` laisse l'outil retirer ce qu'il peut tant que la
silhouette ne bouge pas. Un objet anguleux garde ses arêtes, une boule fond :
c'est ce qu'on veut quand les cinquante modèles n'auront pas la même forme.

Demande `npx`, qui va chercher `@gltf-transform/cli` au premier appel.

Usage :
    python -m outils.modele_rang \\
        --source ~/Téléchargements/Meshy_AI_Party_Frog_…glb --nom grenouille
"""
import argparse
import json
import pathlib
import shutil
import struct
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

DESTINATION = (pathlib.Path(__file__).resolve().parent.parent.parent
               / "app" / "assets" / "modeles")

# Au-delà, le fichier ne rentre plus dans un APK qu'on veut garder raisonnable
# quand il y aura cinquante rangs. C'est un garde-fou, pas une cible.
PLAFOND_MO = 2.0


def _inspecte(chemin: pathlib.Path) -> dict:
    """Lit l'entête glTF sans dépendance : nombre de mailles et de textures."""
    d = chemin.read_bytes()
    if d[:4] != b"glTF":
        raise SystemExit(f"{chemin.name} n'est pas un GLB.")
    off, js = 12, None
    while off < len(d) and js is None:
        clen, ctype = struct.unpack("<I4s", d[off:off + 8])
        if ctype == b"JSON":
            js = json.loads(d[off + 8:off + 8 + clen])
        off += 8 + clen
    return js or {}


def prepare(source: pathlib.Path, destination: pathlib.Path,
            taille_texture: int, erreur: float) -> int:
    if not source.exists():
        raise SystemExit(f"Introuvable : {source}")
    if shutil.which("npx") is None:
        raise SystemExit(
            "npx est absent — il fournit @gltf-transform/cli.\n"
            "  Installez Node, ou passez le modèle sur gltf.report à la main.")

    destination.parent.mkdir(parents=True, exist_ok=True)
    avant = _inspecte(source)
    cmd = [
        "npx", "--yes", "@gltf-transform/cli@latest", "optimize",
        str(source), str(destination),
        "--texture-size", str(taille_texture),
        "--texture-compress", "webp",
        "--simplify-error", str(erreur),
        # Voir l'entête : pas de décodeur à aller chercher sur le réseau.
        "--compress", "false",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not destination.exists():
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit("gltf-transform a échoué.")

    apres = _inspecte(destination)
    mo_avant = source.stat().st_size / 2 ** 20
    mo_apres = destination.stat().st_size / 2 ** 20

    def primitives(js):
        # Le compte exact des faces demanderait de lire les accesseurs ; le
        # nombre de mailles et de primitives suffit à voir qu'on n'a pas tout
        # perdu en route.
        return sum(len(m.get("primitives", [])) for m in js.get("meshes", []))

    print(f"{source.name}\n  → {destination}")
    print(f"  {mo_avant:.2f} Mo → {mo_apres:.2f} Mo "
          f"({mo_avant / max(mo_apres, 0.001):.0f}× plus léger)")
    print(f"  mailles {len(avant.get('meshes', []))} → "
          f"{len(apres.get('meshes', []))}, "
          f"primitives {primitives(avant)} → {primitives(apres)}")
    print(f"  textures {len(avant.get('images', []))} → "
          f"{len(apres.get('images', []))}, ramenées à {taille_texture}²")

    if not apres.get("meshes"):
        raise SystemExit("Le résultat n'a plus de maillage — modèle inutilisable.")
    if not apres.get("images"):
        print("  !! plus aucune texture : l'objet sortira en gris uni")
    if mo_apres > PLAFOND_MO:
        print(f"  !! au-dessus de {PLAFOND_MO} Mo — baissez --taille-texture "
              f"ou montez --erreur")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", type=pathlib.Path, required=True)
    ap.add_argument("--nom", default=None,
                    help="nom du fichier produit, sans extension")
    ap.add_argument("--destination", type=pathlib.Path, default=None)
    ap.add_argument("--taille-texture", type=int, default=1024)
    ap.add_argument("--erreur", type=float, default=0.001,
                    help="tolérance de simplification ; plus haut = plus léger")
    a = ap.parse_args()

    if a.destination is not None:
        sortie = a.destination.expanduser()
    else:
        nom = a.nom or a.source.stem
        sortie = DESTINATION / f"{nom}.glb"
    return prepare(a.source.expanduser(), sortie, a.taille_texture, a.erreur)


if __name__ == "__main__":
    raise SystemExit(main())
