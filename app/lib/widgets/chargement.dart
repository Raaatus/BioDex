import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme.dart';

/// L'attente, en un seul endroit.
///
/// **Pourquoi ce n'est plus un GIF.** Il ne tournait pas dans l'application, et
/// le fichier n'y était pour rien : vérifié au niveau des octets, il avait ses
/// 45 images, ses 45 blocs de contrôle, son délai de 100 ms et son disposal 2.
/// C'est le décodeur d'images animées de Flutter qui refusait de l'animer. On
/// dessine donc les images nous-mêmes, depuis une planche de tuiles, cadencées
/// par un `Ticker`. La rotation devient une chose qu'on contrôle et qu'un test
/// peut vérifier — ce qu'aucun test ne pouvait faire sur un GIF.
///
/// L'anneau autour n'est pas décoratif. Un personnage qui pivote lentement ne
/// se lit pas comme « ça travaille » : sur une attente d'une demi-seconde, on
/// n'en voit que quelques degrés. L'anneau, lui, fait un tour en une seconde et
/// dit sans ambiguïté que quelque chose est en cours.
class Chargement extends StatelessWidget {
  const Chargement({super.key, this.taille = 120, this.message});

  final double taille;

  /// Ce qu'on attend, quand ça vaut la peine d'être dit. « Chargement… » ne
  /// vaut pas la peine : l'animation le dit déjà.
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Pastille(taille: taille),
          if (message != null) ...[
            const SizedBox(height: 14),
            Text(message!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Palette.texteDoux)),
          ],
        ],
      ),
    );
  }
}

/// Le sujet qui tourne, dans son anneau.
class Pastille extends StatefulWidget {
  const Pastille({super.key, this.taille = 120, this.anneau = true});

  final double taille;

  /// L'anneau se coupe pour un usage décoratif — un aperçu posé quelque part
  /// où rien n'est en train de charger.
  final bool anneau;

  /// La planche et sa disposition.
  ///
  /// Elle vient désormais d'un rendu 3D de la grenouille à chapeau, et non
  /// plus d'un GIF converti — même format, même cadence, mais le sujet est le
  /// nôtre. `apercu_modele.py` rappelle ces deux nombres à chaque exécution :
  ///
  ///     python -m outils.modele_rang --source <la grenouille>.glb \
  ///         --destination /tmp/fete.glb
  ///     python -m outils.apercu_modele --source /tmp/fete.glb \
  ///         --dossier /tmp --images 30 --tuile 180
  ///
  /// puis `/tmp/fete_tour.webp` est recopié ici et dans `backend/web/media/`.
  /// `anim_chargement.py` reste pour mémoire : il convertissait un GIF.
  static const chemin = 'assets/animations/chargement.webp';
  static const images = 30;
  static const colonnes = 6;

  /// Un tour du sujet. Lent volontairement : c'est un manège, pas une roue de
  /// hamster.
  static const tour = Duration(milliseconds: 2400);

  /// Un tour de l'anneau. Rapide, parce que c'est lui qui porte le message
  /// « ça travaille ».
  static const tourAnneau = Duration(milliseconds: 1100);

  @override
  State<Pastille> createState() => _PastilleState();
}

class _PastilleState extends State<Pastille>
    with SingleTickerProviderStateMixin {
  late final Ticker _horloge;
  ui.Image? _planche;
  Duration _ecoule = Duration.zero;

  @override
  void initState() {
    super.initState();
    _horloge = createTicker((d) => setState(() => _ecoule = d))..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_planche == null) _charge();
  }

  Future<void> _charge() async {
    // On décode la planche à la main plutôt que par `Image.asset` : le peintre
    // a besoin de l'objet `ui.Image` pour n'en dessiner qu'un morceau.
    final data = await DefaultAssetBundle.of(context).load(Pastille.chemin);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    setState(() => _planche = frame.image);
  }

  @override
  void dispose() {
    _horloge.dispose();
    _planche?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _ecoule.inMicroseconds;
    final part =
        (t % Pastille.tour.inMicroseconds) / Pastille.tour.inMicroseconds;
    final partAnneau = (t % Pastille.tourAnneau.inMicroseconds) /
        Pastille.tourAnneau.inMicroseconds;

    return SizedBox(
      width: widget.taille,
      height: widget.taille,
      child: CustomPaint(
        painter: _PeintrePastille(
          planche: _planche,
          image: (part * Pastille.images).floor() % Pastille.images,
          anneau: widget.anneau ? partAnneau : null,
          fond: Palette.fondSecondaire,
          trait: Palette.accent,
        ),
      ),
    );
  }
}

class _PeintrePastille extends CustomPainter {
  _PeintrePastille({
    required this.planche,
    required this.image,
    required this.anneau,
    required this.fond,
    required this.trait,
  });

  final ui.Image? planche;
  final int image;

  /// La position de l'arc sur le tour, ou null s'il ne faut pas le dessiner.
  final double? anneau;
  final Color fond;
  final Color trait;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final rayon = size.width / 2;

    // Le disque de fond. Le personnage est presque noir sur fond transparent :
    // sans lui, il disparaîtrait dans une page en thème sombre.
    canvas.drawCircle(centre, rayon, Paint()..color = fond);

    final img = planche;
    if (img != null) {
      final tuile = img.width / Pastille.colonnes;
      final src = Rect.fromLTWH(
        (image % Pastille.colonnes) * tuile,
        (image ~/ Pastille.colonnes) * tuile,
        tuile,
        tuile,
      );
      // Le sujet occupe l'intérieur du disque, pas tout le carré : sinon ses
      // pieds sortent du cercle quand il pivote de profil.
      final marge = rayon * 0.10;
      canvas.drawImageRect(
        img,
        src,
        Rect.fromCircle(center: centre, radius: rayon - marge),
        Paint()..filterQuality = FilterQuality.medium,
      );
    }

    final tour = anneau;
    if (tour == null) return;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(size.width * 0.045, 2.5)
      ..strokeCap = StrokeCap.round
      ..color = trait;
    // Un arc d'un quart de tour, pas un cercle complet : c'est le vide qui rend
    // le mouvement visible.
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: rayon - p.strokeWidth / 2),
      tour * 2 * math.pi,
      math.pi / 2,
      false,
      p,
    );
  }

  @override
  bool shouldRepaint(_PeintrePastille vieux) =>
      vieux.image != image ||
      vieux.anneau != anneau ||
      vieux.planche != planche ||
      vieux.fond != fond;
}

/// La même attente, en petit et sans fioriture.
///
/// Pour les endroits où l'attente s'insère dans autre chose : un bouton, un
/// pied de liste qui charge la suite. Le sujet y serait ridicule — à vingt
/// pixels on ne distingue plus rien — et le cercle reste ce qu'il y a de plus
/// lisible.
class PetitChargement extends StatelessWidget {
  const PetitChargement({super.key, this.taille = 18, this.couleur});

  final double taille;
  final Color? couleur;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: taille,
        height: taille,
        child: CircularProgressIndicator(
          strokeWidth: taille < 20 ? 2 : 2.6,
          color: couleur,
        ),
      );
}
