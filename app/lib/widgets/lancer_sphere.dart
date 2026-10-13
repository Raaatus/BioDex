import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// L'animation de capture, jouée par-dessus la photo figée.
///
/// L'ordre des scènes suit celui du geste réel, et non celui de l'analyse :
/// on vise, on lance, la sphère secoue, puis on apprend le résultat. La
/// première version faisait partir la sphère à l'arrivée du verdict, si bien
/// que le lancer — le moment qu'on attend — passait en une fraction de seconde
/// à la toute fin.
///
///   0,0 – 0,9 s   le cercle de visée se resserre sur la bête
///   0,9 – 2,15 s  la sphère traverse le cadre en arc, traînée à l'appui
///   2,2 s – …     elle secoue, en boucle, aussi longtemps que dure l'analyse
///   à la réponse  elle s'illumine, ou s'ouvre et la bête s'échappe
///
/// Les quinze secondes d'analyse sont ainsi occupées sans être escamotées.
enum EtatCapture {
  /// Le moteur travaille : on vise, on lance, puis la sphère secoue.
  attente,

  /// Espèce identifiée : la sphère s'illumine.
  reussi,

  /// Rien d'identifié : la sphère s'ouvre.
  manque,
}

class LancerSphere extends StatefulWidget {
  const LancerSphere({
    super.key,
    required this.etat,
    required this.couleur,
    this.surFin,
  });

  final EtatCapture etat;

  /// La couleur du cercle et du halo : celle de la qualité une fois connue,
  /// verte tant qu'on ne sait pas.
  final Color couleur;

  /// Appelé quand tout est terminé, pour rendre la main à la page.
  final VoidCallback? surFin;

  @override
  State<LancerSphere> createState() => _LancerSphereState();
}

