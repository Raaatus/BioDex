import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// La sphère de capture, dessinée au trait.
///
/// Elle sert de bouton central : c'est l'objet du jeu, il mérite mieux qu'une
/// icône d'appareil photo. Dessinée plutôt qu'importée, elle reste nette à
/// toutes les tailles et suit la couleur qu'on lui donne.
class Sphere extends StatelessWidget {
  const Sphere({
    super.key,
    this.taille = 64,
    this.couleur = const Color(0xFFE84C4C),
    this.ouverte = false,
    this.lueur = 0,
  });

  final double taille;

  /// La teinte de la calotte supérieure.
  final Color couleur;

  /// Vrai pour montrer la sphère entrouverte, bouton allumé.
  final bool ouverte;

  /// Un halo autour, de 0 à 1 : sert à signaler qu'elle est active.
  final double lueur;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: taille,
      height: taille,
      child: CustomPaint(
        painter: _PeintreSphere(
            couleur: couleur, ouverte: ouverte, lueur: lueur),
      ),
    );
  }
}

class _PeintreSphere extends CustomPainter {
  _PeintreSphere({
    required this.couleur,
    required this.ouverte,
    required this.lueur,
  });

  final Color couleur;
  final bool ouverte;
  final double lueur;

  @override
  void paint(Canvas toile, Size taille) {
    final centre = Offset(taille.width / 2, taille.height / 2);
    final rayon = taille.width / 2 - taille.width * .06;
    final cadre = Rect.fromCircle(center: centre, radius: rayon);
    const encre = Color(0xFF17181C);
    final epaisseur = rayon * .13;

    if (lueur > 0) {
      toile.drawCircle(centre, rayon + rayon * .22 * lueur,
          Paint()..color = couleur.withValues(alpha: .38 * lueur));
    }

    // Calotte colorée, puis calotte claire : la ceinture les sépare.
    toile.drawArc(cadre, pi, pi, true, Paint()..color = couleur);
    toile.drawArc(cadre, 0, pi, true, Paint()..color = const Color(0xFFF7F7F8));

    // Un reflet en haut à gauche : sans lui la sphère paraît plate.
    toile.save();
    toile.clipPath(Path()..addOval(cadre));
    toile.drawCircle(
        centre + Offset(-rayon * .34, -rayon * .40),
        rayon * .30,
        Paint()..color = Colors.white.withValues(alpha: .34));
    toile.restore();

    final trait = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = epaisseur * .8
      ..color = encre;
    toile.drawCircle(centre, rayon, trait);

    if (ouverte) {
      // Entrouverte : la ceinture s'écarte et le bouton s'allume.
      final ecart = rayon * .16;
      toile.drawLine(
          Offset(centre.dx - rayon, centre.dy - ecart),
          Offset(centre.dx + rayon, centre.dy - ecart),
          Paint()
            ..color = encre
            ..strokeWidth = epaisseur);
      toile.drawLine(
          Offset(centre.dx - rayon, centre.dy + ecart),
          Offset(centre.dx + rayon, centre.dy + ecart),
          Paint()
            ..color = encre
            ..strokeWidth = epaisseur);
      toile.drawCircle(centre, rayon * .30, Paint()..color = encre);
      toile.drawCircle(centre, rayon * .19,
          Paint()..color = const Color(0xFFFFE9A8));
      return;
    }

    toile.drawLine(
        Offset(centre.dx - rayon, centre.dy),
        Offset(centre.dx + rayon, centre.dy),
        Paint()
          ..color = encre
          ..strokeWidth = epaisseur);
    toile.drawCircle(centre, rayon * .30, Paint()..color = encre);
    toile.drawCircle(centre, rayon * .21,
        Paint()..color = const Color(0xFFF7F7F8));
    toile.drawCircle(
        centre,
        rayon * .21,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = epaisseur * .45
          ..color = encre);
  }

  @override
  bool shouldRepaint(covariant _PeintreSphere ancien) =>
      ancien.couleur != couleur ||
      ancien.ouverte != ouverte ||
      ancien.lueur != lueur;
}

/// La sphère du menu, qui frémit quand on la garde appuyée.
///
/// Rien d'utile ne s'y cache : c'est une bête qui s'agite dans sa boule, et le
/// tremblement suffit à donner envie d'appuyer. Il suit l'horloge réelle,
/// comme les autres animations du jeu — l'échelle d'animation du système peut
/// être réglée au minimum, et tout défilerait alors trop vite.
class SphereMenu extends StatefulWidget {
  const SphereMenu({super.key, required this.surAppui, this.taille = 68});

  final VoidCallback surAppui;
  final double taille;

  @override
  State<SphereMenu> createState() => _SphereMenuState();
}

class _SphereMenuState extends State<SphereMenu>
    with SingleTickerProviderStateMixin {
  Ticker? _battement;
  Duration _origine = Duration.zero;
  double _angle = 0;
  bool _tient = false;

  void _demarre() {
    if (_tient) return;
    _tient = true;
    _origine = Duration.zero;
    _dernierCycle = -1;
    _battement ??= createTicker(_avance);
    _battement!.start();
  }

  void _arrete() {
    if (!_tient) return;
    _tient = false;
    _battement?.stop();
    setState(() => _angle = 0);
  }

  int _dernierCycle = -1;

  void _avance(Duration total) {
    if (_origine == Duration.zero) _origine = total;
    final ms = (total - _origine).inMilliseconds;
    // Deux secousses rapprochées, une pause, et ça recommence : le rythme d'un
    // animal qui s'agite par à-coups, pas d'un objet qui vibre.
    final cycle = ms % 900;
    final a = cycle < 420 ? sin(cycle / 420 * pi * 3) * .13 : 0.0;

    // Une secousse dans la main à chaque à-coup : c'est ce qui donne
    // l'impression que quelque chose se débat là-dedans. Le repère de cycle
    // évite de la déclencher à chaque image.
    final tour = ms ~/ 900;
    if (tour != _dernierCycle) {
      _dernierCycle = tour;
      HapticFeedback.mediumImpact();
    } else if (cycle > 130 && cycle < 160) {
      HapticFeedback.lightImpact();
    } else if (cycle > 270 && cycle < 300) {
      HapticFeedback.lightImpact();
    }
    setState(() => _angle = a);
  }

  @override
  void dispose() {
    _battement?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.surAppui,
      onLongPressDown: (_) => _demarre(),
      onLongPressUp: _arrete,
      onLongPressCancel: _arrete,
      onTapCancel: _arrete,
      child: Transform.rotate(
        angle: _angle,
        child: Container(
          width: widget.taille,
          height: widget.taille,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .28),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Sphere(taille: widget.taille, lueur: _tient ? .6 : 0),
        ),
      ),
    );
  }
}
