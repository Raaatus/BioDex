#!/usr/bin/env python3
"""
Passe les images de FishNet dans BioCLIP et garde les vecteurs.

C'est l'étape longue, et elle ne se fait qu'une fois. Ce qui en sort — un
vecteur de 768 nombres par image, plus son étiquette taxonomique — sert ensuite
à `tete_poissons.py`, qui n'a plus jamais besoin de revoir une image.

Pourquoi geler BioCLIP au lieu de le réentraîner : le serveur calcule déjà cet
embedding pour chaque photo. Tout ce qui vit dans cet espace-là est donc
gratuit à l'inférence. Un modèle réentraîné, lui, serait un second réseau à
charger et à faire tourner sur un CPU qui peine déjà.

Le prétraitement vient de `moteur.py`, sans variante : les vecteurs
d'entraînement doivent sortir du même chemin que ceux de production, sinon la
tête apprend dans un espace et travaille dans un autre.

Usage :
    python -m outils.embeddings_poissons --images ~/fishnet-travail
"""
import argparse
import csv
import os
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config  # noqa: E402

# Les images dont le nom n'apparaît dans aucun CSV. Il y en a 273 : elles n'ont
# pas d'étiquette, donc rien à apprendre.
VIDE = ("", "nan", "NaN", "None")


def _propre(ligne: dict, champ: str) -> str:
    v = (ligne.get(champ) or "").strip()
    return "" if v in VIDE else v


def lit_annotations(racine: pathlib.Path) -> list[dict]:
    """Apparie les lignes des CSV officiels aux fichiers réellement sur le disque.

    Deux formats cohabitent dans la colonne `image`, et c'est un piège : les
    lignes iNaturalist portent un nom de fichier, les lignes FishBase une URL
    complète. Prendre le dernier segment marche pour les deux.

    On préfère le CSV au décodage des noms de fichiers. Le code à cinq lettres
    de FishBase est ambigu — 13,5 % d'entre eux désignent des poissons de
    familles différentes — alors que la colonne `species` est explicite.
    """
    lignes = []
    for nom in ("fnet_train.csv", "fnet_test.csv"):
        chemin = racine / nom
        if not chemin.exists():
            raise SystemExit(
                f"{chemin} manquant.\n"
                "Récupérez-les dans le dépôt FishNet :\n"
                "  https://raw.githubusercontent.com/faixan-khan/FishNet"
                "/main/anns/train.csv")
        with open(chemin, encoding="utf-8", errors="replace") as f:
            for r in csv.DictReader(f):
                r["_split"] = "test" if "test" in nom else "train"
                lignes.append(r)

    sur_disque = {}
    for dossier, _, fichiers in os.walk(racine / "Image_Library"):
        fam = os.path.basename(dossier)
        for f in fichiers:
            if f.endswith(".jpg"):
                sur_disque[(fam, f)] = os.path.join(dossier, f)

    retenues, absentes = [], 0
    for r in lignes:
        cle = (_propre(r, "Folder"), os.path.basename(_propre(r, "image")))
        chemin = sur_disque.get(cle)
        if chemin is None:
            absentes += 1
            continue
        retenues.append({
            "chemin": chemin,
            "espece": _propre(r, "species"),
            "genre": _propre(r, "Genus"),
            "famille": _propre(r, "Family"),
            "ordre": _propre(r, "Order"),
            "source": _propre(r, "source"),
            "split": r["_split"],
        })

    print(f"{len(retenues)} images appariées"
          + (f", {absentes} lignes sans fichier" if absentes else ""))
    if not retenues:
        raise SystemExit("Aucune image appariée : vérifiez --images.")
    return retenues


class JeuImages:
    """Ouvre et prétraite une image. Volontairement minimal : le `DataLoader`
    en fait tourner plusieurs en parallèle, et tout ce qui est fait ici l'est
    autant de fois."""

    def __init__(self, entrees, prep):
        self.entrees = entrees
        self.prep = prep

    def __len__(self):
        return len(self.entrees)

    def __getitem__(self, i):
        from PIL import Image
        try:
            with Image.open(self.entrees[i]["chemin"]) as im:
                return self.prep(im.convert("RGB")), i
        except Exception:
            # Une image illisible ne doit pas arrêter une passe de trois
            # quarts d'heure. On renvoie du noir et on l'écarte ensuite : le
            # marqueur, c'est l'indice négatif.
            import torch
            return torch.zeros(3, 224, 224), -1 - i


