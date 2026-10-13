"""
Réception et rangement des photos.

Les téléphones envoient volontiers des JPEG de 4000 px et 8 Mo. On les réduit
avant de les ranger : le classificateur travaille de toute façon sur un recadrage
de quelques centaines de pixels, et le stockage comme la bande passante s'en
portent mieux. L'orientation EXIF est appliquée tout de suite, sinon les photos
prises à la verticale ressortent couchées dans la grille.
"""
import datetime
import io
import pathlib
import secrets

from . import config


class ImageInvalide(Exception):
    pass


# Le format des iPhone. Pillow ne le connaît pas seul.
#
# Depuis iOS 11, l'appareil photo enregistre en HEIC. Safari convertit en JPEG
# quand la photo passe par le sélecteur de photos, mais pas quand elle vient de
# l'application Fichiers, d'un album partagé ou d'AirDrop : le fichier arrive
# alors tel quel, et `Image.open` levait `UnidentifiedImageError` — une photo
# d'iPhone parfaitement valide refusée en 400, « ce n'est pas une image ».
#
# L'enregistrement est global à Pillow et ne se fait qu'une fois. On le pose ici
# plutôt qu'au chargement du module parce que PIL lui-même y est importé
# tardivement, fonction par fonction, pour ne pas ralentir le démarrage.
#
# Absent, le décodeur ne fait pas échouer le serveur : tout le reste continue de
# marcher, et seules les photos HEIC restent refusées comme avant.
_heic_pret = False


def _accepte_heic() -> None:
    global _heic_pret
    if _heic_pret:
        return
    _heic_pret = True
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()
    except Exception:
        pass


# Les découpes sont en WebP : un PNG de 512 px pesait 160 Ko pour une image
# qui en vaut 30 — le PNG ne sait pas compresser une photo, seulement un aplat.
# WebP garde la transparence et divise le poids par cinq.
DECOUPE_SUFFIXE = ".webp"


def dossier_de(utilisateur_id: int | None) -> str:
    """Le sous-dossier d'une photo : le joueur, puis le mois.

    Un dossier plat de dix mille fichiers n'est pas lent, il est illisible :
    impossible de voir, sauvegarder ou effacer les photos d'une personne. Ici
    `photos/12/2026-10/…` dit à qui et à quand sans ouvrir la base. Les noms
    restent uniques dans tout l'arbre, le cache des miniatures peut donc rester
    à plat.
    """
    if utilisateur_id is None:
        return ""
    return f"{utilisateur_id}/{datetime.datetime.now():%Y-%m}"


def _nom_unique(suffixe: str) -> str:
    horo = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return f"{horo}-{secrets.token_hex(6)}{suffixe}"


def _date_exif(img) -> str | None:
    try:
        brut = img.getexif().get(0x9003) or img.getexif().get(0x0132)   # DateTimeOriginal
        if brut:
            return datetime.datetime.strptime(brut, "%Y:%m:%d %H:%M:%S").isoformat(" ")
    except Exception:
        pass
    return None


def _degres(valeur) -> float:
    """Convertit un triplet EXIF (degrés, minutes, secondes) en degrés décimaux."""
    d, m, s = (float(x) for x in valeur)
    return d + m / 60 + s / 3600


def _position_exif(img) -> tuple[float, float] | None:
    """Les coordonnées inscrites dans la photo, si l'appareil les a notées.

    C'est la meilleure source : elle dit où la photo a été prise, alors que la
    position du téléphone au moment de l'envoi dit seulement où l'on se trouvait
    en vidant sa galerie — ce qui peut être à des centaines de kilomètres.
    """
    try:
        gps = img.getexif().get_ifd(0x8825)
        if not gps:
            return None
        lat, lon = _degres(gps[2]), _degres(gps[4])
        if gps.get(1) in ("S", b"S"):
            lat = -lat
        if gps.get(3) in ("W", b"W"):
            lon = -lon
        # Le point (0, 0) au large du golfe de Guinée signale presque toujours
        # un appareil qui a écrit des zéros faute de fix GPS.
        if abs(lat) < 1e-6 and abs(lon) < 1e-6:
            return None
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            return None
        return lat, lon
    except Exception:
        return None


