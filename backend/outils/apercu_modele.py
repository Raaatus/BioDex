#!/usr/bin/env python3
"""
Rend un modèle 3D en images, pour l'afficher sans moteur 3D.

La visionneuse de la vitrine utilise `model-viewer`, qui embarque une WebView.
C'est acceptable pour un écran qu'on ouvre exprès ; c'est déraisonnable pour une
vignette de cinquante pixels dans un bandeau qui défile, et absurde pour une
grille de cinquante rangs — cinquante WebView.

On rend donc le modèle ici, une fois, en une planche de tuiles : le même format
que l'animation de chargement, dont l'application sait déjà dessiner une tuile
à la fois. L'objet tourne au doigt sans qu'aucun moteur 3D ne tourne.

Aucun moteur de rendu n'était installé — ni pyrender, ni pyglet, ni OpenGL — et
en installer un headless demande des bibliothèques système. Le rastériseur
ci-dessous tient en quelques dizaines de lignes de numpy : z-buffer, coordonnées
barycentriques, échantillonnage de texture, une lumière diffuse. C'est
suffisant pour un objet vu à deux cents pixels, et ça ne dépend de rien.

Usage :
    python -m outils.apercu_modele --source app/assets/modeles/grenouille.glb
"""
import argparse
import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

DESTINATION = (pathlib.Path(__file__).resolve().parent.parent.parent
               / "app" / "assets" / "modeles")

IMAGES = 24
TUILE = 160

# La lumière, en coordonnées de la caméra. Légèrement en haut à gauche et vers
# l'avant : de face, l'objet est plat ; rasante, il est illisible.
LUMIERE = (-0.35, 0.55, 0.75)

# Ce qui reste éclairé dans l'ombre. À zéro, les faces opposées à la lumière
# sont parfaitement noires et l'objet paraît troué.
AMBIANTE = 0.35


def _charge(chemin: pathlib.Path):
    import numpy as np
    import trimesh

    scene = trimesh.load(chemin, force="scene")
    maillages = list(scene.geometry.values())
    if not maillages:
        raise SystemExit(f"{chemin.name} ne contient aucun maillage.")
    m = trimesh.util.concatenate(maillages) if len(maillages) > 1 else maillages[0]

    v = np.asarray(m.vertices, dtype=np.float64)
    # Recentrer sur la boîte englobante et non sur la moyenne des sommets : un
    # maillage dense d'un côté décalerait l'objet hors du cadre.
    centre = (v.min(axis=0) + v.max(axis=0)) / 2
    v = v - centre
    v = v / np.abs(v).max()

    uv = getattr(m.visual, "uv", None)
    texture = getattr(getattr(m.visual, "material", None), "baseColorTexture", None)
    return v, np.asarray(m.faces), (np.asarray(uv) if uv is not None else None), texture