def extrait(racine: pathlib.Path, sortie: pathlib.Path, lot: int,
            ouvriers: int) -> int:
    import torch
    from torch.utils.data import DataLoader
    import open_clip

    entrees = lit_annotations(racine)

    print(f"Chargement de BioCLIP 2 ({config.MODELE_CLIP})…", flush=True)
    modele, _, prep = open_clip.create_model_and_transforms(config.MODELE_CLIP)
    modele.eval()

    appareil = "cuda" if torch.cuda.is_available() else "cpu"
    if appareil == "cuda":
        print(f"  GPU : {torch.cuda.get_device_name(0)}", flush=True)
    else:
        # 94 000 images à 0,22 s l'unité font près de six heures. C'est
        # faisable, mais autant le dire avant que la nuit tombe.
        print("  !! pas de GPU : comptez plusieurs heures", flush=True)
        torch.set_num_threads(config.FILS_TORCH)
    modele = modele.to(appareil)

    chargeur = DataLoader(JeuImages(entrees, prep), batch_size=lot,
                          num_workers=ouvriers, pin_memory=(appareil == "cuda"))

    n = len(entrees)
    vecteurs = torch.zeros(n, 768, dtype=torch.float16)
    valide = torch.zeros(n, dtype=torch.bool)
    faits, depart = 0, time.time()

    with torch.no_grad():
        for images, indices in chargeur:
            images = images.to(appareil, non_blocking=True)
            # L'autocast ne change que la précision des calculs internes ; le
            # vecteur sort normalisé, donc comparable à ceux du serveur, qui
            # tourne pourtant en float32. Vérifié sur un échantillon avant de
            # lancer la passe complète.
            with torch.autocast(appareil, dtype=torch.float16,
                                enabled=(appareil == "cuda")):
                e = modele.encode_image(images)
            e = (e / e.norm(dim=-1, keepdim=True)).float().cpu()

            for k, i in enumerate(indices.tolist()):
                if i >= 0:
                    vecteurs[i] = e[k].half()
                    valide[i] = True

            faits += len(indices)
            if faits % (lot * 20) < lot or faits >= n:
                ecoule = time.time() - depart
                reste = ecoule / max(faits, 1) * (n - faits)
                print(f"  {faits}/{n}  ({100 * faits / n:4.1f} %)  "
                      f"reste ~{reste / 60:.0f} min", flush=True)

    perdues = int((~valide).sum())
    if perdues:
        print(f"  {perdues} images illisibles, écartées")

    garde = valide.nonzero(as_tuple=True)[0]
    paquet = {
        "emb": vecteurs[garde],
        "espece": [entrees[i]["espece"] for i in garde.tolist()],
        "genre": [entrees[i]["genre"] for i in garde.tolist()],
        "famille": [entrees[i]["famille"] for i in garde.tolist()],
        "ordre": [entrees[i]["ordre"] for i in garde.tolist()],
        "source": [entrees[i]["source"] for i in garde.tolist()],
        "split": [entrees[i]["split"] for i in garde.tolist()],
        "modele": config.MODELE_CLIP,
    }
    sortie.parent.mkdir(parents=True, exist_ok=True)
    torch.save(paquet, sortie)
    mo = sortie.stat().st_size / 2 ** 20
    print(f"\n{len(garde)} vecteurs écrits dans {sortie} ({mo:.0f} Mo)")
    print(f"Durée : {(time.time() - depart) / 60:.1f} min")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--images", type=pathlib.Path, required=True,
                    help="dossier contenant Image_Library/ et les deux CSV")
    ap.add_argument("--sortie", type=pathlib.Path,
                    default=config.DONNEES / "poissons_embeddings.pt")
    ap.add_argument("--lot", type=int, default=128)
    ap.add_argument("--ouvriers", type=int, default=8,
                    help="processus qui décodent les JPEG en parallèle")
    a = ap.parse_args()
    return extrait(a.images.expanduser(), a.sortie.expanduser(), a.lot,
                   a.ouvriers)


if __name__ == "__main__":
    raise SystemExit(main())
