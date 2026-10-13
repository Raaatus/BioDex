#!/usr/bin/env python3
"""
La couleur de chaque grenouille, et celle de ses fissures.

Le cristal d'un succès prenait sa teinte de la difficulté : trois couleurs pour
trente récompenses. C'était une information que le joueur a déjà — elle est
écrite sur la tuile — et ça rendait vingt-neuf gemmes interchangeables.

Ici la gemme prend la couleur de ce qu'elle enferme. La grenouille festive est
verte avec un chapeau rose : cristal vert, fissures roses. On sait ce qu'on va
ouvrir avant de l'ouvrir, et chaque succès a sa gemme.

**Comment.** On lit les planches de rotation — vingt-quatre angles, pas un seul
aperçu de face : un chapeau vu de dos échapperait à une vue unique. Les pixels
transparents, les ombres et les reflets sont écartés, puis les teintes restantes
tombent dans vingt-quatre bandes de quinze degrés, pondérées par leur saturation.

  corps   la bande la plus lourde ;
  accent  la bande la plus éloignée en teinte qui pèse encore quelque chose —
          pondérée par cet écart, sinon un vert voisin du vert du corps
          l'emporterait sur un rose franc plus discret.

**Pourquoi on ne garde pas les couleurs telles quelles.** Le rendu est ombré :
les teintes sortent justes mais très sombres, entre 10 % et 40 % de luminosité.
Une gemme peinte avec ça serait un caillou. On ne garde donc que la teinte, et
on impose une saturation et une luminosité de cristal — lumineux sans être
criard pour le corps, franchement lumineux pour la lumière qui fuit des
fissures.

**Quand aucun accent ne se détache** — une grenouille d'une seule couleur —
on prend la complémentaire du corps. C'est ce qui donne le meilleur contraste,
et ça se lit comme un choix plutôt que comme un défaut.

Usage :
    python -m outils.couleurs_succes              # écrit le fichier
    python -m outils.couleurs_succes --montre     # planche de contrôle
"""
import argparse
import colorsys
import json
import pathlib
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from outils.modeles_succes import MODELES, TABLE  # noqa: E402

SORTIE = pathlib.Path(__file__).resolve().parent.parent / "biodex" / "couleurs_succes.json"

BANDES = 24          # bandes de teinte, 15° chacune
ECART_MIN = 4        # 60° : en deçà, deux teintes se confondent sur une gemme

# Les valeurs de cristal. Le corps reste tenu — au-delà, la gemme devient un
# bonbon et on ne voit plus les facettes. Les fissures sont poussées : c'est
# de la lumière qui sort, elle doit surexposer.
CORPS_S = (0.34, 0.60)
CORPS_V = 0.90
FISSURE_S = (0.55, 0.85)
FISSURE_V = 1.00


def _hsv_des_pixels(nom: str):
    """Les teintes utiles d'un modèle, en HSV, une ligne par pixel retenu."""
    chemin = MODELES / f"{nom}_tour.webp"
    a = np.asarray(Image.open(chemin).convert("RGBA"), dtype=np.float32) / 255
    px = a[a[..., 3] > 0.78][:, :3]
    if not len(px):
        return np.zeros((0, 3), dtype=np.float32)

    mx, mn = px.max(1), px.min(1)
    s = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
    # Ni les ombres ni les reflets spéculaires ne disent la couleur de l'objet.
    garde = (mx > 0.18) & (mx < 0.97) & (s > 0.22)
    if not garde.any():
        return np.zeros((0, 3), dtype=np.float32)
    return np.array([colorsys.rgb_to_hsv(*p) for p in px[garde]], dtype=np.float32)


def _serre(x, bornes):
    return max(bornes[0], min(bornes[1], x))


