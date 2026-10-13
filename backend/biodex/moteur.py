"""
Le moteur : photo -> moteur du règne -> case du dex.

Trois règnes, trois chaînes, choisies d'après ce que le joueur a déclaré
photographier :

  animal      MegaDetector recadre l'animal, BioCLIP 2 tranche sur 411 743
              espèces.
  plante      Pl@ntNet quand le joueur a fourni sa clé — 500 identifications
              par jour et par clé, d'où le fait qu'elle soit personnelle ;
              BioCLIP plantes (444 292 espèces) sinon, ou dès que l'API doute.
  champignon  FungiTastic, spécialisé et bien plus précis, mais borné à 2829
              espèces ; BioCLIP champignons (172 313 espèces) prend le relais
              dès qu'il n'est pas sûr.

Trois différences avec la maquette biodex dont il est issu.

1. Il tourne dans un fil dédié, alimenté par une file. Une analyse prend une
   quinzaine de secondes sur CPU ; faire attendre la requête HTTP tout ce temps
   marche mal depuis un téléphone (coupures réseau, mise en veille). L'app poste
   sa photo, reçoit un identifiant, puis interroge le résultat.

2. La décision se prend au niveau de la *case*, pas de l'espèce. Comme une case
   regroupe les sous-espèces et les synonymes, l'hésitation classique du modèle
   entre proches parents disparaît d'elle-même : « Bos taurus » et « Bos indicus »
   sont deux réponses concurrentes au niveau espèce, mais une seule et même case.
   On somme donc les probabilités par case avant de trancher.

3. Le modèle n'est chargé qu'une fois, à la première utilisation, et jamais
   partagé entre fils : ni torch ni MegaDetector ne garantissent d'être
   réentrants, et un seul fil suffit largement ici.
"""
import queue
import threading
import time
from dataclasses import dataclass, field

from . import config, db

CAT_MD = {"1": "animal", "2": "humain", "3": "véhicule"}


@dataclass
class Resultat:
    etat: str                      # ok | doute | rejet | erreur
    verdict: str = ""
    latin: str = ""
    niveau: str = ""               # espece | genre | ''
    confiance: float = 0.0
    note: str = ""
    case_id: int | None = None
    duree: float = 0.0
    # Les pistes proposées au joueur, au niveau **case** : c'est la case qu'il
    # choisira s'il corrige, pas un binôme latin. [(case_id, latin, proba)]
    top: list = field(default_factory=list)
    # Boîte de MegaDetector, en fractions de l'image : sert à recadrer la
    # découpe. None quand aucun animal n'a été détecté — donc toujours pour la
    # flore, qui n'a pas de détecteur équivalent.
    bbox: tuple[float, float, float, float] | None = None
    # animal | plante | champignon : le règne déclaré par le joueur.
    regne: str = "animal"
    # Qui a tranché : bioclip | plantnet | fungitastic | megadetector.
    moteur: str = ""


