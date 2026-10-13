import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Un objet 3D qui tourne, sans moteur 3D.
///
/// Les images ont été rendues une fois par `backend/outils/apercu_modele.py` et
/// rangées dans une planche de tuiles. On en dessine une à la fois. C'est le
/// même procédé que l'animation de chargement, pour la même raison : ce qui est
/// dessiné à la main tourne toujours, là où un décodeur d'images animées fait
/// ce qu'il veut.
///
/// L'autre raison est le coût. La vraie visionneuse utilise `model-viewer`, qui
/// embarque une WebView : acceptable pour un écran qu'on ouvre exprès,
/// déraisonnable pour une vignette dans un bandeau qui défile, et absurde pour
/// une grille de cinquante rangs.
class Tourneur extends StatefulWidget {
  const Tourneur({
    super.key,
    required this.planche,
    this.taille = 56,
    this.images = 24,
    this.colonnes = 5,
    this.tour = const Duration(milliseconds: 6000),
    this.automatique = true,
    this.manipulable = false,
    this.noir = false,
  });

  /// La planche de tuiles, dans les assets.
  final String planche;

  final double taille;
  final int images;
  final int colonnes;

  /// Durée d'un tour complet quand il tourne seul.
  final Duration tour;

  /// Faux pour un aperçu figé — une grille de cinquante objets qui tournent
  /// tous en même temps donne le mal de mer, et fait chauffer le téléphone.
  final bool automatique;

  /// Vrai pour laisser le doigt le faire pivoter.
  final bool manipulable;

  /// La silhouette en noir, pour un rang qu'on n'a pas atteint. On garde la
  /// forme : elle dit qu'il y a quelque chose à gagner, sans le montrer.
  final bool noir;

  @override
  State<Tourneur> createState() => _TourneurState();
}

class _TourneurState extends State<Tourneur>
    with SingleTickerProviderStateMixin {
  Ticker? _horloge;

  /// L'image fixe, légère : une seule vue de 160×160.
  ui.Image? _fixe;

  /// La planche complète, lourde : vingt-quatre vues en 800×800, soit 2,4 Mo
  /// une fois décodée. On ne la charge que si l'objet doit vraiment tourner.
  ///
  /// La grille des succès pose quatre-vingt-deux vignettes. Les charger toutes
  /// faisait deux cents mégaoctets d'images décodées pour n'afficher, la
  /// plupart du temps, qu'une seule vue de chacune. L'image fixe donne le même
  /// résultat pour huit mégaoctets à elles toutes, à résolution identique —
  /// c'est très exactement une vue de la planche.
  ui.Image? _rotation;
  bool _rotationDemandee = false;

  /// La position sur le tour, de 0 à 1.
  double _position = 0;

  /// Vrai pendant que le doigt tient l'objet : la rotation automatique se met
  /// en pause, sinon l'objet se dérobe sous le doigt.
  bool _tenu = false;

  @override
  void initState() {
    super.initState();
    if (widget.automatique) {
      Duration precedent = Duration.zero;
      _horloge = createTicker((d) {
        final delta = d - precedent;
        precedent = d;
        if (_tenu) return;
        setState(() {
          _position =
              (_position + delta.inMicroseconds / widget.tour.inMicroseconds) %
                  1.0;
        });
      })..start();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_fixe != null || _rotationDemandee) return;
    if (widget.automatique) {
      // Il tourne déjà : la planche lui est indispensable tout de suite.
      _chargeLaRotation();
    } else {
      _charge(_cheminFixe).then((img) {
        if (img != null) setState(() => _fixe = img);
      });
    }
  }

  String get _cheminFixe =>
      widget.planche.replaceAll('_tour.webp', '_apercu.webp');

  /// Réclame la planche complète. Appelée au premier doigt posé : avant ça,
  /// l'image fixe suffit et personne n'attend ce qu'il ne regarde pas.
  void _chargeLaRotation() {
    if (_rotationDemandee) return;
    _rotationDemandee = true;
    _charge(widget.planche).then((img) {
      if (img != null) setState(() => _rotation = img);
    });
  }

  Future<ui.Image?> _charge(String chemin) async {
    final data = await DefaultAssetBundle.of(context).load(chemin);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    if (!mounted) {
      frame.image.dispose();
      return null;
    }
    return frame.image;
  }

  @override
  void dispose() {
    _horloge?.dispose();
    // Les deux : l'image fixe survit à l'arrivée de la planche, pour qu'aucune
    // trame ne peigne à partir d'une image déjà libérée.
    _fixe?.dispose();
    _rotation?.dispose();
    super.dispose();
  }

  void _tire(double dx) {
    setState(() {
      // Une largeur de widget balayée fait un tour et demi : assez pour faire
      // le tour d'un pouce, pas au point que le moindre frémissement l'emballe.
      _position = (_position + 1.5 * dx / widget.taille) % 1.0;
      if (_position < 0) _position += 1.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Tant que la planche n'est pas là, on peint l'image fixe : elle tient en
    // une seule vue, d'où la colonne unique et l'indice zéro.
    final tourne = _rotation != null;
    final vue = SizedBox(
      width: widget.taille,
      height: widget.taille,
      child: CustomPaint(
        painter: _PeintreTourneur(
          planche: _rotation ?? _fixe,
          image: tourne
              ? (_position * widget.images).floor() % widget.images
              : 0,
          colonnes: tourne ? widget.colonnes : 1,
          noir: widget.noir,
        ),
      ),
    );
    if (!widget.manipulable) return vue;
    return GestureDetector(
      onHorizontalDragStart: (_) {
        // Le doigt réclame la planche : sans elle, rien à faire tourner.
        _chargeLaRotation();
        setState(() => _tenu = true);
      },
      onHorizontalDragUpdate: (d) => _tire(d.delta.dx),
      onHorizontalDragEnd: (_) => setState(() => _tenu = false),
      onHorizontalDragCancel: () => setState(() => _tenu = false),
      child: vue,
    );
  }
}

class _PeintreTourneur extends CustomPainter {
  _PeintreTourneur({
    required this.planche,
    required this.image,
    required this.colonnes,
    required this.noir,
  });

  final ui.Image? planche;
  final int image;
  final int colonnes;
  final bool noir;

  @override
  void paint(Canvas canvas, Size size) {
    final img = planche;
    if (img == null) return;
    final tuile = img.width / colonnes;
    final src = Rect.fromLTWH(
      (image % colonnes) * tuile,
      (image ~/ colonnes) * tuile,
      tuile,
      tuile,
    );
    final p = Paint()..filterQuality = FilterQuality.medium;
    if (noir) {
      // `srcIn` garde l'alpha et remplace la couleur : la silhouette reste
      // exacte, y compris les trous entre les pattes.
      p.colorFilter =
          const ColorFilter.mode(Color(0xFF141414), BlendMode.srcIn);
    }
    canvas.drawImageRect(
        img, src, Rect.fromLTWH(0, 0, size.width, size.height), p);
  }

  @override
  bool shouldRepaint(_PeintreTourneur vieux) =>
      vieux.image != image ||
      vieux.planche != planche ||
      vieux.noir != noir ||
      vieux.colonnes != colonnes;
}