class Metadonnees:
    """Ce que la photo dit d'elle-même : quand, et où."""

    def __init__(self, prise_le: str | None, lat: float | None, lon: float | None):
        self.prise_le = prise_le
        self.lat = lat
        self.lon = lon


def enregistre(blob: bytes, utilisateur_id: int | None = None) -> tuple[str, str, Metadonnees]:
    """Range une photo reçue et sa vignette.

    Renvoie (chemin relatif de la photo, celui de la vignette, métadonnées
    lues). Le chemin est relatif au dossier des photos : `12/2026-10/….jpg`.
    """
    from PIL import Image, ImageOps, UnidentifiedImageError
    _accepte_heic()

    if not blob:
        raise ImageInvalide("Fichier vide.")
    if len(blob) > config.TAILLE_MAX_PHOTO:
        raise ImageInvalide(
            f"Photo trop lourde ({len(blob) // 2**20} Mo, "
            f"maximum {config.TAILLE_MAX_PHOTO // 2**20} Mo).")

    try:
        img = Image.open(io.BytesIO(blob))
        img.load()
    except (UnidentifiedImageError, OSError) as e:
        raise ImageInvalide("Fichier illisible : ce n'est pas une image.") from e

    # À lire avant `exif_transpose`, qui repart d'une image sans métadonnées.
    meta = Metadonnees(_date_exif(img), None, None)
    position = _position_exif(img)
    if position:
        meta.lat, meta.lon = position
    img = ImageOps.exif_transpose(img).convert("RGB")

    config.prepare_dossiers()
    sous = dossier_de(utilisateur_id)
    nom = f"{sous}/{_nom_unique('.jpg')}" if sous else _nom_unique(".jpg")
    (config.PHOTOS / nom).parent.mkdir(parents=True, exist_ok=True)
    (config.VIGNETTES / nom).parent.mkdir(parents=True, exist_ok=True)

    grande = img.copy()
    grande.thumbnail((config.COTE_MAX_PHOTO, config.COTE_MAX_PHOTO), Image.LANCZOS)
    grande.save(config.PHOTOS / nom, "JPEG", quality=88, optimize=True)

    vignette = img.copy()
    vignette.thumbnail((config.COTE_VIGNETTE, config.COTE_VIGNETTE), Image.LANCZOS)
    vignette.save(config.VIGNETTES / nom, "JPEG", quality=80, optimize=True)

    return nom, nom, meta


# Le modèle de détourage est coûteux à instancier mais réutilisable : on le
# garde d'un appel à l'autre, comme les autres modèles.
_session_detourage = None
_verrou_detourage = None


def _session():
    global _session_detourage, _verrou_detourage
    if _verrou_detourage is None:
        import threading
        _verrou_detourage = threading.Lock()
    with _verrou_detourage:
        if _session_detourage is None:
            from rembg import new_session
            _session_detourage = new_session(config.MODELE_DETOURAGE)
        return _session_detourage