class Catalogue:
    """Un catalogue BioCLIP pour un règne : ses espèces, ses cases, son a priori.

    Un règne par catalogue, jamais de mélange. Mettre plantes et champignons
    dans un même espace de labels n'ajoute que des concurrents : la masse par
    case se dilue et le verdict se dégrade, ce qui a été mesuré à plusieurs
    reprises sur la maquette.
    """

    def __init__(self, torch, chemin, regne: str):
        self._torch = torch
        # Le règne sous lequel vivent les cases, qui n'est pas toujours celui du
        # catalogue. « aquatique » cherche dans les cases animales : ses
        # poissons sont déjà au dex, et une capture doit rejoindre la case
        # existante plutôt que d'en ouvrir une seconde à côté.
        self.regne = "animal" if regne == "aquatique" else regne
        print(f"Chargement du catalogue {chemin.name} ({regne})…", flush=True)
        d = torch.load(chemin, weights_only=False)
        self.noms = d["noms"]
        self.txt = d["emb"]        # laissé en float16 : moitié moins de mémoire
        self.obs = d.get("obs") or [0] * len(self.noms)
        # Le catalogue animal v2 donne un groupe explicite par entrée. C'est ce
        # qui permet de ranger « Cocker Spaniel » sous « Chien domestique »
        # plutôt que sous « Cocker » : les races n'ont pas de binôme dont on
        # pourrait déduire un genre. Les catalogues de flore n'en ont pas.
        self.groupes = d.get("genres")
        print(f"  {len(self.noms)} espèces, "
              f"{self.txt.numel() * self.txt.element_size() / 2**30:.2f} Go", flush=True)

        self._indexe_genres()
        self._indexe_cases()
        self._reprend_observations()
        self._prepare_biais()
        self._prepare_tete(d)

    def _prepare_tete(self, d) -> None:
        """La tête « genre » apprise sur les images de FishNet, s'il y en a une.

        Le catalogue seul dit déjà à quoi ressemble un poisson, mais il le dit
        depuis le *texte* : ses vecteurs viennent du nom latin encodé par CLIP,
        jamais d'une photo. La tête, elle, a vu 94 000 poissons. Elle ne tranche
        pas l'espèce — elle penche vers un genre, et ce penchant est reporté sur
        toutes les espèces de ce genre.

        Pourquoi le genre et pas l'espèce : FishNet donne une médiane de deux
        images par espèce, et aucune n'atteint la cinquantaine. À ce régime une
        tête espèce retiendrait les photos, pas les poissons.
        """
        self.tete = None
        poids = d.get("tete_genres")
        if poids is None:
            return
        torch = self._torch
        noms = d["tete_noms"]
        # La tête connaît 1 113 genres, le catalogue en compte davantage : on
        # range les poids dans l'ordre du catalogue, et les genres que la tête
        # ignore restent à zéro — ni poussés, ni pénalisés.
        pos = {g: i for i, g in enumerate(self.noms_genres)}
        lignes = [(pos[g], i) for i, g in enumerate(noms) if g in pos]
        if not lignes:
            print("  !! la tête genres ne recoupe aucun genre du catalogue, "
                  "ignorée", flush=True)
            return
        self.tete = torch.zeros(len(self.noms_genres), poids.shape[1])
        self.tete_biais = torch.full((len(self.noms_genres),), float("-inf"))
        b = d.get("tete_biais")
        for cat_i, tete_i in lignes:
            self.tete[cat_i] = poids[tete_i].float()
            self.tete_biais[cat_i] = float(b[tete_i]) if b is not None else 0.0
        self.tete_connus = torch.tensor([c for c, _ in lignes])
        print(f"  tête genres : {len(lignes)} genres sur "
              f"{len(self.noms_genres)} reconnus par le catalogue", flush=True)

    def _indexe_genres(self) -> None:
        genres = self.groupes or [n.split(" ")[0] for n in self.noms]
        # Un genre latin tient en un mot ; les groupes de races n'en sont pas —
        # « Chien domestique », « Petit élevage ». C'est ce qui distingue une
        # race d'un binôme, sans avoir à deviner d'après l'orthographe : « Tabby
        # cat » ressemble à s'y méprendre à un nom scientifique.
        self.races = {n for n, g in zip(self.noms, genres) if " " in g}
        if self.races:
            print(f"  {len(self.races)} races domestiques au catalogue", flush=True)
        self.noms_genres = sorted(set(genres))
        pos = {g: i for i, g in enumerate(self.noms_genres)}
        self.idx_genre = self._torch.tensor([pos[g] for g in genres])

    def _indexe_cases(self) -> None:
        """Associe chaque entrée du catalogue à sa case, pour pouvoir sommer les
        probabilités par case d'un seul `index_add_`.

        La recherche est bornée au règne : deux règnes peuvent porter le même
        binôme — les homonymies entre champignons et plantes existent — et une
        photo de champignon ne doit jamais atterrir dans une case de plante.
        """
        vers_case = dict(db.lit(
            """SELECT a.latin, a.case_id FROM alias a
               JOIN cases c ON c.id = a.case_id WHERE c.regne = ?""", (self.regne,)))
        manquants = [n for n in self.noms if n not in vers_case]
        if manquants:
            print(f"!! {len(manquants)} noms du catalogue {self.regne} sans case "
                  f"(ex. {manquants[:3]}) — relancer outils/construit_dex.py "
                  f"--regne {self.regne}", flush=True)

        self.cases = sorted({vers_case[n] for n in self.noms if n in vers_case})
        pos = {c: i for i, c in enumerate(self.cases)}
        # Les noms sans case sont dirigés vers un index poubelle en fin de
        # tableau, qu'on ignorera au moment de lire les scores.
        self.poubelle = len(self.cases)
        self.idx_case = self._torch.tensor(
            [pos.get(vers_case.get(n), self.poubelle) for n in self.noms])
        print(f"  {len(self.cases)} cases couvertes par le catalogue", flush=True)

    def _reprend_observations(self) -> None:
        """Va chercher en base les compteurs que le catalogue n'a pas.

        Les catalogues de flore ont été encodés sans compteur d'observations.
        Sans a priori, le modèle met la pâquerette (1,1 million d'observations)
        au coude à coude avec Tetraperone bellioides (17) : mesuré, la
        pâquerette ne sortait même pas du lot. Les compteurs sont déjà en base,
        rangés sur les cases — on les relit plutôt que de réencoder 672 Mo.
        """
        if any(self.obs):
            return
        par_nom = dict(db.lit(
            """SELECT a.latin, c.obs FROM alias a
               JOIN cases c ON c.id = a.case_id
               WHERE a.regne = ?""", (self.regne,)))
        self.obs = [par_nom.get(n, 0) for n in self.noms]
        connus = sum(1 for o in self.obs if o)
        print(f"  {connus} compteurs d'observations repris de la base "
              f"({connus * 100 // max(len(self.noms), 1)} %)", flush=True)

    def _prepare_biais(self) -> None:
        """Terme ajouté aux logits : l'a priori de fréquence, et l'exclusion des
        entrées qui ne désignent aucune espèce.

        GBIF publie des noms comme « Bos spec » ou « Larus indet », qui veulent
        dire « un bovin quelconque » et « un goéland quelconque ». Ils sont très
        proches de tout leur genre dans l'espace CLIP, donc ils raflent la mise :
        sur une photo de vache, « Bos spec » sortait à 38 % devant Bos taurus à
        11 %. Ce ne sont pas des cases jouables, on les met hors course.
        """
        torch = self._torch
        obs = torch.tensor(self.obs, dtype=torch.float32)
        self.biais = config.PRIOR_OBS * torch.log1p(obs)
        if not any(self.obs):
            print("  ATTENTION : catalogue sans compteur d'observations, aucun "
                  "a priori de fréquence — les espèces rarissimes concourent à "
                  "égalité avec les communes", flush=True)

        vagues = [i for i, n in enumerate(self.noms)
                  if n.endswith((" spec", " indet", " sp", " cf"))]
        if vagues:
            self.biais[torch.tensor(vagues)] = float("-inf")
            print(f"  {len(vagues)} entrées non spécifiques écartées "
                  f"(ex. {self.noms[vagues[0]]})", flush=True)

    def probabilites(self, e):
        """`e` est l'image déjà encodée et normalisée par BioCLIP."""
        torch = self._torch
        with torch.no_grad():
            # Produit scalaire par tranches : on ne convertit en float32 qu'un
            # morceau du catalogue à la fois, jamais tous les vecteurs d'un coup.
            cos = torch.empty(len(self.noms))
            for i in range(0, len(self.noms), config.TRANCHE):
                cos[i:i + config.TRANCHE] = self.txt[i:i + config.TRANCHE].float() @ e
            logits = 100.0 * cos + self.biais
            avis = self._avis_de_la_tete(e)
            if avis is not None:
                logits = logits + avis[self.idx_genre]
            return logits.softmax(dim=-1)

    def _avis_de_la_tete(self, e):
        """Ce que la tête genres pense de cette image, en log-probabilités.

        Le résultat est **centré** avant d'être appliqué, et c'est le point
        important : la tête ne connaît que 1 113 genres sur les 3 800 du
        catalogue. Sans centrage, les genres qu'elle ignore recevraient zéro
        pendant que les autres reçoivent une valeur négative, ce qui les
        avantagerait précisément parce qu'ils sont inconnus. Centré, l'avis
        pousse les uns et retient les autres autour de zéro, et l'inconnu reste
        neutre.
        """
        if self.tete is None or config.POIDS_TETE_GENRES == 0:
            return None
        torch = self._torch
        connus = self.tete_connus
        s = self.tete[connus] @ e + self.tete_biais[connus]
        lp = torch.log_softmax(s, dim=-1)
        avis = torch.zeros(len(self.noms_genres))
        avis[connus] = config.POIDS_TETE_GENRES * (lp - lp.mean())
        return avis

    def classe(self, e, k: int = 5, k_cases: int | None = None):
        """Renvoie (top espèces, top genres, top cases) triés par probabilité."""
        torch = self._torch
        pr = self.probabilites(e)

        m_genre = torch.zeros(len(self.noms_genres)).index_add_(0, self.idx_genre, pr)
        m_case = torch.zeros(self.poubelle + 1).index_add_(0, self.idx_case, pr)
        m_case[self.poubelle] = 0.0     # la poubelle ne peut pas gagner

        # On regarde plus loin du côté des cases : ce sont elles qu'on propose
        # au joueur, et il faut de la marge pour appliquer un seuil dessus.
        t_sp = torch.topk(pr, k)
        t_ge = torch.topk(m_genre, k)
        t_ca = torch.topk(m_case, min(k_cases or k, m_case.numel()))
        return (
            [(self.noms[i], float(v)) for i, v in zip(t_sp.indices, t_sp.values)],
            [(self.noms_genres[i], float(v)) for i, v in zip(t_ge.indices, t_ge.values)],
            [(self.cases[i], float(v)) for i, v in zip(t_ca.indices, t_ca.values)],
        )


