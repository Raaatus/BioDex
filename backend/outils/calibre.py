#!/usr/bin/env python3
"""
Règle l'a priori d'observation sur un jeu d'images étiquetées.

Le classificateur seul ne sait pas ce qui est fréquent : il place le chevreuil à
égalité avec un cerf chilien vu 404 fois dans l'histoire. On corrige par un
a priori tiré du nombre d'observations GBIF, mais son poids doit se choisir sur
des mesures — trop faible il ne sert à rien, trop fort il ne répondrait plus que
« pigeon » et « moineau ».

Ce script encode chaque image une seule fois, puis rejoue la décision pour
plusieurs poids et compte les bonnes réponses.

    python outils/calibre.py --images ~/biodex/images
"""
import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from biodex import config, db, moteur  # noqa: E402

POIDS = [0.0, 0.25, 0.5, 0.75, 1.0, 1.5]


def case_de(latin: str) -> int | None:
    r = db.lit_un("SELECT case_id FROM alias WHERE latin = ?", (latin,))
    return r["case_id"] if r else None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--images", required=True, type=pathlib.Path)
    ap.add_argument("--etiquettes", type=pathlib.Path,
                    default=pathlib.Path(__file__).parent / "etiquettes.json")
    a = ap.parse_args()

    attendus = {k: v for k, v in json.loads(a.etiquettes.read_text(encoding="utf-8")).items()
                if not k.startswith("_")}
    db.initialise()

    import torch
    from PIL import Image

    m = moteur.Moteur()
    m.charge()

    # ---- une seule passe d'encodage, réutilisée pour tous les poids ---------
    cas = []
    for chemin in sorted(a.images.glob("*.*")):
        attendu = attendus.get(chemin.stem)
        if attendu is None:
            continue
        with Image.open(chemin) as img:
            from PIL import ImageOps
            img = ImageOps.exif_transpose(img).convert("RGB")
            det = m.md.generate_detections_one_image(
                img, "calibrage", detection_threshold=config.SEUIL_DETECTION)
            dets = sorted(det.get("detections", []), key=lambda d: -d["conf"])
            animaux = [d for d in dets if d["category"] == "1"]
            if not animaux and dets:
                cas.append((chemin.stem, attendu, None))     # rejeté par MegaDetector
                continue
            crop = m._recadre(img, animaux[0]["bbox"]) if animaux else img
            with torch.no_grad():
                e = m.clip.encode_image(m.prep(crop).unsqueeze(0))
                e = (e / e.norm(dim=-1, keepdim=True))[0]
                cos = torch.empty(len(m.noms))
                for i in range(0, len(m.noms), config.TRANCHE):
                    cos[i:i + config.TRANCHE] = m.txt[i:i + config.TRANCHE].float() @ e
            cas.append((chemin.stem, attendu, cos))

    manquants = [att for _, att, _ in cas if att != "REJET" and case_de(att) is None]
    if manquants:
        print(f"!! étiquettes sans case : {manquants}\n")

    obs = torch.tensor(m.obs, dtype=torch.float32)
    vagues = torch.tensor([i for i, n in enumerate(m.noms)
                           if n.endswith((" spec", " indet", " sp", " cf"))])

    print(f"{len(cas)} images étiquetées\n")
    entete = "poids  " + "".join(f"{nom[:14]:>16}" for nom, _, _ in cas) + "   score"
    print(entete)
    print("-" * len(entete))

    for poids in POIDS:
        biais = poids * torch.log1p(obs)
        if len(vagues):
            biais[vagues] = float("-inf")
        bons, ligne = 0, f"{poids:<5.2f} "
        for nom, attendu, cos in cas:
            if cos is None:
                juste = attendu == "REJET"
                bons += juste
                ligne += f"{'REJET ok' if juste else 'REJET !':>16}"
                continue
            pr = (100.0 * cos + biais).softmax(dim=-1)
            masse = torch.zeros(m.poubelle + 1).index_add_(0, m.idx_case, pr)
            masse[m.poubelle] = 0.0
            haut = torch.topk(masse, 2)
            case1, mc1 = m.cases[haut.indices[0]], float(haut.values[0])
            mc2 = float(haut.values[1])
            valide = mc1 >= config.SEUIL_CASE and mc1 / max(mc2, 1e-9) >= config.RATIO_CASE

            cible = case_de(attendu) if attendu != "REJET" else None
            if attendu == "REJET":
                juste = not valide
                marque = "rien ok" if juste else "à tort"
            else:
                juste = valide and case1 == cible
                marque = f"{mc1:.2f} ok" if juste else (
                    f"{mc1:.2f} faux" if valide else f"{mc1:.2f} mou")
            bons += juste
            ligne += f"{marque:>16}"
        print(ligne + f"   {bons}/{len(cas)}")

    print("\n« mou » = bonne piste mais sous le seuil, « faux » = mauvaise case validée.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
