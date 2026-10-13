#!/usr/bin/env python3
"""PyTorch contre ONNX Runtime, sur l'encodeur d'image.

N'installe rien dans l'environnement du serveur : les bibliothèques d'essai
vont dans /tmp, et le modèle exporté aussi. Tout s'efface d'un `rm -rf /tmp/onnx*`.

    python3 -m pip install --target=/tmp/onnx-libs onnxruntime onnx
    PYTHONPATH=/tmp/onnx-libs BIODEX_RACINE=/opt/biodex/backend \\
        /opt/biodex/backend/.venv/bin/python /tmp/essai_onnx.py

Ce qu'on mesure est l'encodeur BioCLIP seul. Le détecteur, lui, ne s'exporte
pas d'un claquement de doigts — et c'est justement lui qui coûte le plus, d'où
l'intérêt de commencer par mesurer plutôt que par convertir.
"""
import os
import pathlib
import statistics
import sys
import time

os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")

RACINE = pathlib.Path(os.environ.get(
    "BIODEX_RACINE", pathlib.Path(__file__).resolve().parent.parent)).resolve()
sys.path.insert(0, str(RACINE))
os.chdir(RACINE)

SORTIE = pathlib.Path("/tmp/onnx-modeles")
SORTIE.mkdir(exist_ok=True)


def poids(chemin: pathlib.Path) -> float:
    """La place occupée, en Mo.

    Le fichier `.onnx` ne contient que le graphe : au-delà de deux gigaoctets,
    et souvent bien avant, les poids partent dans un `.onnx.data` à côté. Ne
    lire que le premier annonçait « 0 Mo » pour un modèle d'un gigaoctet.
    """
    total = chemin.stat().st_size
    annexe = chemin.with_suffix(chemin.suffix + ".data")
    if annexe.exists():
        total += annexe.stat().st_size
    return total / 2**20


def median(fn, tours=5):
    """Le temps d'une opération, premier tour jeté."""
    fn()
    return statistics.median([_un(fn) for _ in range(tours)])


def _un(fn):
    t = time.perf_counter()
    fn()
    return time.perf_counter() - t