def pistes_depuis(cases: list[tuple[int, float]]) -> list[tuple[int, str, float]]:
    """Les cases à proposer au joueur, seuil appliqué.

    Le nombre de pistes suit ce que le modèle a réellement à dire : une image
    nette n'en produit qu'une, une image douteuse en produit huit. Le plancher
    évite l'écran vide quand tout est sous le seuil ; le plafond évite la liste
    à rallonge.
    """
    retenues = [(c, p) for c, p in cases if p >= config.SEUIL_PISTE]
    if len(retenues) < config.MIN_PISTES:
        retenues = cases[:config.MIN_PISTES]
    retenues = retenues[:config.MAX_PISTES]
    if not retenues:
        return []

    marques = ",".join("?" * len(retenues))
    noms = {
        r["id"]: r["latin"] for r in db.lit(
            f"SELECT id, latin FROM cases WHERE id IN ({marques})",
            [c for c, _ in retenues])
    }
    return [(c, noms.get(c, ""), p) for c, p in retenues if c in noms]


def case_du_nom(latin: str, regne: str) -> dict | None:
    """Retrouve la case d'un nom latin rendu par un moteur externe.

    Pl@ntNet et FungiTastic ont leur propre référentiel : ils peuvent nommer une
    espèce que notre dex ne connaît pas. On cherche d'abord parmi les alias, qui
    couvrent les synonymes, puis sur le nom accepté.
    """
    r = db.lit_un(
        """SELECT c.id, c.latin, c.nom_fr FROM alias a
           JOIN cases c ON c.id = a.case_id
           WHERE a.latin = ? AND c.regne = ? LIMIT 1""", (latin, regne))
    if r is None:
        r = db.lit_un("SELECT id, latin, nom_fr FROM cases WHERE latin = ? AND regne = ?",
                      (latin, regne))
    return r


