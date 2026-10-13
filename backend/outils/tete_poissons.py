#!/usr/bin/env python3
"""
Apprend une tête « genre » sur les embeddings BioCLIP de FishNet.

Pourquoi le genre, et pas l'espèce. FishNet annonce 17 356 espèces, mais la
médiane est de **deux images par espèce** et aucune n'en atteint cinquante :
c'est un inventaire d'étiquettes, pas un jeu d'entraînement. Le genre, lui, est
renseigné sur 99,5 % des images, et 1 113 genres dépassent les dix images —
soit 90 % du jeu. C'est le rang le plus fin qui soit réellement apprenable ici.

Ce qu'on entraîne tient en une matrice. Pas de réseau, pas de couche cachée :
une régression logistique sur des vecteurs de 768 nombres que le serveur
calcule déjà. À l'inférence elle coûte une multiplication de 0,9 million
d'opérations, contre les 316 millions que le catalogue animal fait aujourd'hui
en un centième de seconde.

Ce que la tête sert à faire : pousser BioCLIP vers le bon genre, pas décider à
sa place. Le verdict d'espèce reste au catalogue ; la tête ne fait qu'ajouter
un terme aux logits, exactement comme l'a priori de fréquence existant.

Usage :
    python -m outils.tete_poissons --embeddings ~/fishnet-travail/poissons_embeddings.pt
"""
import argparse
import collections
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config  # noqa: E402

# En dessous, un genre n'a pas de quoi apprendre : il retiendrait la photo
# plutôt que le poisson. Mesuré à 5, 10 et 20 ; 10 est le meilleur compromis
# entre couverture et exactitude.
MINIMUM_IMAGES = 10


def prepare(chemin: pathlib.Path, minimum: int):
    import torch

    d = torch.load(chemin, weights_only=False, map_location="cpu")
    emb, genre, split = d["emb"], d["genre"], d["split"]
    if d.get("modele") != config.MODELE_CLIP:
        print(f"!! embeddings produits par {d.get('modele')!r}, "
              f"le serveur tourne sur {config.MODELE_CLIP!r}", flush=True)

    compte = collections.Counter(g for g in genre if g)
    gardes = sorted(g for g, n in compte.items() if n >= minimum)
    pos = {g: i for i, g in enumerate(gardes)}
    print(f"{len(compte)} genres au total, {len(gardes)} retenus "
          f"(≥ {minimum} images)")

    idx = [i for i, g in enumerate(genre) if g in pos]
    X = emb[torch.tensor(idx)].float()
    y = torch.tensor([pos[genre[i]] for i in idx])
    est_test = torch.tensor([split[i] == "test" for i in idx])
    print(f"  {len(idx)} images  →  {int((~est_test).sum())} apprentissage, "
          f"{int(est_test.sum())} contrôle")
    return X, y, est_test, gardes, d


def entraine(X, y, est_test, n_classes, epoques, lr):
    import torch

    appareil = "cuda" if torch.cuda.is_available() else "cpu"
    Xtr, ytr = X[~est_test].to(appareil), y[~est_test].to(appareil)
    Xte, yte = X[est_test].to(appareil), y[est_test].to(appareil)

    couche = torch.nn.Linear(X.shape[1], n_classes).to(appareil)
    opt = torch.optim.AdamW(couche.parameters(), lr=lr, weight_decay=1e-4)
    prog = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=epoques)
    perte = torch.nn.CrossEntropyLoss(label_smoothing=0.1)

    n, lot = len(Xtr), 1024
    meilleur, poids_gardes = 0.0, None
    for e in range(epoques):
        couche.train()
        for i in torch.randperm(n, device=appareil).split(lot):
            opt.zero_grad()
            perte(couche(Xtr[i]), ytr[i]).backward()
            opt.step()
        prog.step()

        couche.eval()
        with torch.no_grad():
            s = couche(Xte)
            t1 = (s.argmax(-1) == yte).float().mean().item()
            t5 = (s.topk(5, -1).indices == yte[:, None]).any(-1).float().mean().item()
        if t1 > meilleur:
            meilleur = t1
            poids_gardes = (couche.weight.detach().clone(),
                            couche.bias.detach().clone())
        if e % 5 == 0 or e == epoques - 1:
            print(f"  époque {e:>3}  top-1 {t1:.1%}  top-5 {t5:.1%}", flush=True)

    print(f"\nMeilleur top-1 sur le contrôle : {meilleur:.1%}")
    return poids_gardes, meilleur


def main() -> int:
    import torch

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--embeddings", type=pathlib.Path, required=True)
    ap.add_argument("--sortie", type=pathlib.Path,
                    default=config.DONNEES / "tete_genres.pt")
    ap.add_argument("--minimum", type=int, default=MINIMUM_IMAGES)
    ap.add_argument("--epoques", type=int, default=40)
    ap.add_argument("--lr", type=float, default=1e-3)
    a = ap.parse_args()

    X, y, est_test, genres, _ = prepare(a.embeddings.expanduser(), a.minimum)
    (W, b), score = entraine(X, y, est_test, len(genres), a.epoques, a.lr)

    sortie = a.sortie.expanduser()
    sortie.parent.mkdir(parents=True, exist_ok=True)
    torch.save({
        "genres": genres,
        # float16 comme les catalogues : la tête voyage avec eux, et la perte
        # de précision est sans effet mesurable sur un argmax.
        "poids": W.cpu().half(),
        "biais": b.cpu().float(),
        "top1": score,
        "minimum": a.minimum,
        "modele": config.MODELE_CLIP,
    }, sortie)
    mo = sortie.stat().st_size / 2 ** 20
    print(f"Écrit : {sortie}  ({mo:.1f} Mo, {len(genres)} genres)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
