import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// L'animation de relâche : la sphère s'ouvre et la bête s'enfuit.
///
/// L'inverse exact de la capture. La sphère tombe sur la photo, s'entrouvre en
/// projetant des rais rouges, et la bête s'échappe — la photo s'efface en
/// s'éloignant, comme un animal qui détale. Le rendu suit l'horloge réelle,
/// comme le lancer : les contrôleurs d'animation obéissent à l'échelle du
/// système, qui peut être réglée au minimum.
///
///   0,0 – 0,45 s  la sphère descend au centre et rebondit
///   0,45 – 1,0 s  elle s'ouvre, les rais jaillissent, l'éclair monte
///   1,0 – 1,7 s   la photo s'éloigne et disparaît
class Relacher extends StatefulWidget {
  const Relacher({
    super.key,
    required this.enfant,
    required this.couleur,
    this.surFin,
  });

  /// Ce qui est libéré : la photo, qui s'efface une fois la sphère ouverte.
  final Widget enfant;
  final Color couleur;
  final VoidCallback? surFin;

  @override
  State<Relacher> createState() => _RelacherState();
}

class _RelacherState extends State<Relacher>
    with SingleTickerProviderStateMixin {
  Ticker? _battement;
  Duration _origine = Duration.zero;
  double _t = 0;
  bool _aOuvert = false;

  static const _duree = 1700;

  @override
  void initState() {
    super.initState();
    _battement = createTicker(_avance)..start();
  }

  void _avance(Duration total) {
    if (_origine == Duration.zero) _origine = total;
    final t = ((total - _origine).inMilliseconds / _duree).clamp(0.0, 1.0);
    if (!_aOuvert && t >= .45) {
      _aOuvert = true;
      HapticFeedback.mediumImpact();
    }
    setState(() => _t = t);
    if (t >= 1) {
      _battement?.stop();
      widget.surFin?.call();
    }
  }

  @override
  void dispose() {
    _battement?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // La photo reste entière jusqu'à l'ouverture, puis s'éloigne et s'efface :
    // la bête a filé, il ne reste rien à voir.
    final fuite = ((_t - .55) / .45).clamp(0.0, 1.0);
    return Stack(fit: StackFit.expand, children: [
      Opacity(
        opacity: 1 - fuite,
        child: Transform.scale(
          scale: 1 - .22 * fuite,
          child: widget.enfant,
        ),
      ),
      IgnorePointer(
        child: CustomPaint(
          painter: _PeintreRelache(t: _t, couleur: widget.couleur),
          child: const SizedBox.expand(),
        ),
      ),
    ]);
  }
}

class _PeintreRelache extends CustomPainter {
  _PeintreRelache({required this.t, required this.couleur});

  final double t;
  final Color couleur;

  @override
  void paint(Canvas toile, Size taille) {
    final centre = Offset(taille.width / 2, taille.height * .46);

    if (t < .45) {
      // Descente puis rebond : la sphère arrive et se pose.
      final avance = t / .45;
      final chute = Curves.easeInCubic.transform(avance);
      final y = -60 + (centre.dy + 60) * chute;
      final rebond = avance > .88 ? sin((avance - .88) / .12 * pi) * 8 : 0.0;
      _sphere(toile, Offset(centre.dx, y - rebond), 34, 0);
      return;
    }

    final ouverture = ((t - .45) / .55).clamp(0.0, 1.0);

    // Les rais rouges : ils jaillissent du centre, s'allongent puis pâlissent.
    // C'est la signature visuelle de l'ouverture.
    _rais(toile, centre, taille, ouverture);

    // L'éclair blanc au moment précis de l'ouverture.
    if (ouverture < .45) {
      final e = ouverture / .45;
      toile.drawCircle(
          centre,
          40 + taille.width * .9 * e,
          Paint()..color = Colors.white.withValues(alpha: (1 - e) * .85));
    }

    // Les deux moitiés s'écartent et sortent du champ.
    if (ouverture < .8) {
      _sphere(toile, centre, 34, ouverture / .8);
    }
  }

  /// Les rais de lumière, façon décharge : des fuseaux fins qui partent du
  /// centre, de longueurs inégales pour éviter l'effet de roue dentée.
  void _rais(Canvas toile, Offset centre, Size taille, double ouverture) {
    const combien = 16;
    final longueur = taille.width * (.18 + .62 * Curves.easeOut.transform(ouverture));
    final opacite = ouverture < .3 ? 1.0 : (1 - (ouverture - .3) / .7);
    final pinceau = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (var i = 0; i < combien; i++) {
      final angle = i / combien * pi * 2 + ouverture * .35;
      // Une longueur qui varie d'un rai à l'autre, sans hasard : le même
      // motif à chaque relâche, mais qui ne paraît pas régulier.
      final facteur = .55 + .45 * ((i * 37) % 11) / 10;
      final debut = centre + Offset(cos(angle) * 26, sin(angle) * 26);
      final fin = centre +
          Offset(cos(angle) * longueur * facteur,
                 sin(angle) * longueur * facteur);
      pinceau
        ..strokeWidth = (i.isEven ? 4.5 : 2.5) * (1 - ouverture * .5)
        ..color = (i.isEven ? const Color(0xFFE84C4C) : couleur)
            .withValues(alpha: opacite.clamp(0, 1) * .9);
      toile.drawLine(debut, fin, pinceau);
    }
  }

  /// La sphère, entière ou entrouverte.
  void _sphere(Canvas toile, Offset centre, double rayon, double ouverture) {
    const encre = Color(0xFF17181C);
    final ecart = ouverture * rayon * 2.6;
    final cadre = Rect.fromCircle(center: Offset.zero, radius: rayon);
    final trait = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = encre;

    toile.save();
    toile.translate(centre.dx, centre.dy);

    toile.save();
    toile.translate(0, -ecart);
    toile.drawArc(cadre, pi, pi, true, Paint()..color = const Color(0xFFE84C4C));
    toile.drawArc(cadre, pi, pi, false, trait);
    toile.restore();

    toile.save();
    toile.translate(0, ecart);
    toile.drawArc(cadre, 0, pi, true, Paint()..color = const Color(0xFFF7F7F8));
    toile.drawArc(cadre, 0, pi, false, trait);
    toile.restore();

    if (ouverture == 0) {
      toile.drawLine(Offset(-rayon, 0), Offset(rayon, 0),
          Paint()
            ..color = encre
            ..strokeWidth = 6);
      toile.drawCircle(Offset.zero, rayon * .30, Paint()..color = encre);
      toile.drawCircle(Offset.zero, rayon * .20,
          Paint()..color = const Color(0xFFF7F7F8));
    }
    toile.restore();
  }

  @override
  bool shouldRepaint(covariant _PeintreRelache ancien) => ancien.t != t;
}
