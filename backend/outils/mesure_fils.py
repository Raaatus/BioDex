#!/usr/bin/env python3
"""Combien de fils faut-il donner à PyTorch ?

Sur une machine à deux sockets, plus de fils ne veut pas dire plus vite. Passé
les cœurs d'un même processeur, les données traversent le lien entre les deux
puces à chaque opération, et le calcul passe son temps à attendre la mémoire.
Un serveur qui traite une photo à la fois a souvent tout intérêt à rester sur
un seul socket.

Ça ne coûte rien à essayer et c'est réversible d'un mot :

    OMP_NUM_THREADS=8 ./run.sh

    /opt/biodex/backend/.venv/bin/python /tmp/combien_de_fils.py
"""
import os
import pathlib
import statistics
import sys
import time

os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")

RACINE = pathlib.Path(os.environ.get(
    "BIODEX_RACINE", pathlib.Path(__file__).resolve().parent.parent)).resolve()
if not (RACINE / "biodex").is_dir():
    sys.exit(f"Backend introuvable dans {RACINE}.")
sys.path.insert(0, str(RACINE))
os.chdir(RACINE)


def main() -> int:
    import torch
    from PIL import Image

    from biodex import config

    coeurs = os.cpu_count() or 1
    print(f"{coeurs} cœurs vus par ce système\n")

    photos = sorted(config.PHOTOS.glob("*.jpg"))[:1]
    if not photos:
        sys.exit("Aucune photo dans donnees/photos.")
    img = Image.open(photos[0]).convert("RGB")

    import open_clip
    clip, _, prep = open_clip.create_model_and_transforms(config.MODELE_CLIP)
    clip.eval()
    entree = prep(img).unsqueeze(0)

    md = None
    try:
        from megadetector.detection.run_detector import load_detector
        md = load_detector(str(config.MD_POIDS))
    except Exception as e:
        print(f"MegaDetector indisponible : {type(e).__name__}: {e}")

    essais = sorted({1, 2, 4, 8, 12, 16, 20, coeurs // 2, coeurs})
    essais = [n for n in essais if 1 <= n <= coeurs]

    print(f"{'fils':>6} {'MegaDetector':>14} {'BioCLIP':>10} {'total':>10}")
    print("  " + "-" * 42)
    meilleur = (None, float("inf"))
    for n in essais:
        torch.set_num_threads(n)
        t_md = _median(
            lambda: md.generate_detections_one_image(
                img, "x", detection_threshold=0.2)) if md else 0.0
        t_clip = _median(lambda: _encode(torch, clip, entree))
        total = t_md + t_clip
        print(f"{n:>6} {t_md:>13.2f}s {t_clip:>9.2f}s {total:>9.2f}s")
        if total < meilleur[1]:
            meilleur = (n, total)

    print(f"\nLe plus rapide : {meilleur[0]} fils ({meilleur[1]:.2f} s).")
    if meilleur[0] and meilleur[0] < coeurs:
        gain = 0
        print(f"Soit moins que les {coeurs} cœurs disponibles — c'est le signe "
              f"que le calcul\nattend la mémoire plutôt que le processeur. "
              f"À mettre dans l'environnement\ndu service :\n\n"
              f"    OMP_NUM_THREADS={meilleur[0]}\n")
        del gain
    return 0


def _encode(torch, clip, entree):
    with torch.no_grad():
        return clip.encode_image(entree)


def _median(fn, tours=3):
    fn()
    return statistics.median(
        [_chrono(fn) for _ in range(tours)])


def _chrono(fn):
    t = time.perf_counter()
    fn()
    return time.perf_counter() - t


if __name__ == "__main__":
    sys.exit(main())