class _LancerSphereState extends State<LancerSphere>
    with TickerProviderStateMixin {
  /// Un seul battement, et l'horloge réelle.
  ///
  /// Les `AnimationController` obéissent à l'échelle d'animation du système —
  /// celle des options développeur d'Android. Réglée à 0,5× ou coupée, toute
  /// l'animation défile à une vitesse absurde ou n'apparaît pas : c'est
  /// exactement le symptôme d'une sphère qui « surgit » au lieu d'être lancée.
  /// En mesurant le temps écoulé nous-mêmes, le déroulé ne dépend plus que de
  /// l'horloge.
  Ticker? _battement;
  Duration _origine = Duration.zero;
  double _entreeV = 0;
  double _secousseV = -1;
  double _issueV = -1;

  static const _dureeEntree = 2400;
  static const _dureeSecousse = 1100;
  static const _dureeIssue = 1400;

  bool _aFrappe = false;
  bool _issueLancee = false;

  @override
  void initState() {
    super.initState();
    _battement = createTicker(_avance)..start();
  }

  void _avance(Duration total) {
    if (_origine == Duration.zero) _origine = total;
    final ms = (total - _origine).inMilliseconds;

    // 1. Visée puis lancer, une seule fois.
    final entree = (ms / _dureeEntree).clamp(0.0, 1.0);

    // Un choc au moment de l'impact, pas au lancer : c'est là qu'on le sent.
    if (!_aFrappe && entree >= .90) {
      _aFrappe = true;
      HapticFeedback.mediumImpact();
    }

    var secousse = -1.0;
    var issue = -1.0;
    if (entree >= 1) {
      final apres = ms - _dureeEntree;
      if (widget.etat == EtatCapture.attente) {
        // 2. Secousses, en boucle, aussi longtemps que dure l'analyse.
        secousse = (apres % _dureeSecousse) / _dureeSecousse;
      } else {
        // 3. L'issue, une fois le verdict connu.
        if (!_issueLancee) {
          _issueLancee = true;
          _debutIssue = ms;
          HapticFeedback.heavyImpact();
        }
        issue = ((ms - _debutIssue) / _dureeIssue).clamp(0.0, 1.0);
        if (issue >= 1) {
          _battement?.stop();
          widget.surFin?.call();
        }
      }
    }

    setState(() {
      _entreeV = entree;
      _secousseV = secousse;
      _issueV = issue;
    });
  }

  int _debutIssue = 0;

  @override
  void dispose() {
    _battement?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _PeintreCapture(
          entree: _entreeV,
          secousse: _secousseV,
          issue: _issueV,
          couleur: widget.couleur,
          reussi: widget.etat != EtatCapture.manque,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _PeintreCapture extends CustomPainter {
  _PeintreCapture({
    required this.entree,
    required this.secousse,
    required this.issue,
    required this.couleur,
    required this.reussi,
  });

  /// 0 → 1 : visée jusqu'à 0,5, lancer jusqu'à 0,88, impact ensuite.
  final double entree;

  /// 0 → 1 en boucle, ou -1 quand les secousses ne jouent pas.
  final double secousse;

  /// 0 → 1 pour l'issue, ou -1 tant qu'elle n'a pas commencé.
  final double issue;

  final Color couleur;
  final bool reussi;

  static const _finVisee = .38;
  static const _finVol = .90;

  @override
  void paint(Canvas toile, Size taille) {
    final centre = Offset(taille.width / 2, taille.height * .44);
    final pose = centre + Offset(0, taille.height * .10);

    if (issue >= 0) {
      _issueFinale(toile, pose);
      return;
    }
    if (secousse >= 0) {
      _secoue(toile, pose);
      return;
    }
    _entreeEnScene(toile, centre, pose, taille);
  }

  /// Visée, puis vol, puis impact.
  void _entreeEnScene(Canvas toile, Offset centre, Offset pose, Size taille) {
    if (entree < _finVisee) {
      _cible(toile, centre, taille, entree / _finVisee);
      return;
    }

    if (entree < _finVol) {
      // Le cercle reste, pâlissant : la cible ne disparaît pas sous le lancer.
      _cible(toile, centre, taille, 1, opacite: .35);
      final t = (entree - _finVisee) / (_finVol - _finVisee);

      // Le départ est **dans** le cadre, en bas à gauche. La première version
      // lançait depuis sous la photo : le cadre étant rogné, la sphère
      // n'apparaissait qu'une fois presque arrivée, et il ne restait du lancer
      // qu'un surgissement.
      final depart = Offset(taille.width * .14, taille.height * .96);

      // La traînée dit le mouvement mieux que la sphère seule : sur un vol
      // court, l'œil suit la trace là où il perdrait un point isolé.
      for (var i = 10; i >= 1; i--) {
        final tt = t - i * .035;
        if (tt <= 0) continue;
        final q = _volAt(depart, pose, tt, taille);
        toile.drawCircle(
            q,
            (22 + 10 * tt) * (1 - i * .07),
            Paint()
              ..color = couleur.withValues(alpha: .22 * (1 - i / 11)));
      }

      final p = _volAt(depart, pose, t, taille);
      // Elle grossit en approchant : elle vient vers la bête.
      _sphere(toile, p, 22 + 10 * t, rotation: t * pi * 4);
      return;
    }

    // L'impact : éclair blanc bref, sphère posée.
    final t = (entree - _finVol) / (1 - _finVol);
    _sphere(toile, pose, 28);
    toile.drawCircle(
        pose,
        30 + 140 * t,
        Paint()..color = Colors.white.withValues(alpha: (1 - t) * .85));
  }

  /// La position de la sphère en vol, à l'instant `t` de 0 à 1.
  ///
  /// Une parabole franche : elle monte largement au-dessus de la ligne
  /// départ-cible avant d'y retomber. Sans ce ventre, le lancer paraît glisser
  /// au sol et ne se lit pas.
  Offset _volAt(Offset depart, Offset pose, double t, Size taille) => Offset(
        depart.dx + (pose.dx - depart.dx) * t,
        depart.dy +
            (pose.dy - depart.dy) * t -
            sin(t.clamp(0, 1) * pi) * taille.height * .46,
      );

  /// Le cercle de visée : un anneau fixe, un second qui vient l'épouser.
  void _cible(Canvas toile, Offset centre, Size taille, double t,
      {double opacite = 1}) {
    final rayon = taille.width * .28;
    final pinceau = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white.withValues(alpha: .85 * opacite);
    toile.drawCircle(centre, rayon, pinceau);

    final avance = Curves.easeInOut.transform(t.clamp(0, 1));
    final mobile = rayon + taille.width * .55 * (1 - avance);
    toile.drawCircle(
        centre,
        mobile,
        pinceau
          ..color = couleur.withValues(alpha: (.3 + .6 * avance) * opacite)
          ..strokeWidth = 4);

    final c = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: .9 * opacite);
    const patte = 16.0;
    for (final (sx, sy) in [(-1, -1), (1, -1), (-1, 1), (1, 1)]) {
      final p = centre + Offset(sx * rayon * .96, sy * rayon * .96);
      toile.drawLine(p, p + Offset(-sx * patte, 0), c);
      toile.drawLine(p, p + Offset(0, -sy * patte), c);
    }
  }

  /// Les secousses : la sphère bascule d'un bord sur l'autre, sans fin, tant
  /// que le moteur n'a pas tranché.
  void _secoue(Canvas toile, Offset pose) {
    // Deux basculements par tour, séparés d'un temps mort : c'est le rythme
    // qui fait durer le doute.
    final t = secousse;
    final angle = t < .62 ? sin(t / .62 * pi * 2) * .5 : 0.0;
    toile.save();
    toile.translate(pose.dx, pose.dy + 22);
    toile.rotate(angle);
    toile.translate(-pose.dx, -(pose.dy + 22));
    _sphere(toile, pose, 28);
    toile.restore();
  }

  void _issueFinale(Canvas toile, Offset pose) {
    if (reussi) {
      toile.drawCircle(
          pose,
          32 + 90 * issue,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5 * (1 - issue)
            ..color = couleur.withValues(alpha: 1 - issue));
      // Les étoiles de capture : elles jaillissent de la sphère, montent en
      // tournant puis s'éteignent. C'est le signe que la prise est acquise.
      _etoiles(toile, pose);
      _sphere(toile, pose, 28, lueur: 1 - issue * .5);
    } else {
      _sphere(toile, pose, 28, ouverture: issue);
      toile.drawCircle(
          pose,
          20 + 70 * issue,
          Paint()..color = Colors.white.withValues(alpha: (1 - issue) * .5));
    }
  }

  /// Les étoiles qui tournent autour de la sphère une fois la bête prise.
  void _etoiles(Canvas toile, Offset pose) {
    const combien = 7;
    for (var i = 0; i < combien; i++) {
      final depart = i / combien * pi * 2;
      // Elles s'écartent en spirale : l'angle avance pendant que le rayon
      // grandit, sinon le bouquet paraît figé.
      final angle = depart + issue * 1.9;
      final rayon = 26 + 58 * Curves.easeOut.transform(issue);
      final p = pose + Offset(cos(angle) * rayon, sin(angle) * rayon * .72);
      final taille = 9 * (1 - issue * .55);
      final opacite = issue < .18 ? issue / .18 : (1 - (issue - .18) / .82);
      _etoile(toile, p, taille, angle * 2,
          Paint()..color = Colors.white.withValues(alpha: opacite.clamp(0, 1)));
    }
  }

  /// Une étoile à cinq branches, pointe en haut.
  void _etoile(Canvas toile, Offset centre, double rayon, double rotation,
      Paint pinceau) {
    final chemin = Path();
    for (var i = 0; i < 10; i++) {
      final r = i.isEven ? rayon : rayon * .42;
      final a = rotation + i * pi / 5 - pi / 2;
      final p = centre + Offset(cos(a) * r, sin(a) * r);
      i == 0 ? chemin.moveTo(p.dx, p.dy) : chemin.lineTo(p.dx, p.dy);
    }
    chemin.close();
    toile.drawPath(chemin, pinceau);
  }

  /// La sphère de capture : deux hémisphères, une ceinture, un bouton.
  void _sphere(Canvas toile, Offset centre, double rayon,
      {double rotation = 0, double lueur = 0, double ouverture = 0}) {
    toile.save();
    toile.translate(centre.dx, centre.dy);
    toile.rotate(rotation);

    // Une ombre portée détache la sphère de la photo, qui peut être claire.
    toile.drawCircle(const Offset(0, 3), rayon + 1,
        Paint()..color = Colors.black.withValues(alpha: .28));
    if (lueur > 0) {
      toile.drawCircle(Offset.zero, rayon + 12 * lueur,
          Paint()..color = couleur.withValues(alpha: .55 * lueur));
    }

    final ecart = ouverture * rayon * 1.5;
    final blanc = Paint()..color = Colors.white;
    final rouge = Paint()..color = const Color(0xFFE84C4C);
    final trait = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = const Color(0xFF1B1D21);
    final cadre = Rect.fromCircle(center: Offset.zero, radius: rayon);

    toile.save();
    toile.translate(0, -ecart);
    toile.drawArc(cadre, pi, pi, true, rouge);
    toile.drawArc(cadre, pi, pi, false, trait);
    toile.restore();

    toile.save();
    toile.translate(0, ecart);
    toile.drawArc(cadre, 0, pi, true, blanc);
    toile.drawArc(cadre, 0, pi, false, trait);
    toile.restore();

    if (ouverture == 0) {
      toile.drawLine(
          Offset(-rayon, 0),
          Offset(rayon, 0),
          Paint()
            ..color = const Color(0xFF1B1D21)
            ..strokeWidth = 5);
      toile.drawCircle(
          Offset.zero, rayon * .30, Paint()..color = const Color(0xFF1B1D21));
      toile.drawCircle(Offset.zero, rayon * .20, blanc);
    }
    toile.restore();
  }

  @override
  bool shouldRepaint(covariant _PeintreCapture ancien) => true;
}

/// La couleur d'un palier de qualité, ou le vert d'une prise facile tant qu'on
/// ne sait pas encore ce qu'on a attrapé.
Color couleurAttente(int? qualite) =>
    qualite == null ? const Color(0xFF3DBE6A) : Palette.qualite(qualite);
