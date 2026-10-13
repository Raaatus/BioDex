#!/usr/bin/env python3
"""
Prépare l'animation de chargement : une planche d'images, pas un GIF.

Le GIF ne tournait pas dans l'application. Le fichier n'y était pour rien —
vérifié au niveau des octets : 45 images, 45 blocs de contrôle, délai de 100 ms,
disposal 2, tout ce qu'il faut. C'est le décodeur d'images animées de Flutter
qui refusait de l'animer, et diagnostiquer son humeur aurait coûté plus cher que
de s'en passer.

On produit donc une **planche de tuiles** : toutes les images côte à côte dans
un seul fichier. L'application en dessine une à la fois, cadencée par un
`AnimationController` qu'elle contrôle. Plus de décodeur animé dans la boucle,
donc plus de « ça ne tourne pas » — et un test peut vérifier que l'indice de
tuile avance, ce qu'aucun test ne pouvait faire sur un GIF.

Accessoirement, c'est plus léger : 181 Ko contre 646.

    origine   540 × 540, 90 images, 3,28 Mo
    planche   6 × 5 tuiles de 180 px, 30 images, 181 Ko

Trente images pour un tour : à cette taille le pas est de douze degrés, ce qui
passe pour continu. À vingt-quatre, on voit le personnage sauter.

Usage :
    python -m outils.anim_chargement --source ~/.cache/k3d-model.gif
"""
import argparse
import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

DESTINATION = (pathlib.Path(__file__).resolve().parent.parent.parent
               / "app" / "assets" / "animations" / "chargement.webp")

IMAGES = 30
TUILE = 180


def prepare(source: pathlib.Path, destination: pathlib.Path,
            images: int, tuile: int) -> int:
    from PIL import Image, ImageSequence

    if not source.exists():
        raise SystemExit(f"Introuvable : {source}")

    src = Image.open(source)
    total = getattr(src, "n_frames", 1)
    if total < images:
        raise SystemExit(
            f"{source.name} n'a que {total} images, il en faut {images}.")

    # On échantillonne sur toute la durée plutôt que de prendre les N
    # premières : un tour complet doit rester un tour complet, sinon le
    # personnage revient en arrière d'un coup à la fin de la boucle.
    brutes = [f.convert("RGBA") for f in ImageSequence.Iterator(src)]
    choisies = [brutes[round(i * total / images)] for i in range(images)]

    colonnes = math.ceil(math.sqrt(images))
    lignes = math.ceil(images / colonnes)
    planche = Image.new("RGBA", (colonnes * tuile, lignes * tuile), (0, 0, 0, 0))
    for i, f in enumerate(choisies):
        planche.paste(f.resize((tuile, tuile), Image.LANCZOS),
                      ((i % colonnes) * tuile, (i // colonnes) * tuile))

    destination.parent.mkdir(parents=True, exist_ok=True)
    # WebP plutôt que PNG : la transparence est conservée et la planche pèse
    # trois fois moins. `method=6` est le plus lent à l'encodage, ce qui est
    # sans importance pour un fichier qu'on produit une fois.
    planche.save(destination, "WEBP", quality=88, method=6)

    avant = source.stat().st_size / 2 ** 20
    apres = destination.stat().st_size / 1024
    print(f"{source.name} → {destination}")
    print(f"  {src.size[0]}×{src.size[1]}, {total} images, {avant:.2f} Mo")
    print(f"  planche {colonnes}×{lignes} tuiles de {tuile} px, "
          f"{images} images, {apres:.0f} Ko")
    print()
    print(f"  À reporter dans lib/widgets/chargement.dart si vous changez "
          f"ces valeurs :")
    print(f"    _images = {images}   _colonnes = {colonnes}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", type=pathlib.Path, required=True)
    ap.add_argument("--destination", type=pathlib.Path, default=DESTINATION)
    ap.add_argument("--images", type=int, default=IMAGES)
    ap.add_argument("--tuile", type=int, default=TUILE)
    a = ap.parse_args()
    return prepare(a.source.expanduser(), a.destination.expanduser(),
                   a.images, a.tuile)


if __name__ == "__main__":
    raise SystemExit(main())