def main() -> int:
    import torch
    from PIL import Image
    from biodex import config

    try:
        import onnxruntime as ort
    except ImportError:
        sys.exit("onnxruntime absent. Voir l'en-tête du fichier pour l'installer.")

    print(f"torch {torch.__version__}, onnxruntime {ort.__version__}, "
          f"{torch.get_num_threads()} fils\n")

    import open_clip
    clip, _, prep = open_clip.create_model_and_transforms(config.MODELE_CLIP)
    clip.eval()

    photo = sorted(config.PHOTOS.glob("*.jpg"))[0]
    with Image.open(photo) as img:
        entree = prep(img.convert("RGB")).unsqueeze(0)

    # On n'exporte que la tour visuelle : c'est elle qui tourne à chaque photo,
    # la tour de texte ayant été calculée une fois pour toutes dans le catalogue.
    class TourVisuelle(torch.nn.Module):
        def __init__(self, modele):
            super().__init__()
            self.modele = modele

        def forward(self, x):
            return self.modele.encode_image(x)

    chemin = SORTIE / "bioclip_image.onnx"
    if not chemin.exists():
        print("export vers ONNX…", flush=True)
        t = time.perf_counter()
        torch.onnx.export(
            TourVisuelle(clip), entree, str(chemin),
            input_names=["image"], output_names=["embedding"],
            dynamic_axes={"image": {0: "lot"}, "embedding": {0: "lot"}},
            opset_version=17,
        )
        print(f"  fait en {time.perf_counter()-t:.1f} s, "
              f"{poids(chemin):.0f} Mo\n")

    fils = torch.get_num_threads()
    options = ort.SessionOptions()
    options.intra_op_num_threads = fils
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL

    tableau = entree.numpy()

    def torche():
        with torch.no_grad():
            return clip.encode_image(entree)

    session = ort.InferenceSession(str(chemin), options,
                                   providers=["CPUExecutionProvider"])
    def onnx32():
        return session.run(None, {"image": tableau})

    print(f"{'':28} {'temps':>8}")
    t_torch = median(torche)
    print(f"  {'PyTorch':26} {t_torch:>7.3f}s")
    t_onnx = median(onnx32)
    print(f"  {'ONNX Runtime (float32)':26} {t_onnx:>7.3f}s   "
          f"×{t_torch / t_onnx:.2f}")

    # La quantification en entiers 8 bits.
    #
    # Elle ne paie vraiment que sur un processeur qui sait multiplier des
    # entiers vectoriels — l'instruction VNNI, apparue avec Cascade Lake en
    # 2019. Sans elle, le gain est faible et parfois négatif : c'est pour ça
    # qu'on mesure au lieu de supposer.
    quant = SORTIE / "bioclip_image_int8.onnx"
    try:
        from onnxruntime.quantization import QuantType, quantize_dynamic
        if not quant.exists():
            print("\nquantification en entiers 8 bits…", flush=True)
            quantize_dynamic(str(chemin), str(quant), weight_type=QuantType.QInt8)
            print(f"  {poids(quant):.0f} Mo "
                  f"(contre {poids(chemin):.0f})")
        s8 = ort.InferenceSession(str(quant), options,
                                  providers=["CPUExecutionProvider"])
        t_int8 = median(lambda: s8.run(None, {"image": tableau}))
        print(f"  {'ONNX Runtime (entiers 8 bits)':26} {t_int8:>7.3f}s   "
              f"×{t_torch / t_int8:.2f}")
        ecart8 = _ecart(torch, clip, entree, s8, tableau)
        print(f"  {'  écart avec PyTorch':26} {ecart8:>7.1e}")
    except Exception as e:
        print(f"\nquantification impossible : {type(e).__name__}: {e}")

    # Un modèle plus rapide qui répond autre chose n'est pas plus rapide.
    #
    # L'écart se juge sur ce qui décide vraiment : la similarité entre le
    # vecteur d'image et ceux du catalogue. Deux embeddings qui diffèrent au
    # millième donnent le même verdict si leur direction est la même — et
    # c'est la direction qui compte, les vecteurs étant normalisés avant
    # comparaison.
    print(f"\nécart avec PyTorch (float32) : "
          f"{_ecart(torch, clip, entree, session, tableau):.1e}")
    print("  mesuré sur la direction du vecteur, celle qui décide du verdict.")

    # La seule mesure qui tranche : l'espèce trouvée change-t-elle ?
    #
    # Un écart de vecteur ne dit rien tant qu'on ne l'a pas confronté au
    # catalogue. Sur 411 743 espèces dont beaucoup sont à un cheveu l'une de
    # l'autre, un millième de déviation suffit parfois à faire permuter deux
    # voisines — et parfois pas. On regarde.
    print("\n— l'espèce trouvée change-t-elle ? —")
    d = torch.load(config.CATALOGUE, weights_only=False)
    noms, txt = d["noms"], d["emb"]
    photos = sorted(config.PHOTOS.glob("*.jpg"))[:15]
    print(f"  sur {len(photos)} photo(s)")

    sessions = {"float32": session}
    if quant.exists():
        sessions["entiers 8 bits"] = ort.InferenceSession(
            str(quant), options, providers=["CPUExecutionProvider"])

    accords = {nom: 0 for nom in sessions}
    for f in photos:
        with Image.open(f) as img:
            x = prep(img.convert("RGB")).unsqueeze(0)
        attendu = _top1(torch, noms, txt, _torche_vec(torch, clip, x))
        for nom, sess in sessions.items():
            vec = torch.from_numpy(
                sess.run(None, {"image": x.numpy()})[0]).float()
            if _top1(torch, noms, txt, vec) == attendu:
                accords[nom] += 1

    for nom, n in accords.items():
        etat = "identique" if n == len(photos) else "DIVERGE"
        print(f"  {nom:18} {n}/{len(photos)} d'accord avec PyTorch — {etat}")
    print("\nUn modèle qui répond autre chose n'est pas un modèle plus rapide.")
    return 0


def _torche_vec(torch, clip, x):
    with torch.no_grad():
        return clip.encode_image(x)


def _top1(torch, noms, txt, vecteur):
    """L'espèce la mieux classée, comme le fait le moteur."""
    v = vecteur / vecteur.norm(dim=-1, keepdim=True)
    with torch.no_grad():
        scores = (v.half() @ txt.T).float()
    return noms[int(scores.argmax())]


def _ecart(torch, clip, entree, session, tableau) -> float:
    """1 moins le cosinus entre les deux vecteurs : zéro = même réponse."""
    with torch.no_grad():
        ref = clip.encode_image(entree)
    ref = ref / ref.norm(dim=-1, keepdim=True)
    obtenu = torch.from_numpy(session.run(None, {"image": tableau})[0]).float()
    obtenu = obtenu / obtenu.norm(dim=-1, keepdim=True)
    return float(1 - (ref * obtenu).sum())


if __name__ == "__main__":
    sys.exit(main())