def decoupe(nom_photo: str, bbox: tuple[float, float, float, float] | None) -> str | None:
    """Fabrique l'animal détouré sur fond transparent, et renvoie son nom.

    On recadre d'abord largement autour de la boîte de MegaDetector : détourer
    la photo entière ferait garder au modèle la branche sur laquelle l'oiseau
    est perché, ou le pré derrière la vache. Le fond est ensuite retiré, et
    l'image rognée au plus près de ce qui reste.

    Renvoie None si le détourage est désactivé ou s'il ne donne rien
    d'exploitable — l'appelant retombe alors sur la vignette carrée.
    """
    if not config.DETOURAGE:
        return None

    from PIL import Image

    try:
        with Image.open(config.PHOTOS / nom_photo) as img:
            img = img.convert("RGB")
            if bbox is not None:
                x, y, w, h = bbox
                W, H = img.size
                # Marge plus généreuse que pour la classification : mieux vaut
                # un peu de fond, que le modèle enlèvera, qu'une patte coupée.
                mx, my = w * 0.15, h * 0.15
                img = img.crop((
                    max(0, int((x - mx) * W)), max(0, int((y - my) * H)),
                    min(W, int((x + w + mx) * W)), min(H, int((y + h + my) * H)),
                ))
            if min(img.size) < 16:
                return None

            from rembg import remove
            sortie = remove(img, session=_session())

        alpha = sortie.getchannel("A")
        cadre = alpha.getbbox()
        if cadre is None:
            return None                      # rien n'a survécu au détourage
        sortie = sortie.crop(cadre)
        # Un détourage qui ne garde presque rien est raté : on préfère la
        # vignette normale à une poussière de pixels.
        if min(sortie.size) < 24:
            return None

        sortie.thumbnail((config.COTE_DECOUPE, config.COTE_DECOUPE), Image.LANCZOS)
        nom = nom_decoupe(nom_photo)
        (config.DECOUPES / nom).parent.mkdir(parents=True, exist_ok=True)
        sortie.save(config.DECOUPES / nom, "WEBP", quality=86, method=6)
        return nom
    except Exception as e:
        print(f"détourage impossible pour {nom_photo} : {type(e).__name__}: {e}",
              flush=True)
        return None


def decoupe_a_la_main(nom_photo: str, blob: bytes) -> str:
    """Range un détourage tracé au doigt, et renvoie son nom.

    Le détourage automatique se trompe souvent : il garde la branche, coupe une
    patte, ou n'attrape rien du tout sur une plante. Le joueur, lui, sait ce
    qu'il a photographié. Quand il entoure la bête lui-même, son tracé fait foi
    et remplace celui du modèle.

    On ne fait confiance qu'à la forme, pas au fichier : l'image reçue est
    ré-encodée, bornée et rognée sur son canal alpha, comme celle du modèle.
    Une découpe qui arriverait en pleine résolution ferait une vignette de
    quatre méga-octets pour un carré de cinquante pixels à l'écran.
    """
    from PIL import Image, UnidentifiedImageError
    _accepte_heic()

    if not blob:
        raise ImageInvalide("Découpe vide.")
    if len(blob) > config.TAILLE_MAX_PHOTO:
        raise ImageInvalide("Découpe trop lourde.")
    try:
        with Image.open(io.BytesIO(blob)) as img:
            img.load()
            sortie = img.convert("RGBA")
    except (UnidentifiedImageError, OSError) as e:
        raise ImageInvalide("Découpe illisible : ce n'est pas une image.") from e

    # On rogne sur ce qui reste après le tracé : le client envoie souvent
    # l'image entière avec un trou au milieu, et garder les marges vides
    # donnerait une vignette où la bête occupe un dixième du cadre.
    cadre = sortie.getchannel("A").getbbox()
    if cadre is None:
        raise ImageInvalide("Le tracé ne garde aucune partie de la photo.")
    sortie = sortie.crop(cadre)
    if min(sortie.size) < 24:
        raise ImageInvalide("Le tracé est trop petit pour faire une vignette.")

    sortie = _affine_au_modele(sortie)

    sortie.thumbnail((config.COTE_DECOUPE, config.COTE_DECOUPE), Image.LANCZOS)
    nom = nom_decoupe(nom_photo)
    (config.DECOUPES / nom).parent.mkdir(parents=True, exist_ok=True)
    sortie.save(config.DECOUPES / nom, "WEBP", quality=86, method=6)
    return nom