class Moteur:
    """Charge les modèles à la demande et classe une image.

    Trois règnes, trois chemins. Chacun a son moteur de tête et son filet :

      animal      MegaDetector recadre, puis BioCLIP tranche.
      plante      Pl@ntNet si le joueur a une clé ; BioCLIP plantes sinon, ou
                  quand l'API doute, échoue, ou ne répond pas.
      champignon  FungiTastic, spécialisé mais borné à 2829 espèces ; BioCLIP
                  champignons prend le relais dès qu'il n'est pas sûr.

    Tout est chargé paresseusement : un serveur qui ne voit que des animaux ne
    paie jamais les 933 Mo des catalogues de flore.
    """

    def __init__(self):
        self._verrou = threading.Lock()
        self._clip_pret = False
        self._catalogues: dict[str, Catalogue] = {}
        self._md = None
        self._fungi = None

    # -------------------------------------------------------------- chargement

    def _charge_clip(self):
        if self._clip_pret:
            return
        import open_clip
        import torch

        self._torch = torch
        torch.set_num_threads(config.FILS_TORCH)
        print("Chargement de BioCLIP 2…", flush=True)
        self.clip, _, self.prep = open_clip.create_model_and_transforms(config.MODELE_CLIP)
        self.clip.eval()
        self._clip_pret = True

    def catalogue(self, regne: str) -> Catalogue:
        """Le catalogue d'un règne, chargé au premier usage."""
        cat = self._catalogues.get(regne)
        if cat is not None:
            return cat
        with self._verrou:
            if regne in self._catalogues:
                return self._catalogues[regne]
            self._charge_clip()
            chemin = {
                "animal": config.CATALOGUE,
                "plante": config.CATALOGUE_PLANTES,
                "champignon": config.CATALOGUE_CHAMPIGNONS,
                "aquatique": config.CATALOGUE_AQUATIQUE,
            }[regne]
            if not chemin.exists():
                raise FileNotFoundError(
                    f"Catalogue {regne} introuvable : {chemin}")
            self._catalogues[regne] = Catalogue(self._torch, chemin, regne)
            print(f"Moteur {regne} prêt.", flush=True)
            return self._catalogues[regne]

    @property
    def md(self):
        """MegaDetector, seulement utile aux animaux."""
        if self._md is None:
            from megadetector.detection.run_detector import load_detector
            print("Chargement de MegaDetector…", flush=True)
            self._md = load_detector(str(config.MD_POIDS))
        return self._md

    @property
    def fungi(self):
        """Le spécialiste champignons, avec son mapping et ses toxiques."""
        if self._fungi is None:
            import json

            import timm
            import torch
            import torchvision.transforms as T

            print("Chargement de FungiTastic…", flush=True)
            classes = {int(k): v for k, v in
                       json.loads(config.FUNGI_CLASSES.read_text(encoding="utf-8")).items()}
            toxiques = set(json.loads(config.FUNGI_TOXIQUES.read_text(encoding="utf-8")))
            modele = timm.create_model(config.FUNGI_MODELE, pretrained=True).eval()
            sorties = modele.get_classifier().out_features
            if sorties != len(classes):
                # Un mapping décalé donnerait des noms faux avec une confiance
                # élevée : sur des champignons, c'est le pire résultat possible.
                raise RuntimeError(
                    f"FungiTastic sort {sorties} classes mais le mapping en "
                    f"contient {len(classes)} : refus de démarrer, les noms "
                    f"seraient faux")
            transforme = T.Compose([T.Resize((384, 384)), T.ToTensor(),
                                    T.Normalize([0.5] * 3, [0.5] * 3)])
            self._fungi = (modele, transforme, classes, toxiques, torch)
            print(f"  {sorties} espèces, {len(toxiques)} marquées toxiques", flush=True)
        return self._fungi

    def charge(self) -> None:
        """Précharge le nécessaire aux animaux, pour que la première photo ne
        paie pas le chargement."""
        self.catalogue("animal")
        _ = self.md

    # ----------------------------------------------------------- classification

    def _encode(self, img):
        """L'image dans l'espace BioCLIP, normalisée."""
        torch = self._torch
        with torch.no_grad():
            e = self.clip.encode_image(self.prep(img).unsqueeze(0))
            return (e / e.norm(dim=-1, keepdim=True))[0]

    def classe(self, img, k: int = 5, k_cases: int | None = None, regne: str = "animal"):
        """Conservé pour les outils d'essai : encode puis classe en une fois."""
        cat = self.catalogue(regne)
        return cat.classe(self._encode(img), k, k_cases)

    # ------------------------------------------------------------------ analyse

    def analyse(self, img, regne: str = "animal", blob: bytes | None = None,
                cle_plantnet: str = "", nom_fichier: str = "photo.jpg") -> Resultat:
        """Aiguille vers le moteur du règne déclaré par le joueur.

        Le règne est déclaré à l'envoi plutôt que deviné : faire tourner les
        trois chaînes sur chaque photo coûterait trois fois le temps d'analyse
        pour une information que le joueur connaît déjà.
        """
        from PIL import ImageOps

        img = ImageOps.exif_transpose(img).convert("RGB")
        if regne == "plante":
            return self._analyse_plante(img, blob, cle_plantnet, nom_fichier)
        if regne == "champignon":
            return self._analyse_champignon(img)
        if regne == "aquatique":
            return self._analyse_aquatique(img)
        return self._analyse_animal(img)

    # ---- poissons ---------------------------------------------------------

    def _analyse_aquatique(self, img) -> Resultat:
        """Le chemin des poissons : même moteur que les animaux, champ réduit.

        Deux écarts avec `_analyse_animal`, tous deux mesurés plutôt que
        supposés.

        MegaDetector est gardé. On pouvait croire qu'un détecteur entraîné sur
        des pièges photographiques terrestres ne verrait rien derrière une
        vitre : sur vingt poissons pris au hasard dans FishNet, il en a cadré
        dix-neuf, à 0,46 de confiance au pire.

        Mais il ne rejette jamais ici. Le vingtième a été classé « personne », et
        sous le règne animal cela aurait renvoyé « Pas d'animal » au joueur.
        Sur un aquarium — des reflets, une main derrière la vitre, un décor — ce
        genre de méprise est trop probable pour qu'on lui donne le dernier mot.
        Quand le cadrage échoue, on analyse l'image entière, ce qui est de toute
        façon ce que le joueur a détouré au doigt.
        """
        cat = self.catalogue("aquatique")
        t0 = time.perf_counter()

        det = self.md.generate_detections_one_image(
            img, "capture", detection_threshold=config.SEUIL_DETECTION)
        dets = sorted(det.get("detections", []), key=lambda d: -d["conf"])
        poissons = [d for d in dets if d["category"] == "1"]

        crop, bbox = img, None
        if poissons:
            d = poissons[0]
            bbox = tuple(d["bbox"])
            crop = self._recadre(img, d["bbox"])
            note = (f"poisson détecté à {d['conf']:.2f}, "
                    f"recadré {crop.size[0]}×{crop.size[1]} px")
        elif dets:
            note = (f"MegaDetector n'a vu que : {CAT_MD.get(dets[0]['category'], '?')} "
                    f"— analyse de l'image entière")
        else:
            note = "rien détecté, analyse de l'image entière"

        esp, gen, cas = cat.classe(self._encode(crop), k_cases=config.MAX_PISTES * 3)
        return self._verdict_bioclip(
            esp, gen, cas, cat, "aquatique", note, time.perf_counter() - t0, bbox,
            config.SEUIL_CASE, config.RATIO_CASE)

    # ---- animaux ----------------------------------------------------------

    def _analyse_animal(self, img) -> Resultat:
        cat = self.catalogue("animal")
        t0 = time.perf_counter()

        det = self.md.generate_detections_one_image(
            img, "capture", detection_threshold=config.SEUIL_DETECTION)
        dets = sorted(det.get("detections", []), key=lambda d: -d["conf"])
        animaux = [d for d in dets if d["category"] == "1"]

        if not animaux and dets:
            quoi = CAT_MD.get(dets[0]["category"], "?")
            return Resultat(
                etat="rejet", verdict="Pas d'animal", regne="animal", moteur="megadetector",
                note=f"MegaDetector n'a vu que : {quoi} ({dets[0]['conf']:.2f})",
                duree=time.perf_counter() - t0)

        crop, note, bbox = img, "", None
        if animaux:
            d = animaux[0]
            bbox = tuple(d["bbox"])
            crop = self._recadre(img, d["bbox"])
            note = f"animal détecté à {d['conf']:.2f}, recadré {crop.size[0]}×{crop.size[1]} px"
        else:
            # Les insectes échappent souvent à MegaDetector, entraîné sur des
            # pièges photographiques : on retente sur l'image entière.
            note = "rien détecté, analyse de l'image entière (chemin insectes)"

        esp, gen, cas = cat.classe(self._encode(crop), k_cases=config.MAX_PISTES * 3)
        return self._verdict_bioclip(
            esp, gen, cas, cat, "animal", note, time.perf_counter() - t0, bbox,
            config.SEUIL_CASE, config.RATIO_CASE)

    # ---- plantes ----------------------------------------------------------

    def _analyse_plante(self, img, blob, cle: str, nom_fichier: str) -> Resultat:
        t0 = time.perf_counter()
        pn, erreur = (None, "aucune clé Pl@ntNet")
        if cle and blob:
            pn, erreur = self._plantnet(blob, nom_fichier, cle)

        if pn:
            latin, score, communs = pn[0]
            if score >= config.SEUIL_PLANTNET:
                c = case_du_nom(latin, "plante")
                # Même précaution que pour les champignons : Pl@ntNet peut
                # proposer deux noms qui aboutissent à la même case.
                pistes = []
                vues = set()
                for nom, s, _ in pn[:config.MAX_PISTES]:
                    autre = case_du_nom(nom, "plante")
                    if autre is not None and autre["id"] not in vues:
                        vues.add(autre["id"])
                        pistes.append((autre["id"], autre["latin"], s))
                if c is not None:
                    return Resultat(
                        etat="ok", verdict=c["nom_fr"] or c["latin"], latin=c["latin"],
                        niveau="espece", confiance=score, case_id=c["id"],
                        regne="plante", moteur="plantnet", top=pistes,
                        duree=time.perf_counter() - t0,
                        note=f"Pl@ntNet à {score:.0%}"
                             + (f" — {communs}" if communs else ""))
                # Pl@ntNet a tranché, mais l'espèce n'est pas dans notre dex :
                # on le dit plutôt que d'inventer une case.
                return Resultat(
                    etat="doute", verdict=latin, latin=latin, niveau="espece",
                    confiance=score, regne="plante", moteur="plantnet", top=pistes,
                    duree=time.perf_counter() - t0,
                    note=f"Pl@ntNet à {score:.0%}, espèce absente du dex")

        # Filet : BioCLIP plantes, seul moteur quand il n'y a pas de clé.
        cat = self.catalogue("plante")
        esp, gen, cas = cat.classe(self._encode(img), k_cases=config.MAX_PISTES * 3)
        pourquoi = (erreur if erreur else
                    f"Pl@ntNet sous le seuil ({pn[0][1]:.0%})" if pn else "Pl@ntNet muet")
        return self._verdict_bioclip(
            esp, gen, cas, cat, "plante", f"BioCLIP plantes — {pourquoi}",
            time.perf_counter() - t0, None,
            config.SEUIL_CASE_FLORE, config.RATIO_CASE_FLORE)

    def _plantnet(self, blob: bytes, nom_fichier: str, cle: str):
        """Interroge Pl@ntNet. Renvoie (liste (latin, score, noms communs), erreur)."""
        import json
        import mimetypes
        import urllib.error
        import urllib.parse
        import urllib.request
        import uuid

        frontiere = uuid.uuid4().hex
        mime = mimetypes.guess_type(nom_fichier)[0] or "image/jpeg"
        corps = (f"--{frontiere}\r\nContent-Disposition: form-data; "
                 f"name=\"organs\"\r\n\r\nauto\r\n").encode()
        corps += (f"--{frontiere}\r\nContent-Disposition: form-data; name=\"images\"; "
                  f"filename=\"{nom_fichier}\"\r\nContent-Type: {mime}\r\n\r\n").encode()
        corps += blob + f"\r\n--{frontiere}--\r\n".encode()

        url = (f"{config.PLANTNET_URL}?api-key={urllib.parse.quote(cle)}"
               f"&nb-results=8&lang=fr")
        req = urllib.request.Request(url, data=corps, headers={
            "User-Agent": "biodex/0.2 (dex local)",
            "Content-Type": f"multipart/form-data; boundary={frontiere}"})
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                d = json.load(r)
        except urllib.error.HTTPError as e:
            # 401 : clé invalide. 429 : quota du jour épuisé. Dans les deux cas
            # le joueur doit pouvoir le lire, pas seulement les journaux.
            detail = {401: "clé Pl@ntNet refusée",
                      429: "quota Pl@ntNet épuisé pour aujourd'hui"}.get(
                          e.code, f"Pl@ntNet HTTP {e.code}")
            return None, detail
        except Exception as e:
            return None, f"Pl@ntNet injoignable ({type(e).__name__})"

        return [(r.get("species", {}).get("scientificNameWithoutAuthor", "?"),
                 float(r.get("score", 0)),
                 ", ".join(r.get("species", {}).get("commonNames", [])[:2]))
                for r in d.get("results", [])[:8]], None

    # ---- champignons ------------------------------------------------------

    def _analyse_champignon(self, img) -> Resultat:
        t0 = time.perf_counter()
        modele, transforme, classes, toxiques, torch = self.fungi
        with torch.no_grad():
            pr = modele(transforme(img).unsqueeze(0)).softmax(-1)[0]
        haut = torch.topk(pr, 8)
        ft = [(classes[int(i)], float(v), int(i) in toxiques)
              for i, v in zip(haut.indices, haut.values)]

        latin, score, toxique = ft[0]
        if score >= config.SEUIL_FUNGI:
            c = case_du_nom(latin, "champignon")
            # Deux espèces du modèle peuvent tomber dans la même case — les
            # synonymes y sont regroupés. On garde alors le meilleur score,
            # sans quoi la même proposition s'affiche deux fois.
            pistes = []
            vues = set()
            for nom, s, _ in ft[:config.MAX_PISTES]:
                autre = case_du_nom(nom, "champignon")
                if autre is not None and autre["id"] not in vues:
                    vues.add(autre["id"])
                    pistes.append((autre["id"], autre["latin"], s))
            note = f"FungiTastic à {score:.0%}"
            if toxique:
                note += " — espèce signalée toxique"
            if c is not None:
                return Resultat(
                    etat="ok", verdict=c["nom_fr"] or c["latin"], latin=c["latin"],
                    niveau="espece", confiance=score, case_id=c["id"],
                    regne="champignon", moteur="fungitastic", top=pistes,
                    duree=time.perf_counter() - t0, note=note)
            return Resultat(
                etat="doute", verdict=latin, latin=latin, niveau="espece",
                confiance=score, regne="champignon", moteur="fungitastic", top=pistes,
                duree=time.perf_counter() - t0,
                note=note + ", espèce absente du dex")

        # Filet : BioCLIP champignons et ses 172 313 espèces. FungiTastic n'en
        # connaît que 2829 — hors de cette liste, il se trompe avec assurance.
        cat = self.catalogue("champignon")
        esp, gen, cas = cat.classe(self._encode(img), k_cases=config.MAX_PISTES * 3)
        return self._verdict_bioclip(
            esp, gen, cas, cat, "champignon",
            f"BioCLIP champignons — FungiTastic sous le seuil ({score:.0%})",
            time.perf_counter() - t0, None,
            config.SEUIL_CASE_FLORE, config.RATIO_CASE_FLORE)

    # ---- verdict commun ---------------------------------------------------

    def _verdict_bioclip(self, esp, gen, cas, cat: Catalogue, regne: str, note: str,
                         duree: float, bbox, seuil_case: float,
                         ratio_min: float) -> Resultat:
        """La décision au niveau case, commune aux trois règnes."""
        (sp1, _), = esp[:1]
        (case1, mc1), (_, mc2) = cas[0], cas[1]
        genre1, mg1 = gen[0]
        ratio_case = mc1 / max(mc2, 1e-9)
        top = pistes_depuis(cas)

        if mc1 >= seuil_case and ratio_case >= ratio_min:
            c = db.lit_un("SELECT id, latin, nom_fr FROM cases WHERE id = ?", (case1,))
            nom = (c["nom_fr"] or c["latin"]) if c else sp1
            # Quand la meilleure piste est une race — « Cocker Spaniel »,
            # « Holstein Friesian cow » — c'est elle qu'on montre en précision
            # plutôt que le binôme latin : la case reste « Chien », mais le
            # joueur voit que sa bête a été reconnue jusqu'à la race.
            precision = sp1 if sp1 in cat.races else (c["latin"] if c else sp1)
            return Resultat(
                etat="ok", verdict=nom, latin=precision, niveau="espece",
                confiance=mc1, case_id=case1, top=top, duree=duree, bbox=bbox,
                regne=regne, moteur="bioclip",
                note=f"{note} — case sûre à {mc1:.0%}, {ratio_case:.0f}× devant la suivante")

        if mg1 >= config.SEUIL_GENRE:
            # On sait à quel genre on a affaire mais pas laquelle de ses espèces :
            # aucune case n'est débloquée, on rend quand même l'information.
            c = db.lit_un("SELECT latin, nom_fr FROM cases WHERE id = ?", (case1,))
            piste = (c["nom_fr"] or c["latin"]) if c else sp1
            return Resultat(
                etat="doute", verdict=f"{genre1} sp.", latin=genre1, niveau="genre",
                confiance=mg1, top=top, duree=duree, bbox=bbox,
                regne=regne, moteur="bioclip",
                note=f"{note} — genre {genre1} à {mg1:.0%}, espèce indécise "
                     f"(piste : {piste})")

        return Resultat(
            etat="doute", verdict="Indéterminé", confiance=mc1, top=top, duree=duree,
            bbox=bbox, regne=regne, moteur="bioclip",
            note=f"{note} — aucun niveau sûr (genre de tête {genre1} à {mg1:.0%})")

    @staticmethod
    def _recadre(img, bbox):
        """bbox MegaDetector = [x, y, largeur, hauteur] normalisé."""
        W, H = img.size
        x, y, w, h = bbox
        mx, my = w * config.MARGE_CROP, h * config.MARGE_CROP
        return img.crop((
            max(0, int((x - mx) * W)), max(0, int((y - my) * H)),
            min(W, int((x + w + mx) * W)), min(H, int((y + h + my) * H)),
        ))