def couleurs(nom: str) -> dict:
    """Le couple (corps, fissure) d'un modèle, en hexadécimal."""
    hsv = _hsv_des_pixels(nom)
    if not len(hsv):
        # Rien d'exploitable : un bleu de cristal neutre vaut mieux qu'un gris.
        return {"corps": "#7fc7ff", "fissure": "#ffd27f", "sur": 0.0}

    bandes = (hsv[:, 0] * BANDES).astype(int) % BANDES
    poids = np.bincount(bandes, weights=hsv[:, 1], minlength=BANDES)

    # On lisse avant de choisir, sur trois bandes voisines et en circulaire.
    #
    # Sans ça, une couleur large perd contre une couleur étroite : le vert d'une
    # grenouille s'étale sur quarante-cinq degrés, un accent orange tient sur
    # quinze, et l'orange l'emportait alors qu'il couvre quatre fois moins de
    # surface. L'entomologiste en est sorti orange, ce qu'il n'est pas.
    lisse = poids + 0.6 * (np.roll(poids, 1) + np.roll(poids, -1))
    dom = int(lisse.argmax())

    def teinte_moyenne(b: int):
        """La teinte d'une bande, moyennée sur le même voisinage que le lissage.

        Sur la bande seule, deux ennuis : le lissage peut désigner une bande
        vide qui n'a fait qu'emprunter le poids de ses voisines — la moyenne y
        vaut alors NaN — et une couleur étalée serait résumée par la tranche de
        quinze degrés où elle culmine plutôt que par son centre.
        """
        m = np.isin(bandes, [(b - 1) % BANDES, b, (b + 1) % BANDES])
        if not m.any():
            return 0.0, 0.0, 0
        # Moyenne circulaire : à cheval sur le rouge, 359° et 1° ne font pas 180°.
        angles = hsv[m, 0] * 2 * np.pi
        h = (np.arctan2(np.sin(angles).mean(), np.cos(angles).mean())
             / (2 * np.pi)) % 1.0
        return float(h), float(hsv[m, 1].mean()), int(m.sum())

    h_corps, s_corps, n_corps = teinte_moyenne(dom)

    ecarts = np.minimum(abs(np.arange(BANDES) - dom), BANDES - abs(np.arange(BANDES) - dom))
    note = lisse * (ecarts >= ECART_MIN) * ecarts
    h_fis = s_fis = None
    source = "complément"
    if note.max() > 0:
        h, s, _ = teinte_moyenne(int(note.argmax()))
        # On vérifie l'écart sur les teintes retenues, pas sur les indices de
        # bande. La moyenne porte sur trois bandes : un accent choisi à
        # soixante degrés du corps peut en revenir à trente si ses voisines
        # penchent vers lui, et une gemme jaune fissurée d'orangé ne se lit
        # pas. En dessous d'un demi-tour de roue sur six, on préfère la
        # complémentaire.
        ecart = abs(((h - h_corps + 0.5) % 1.0) - 0.5)
        if ecart >= 0.14:
            h_fis, s_fis, source = h, s, "accent"
    if h_fis is None:
        # Une grenouille d'une seule couleur : la complémentaire tranche autant
        # qu'un vrai accent, et se lit comme voulue.
        h_fis, s_fis = (h_corps + 0.5) % 1.0, s_corps

    def hexa(h, s, v):
        return "#%02x%02x%02x" % tuple(
            int(round(c * 255)) for c in colorsys.hsv_to_rgb(h, s, v))

    return {
        "corps": hexa(h_corps, _serre(s_corps, CORPS_S), CORPS_V),
        "fissure": hexa(h_fis, _serre(s_fis * 1.25, FISSURE_S), FISSURE_V),
        "source": source,
        "sur": round(n_corps / len(hsv), 3),
    }


def toutes() -> dict:
    return {nom: couleurs(nom) for nom in sorted(TABLE)}


def montre(table: dict) -> pathlib.Path:
    """Une planche de contrôle : chaque grenouille, ses deux couleurs.

    On ne juge pas une paire de couleurs sur deux codes hexadécimaux. Posées à
    côté du modèle dont elles sortent, une erreur saute aux yeux en une seconde.
    """
    from PIL import ImageDraw

    noms = sorted(table)
    T, COLS, BANDE = 132, 5, 26
    lignes = (len(noms) + COLS - 1) // COLS
    planche = Image.new("RGB", (COLS * T, lignes * (T + BANDE + 16)), "#101318")
    d = ImageDraw.Draw(planche)

    for i, nom in enumerate(noms):
        c = table[nom]
        x, y = (i % COLS) * T, (i // COLS) * (T + BANDE + 16)
        im = Image.open(MODELES / f"{nom}_apercu.webp").convert("RGBA")
        fond = Image.new("RGBA", im.size, (16, 19, 24, 255))
        fond.alpha_composite(im)
        planche.paste(fond.convert("RGB").resize((T, T)), (x, y))
        d.rectangle([x, y + T, x + T // 2, y + T + BANDE], fill=c["corps"])
        d.rectangle([x + T // 2, y + T, x + T, y + T + BANDE], fill=c["fissure"])
        d.text((x + 4, y + T + BANDE + 2), f"{nom} · {c['source'][:4]}", fill="#c8ccd4")

    chemin = pathlib.Path("/tmp/couleurs_succes.png")
    planche.save(chemin)
    return chemin


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--montre", action="store_true",
                    help="produire la planche de contrôle")
    ap.add_argument("--ecris", action="store_true", default=None,
                    help="écrire le fichier de couleurs (par défaut)")
    a = ap.parse_args()

    table = toutes()
    for nom in sorted(table):
        c = table[nom]
        print(f"  {nom:16s} corps {c['corps']}  fissure {c['fissure']}  "
              f"({c['source']}, {c['sur']:.0%} du sujet)")

    if a.montre:
        print("planche :", montre(table))
    if a.ecris is not False:
        SORTIE.write_text(json.dumps(table, indent=2, ensure_ascii=False) + "\n")
        print(f"\n{SORTIE.name} — {len(table)} modèles")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
