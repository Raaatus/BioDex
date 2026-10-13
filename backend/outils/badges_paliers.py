#!/usr/bin/env python3
"""
Prépare les illustrations des cinquante rangs pour l'application.

Les images fournies font 1024 × 1024 et pèsent 1,7 Mo pièce, soit 44 Mo pour
la série. Elles s'affichent à quarante-cinq pixels de côté dans le bandeau du
dex : les servir telles quelles ferait télécharger mille fois ce qui est
nécessaire, sur un réseau mobile qui plus est.

Trois traitements, dans cet ordre :

  rognage        les illustrations flottent au milieu d'une large marge
                 blanche ; on la retire pour que le sujet remplisse la
                 vignette, sans toucher aux cadres dessinés ;
  mise au carré  ce qui reste est recentré sur un carré blanc, pour que tous
                 les badges s'alignent quelle que soit la forme du sujet ;
  réduction      deux tailles, l'une pour les listes, l'autre pour l'écran des
                 rangs, en PNG optimisé.

    python -m outils.badges_paliers --source ~/Projects/Biodex/palier
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config  # noqa: E402

# Les tailles servies. 256 couvre l'affichage courant même sur un écran à
# trois fois la densité ; 512 sert l'écran des rangs et les futurs agrandis.
TAILLES = (256, 512)

# Au-delà de ce seuil, un pixel est considéré comme du fond. Les illustrations
# ont des blancs cassés sur les bords, un seuil strict ne rognerait rien.
SEUIL_FOND = 246


def boite_du_sujet(img):
    """La boîte englobante de ce qui n'est pas du fond blanc."""
    from PIL import Image, ImageChops

    fond = Image.new("RGB", img.size, (255, 255, 255))
    ecart = ImageChops.difference(img.convert("RGB"), fond).convert("L")
    # Un point() plutôt qu'un seuil global : les dégradés très clairs comptent
    # comme du sujet dès qu'ils se distinguent du blanc.
    masque = ecart.point(lambda v: 255 if v > 255 - SEUIL_FOND else 0)
    return masque.getbbox()


def prepare(source: pathlib.Path, destination: pathlib.Path) -> None:
    from PIL import Image

    destination.mkdir(parents=True, exist_ok=True)
    total_avant = total_apres = 0
    traites = 0

    for rang in range(1, 51):
        entree = source / f"{rang}.png"
        if not entree.exists():
            print(f"  !! rang {rang} : {entree.name} introuvable", flush=True)
            continue
        total_avant += entree.stat().st_size

        with Image.open(entree) as brut:
            img = brut.convert("RGBA")
            # Les images ont un canal alpha mais un fond blanc opaque : on
            # aplatit sur du blanc avant de chercher la boîte, sinon la
            # transparence fausse la mesure.
            plat = Image.new("RGBA", img.size, (255, 255, 255, 255))
            plat.alpha_composite(img)
            plat = plat.convert("RGB")

            boite = boite_du_sujet(plat)
            if boite:
                # Une marge de deux pour cent : coller au sujet donne une
                # vignette étouffée, et le cadre dessiné doit respirer.
                marge = int(max(plat.size) * 0.02)
                g, h, d, b = boite
                boite = (max(0, g - marge), max(0, h - marge),
                         min(plat.width, d + marge), min(plat.height, b + marge))
                plat = plat.crop(boite)

            # Recentrage sur un carré : les sujets hauts et les sujets larges
            # doivent occuper la même place dans la liste.
            cote = max(plat.size)
            carre = Image.new("RGB", (cote, cote), (255, 255, 255))
            carre.paste(plat, ((cote - plat.width) // 2,
                               (cote - plat.height) // 2))

            for taille in TAILLES:
                petit = carre.resize((taille, taille), Image.LANCZOS)
                sortie = destination / f"{rang:02d}-{taille}.png"
                petit.save(sortie, "PNG", optimize=True)
                total_apres += sortie.stat().st_size
        traites += 1

    print(f"{traites} rangs préparés dans {destination}")
    print(f"  avant : {total_avant / 2**20:.0f} Mo")
    print(f"  après : {total_apres / 2**20:.1f} Mo pour {len(TAILLES)} tailles "
          f"({total_apres / max(total_avant, 1):.1%} du poids d'origine)")
    for taille in TAILLES:
        poids = sum(f.stat().st_size
                    for f in destination.glob(f"*-{taille}.png"))
        print(f"  {taille:>4} px : {poids / 1024:.0f} Ko au total, "
              f"{poids // max(traites, 1) // 1024} Ko par badge")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", type=pathlib.Path, required=True)
    ap.add_argument("--destination", type=pathlib.Path,
                    default=config.SILHOUETTES / "badges")
    a = ap.parse_args()
    if not a.source.exists():
        raise SystemExit(f"Introuvable : {a.source}")
    prepare(a.source.expanduser(), a.destination.expanduser())
    return 0


if __name__ == "__main__":
    sys.exit(main())