def _rend(v, faces, uv, texture, taille: int, angle: float):
    """Une image de l'objet, tourné de `angle` radians autour de la verticale."""
    import numpy as np
    from PIL import Image

    c, s = math.cos(angle), math.sin(angle)
    # Rotation autour de Y, puis léger basculement vers l'avant pour qu'on voie
    # un peu le dessus : de profil strict, la silhouette est ambiguë.
    x = v[:, 0] * c + v[:, 2] * s
    z = -v[:, 0] * s + v[:, 2] * c
    y, z = v[:, 1] * 0.966 - z * 0.259, v[:, 1] * 0.259 + z * 0.966

    marge = 0.92
    px = (x * marge * 0.5 + 0.5) * (taille - 1)
    # L'écran a son axe vertical vers le bas, le modèle vers le haut.
    py = (0.5 - y * marge * 0.5) * (taille - 1)

    couleur = np.zeros((taille, taille, 3), dtype=np.float32)
    alpha = np.zeros((taille, taille), dtype=np.float32)
    prof = np.full((taille, taille), -np.inf, dtype=np.float32)

    tex = None
    if texture is not None and uv is not None:
        tex = np.asarray(texture.convert("RGB"), dtype=np.float32) / 255.0

    tri = faces
    ax, ay = px[tri[:, 0]], py[tri[:, 0]]
    bx, by = px[tri[:, 1]], py[tri[:, 1]]
    cx, cy = px[tri[:, 2]], py[tri[:, 2]]
    aire = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)

    # Faces tournées vers l'arrière : inutile de les rastériser, le z-buffer
    # les écarterait de toute façon. Sur dix mille triangles, c'est la moitié
    # du travail en moins.
    devant = aire < -1e-9
    idx = np.nonzero(devant)[0]

    zs = np.stack([z[tri[:, 0]], z[tri[:, 1]], z[tri[:, 2]]], axis=1)
    lum = np.array(LUMIERE, dtype=np.float64)
    lum = lum / np.linalg.norm(lum)

    for t in idx:
        x0, y0 = ax[t], ay[t]
        x1, y1 = bx[t], by[t]
        x2, y2 = cx[t], cy[t]
        imin = max(int(min(x0, x1, x2)), 0)
        imax = min(int(max(x0, x1, x2)) + 1, taille - 1)
        jmin = max(int(min(y0, y1, y2)), 0)
        jmax = min(int(max(y0, y1, y2)) + 1, taille - 1)
        if imin > imax or jmin > jmax:
            continue

        gx, gy = np.meshgrid(np.arange(imin, imax + 1),
                             np.arange(jmin, jmax + 1))
        d = aire[t]
        w0 = ((x1 - gx) * (y2 - gy) - (y1 - gy) * (x2 - gx)) / d
        w1 = ((x2 - gx) * (y0 - gy) - (y2 - gy) * (x0 - gx)) / d
        w2 = 1.0 - w0 - w1
        dedans = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        if not dedans.any():
            continue

        zz = w0 * zs[t, 0] + w1 * zs[t, 1] + w2 * zs[t, 2]
        vu = dedans & (zz > prof[jmin:jmax + 1, imin:imax + 1])
        if not vu.any():
            continue

        # Normale géométrique du triangle, dans le repère déjà tourné : suffit
        # pour une lumière diffuse, et évite d'interpoler les normales.
        n = np.cross([x1 - x0, y0 - y1, zs[t, 1] - zs[t, 0]],
                     [x2 - x0, y0 - y2, zs[t, 2] - zs[t, 0]])
        nn = np.linalg.norm(n)
        eclairage = AMBIANTE
        if nn > 0:
            eclairage = AMBIANTE + (1 - AMBIANTE) * max(0.0, float(n @ lum) / nn)

        if tex is not None:
            u = w0 * uv[tri[t, 0], 0] + w1 * uv[tri[t, 1], 0] + w2 * uv[tri[t, 2], 0]
            vv = w0 * uv[tri[t, 0], 1] + w1 * uv[tri[t, 1], 1] + w2 * uv[tri[t, 2], 1]
            tu = np.clip((u % 1.0) * (tex.shape[1] - 1), 0, tex.shape[1] - 1).astype(int)
            # L'origine des UV glTF est en bas ; celle de l'image en haut.
            tv = np.clip((1 - (vv % 1.0)) * (tex.shape[0] - 1), 0,
                         tex.shape[0] - 1).astype(int)
            base = tex[tv, tu]
        else:
            base = np.full(gx.shape + (3,), 0.75, dtype=np.float32)

        sous_c = couleur[jmin:jmax + 1, imin:imax + 1]
        sous_a = alpha[jmin:jmax + 1, imin:imax + 1]
        sous_z = prof[jmin:jmax + 1, imin:imax + 1]
        sous_c[vu] = base[vu] * eclairage
        sous_a[vu] = 1.0
        sous_z[vu] = zz[vu]

    rgba = np.dstack([np.clip(couleur * 255, 0, 255), alpha * 255]).astype("uint8")
    return Image.fromarray(rgba, "RGBA")


def prepare(source: pathlib.Path, dossier: pathlib.Path, images: int,
            tuile: int) -> int:
    import time
    from PIL import Image

    if not source.exists():
        raise SystemExit(f"Introuvable : {source}")
    v, faces, uv, texture = _charge(source)
    print(f"{source.name} : {len(v)} sommets, {len(faces)} faces, "
          f"texture {texture.size if texture else 'aucune'}")

    depart = time.time()
    rendus = []
    for i in range(images):
        rendus.append(_rend(v, faces, uv, texture, tuile,
                            2 * math.pi * i / images))
        if i == 0:
            print(f"  première image en {time.time() - depart:.1f} s "
                  f"→ ~{(time.time() - depart) * images:.0f} s au total",
                  flush=True)

    colonnes = math.ceil(math.sqrt(images))
    lignes = math.ceil(images / colonnes)
    planche = Image.new("RGBA", (colonnes * tuile, lignes * tuile), (0, 0, 0, 0))
    for i, im in enumerate(rendus):
        planche.paste(im, ((i % colonnes) * tuile, (i // colonnes) * tuile))

    dossier.mkdir(parents=True, exist_ok=True)
    nom = source.stem
    chemin = dossier / f"{nom}_tour.webp"
    planche.save(chemin, "WEBP", quality=90, method=6)
    # Une image seule pour la vignette : l'application n'a pas à découper la
    # planche là où elle ne veut qu'un aperçu fixe.
    apercu = dossier / f"{nom}_apercu.webp"
    rendus[0].save(apercu, "WEBP", quality=90, method=6)

    print(f"  planche {colonnes}×{lignes} de {tuile} px, {images} images, "
          f"{chemin.stat().st_size / 1024:.0f} Ko")
    print(f"  aperçu {apercu.stat().st_size / 1024:.0f} Ko")
    print(f"  rendu en {time.time() - depart:.0f} s")
    print("\n  À reporter dans le widget si vous changez ces valeurs :")
    print(f"    images = {images}   colonnes = {colonnes}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", type=pathlib.Path, required=True)
    ap.add_argument("--dossier", type=pathlib.Path, default=DESTINATION)
    ap.add_argument("--images", type=int, default=IMAGES)
    ap.add_argument("--tuile", type=int, default=TUILE)
    a = ap.parse_args()
    return prepare(a.source.expanduser(), a.dossier.expanduser(),
                   a.images, a.tuile)


if __name__ == "__main__":
    raise SystemExit(main())