def _affine_au_modele(image):
    """Repasse rembg sur un tracé fait au doigt.

    Le doigt donne la bonne bête mais un contour grossier : on garde forcément
    un peu de branche, un bout de ciel, l'ombre du cadrage. Le modèle sait
    finir ce travail — et sur une image déjà réduite au sujet, il ne peut plus
    se tromper de sujet, ce qui est justement son défaut quand on lui donne la
    photo entière.

    Les deux masques se combinent par intersection : le tracé fixe la zone,
    le modèle en affine le bord. Si le modèle échoue ou rogne trop, on garde
    le tracé — le joueur a toujours raison sur *quoi*, le modèle seulement
    sur *où exactement*.
    """
    if not config.DETOURAGE:
        return image
    try:
        from rembg import remove

        affinee = remove(image.convert("RGB"), session=_session())
        alpha = affinee.getchannel("A")
        cadre = alpha.getbbox()
        if cadre is None:
            return image
        # Un modèle qui ne garde qu'un dixième du tracé s'est trompé de sujet :
        # on préfère le contour grossier du joueur à une poussière de pixels.
        garde = (cadre[2] - cadre[0]) * (cadre[3] - cadre[1])
        if garde < image.size[0] * image.size[1] * 0.10:
            return image

        from PIL import ImageChops

        combine = image.copy()
        combine.putalpha(ImageChops.darker(image.getchannel("A"), alpha))
        recadre = combine.getchannel("A").getbbox()
        return combine.crop(recadre) if recadre else image
    except Exception as e:
        print(f"affinage du tracé impossible : {type(e).__name__}: {e}",
              flush=True)
        return image


def aplatit(blob: bytes) -> bytes:
    """Pose une image transparente sur du blanc, pour l'analyse.

    Les moteurs ne savent pas quoi faire d'un canal alpha : selon la
    bibliothèque, le transparent devient noir — et un animal détouré sur fond
    noir ressemble à une photo de nuit ratée. Le blanc est neutre, et proche
    des fonds sur lesquels ces modèles ont été entraînés.
    """
    from PIL import Image

    with Image.open(io.BytesIO(blob)) as img:
        img.load()
        if img.mode not in ("RGBA", "LA", "P"):
            return blob                      # rien à aplatir
        img = img.convert("RGBA")
        fond = Image.new("RGB", img.size, (255, 255, 255))
        fond.paste(img, mask=img.getchannel("A"))
        tampon = io.BytesIO()
        fond.save(tampon, "JPEG", quality=92)
        return tampon.getvalue()


def avatar(blob: bytes) -> str:
    """Range une photo de profil, recadrée au carré central.

    Le recadrage évite d'avoir à gérer des médaillons de proportions variables
    sur la carte, où la place est comptée.
    """
    from PIL import Image, ImageOps, UnidentifiedImageError
    _accepte_heic()

    if not blob:
        raise ImageInvalide("Fichier vide.")
    if len(blob) > config.TAILLE_MAX_PHOTO:
        raise ImageInvalide("Image trop lourde.")
    try:
        img = Image.open(io.BytesIO(blob))
        img.load()
    except (UnidentifiedImageError, OSError) as e:
        raise ImageInvalide("Fichier illisible : ce n'est pas une image.") from e

    img = ImageOps.exif_transpose(img).convert("RGB")
    cote = min(img.size)
    gauche = (img.width - cote) // 2
    haut = (img.height - cote) // 2
    img = img.crop((gauche, haut, gauche + cote, haut + cote))
    img = img.resize((config.COTE_AVATAR, config.COTE_AVATAR), Image.LANCZOS)

    config.AVATARS.mkdir(parents=True, exist_ok=True)
    nom = _nom_unique(".jpg")
    img.save(config.AVATARS / nom, "JPEG", quality=85, optimize=True)
    return nom


def supprime_avatar(nom: str) -> None:
    try:
        (config.AVATARS / nom).unlink(missing_ok=True)
    except OSError:
        pass


TAILLES_MINIATURE = (96, 160, 256)


def nom_decoupe(nom_photo: str) -> str:
    """Le chemin relatif de la découpe d'une photo : même dossier, même nom,
    en WebP."""
    return str(pathlib.PurePosixPath(nom_photo).with_suffix(DECOUPE_SUFFIXE))


