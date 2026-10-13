#!/usr/bin/env python3
"""Où passent les secondes d'une analyse.

À lancer avant toute optimisation. Trois étapes se partagent le temps — le
détecteur, l'encodeur d'image, et le produit contre le catalogue — et elles ne
se corrigent pas de la même façon. Quantifier au hasard, c'est optimiser celle
qui ne coûtait rien.

    /opt/biodex/backend/.venv/bin/python /tmp/ou_passe_le_temps.py

Ne touche à rien : ni la base, ni les fichiers, ni la configuration.
"""
import os
import pathlib
import statistics
import sys
import time

# Le serveur n'a pas de carte graphique : on mesure ce qu'il vivra vraiment.
# Sans cette ligne, un poste de développement mesurerait son GPU et donnerait
# des chiffres sans rapport — c'est exactement le piège que ce script existe
# pour éviter.
os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")

RACINE = pathlib.Path(os.environ.get(
    "BIODEX_RACINE", pathlib.Path(__file__).resolve().parent.parent)).resolve()
if not (RACINE / "biodex").is_dir():
    sys.exit(f"Backend introuvable dans {RACINE}. "
             f"Donnez le bon chemin : BIODEX_RACINE=/chemin/vers/backend")
sys.path.insert(0, str(RACINE))
os.chdir(RACINE)

TOURS = int(os.environ.get("TOURS", "5"))


def chrono(quoi, fn, tours=TOURS):
    """Mesure une étape, en jetant le premier tour."""
    fn()                                    # chauffe : caches, allocations
    mesures = []
    for _ in range(tours):
        t = time.perf_counter()
        fn()
        mesures.append(time.perf_counter() - t)
    milieu = statistics.median(mesures)
    print(f"  {quoi:38} {milieu:6.2f} s   "
          f"(min {min(mesures):.2f}, max {max(mesures):.2f})")
    return milieu


def main() -> int:
    import torch
    from PIL import Image

    from biodex import config

    print(f"machine : {os.cpu_count()} cœurs vus, "
          f"torch {torch.__version__}, {torch.get_num_threads()} fils")
    print(f"jeux d'instructions : {jeu_dinstructions()}\n")

    photos = sorted((config.PHOTOS).glob("*.jpg"))[:1]
    if not photos:
        return sys.exit("Aucune photo dans donnees/photos pour mesurer.")
    photo = photos[0]
    print(f"photo d'essai : {photo.name}\n")

    print("— chargement (une fois au démarrage du serveur) —")
    t = time.perf_counter()
    import open_clip
    clip, _, prep = open_clip.create_model_and_transforms(config.MODELE_CLIP)
    clip.eval()
    print(f"  BioCLIP                                {time.perf_counter()-t:6.2f} s")

    t = time.perf_counter()
    d = torch.load(config.CATALOGUE, weights_only=False)
    txt = d["emb"]
    print(f"  catalogue ({len(d['noms'])} espèces)          "
          f"{time.perf_counter()-t:6.2f} s   "
          f"{txt.numel()*txt.element_size()/2**30:.2f} Go, {txt.dtype}")

    md = None
    try:
        t = time.perf_counter()
        from megadetector.detection.run_detector import load_detector
        md = load_detector(str(config.MD_POIDS))
        print(f"  MegaDetector                           "
              f"{time.perf_counter()-t:6.2f} s")
    except Exception as e:
        print(f"  MegaDetector indisponible : {type(e).__name__}: {e}")

    print("\n— par photo (c'est ici que se joue l'attente) —")
    img = Image.open(photo).convert("RGB")

    if md is not None:
        chrono("1. MegaDetector (repérer la bête)",
               lambda: md.generate_detections_one_image(
                   img, str(photo), detection_threshold=0.2))
        # Le détecteur tourne à 1280 pixels par défaut, ce que ses métadonnées
        # imposent. Quatre fois moins de pixels coûtent quatre fois moins de
        # calcul ; reste à voir si la bête est toujours trouvée, ce que seul
        # un essai sur vos photos peut dire.
        for cote in (960, 640):
            chrono(f"1bis. MegaDetector à {cote} px",
                   lambda c=cote: md.generate_detections_one_image(
                       img, str(photo), detection_threshold=0.2, image_size=c))

        # La vitesse ne vaut rien si la bête n'est plus trouvée. On compare ce
        # que chaque résolution rend, sur toutes les photos disponibles : c'est
        # la seule mesure qui compte, et elle dépend de *vos* photos — un cerf
        # qui remplit le cadre survit à tout, une mésange au fond d'un buisson
        # non.
        print("\n— ce que chaque résolution trouve —")
        echantillon = sorted(config.PHOTOS.glob("*.jpg"))[:12]
        print(f"  sur {len(echantillon)} photo(s)")
        for cote in (None, 960, 640):
            trouvees, confiances = 0, []
            for f in echantillon:
                with Image.open(f) as x:
                    r = md.generate_detections_one_image(
                        x.convert("RGB"), str(f),
                        detection_threshold=0.2, image_size=cote)
                dets = [d for d in r.get("detections", []) if d["conf"] >= 0.2]
                if dets:
                    trouvees += 1
                    confiances.append(max(d["conf"] for d in dets))
            moyenne = statistics.mean(confiances) if confiances else 0
            nom = "1280 px (défaut)" if cote is None else f"{cote} px"
            print(f"  {nom:18} {trouvees}/{len(echantillon)} trouvées, "
                  f"confiance moyenne {moyenne:.2f}")

    entree = prep(img).unsqueeze(0)
    def encode():
        with torch.no_grad():
            return clip.encode_image(entree)
    chrono("2. BioCLIP (décrire l'image)", encode)

    with torch.no_grad():
        vecteur = encode()
    vecteur = vecteur / vecteur.norm(dim=-1, keepdim=True)

    def compare16():
        with torch.no_grad():
            return (vecteur.half() @ txt.T).float()
    chrono("3. catalogue en float16", compare16)

    # L'hypothèse à vérifier : sur un processeur sans instructions float16
    # natives, PyTorch émule, et le float32 va plus vite malgré deux fois plus
    # de mémoire. C'est gratuit à tester et parfois spectaculaire.
    try:
        txt32 = txt.float()
        def compare32():
            with torch.no_grad():
                return vecteur @ txt32.T
        chrono("3bis. le même en float32", compare32)
        del txt32
    except Exception as e:
        print(f"  float32 impossible : {type(e).__name__}: {e}")

    print("\nCe qui domine est ce qu'il faut attaquer. Le reste peut attendre.")
    return 0


def jeu_dinstructions() -> str:
    """Ce que le processeur sait faire — c'est ce qui décide du gain possible."""
    try:
        drapeaux = set()
        for ligne in pathlib.Path("/proc/cpuinfo").read_text().splitlines():
            if ligne.startswith("flags"):
                drapeaux = set(ligne.split(":", 1)[1].split())
                break
    except OSError:
        return "inconnu"
    interessants = ["avx", "avx2", "fma", "avx512f", "avx512_vnni", "amx_int8"]
    presents = [d for d in interessants if d in drapeaux]
    return ", ".join(presents) if presents else "aucun jeu vectoriel moderne"


if __name__ == "__main__":
    sys.exit(main())