# --------------------------------------------------------------------- la file

class File:
    """File d'analyse à un seul ouvrier.

    Les captures sont enregistrées en base à l'état « attente » dès la réception
    de la photo ; l'ouvrier les reprend une par une. La file en mémoire ne sert
    qu'à réveiller l'ouvrier — la base reste la source de vérité, donc un
    redémarrage ne perd aucune capture.
    """

    def __init__(self):
        self.reveil = queue.Queue()
        self.moteur = Moteur()
        self._fil: threading.Thread | None = None
        self._stop = threading.Event()

    def demarre(self) -> None:
        if config.SANS_MOTEUR:
            print("BIODEX_SANS_MOTEUR=1 : les captures resteront en attente.", flush=True)
            return
        # Une capture laissée à « analyse » vient forcément d'un arrêt brutal :
        # personne ne travaille dessus au démarrage.
        n = db.ecrit("UPDATE captures SET etat = 'attente' WHERE etat = 'analyse'").rowcount
        if n:
            print(f"{n} capture(s) interrompue(s) remise(s) en file.", flush=True)
        self._fil = threading.Thread(target=self._boucle, name="moteur", daemon=True)
        self._fil.start()
        self.relance()

    def arrete(self) -> None:
        self._stop.set()
        self.reveil.put(None)

    def relance(self) -> None:
        """Signale qu'il y a peut-être du travail."""
        self.reveil.put(True)

    def en_attente(self) -> int:
        return db.valeur("SELECT COUNT(*) FROM captures WHERE etat IN ('attente','analyse')", (), 0)

    def _boucle(self) -> None:
        while not self._stop.is_set():
            try:
                # Le réveil périodique rattrape le cas où un signal se perdrait.
                self.reveil.get(timeout=30)
            except queue.Empty:
                pass
            # Une capture qui explose ne doit pas emporter l'ouvrier. Sans ce
            # filet, la moindre erreur d'écriture tuait le fil : le serveur
            # continuait de répondre, mais plus aucune photo n'était analysée,
            # et rien ne le signalait — les captures restaient simplement « en
            # attente » pour toujours.
            try:
                while not self._stop.is_set() and self._traite_une():
                    pass
            except Exception as e:
                import traceback
                print(f"!! l'ouvrier a trébuché : {type(e).__name__}: {e}",
                      flush=True)
                traceback.print_exc()
                # On reprend au tour suivant. La capture fautive a été marquée
                # en erreur par _traite_une, ou le sera au prochain passage.
                time.sleep(1)
        db.ferme()

    def _traite_une(self) -> bool:
        """Traite la plus ancienne capture en attente. Renvoie False si la file
        est vide."""
        r = db.lit_un("""SELECT c.id, c.utilisateur, c.fichier, c.regne,
                                c.fichier_analyse, c.decoupe,
                                u.cle_plantnet
                         FROM captures c
                         JOIN utilisateurs u ON u.id = c.utilisateur
                         WHERE c.etat = 'attente' ORDER BY c.id LIMIT 1""")
        if r is None:
            return False
        db.ecrit("UPDATE captures SET etat = 'analyse' WHERE id = ?", (r["id"],))
        # Tout ce qui suit est protégé : analyse, découpe et écriture. Une
        # capture qui échoue est marquée en erreur et la file continue.
        try:
            from PIL import Image
            # La version retouchée par le joueur si elle existe : c'est elle
            # qui pose la question au moteur, l'originale n'étant gardée que
            # comme témoignage.
            a_analyser = r["fichier_analyse"] or r["fichier"]
            chemin = config.PHOTOS / a_analyser
            # Pl@ntNet veut le fichier d'origine, pas une image ré-encodée :
            # on ne le lit que pour les plantes, et seulement si une clé existe.
            blob = None
            if r["regne"] == "plante" and r["cle_plantnet"]:
                blob = chemin.read_bytes()
            with Image.open(chemin) as img:
                res = self.moteur.analyse(
                    img, regne=r["regne"], blob=blob,
                    cle_plantnet=r["cle_plantnet"], nom_fichier=a_analyser)
        except Exception as e:
            print(f"capture {r['id']} : {type(e).__name__}: {e}", flush=True)
            db.ecrit("""UPDATE captures SET etat = 'erreur', note = ?,
                        fini_le = datetime('now') WHERE id = ?""",
                     (f"{type(e).__name__}: {e}", r["id"]))
            return True

        # La découpe ne sert que pour une case remplie : inutile de détourer une
        # photo de voiture. Elle se fait après l'analyse, qui a fourni la boîte.
        try:
            decoupe = r["decoupe"]
            # Le tracé du joueur l'emporte, et il faut qu'il l'emporte : sa
            # boîte a été calculée sur l'image retouchée, dont le cadre n'est
            # pas celui de l'originale. L'y appliquer découperait une région
            # au hasard.
            if decoupe is None and res.case_id is not None:
                from . import images
                decoupe = images.decoupe(r["fichier"], res.bbox)
            self._enregistre(r["id"], r["utilisateur"], res, decoupe)
            # L'image d'analyse a fait son office. La garder doublerait la
            # place occupée par chaque photo retouchée, pour rien.
            if r["fichier_analyse"]:
                from . import images
                images.supprime(r["fichier_analyse"])
        except Exception as e:
            print(f"capture {r['id']} : écriture impossible — "
                  f"{type(e).__name__}: {e}", flush=True)
            db.ecrit("""UPDATE captures SET etat = 'erreur', note = ?,
                        fini_le = datetime('now') WHERE id = ?""",
                     (f"écriture : {type(e).__name__}: {e}", r["id"]))
            return True
        print(f"capture {r['id']} [{r['regne']}/{res.moteur}] -> {res.verdict} "
              f"({res.duree:.1f} s)", flush=True)
        return True

    def _enregistre(self, capture_id: int, utilisateur: int, res: Resultat,
                    decoupe: str | None = None) -> None:
        noms_fr = {}
        if res.top:
            marques = ",".join("?" * len(res.top))
            noms_fr = {
                r["id"]: r["nom_fr"] for r in db.lit(
                    f"SELECT id, nom_fr FROM cases WHERE id IN ({marques})",
                    [c for c, _, _ in res.top])
            }

        with db.transaction() as cx:
            cx.execute(
                """UPDATE captures SET etat=?, case_id=?, verdict=?, latin=?, niveau=?,
                       confiance=?, note=?, duree=?, decoupe=?, moteur=?, bbox=?,
                       fichier_analyse=NULL, fini_le=datetime('now')
                   WHERE id = ?""",
                (res.etat, res.case_id, res.verdict, res.latin, res.niveau,
                 res.confiance, res.note, res.duree, decoupe, res.moteur,
                 ",".join(f"{v:.5f}" for v in res.bbox) if res.bbox else None,
                 capture_id))
            cx.execute("DELETE FROM captures_top WHERE capture = ?", (capture_id,))
            cx.executemany(
                """INSERT INTO captures_top (capture, rang, latin, nom_fr, proba, case_id)
                   VALUES (?,?,?,?,?,?)""",
                [(capture_id, i, l, noms_fr.get(c), p, c)
                 for i, (c, l, p) in enumerate(res.top, 1)])

            if res.case_id is not None:
                # La case revient à l'auteur et à tous ceux qu'il a identifiés
                # sur la photo. Les amis peuvent avoir été ajoutés avant que
                # l'analyse ne se termine : c'est même le cas courant, puisque
                # l'identification se fait au moment de l'envoi.
                from .routes.captures import _donne_decouverte, _signataires
                for signataire in _signataires(cx, capture_id, utilisateur):
                    _donne_decouverte(cx, signataire, res.case_id, capture_id)

        # Prévenir les amis, une fois la transaction refermée : réveillés plus
        # tôt, ils rechargeraient leurs notifications avant que la trouvaille
        # n'existe. Une photo qu'on garde pour soi ne regarde personne, d'où le
        # filtre sur `partage`.
        if res.case_id is not None:
            partagee = db.valeur(
                "SELECT partage FROM captures WHERE id = ?", (capture_id,), 0)
            if partagee:
                from .routes.notifications import previens_activite
                previens_activite(utilisateur, capture_id)


file = File()
