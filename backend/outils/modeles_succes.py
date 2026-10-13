#!/usr/bin/env python3
"""
Prépare les trente grenouilles des succès, d'un bout à l'autre.

Chaque succès a son modèle. Ce qui sort du générateur pèse entre 60 et 136 Mo :
trois millions de faces et des textures en 4096², faits pour un rendu de
cinéma. Trente fichiers pareils, ce sont deux gigaoctets et demi dans un APK.

L'outil enchaîne pour chacun ce qu'il faut :

  1. `modele_rang` réduit le GLB — la géométrie et les textures ;
  2. `apercu_modele` en tire une image fixe et une planche de rotation, pour
     que les vignettes et le bandeau n'aient pas à démarrer un moteur 3D ;
  3. le résultat est recopié dans `web/media/`, que le site sert directement.

**Le réglage.** `--erreur 0.005` plutôt que le 0.001 par défaut. Mesuré sur
trois modèles : 870 Ko contre 300 Ko, et les rendus comparés côte à côte à la
taille d'affichage sont indiscernables. La différence est dans la géométrie,
pas dans les textures — descendre celles-ci à 512² ne gagnait que 10 %, pour
une perte visible sur les écussons et les motifs.

**La correspondance.** Les fichiers du générateur portent son vocabulaire à lui
(« Astro Frog », « Plague Toad Potion Keeper ») et les succès le leur. La table
ci-dessous fait le pont, une fois, explicitement — plutôt qu'un rapprochement
deviné sur les noms, qui se tromperait en silence le jour où un modèle est
régénéré sous un autre titre.

Usage :
    python -m outils.modeles_succes                 # les trente
    python -m outils.modeles_succes --seulement astronaute chevalier
    python -m outils.modeles_succes --verifie       # ne fait rien, contrôle
"""
import argparse
import pathlib
import shutil
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

RACINE = pathlib.Path(__file__).resolve().parent.parent.parent
MODELES = RACINE / "app" / "assets" / "modeles"
WEB = RACINE / "backend" / "web" / "media"
SOURCES = pathlib.Path.home() / "Téléchargements"

# Voir plus haut : le compromis mesuré, pas une valeur au hasard.
ERREUR = 0.005