def _variantes(nom: str) -> set[str]:
    """Les noms sous lesquels une image et ses dérivés peuvent exister : le
    sien, et la découpe en WebP comme en PNG (le format d'avant)."""
    p = pathlib.PurePosixPath(nom)
    return {nom, str(p.with_suffix(".webp")), str(p.with_suffix(".png"))}


def _retire_dossiers_vides(chemin: pathlib.Path, racine: pathlib.Path) -> None:
    """Après une suppression, le mois puis le joueur disparaissent s'ils sont
    vides : un arbre de dossiers creux ne dit plus rien."""
    try:
        for d in chemin.parents:
            if not d.is_relative_to(racine) or d == racine:
                break
            d.rmdir()
    except OSError:
        pass


def miniature(source: pathlib.Path, taille: int) -> pathlib.Path:
    """Renvoie une version réduite du fichier, fabriquée une fois puis gardée.

    Les marqueurs de la carte affichent des vignettes de cinquante pixels : leur
    envoyer les découpes en 512 rendait la carte poussive pour rien. La taille
    demandée est arrondie à une des valeurs prévues, sinon n'importe qui pourrait
    faire fabriquer des milliers de fichiers en variant le paramètre.
    """
    from PIL import Image

    taille = min(TAILLES_MINIATURE, key=lambda t: abs(t - taille))
    cache = config.DONNEES / "miniatures" / str(taille)
    # Le cache reste à plat : les noms sont uniques dans tout l'arbre.
    cible = cache / source.name
    if cible.exists():
        return cible

    cache.mkdir(parents=True, exist_ok=True)
    with Image.open(source) as img:
        img = img.copy()
        img.thumbnail((taille, taille), Image.LANCZOS)
        # La transparence des découpes est gardée — en WebP, et en PNG pour
        # celles d'avant la conversion. Le reste part en JPEG.
        if source.suffix.lower() == ".webp":
            img.save(cible, "WEBP", quality=84, method=6)
        elif source.suffix.lower() == ".png":
            img.save(cible, "PNG", optimize=True)
        else:
            img.convert("RGB").save(cible, "JPEG", quality=82, optimize=True)
    return cible


def oublie_miniatures(nom: str) -> None:
    """Jette les miniatures dérivées d'une image qu'on vient de remplacer.

    Elles sont mises en cache par taille, sous le nom du fichier source. Quand
    un joueur retrace sa découpe, le fichier garde le même nom : sans ce
    nettoyage, la grille continuerait à servir l'ancien tracé depuis le cache,
    et le joueur croirait son geste perdu.
    """
    for taille in TAILLES_MINIATURE:
        for fichier in _variantes(nom):
            try:
                (config.DONNEES / "miniatures" / str(taille)
                 / pathlib.PurePosixPath(fichier).name).unlink(missing_ok=True)
            except OSError:
                pass


def supprime(nom: str) -> None:
    for dossier in (config.PHOTOS, config.VIGNETTES):
        try:
            (dossier / nom).unlink(missing_ok=True)
            _retire_dossiers_vides(dossier / nom, dossier)
        except OSError:
            pass
    # Et les miniatures dérivées, sinon elles survivraient à la photo.
    oublie_miniatures(nom)
    # La découpe porte le même nom — en WebP, ou en PNG pour les anciennes.
    for fichier in _variantes(nom) - {nom}:
        try:
            (config.DECOUPES / fichier).unlink(missing_ok=True)
            _retire_dossiers_vides(config.DECOUPES / fichier, config.DECOUPES)
        except OSError:
            pass


def chemin_sur(dossier: pathlib.Path, nom: str) -> pathlib.Path:
    """Empêche qu'un nom de fichier venu de la base sorte de son dossier."""
    p = (dossier / nom).resolve()
    if not p.is_relative_to(dossier.resolve()):
        raise ImageInvalide("Chemin de fichier invalide.")
    return p