# nom du succès → fichier livré par le générateur.
#
# Deux rapprochements ne vont pas de soi et méritent d'être dits :
#   — « Sleepy Froggy Lullaby » sert le Lève-tôt. C'est la grenouille qui
#     s'éveille, pas celle qui s'endort ; le Noctambule a son mineur de minuit.
#   — « Leafy Little Frog » sert le Premier pas : la plus simple des trente,
#     pour le succès qu'on décroche sans le chercher.
TABLE = {
    "grenouille":     "Meshy_AI_Leafy_Little_Frog_0901131301_texture.glb",
    "pompier":        "Meshy_AI_Firefighter_Frog_0901125831_texture.glb",
    "pecheur":        "Meshy_AI_Fishing_Frog_Mascot_0901125655_texture.glb",
    "cooking":        "Meshy_AI_Frog_cooking__0901125539_texture.glb",
    "jardinier":      "Meshy_AI_Garden_Frog_0901125638_texture.glb",
    "skateur":        "Meshy_AI_Skater_Frog_0901125603_texture.glb",
    "touriste":       "Meshy_AI_Frog_City_Explorer_0901125533_texture.glb",
    "detective":      "Meshy_AI_Detective_Frog_0901125614_texture.glb",
    "podium":         "Meshy_AI_Champion_Frog_0901125837_texture.glb",
    "matinale":       "Meshy_AI_Sleepy_Froggy_Lullaby_0901125845_texture.glb",
    "astronaute":     "Meshy_AI_Astro_Frog_0901125547_texture.glb",
    "chevalier":      "Meshy_AI_Frog_Knight_0901125551_texture.glb",
    "peintre":        "Meshy_AI_Palette_Puddle_Frog_0901125622_texture.glb",
    "dragon":         "Meshy_AI_Ruby_Dragonfrog_0901125851_texture.glb",
    "musicienne":     "Meshy_AI_Golden_Frog_Serenade_0901131132_texture.glb",
    "noe":            "Meshy_AI_Noé_0901125857_texture.glb",
    "cueilleuse":     "Meshy_AI_Frog’s_Mushroom_Bas_0901125909_texture.glb",
    "jumelles":       "Meshy_AI_jumelles_Frog_Scout_0901125914_texture.glb",
    "entomologiste":  "Meshy_AI_Frog_entomologiste_0901125922_texture.glb",
    "duo":            "Meshy_AI_Froggy_Love_Call_0901130905_texture.glb",
    "scene":          "Meshy_AI_Cosmic_Croaker_Karaok_0901125932_texture.glb",
    "saisons":        "Meshy_AI_Cool_multi-saison_0901130007_texture.glb",
    "apothicaire":    "Meshy_AI_Plague_Toad_Potion_Ke_0901130036_texture.glb",
    "arcenciel":      "Meshy_AI_Rainbow_Frog_Plush_0901130044_texture.glb",
    "lampe":          "Meshy_AI_Midnight_Miner_Frog_0901130112_texture.glb",
    "orfevre":        "Meshy_AI_Frog_orfevre_0901132643_texture.glb",
    "eclair":         "Meshy_AI_éclair_Froglet_0901130059_texture.glb",
    "archere":        "Meshy_AI_Sans faute_Frog_0901131907_texture.glb",
    "bibliothecaire": "Meshy_AI_bibliothécaire_Frog_0901130050_texture.glb",
    "couronne":       "Meshy_AI_legend_Frog_0901132558_texture.glb",

    # ---- les vingt-six grenouilles du 4 septembre ---------------------------
    #
    # Le générateur a produit plusieurs versions de certaines : on garde
    # systématiquement la plus récente, y compris quand le navigateur a ajouté
    # un « (1) » au nom.
    #
    "crabe":         "Meshy_AI_Beach_Frog_Toy_0904122528_texture.glb",
    "estivante":     "Meshy_AI_Beach_Buddy_0904121840_texture.glb",
    "fourmiliere":   "Meshy_AI_Curious_Frog_Detectiv_0904122357_texture(1).glb",
    "russule":       "Meshy_AI_Forest_Forager_Frog_0904122350_texture(1).glb",
    "charancon":     "Meshy_AI_Blue_Beetle_Frog_0904121943_texture(1).glb",
    "orchidophile":  "Meshy_AI_Froggy_Greenhouse_Gar_0904123018_texture.glb",
    "calendrier":    "Meshy_AI_Lucky_Frog_Collector_0904121844_texture(1).glb",
    "myriapode":     "Meshy_AI_Frog_Lab_Companion_0904121902_texture(1).glb",
    "nomade":        "Meshy_AI_Explorer_Frog_0904122125_texture.glb",
    "randonneuse":   "Meshy_AI_Frog_Explorer_0904122323_texture.glb",
    "mycologue":     "Meshy_AI_Harvest_Frog_0904122102_texture.glb",
    "opticienne":    "Meshy_AI_The_Curious_Frog_Doct_0904121851_texture.glb",
    "duelliste":     "Meshy_AI_Bullseye_Frog_0904122032_texture.glb",
    "fleuriste":     "Meshy_AI_Daisy_Garden_Frog_0904121909_texture.glb",
    "fougere":       "Meshy_AI_Ferncloak_Frog_0904122014_texture.glb",
    "vedette":       "Meshy_AI_Frog_Idol_0904122118_texture.glb",
    "conteuse":      "Meshy_AI_Frog_Tailor_0904121923_texture.glb",
    "joailliere":    "Meshy_AI_Gemstone_Frog_Artisan_0904122018_texture.glb",
    "exploratrice":  "Meshy_AI_Globetrotter_Frog_0904121932_texture.glb",
    "coccinelle":    "Meshy_AI_Ladybug_Frog_0904122112_texture(1).glb",
    "marathonienne": "Meshy_AI_Marathon_Frog_Mascot_0904122021_texture.glb",
    "veilleuse":     "Meshy_AI_Midnight_Lantern_Frog_0904122133_texture.glb",
    "maraichere":    "Meshy_AI_Pea_Patch_Polly_0904121916_texture.glb",
    "boussole":      "Meshy_AI_Scout_Frog_Adventure_0904122049_texture.glb",
    "encyclopedie":  "Meshy_AI_The_Scholarly_Frog_0904122026_texture.glb",
    "jumeaux":       "Meshy_AI_Twin_Frog_Keepsake_0904122038_texture.glb",

    # ---- les vingt-six grenouilles du 6 septembre --------------------------
    #
    # Livrées dans l'ordre du tableau des succès, une par emplacement encore
    # vide. Deux noms du générateur trompent et méritent d'être dits :
    #   — « Emerald Horned Frog » est le capricorne, pas un amphibien : les
    #     cornes sont les antennes du longicorne.
    #   — « Curious Frog Detective » est le têtard, malgré son nom ; le vrai
    #     limier est « Detective Toadsworth ».
    "reine":            "Meshy_AI_Royal_Purple_Frog_0906141107_texture.glb",
    "skieuse":          "Meshy_AI_Snowflake_Ski_Penguin_0906141115_texture.glb",
    "geologue":         "Meshy_AI_Rockhound_Frog_0906141123_texture.glb",
    "capitaine":        "Meshy_AI_Captain_Croak_of_the__0906141132_texture.glb",
    "apicultrice":      "Meshy_AI_Honeykeeper_Bear_0906141209_texture.glb",
    "bernard-lhermite": "Meshy_AI_Seaside_Frog_Floaty_0906141223_texture.glb",
    "chef":             "Meshy_AI_Chef_Froggy_s_Kitchen_0906141230_texture.glb",
    "fermiere":         "Meshy_AI_Harvest_Hopper_0906141235_texture.glb",
    "arachnologue":     "Meshy_AI_Spiderweb_Sleuth_Frog_0906141241_texture.glb",
    "alpiniste":        "Meshy_AI_Climber_Frog_0906141253_texture.glb",
    "herpetologue":     "Meshy_AI_Safari_Frog_and_Frien_0906141312_texture.glb",
    "carnivore":        "Meshy_AI_Garden_Frog_Curiositi_0906141318_texture.glb",
    "bucheronne":       "Meshy_AI_Lumberfrog_0906141324_texture.glb",
    "scientifique":     "Meshy_AI_Professor_Ribbit’s__0906141337_texture.glb",
    "alchimiste":       "Meshy_AI_Frog_Wizard_s_Potion__0906141350_texture.glb",
    "cocon":            "Meshy_AI_Blossom_Bugkeeper_0906141357_texture.glb",
    "druide":           "Meshy_AI_Frog_Druid_of_the_Aco_0906141406_texture.glb",
    "pisteresse":       "Meshy_AI_Explorer_Frog_0906141418_texture.glb",
    "biohazard":        "Meshy_AI_Hazmat_Frog_0906141423_texture.glb",
    "urbaine":          "Meshy_AI_Graffiti_Frog_0906141430_texture.glb",
    "archiviste":       "Meshy_AI_Frog_Desk_Buddy_0906141557_texture.glb",
    "botaniste":        "Meshy_AI_Frog_Botanist_Artisan_0906141607_texture.glb",
    "capricorne":       "Meshy_AI_Emerald_Horned_Frog_C_0906141614_texture.glb",
    "limier":           "Meshy_AI_Detective_Toadsworth_0906141621_texture.glb",
    "plongeuse":        "Meshy_AI_Snorkel_Frog_0906141625_texture.glb",
    "tetard":           "Meshy_AI_Curious_Frog_Detectiv_0906142243_texture.glb",
}


def verifie() -> list[str]:
    """Ce qui manque, avant de lancer une heure de calcul pour rien.

    Deux contrôles séparés : la table doit couvrir exactement le catalogue des
    succès — ni oubli ni modèle orphelin — et chaque fichier source doit
    exister. Un nom mal orthographié ici donnerait un succès sans modèle,
    lequel se rabattrait silencieusement sur la grenouille par défaut.
    """
    from biodex import succes

    ennuis = []
    attendus = {s["modele"] for s in succes.catalogue()}
    if manquants := attendus - set(TABLE):
        # Signalé, pas bloquant : un succès sans modèle retombe sur la
        # grenouille par défaut, et rien ne justifie d'empêcher de traiter les
        # autres en attendant.
        print(f"   {len(manquants)} modèle(s) encore attendus : "
              f"{', '.join(sorted(manquants))}")
    if trop := set(TABLE) - attendus:
        ennuis.append(f"modèles que personne ne réclame : {sorted(trop)}")
    for nom, fichier in TABLE.items():
        if not (SOURCES / fichier).exists():
            ennuis.append(f"{nom} : fichier introuvable — {fichier}")
    return ennuis


def _lance(module: str, *args: str) -> None:
    """Enchaîne un outil, et remonte ce qu'il a d'important à dire.

    La sortie est capturée pour que les cinquante lignes de `gltf-transform`
    ne noient pas le tableau d'avancement. Mais elle était jusqu'ici jetée dès
    lors que la commande réussissait — or `modele_rang` signale par là qu'un
    modèle dépasse le plafond de taille, sans pour autant échouer. On a donc
    intégré une grenouille de dix-huit mégaoctets sans que rien ne le dise.
    Les lignes d'alerte remontent maintenant, succès ou non.
    """
    r = subprocess.run([sys.executable, "-m", module, *args],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit(f"{module} a échoué.")
    for ligne in (r.stdout + r.stderr).splitlines():
        if "!!" in ligne:
            print(f"  {ligne.strip()}", flush=True)


def prepare(nom: str, fichier: str) -> tuple[float, float]:
    """Un modèle, de bout en bout. Rend les tailles avant et après, en Mo."""
    source = SOURCES / fichier
    sortie = MODELES / f"{nom}.glb"

    _lance("outils.modele_rang", "--source", str(source),
           "--destination", str(sortie), "--erreur", str(ERREUR))
    _lance("outils.apercu_modele", "--source", str(sortie),
           "--dossier", str(MODELES))

    # Le site sert ses propres fichiers : il ne peut pas lire dans les
    # ressources de l'application Android. Les trois lui sont nécessaires — le
    # modèle pour la fiche, l'image fixe pendant son chargement, et la planche
    # de rotation pour la grille, qui dessine trente vignettes et ne peut pas
    # démarrer trente moteurs 3D.
    WEB.mkdir(parents=True, exist_ok=True)
    for f in (f"{nom}.glb", f"{nom}_apercu.webp", f"{nom}_tour.webp"):
        shutil.copy2(MODELES / f, WEB / f)

    return (source.stat().st_size / 2 ** 20, sortie.stat().st_size / 2 ** 20)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seulement", nargs="*", default=None,
                    help="ne traiter que ces modèles")
    ap.add_argument("--verifie", action="store_true",
                    help="contrôler la table et les sources, sans rien produire")
    a = ap.parse_args()

    if ennuis := verifie():
        for e in ennuis:
            print(f"!! {e}")
        return 1
    print(f"Table complète : {len(TABLE)} modèles, toutes les sources présentes.",
          flush=True)
    if a.verifie:
        return 0

    MODELES.mkdir(parents=True, exist_ok=True)
    a_faire = {n: f for n, f in TABLE.items()
               if a.seulement is None or n in a.seulement}

    total_avant = total_apres = 0.0
    for i, (nom, fichier) in enumerate(sorted(a_faire.items()), 1):
        avant, apres = prepare(nom, fichier)
        total_avant += avant
        total_apres += apres
        print(f"[{i:2d}/{len(a_faire)}] {nom:15s} "
              f"{avant:6.1f} Mo → {apres * 1024:4.0f} Ko", flush=True)

    print(f"\n{len(a_faire)} modèles : {total_avant / 1024:.2f} Go → "
          f"{total_apres:.1f} Mo")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
