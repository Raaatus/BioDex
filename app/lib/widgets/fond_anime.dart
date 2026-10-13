import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Le décor animé d'un thème, derrière tous les écrans.
///
/// Un seul peintre plein écran, posé sous le navigateur par `main.dart` : il
/// ne passe devant rien, il remplit ce que les écrans laissent transparent.
/// Chaque thème y dessine son décor — les mêmes que sur le site, aux mêmes
/// rythmes : pluie de signes, étoiles, feuilles, pétales, bulles, grille,
/// neige, aurore, lucioles, savane, aquarelle, lagon, nébuleuse.
///
/// Sobre sur la batterie : vingt-quatre images par seconde et non soixante,
/// rien quand l'application est à l'arrière-plan, et une seule image figée si
/// le réglage « Décor animé » est éteint.
class FondAnime extends StatefulWidget {
  const FondAnime({super.key, required this.effet, this.anime = true});
  final String effet;

  /// Faux : une seule image, figée. C'est le réglage « Décor animé » des
  /// paramètres — et non le drapeau « animations réduites » du téléphone, que
  /// l'échelle d'animation à zéro des options développeur lève aussi, et qui
  /// figeait le décor chez qui n'avait rien demandé.
  final bool anime;

  @override
  State<FondAnime> createState() => _FondAnimeState();
}

class _FondAnimeState extends State<FondAnime>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _cadence = Duration(milliseconds: 42);

  late final Ticker _ticker;
  late final _Effet _effet;
  Duration _derniere = Duration.zero;
  int _temps = 0;

  /// Le nombre d'images peintes, pour les tests : il doit avancer.
  int get temps => _temps;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _effet = _Effet.parNom(widget.effet);
    _ticker = createTicker(_tic);
    if (widget.anime) {
      _ticker.start();
    } else {
      // Figé : quelques images pour poser le décor, puis plus rien.
      _temps = 40;
    }
  }

  @override
  void didUpdateWidget(FondAnime vieux) {
    super.didUpdateWidget(vieux);
    if (vieux.anime == widget.anime) return;
    if (widget.anime) {
      _relance();
    } else {
      _ticker.stop();
    }
  }

  void _tic(Duration t) {
    // Un ticker relancé repart de zéro : si la dernière image retenue date de
    // l'ancienne course, on l'oublie — sinon rien ne repeint tant que la
    // nouvelle n'a pas rattrapé l'ancienne, et le décor paraît figé au retour.
    if (t < _derniere) _derniere = Duration.zero;
    if (t - _derniere < _cadence) return;
    _derniere = t;
    setState(() => _temps += 1);
  }

  void _relance() {
    if (_ticker.isActive || !widget.anime) return;
    _derniere = Duration.zero;
    _ticker.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState etat) {
    // Rien ne tourne quand on ne regarde pas.
    if (etat == AppLifecycleState.resumed) {
      _relance();
    } else {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _Peintre(_effet, _temps),
        size: Size.infinite,
      ),
    );
  }
}

class _Peintre extends CustomPainter {
  _Peintre(this.effet, this.temps);
  final _Effet effet;
  final int temps;

  @override
  void paint(Canvas canvas, Size size) {
    if (effet.taille != size) {
      effet.taille = size;
      effet.init(size);
    }
    effet.image(canvas, size, temps);
  }

  @override
  bool shouldRepaint(_Peintre vieux) => vieux.temps != temps || vieux.effet != effet;
}

// ───────────────────────────────── les effets ────────────────────────────────

final _hasard = math.Random();
double _entre(double a, double b) => a + _hasard.nextDouble() * (b - a);

/// Un effet : `init` à la taille, `image` à chaque tic. Le canevas est opaque,
/// c'est lui le fond — chaque effet peint le sien.
abstract class _Effet {
  Size taille = Size.zero;
  void init(Size s);
  void image(Canvas c, Size s, int t);

  static _Effet parNom(String nom) => switch (nom) {
        'matrice' => _Matrice(),
        'etoiles' => _Etoiles(),
        'feuilles' => _Feuilles(),
        'sakura' => _Sakura(),
        'neige' => _Neige(),
        'bulles' => _Bulles(),
        'grille' => _Grille(),
        'aurore' => _Aurore(),
        'lucioles' => _Lucioles(),
        'savane' => _Savane(),
        'aquarelle' => _Aquarelle(),
        'lagon' => _Lagon(),
        'nebuleuse' => _Nebuleuse(),
        _ => _Etoiles(),
      };
}

Paint _degradeVertical(Size s, List<Color> couleurs, [List<double>? arrets]) =>
    Paint()
      ..shader = ui.Gradient.linear(
          Offset.zero, Offset(0, s.height), couleurs, arrets);

/// La pluie de signes du thème hacker.
///
/// Les traînées ne sont pas gardées d'une image à l'autre — un peintre
/// repart de zéro à chaque tic. Chaque colonne dessine donc sa tête et
/// dix-huit signes au-dessus, de plus en plus pâles : c'est la même image, et
/// elle ne coûte qu'un tableau de nombres.
class _Matrice extends _Effet {
  static const _signes = 'アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\$+-*/<>=#%&';
  static const _taille = 15.0;
  static const _traine = 18;

  final _colonnes = <List<double>>[]; // [y en rangées, vitesse]
  final _glyphes = <String, TextPainter>{};

  TextPainter _glyphe(String s, Color couleur) {
    final cle = '$s${couleur.toARGB32()}';
    return _glyphes.putIfAbsent(cle, () {
      final p = TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(
                color: couleur, fontSize: _taille, fontFamily: 'monospace')),
        textDirection: TextDirection.ltr,
      )..layout();
      return p;
    });
  }

  @override
  void init(Size s) {
    _colonnes
      ..clear()
      ..addAll(List.generate((s.width / _taille).ceil(),
          (_) => [_hasard.nextDouble() * s.height / _taille, _entre(.35, 1.25)]));
  }

  @override
  void image(Canvas c, Size s, int t) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF000000));
    for (var i = 0; i < _colonnes.length; i++) {
      final col = _colonnes[i];
      final tete = col[0].floor();
      for (var k = 0; k < _traine; k++) {
        final rangee = tete - k;
        if (rangee < 0) break;
        final y = rangee * _taille;
        if (y > s.height) continue;
        // Un signe stable quelques images durant, puis un autre : le
        // scintillement vient de là, pas d'un tirage à chaque tic.
        final graine = (i * 73856093) ^ (rangee * 19349663) ^ ((t ~/ 4) * 83492791);
        final signe = _signes[graine.abs() % _signes.length];
        final alpha = k == 0 ? .95 : (1 - k / _traine) * .7;
        final couleur = k == 0
            ? Color.fromRGBO(200, 255, 208, alpha * .6)
            : Color.fromRGBO(25, 201, 74, alpha * .6);
        _glyphe(signe, couleur).paint(c, Offset(i * _taille, y - _taille));
      }
      col[0] += col[1];
      if (tete * _taille > s.height + _traine * _taille && _hasard.nextDouble() > .975) {
        col[0] = 0;
      }
    }
  }
}

/// Nuit étoilée : des étoiles qui scintillent, et de temps en temps une
/// filante.
class _Etoiles extends _Effet {
  final _etoiles = <List<double>>[]; // x, y, r, phase, v, teinte(0..2)
  List<double>? _filante;            // x, y, vx, vy, vie

  @override
  void init(Size s) {
    _etoiles
      ..clear()
      ..addAll(List.generate((s.width * s.height / 4500).round(), (_) {
        final tirage = _hasard.nextDouble();
        return [
          _hasard.nextDouble() * s.width, _hasard.nextDouble() * s.height,
          _entre(.4, 1.7), _hasard.nextDouble() * math.pi * 2, _entre(.02, .08),
          tirage < .15 ? 1 : (tirage < .35 ? 2 : 0),
        ];
      }));
  }

  @override
  void image(Canvas c, Size s, int t) {
    c.drawRect(Offset.zero & s,
        _degradeVertical(s, const [Color(0xFF05081A), Color(0xFF0D1430)]));
    final p = Paint();
    for (final e in _etoiles) {
      final a = .45 + .55 * math.pow(math.sin(e[3] + t * e[4]), 2);
      p.color = switch (e[5].toInt()) {
        1 => Color.fromRGBO(255, 220, 170, a),
        2 => Color.fromRGBO(190, 210, 255, a),
        _ => Color.fromRGBO(255, 255, 255, a),
      };
      c.drawCircle(Offset(e[0], e[1]), e[2], p);
    }
    if (_filante == null && _hasard.nextDouble() < 1 / 180) {
      _filante = [_entre(0, s.width * .8), _entre(0, s.height * .4), _entre(9, 14), _entre(4, 7), 0];
    }
    final f = _filante;
    if (f != null) {
      const long = 14 / 4;
      final fin = Offset(f[0] - f[2] * long, f[1] - f[3] * long);
      c.drawLine(
          Offset(f[0], f[1]), fin,
          Paint()
            ..shader = ui.Gradient.linear(Offset(f[0], f[1]), fin,
                [const Color(0xF2FFFFFF), const Color(0x00FFFFFF)])
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round);
      f[0] += f[2]; f[1] += f[3]; f[4] += 1;
      if (f[4] > 28 || f[0] > s.width || f[1] > s.height) _filante = null;
    }
  }
}

// ── les formes : feuilles, pétales, acacia ──────────────────────────────
//
// Dessinées dans un repère unitaire (de -1 à 1), puis posées à l'échelle.

const _erable = [
  [0.0, -1.0], [.18, -.55], [.52, -.72], [.42, -.3], [.95, -.38], [.6, .02], [.78, .42],
  [.3, .3], [.14, .9], [0.0, .6], [-.14, .9], [-.3, .3], [-.78, .42], [-.6, .02],
  [-.95, -.38], [-.42, -.3], [-.52, -.72], [-.18, -.55],
];

void _dessineErable(Canvas c, Paint plein, Paint trait) {
  final p = Path();
  for (var i = 0; i < _erable.length; i++) {
    final pt = Offset(_erable[i][0], _erable[i][1]);
    i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
  }
  p.close();
  c.drawPath(p, plein);
  final n = Path();
  for (final v in const [[0.0, -1.0], [.95, -.38], [.78, .42], [-.78, .42], [-.95, -.38]]) {
    n.moveTo(0, .6); n.lineTo(v[0] * .9, v[1] * .9);
  }
  n.moveTo(0, .6); n.lineTo(0, 1.25);
  c.drawPath(n, trait);
}

void _dessineChene(Canvas c, Paint plein, Paint trait) {
  final p = Path();
  for (var i = 0; i <= 60; i++) {
    final a = i / 60 * math.pi * 2;
    final lobes = 1 + .22 * math.cos(a * 5 + math.pi);
    final x = math.sin(a) * .55 * lobes * (1 - .25 * math.cos(a));
    final y = -math.cos(a) * lobes;
    i == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
  }
  p.close();
  c.drawPath(p, plein);
  final n = Path()..moveTo(0, 1.3)..lineTo(0, -.9);
  for (var k = -.6; k < .8; k += .35) {
    n.moveTo(0, k); n.lineTo(.4, k - .25); n.moveTo(0, k); n.lineTo(-.4, k - .25);
  }
  c.drawPath(n, trait);
}

void _dessineHetre(Canvas c, Paint plein, Paint trait) {
  final p = Path()
    ..moveTo(0, -1)
    ..cubicTo(.7, -.6, .7, .5, 0, 1)
    ..cubicTo(-.7, .5, -.7, -.6, 0, -1);
  c.drawPath(p, plein);
  final n = Path()..moveTo(0, 1.3)..lineTo(0, -.95);
  for (var k = -.55; k < .7; k += .3) {
    n.moveTo(0, k); n.lineTo(.42, k - .3); n.moveTo(0, k); n.lineTo(-.42, k - .3);
  }
  c.drawPath(n, trait);
}

Path _petale() => Path()
  ..moveTo(0, 1)
  ..cubicTo(.95, .75, .95, -.45, .38, -.9)
  ..quadraticBezierTo(.18, -1.02, 0, -.68)
  ..quadraticBezierTo(-.18, -1.02, -.38, -.9)
  ..cubicTo(-.95, -.45, -.95, .75, 0, 1);

void _dessineFleur(Canvas c, Paint plein) {
  for (var i = 0; i < 5; i++) {
    c.save();
    c.rotate(i / 5 * math.pi * 2);
    c.translate(0, -.95);
    c.scale(.55, .9);
    c.drawPath(_petale(), plein);
    c.restore();
  }
  final coeur = Paint()..color = const Color(0xFFF4D35E);
  for (var i = 0; i < 6; i++) {
    final a = i / 6 * math.pi * 2;
    c.drawCircle(Offset(math.cos(a) * .22, math.sin(a) * .22), .09, coeur);
  }
}

/// Un acacia parasol en ombre chinoise : tronc, branches qui s'écartent, cime
/// plate au dessus presque droit et au dessous festonné.
void _dessineAcacia(Canvas c, double x, double y, double h, double l) {
  final ombre = Paint()..color = const Color(0xFF120806);
  final branche = Paint()
    ..color = const Color(0xFF120806)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  c.drawPath(
      Path()
        ..moveTo(x - 3.5, y)..lineTo(x + 3.5, y)
        ..lineTo(x + 1.5, y - h * .42)..lineTo(x - 1.5, y - h * .42)..close(),
      ombre);
  final haut = y - h * .42;
  final cime = haut - h * .3;
  for (final d in [[-l * .36, -h * .22], [l * .34, -h * .25], [-l * .12, -h * .3], [l * .14, -h * .29], [-l * .24, -h * .27]]) {
    branche.strokeWidth = 2;
    c.drawPath(
        Path()..moveTo(x, haut)..quadraticBezierTo(x + d[0] * .35, haut + d[1] * .4, x + d[0], haut + d[1]),
        branche);
    branche.strokeWidth = 1.2;
    c.drawLine(Offset(x + d[0] * .6, haut + d[1] * .6), Offset(x + d[0] * .9, haut + d[1] * .95 - 6), branche);
  }
  Path couronne(double cx, double cy, double larg, double prof, int n) {
    final p = Path()..moveTo(cx - larg / 2, cy + 2);
    for (var i = 0; i <= n; i++) {
      final px = cx - larg / 2 + larg * i / n;
      p.lineTo(px, cy - (i == 0 || i == n ? 0 : 3 + 3 * (math.sin(i * 2.1)).abs()));
    }
    for (var i = n; i >= 0; i--) {
      final px = cx - larg / 2 + larg * i / n;
      final pr = 6 + prof * (1 - (i - n / 2).abs() / (n / 2 + .5));
      p.quadraticBezierTo(px + larg / (2 * n), cy + pr + 5, px - larg / (2 * n), cy + pr);
    }
    return p..close();
  }
  c.drawPath(couronne(x, cime, l, h * .13, 10), ombre);
  c.drawPath(couronne(x + l * .08, cime - h * .1, l * .45, 4, 6), ombre);
}

/// Des choses qui tombent en se balançant : feuilles, pétales, flocons.
abstract class _Chute extends _Effet {
  _Chute({required this.combien, required this.gabarit, required this.vitesse,
          required this.balancement, this.vent = 0});
  final int combien;
  final List<double> gabarit, vitesse, balancement;
  final double vent;
  final parts = <_Part>[];

  Color couleur();
  void fond(Canvas c, Size s);
  void forme(Canvas c, double x, double y, _Part p, int t);

  _Part neuve(Size s, bool haut) => _Part(
        x: _hasard.nextDouble() * s.width, y: haut ? -20 : _hasard.nextDouble() * s.height,
        l: _entre(gabarit[0], gabarit[1]), v: _entre(vitesse[0], vitesse[1]),
        phase: _hasard.nextDouble() * math.pi * 2, bal: _entre(balancement[0], balancement[1]),
        rot: _hasard.nextDouble() * math.pi * 2, vrot: _entre(-.05, .05), c: couleur(),
        variante: _hasard.nextInt(1000),
      );

  @override
  void init(Size s) {
    parts
      ..clear()
      ..addAll(List.generate((combien * s.width * s.height / (390 * 844)).round(), (_) => neuve(s, false)));
  }

  @override
  void image(Canvas c, Size s, int t) {
    fond(c, s);
    for (var i = 0; i < parts.length; i++) {
      final p = parts[i];
      final x = (p.x + math.sin(t * .04 + p.phase) * p.bal + t * vent) % (s.width + 40) - 20;
      forme(c, x, p.y, p, t);
      p.y += p.v;
      p.rot += p.vrot;
      if (p.y > s.height + 20) parts[i] = neuve(s, true);
    }
  }
}

class _Part {
  _Part({required this.x, required this.y, required this.l, required this.v, required this.phase,
         required this.bal, required this.rot, required this.vrot, required this.c, required this.variante});
  double x, y, l, v, phase, bal, rot, vrot;
  Color c;
  int variante;
}

void _pose(Canvas c, double x, double y, double echelle, double angle, void Function(Canvas) dessine) {
  c.save();
  c.translate(x, y);
  c.rotate(angle);
  c.scale(echelle, echelle);
  dessine(c);
  c.restore();
}

/// Forêt : érable, chêne, hêtre, nervurés, en sept teintes d'automne.
class _Feuilles extends _Chute {
  _Feuilles() : super(combien: 30, gabarit: const [7, 13], vitesse: const [.5, 1.3], balancement: const [10, 30]);
  static const _teintes = [Color(0xFFB8702C), Color(0xFFC9922F), Color(0xFF8C4A1F), Color(0xFF6E7F2A),
                           Color(0xFFA35A24), Color(0xFFD4A94A), Color(0xFFC1392B)];
  @override
  Color couleur() => _teintes[_hasard.nextInt(_teintes.length)];
  @override
  void fond(Canvas c, Size s) =>
      c.drawRect(Offset.zero & s, _degradeVertical(s, const [Color(0xFF101A14), Color(0xFF16241B)]));
  @override
  void forme(Canvas c, double x, double y, _Part p, int t) {
    final plein = Paint()..color = p.c;
    final trait = Paint()
      ..color = const Color(0x73281405)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 / p.l
      ..strokeCap = StrokeCap.round;
    _pose(c, x, y, p.l, p.rot, (c) {
      switch (p.variante % 3) {
        case 0: _dessineErable(c, plein, trait);
        case 1: _dessineChene(c, plein, trait);
        default: _dessineHetre(c, plein, trait);
      }
    });
  }
}

/// Sakura : des pétales de cerisier, l'encoche au bout, et une fleur entière
/// sur huit.
class _Sakura extends _Chute {
  _Sakura() : super(combien: 40, gabarit: const [5, 9], vitesse: const [.4, 1.1], balancement: const [14, 36], vent: .25);
  static const _teintes = [Color(0xFFFFC2D4), Color(0xFFFFB0C8), Color(0xFFFFD3DF), Color(0xFFF9A0BD), Color(0xFFFFE0EA)];
  @override
  Color couleur() => _teintes[_hasard.nextInt(_teintes.length)];
  @override
  void fond(Canvas c, Size s) =>
      c.drawRect(Offset.zero & s, _degradeVertical(s, const [Color(0xFFFFF8FB), Color(0xFFFFEEF4)]));
  @override
  void forme(Canvas c, double x, double y, _Part p, int t) {
    if (p.variante % 8 == 0) {
      _pose(c, x, y, p.l * 1.1, p.rot, (c) => _dessineFleur(c, Paint()..color = p.c));
    } else {
      _pose(c, x, y, p.l, p.rot, (c) {
        c.drawPath(
            _petale(),
            Paint()
              ..shader = ui.Gradient.linear(const Offset(0, 1), const Offset(0, -1), [const Color(0xFFF48FB1), p.c]));
      });
    }
  }
}

/// Hiver : la neige, lente, un peu de vent.
class _Neige extends _Chute {
  _Neige() : super(combien: 90, gabarit: const [1.2, 3.6], vitesse: const [.35, 1.1], balancement: const [6, 18], vent: .12);
  static const _teintes = [Color(0xF2FFFFFF), Color(0xE6DCE8F5), Color(0xD9C8D7EB)];
  @override
  Color couleur() => _teintes[_hasard.nextInt(_teintes.length)];
  @override
  void fond(Canvas c, Size s) =>
      c.drawRect(Offset.zero & s, _degradeVertical(s, const [Color(0xFFE9F0F8), Color(0xFFF6F9FC)]));
  @override
  void forme(Canvas c, double x, double y, _Part p, int t) =>
      c.drawCircle(Offset(x, y), p.l, Paint()..color = p.c);
}

/// Abysses : des bulles qui montent, un peu de lumière qui tombe d'en haut.
class _Bulles extends _Effet {
  final _bulles = <List<double>>[]; // x, y, r, v, phase, bal
  List<double> _neuve(Size s, bool bas) => [
        _hasard.nextDouble() * s.width, bas ? s.height + 10 : _hasard.nextDouble() * s.height,
        _entre(1.5, 6), _entre(.4, 1.4), _hasard.nextDouble() * math.pi * 2, _entre(4, 14),
      ];

  @override
  void init(Size s) {
    _bulles
      ..clear()
      ..addAll(List.generate((45 * s.width * s.height / (390 * 844)).round(), (_) => _neuve(s, false)));
  }

  @override
  void image(Canvas c, Size s, int t) {
    c.drawRect(
        Offset.zero & s,
        Paint()
          ..shader = ui.Gradient.radial(Offset(s.width / 2, -s.height * .1), s.height * 1.1,
              const [Color(0xFF0D4466), Color(0xFF06223A), Color(0xFF030D1A)], const [0, .55, 1]));
    for (var i = 0; i < 4; i++) {
      final cx = s.width * (.15 + i * .25) + math.sin(t * .01 + i) * 30;
      final a = .05 + .03 * math.sin(t * .02 + i);
      c.drawPath(
          Path()..moveTo(cx - 25, 0)..lineTo(cx + 25, 0)..lineTo(cx + 140, s.height)..lineTo(cx - 60, s.height)..close(),
          Paint()
            ..shader = ui.Gradient.linear(Offset(cx, 0), Offset(cx + 60, s.height * .8),
                [Color.fromRGBO(80, 200, 220, a), const Color(0x0050C8DC)]));
    }
    final contour = Paint()
      ..color = const Color(0x8CA0E6F0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final reflet = Paint()..color = const Color(0x59C8F5FF);
    for (final b in _bulles) {
      final x = b[0] + math.sin(t * .05 + b[4]) * b[5];
      c.drawCircle(Offset(x, b[1]), b[2], contour);
      c.drawCircle(Offset(x - b[2] * .35, b[1] - b[2] * .35), b[2] * .3, reflet);
      b[1] -= b[3];
      if (b[1] < -10) {
        final n = _neuve(s, true);
        for (var k = 0; k < n.length; k++) { b[k] = n[k]; }
      }
    }
  }
}

/// Néon : la grille synthwave qui défile vers soi, et le soleil derrière.
class _Grille extends _Effet {
  @override
  void init(Size s) {}

  @override
  void image(Canvas c, Size s, int t) {
    final horizon = s.height * .42;
    c.drawRect(Offset.zero & s,
        _degradeVertical(s, const [Color(0xFF0D0620), Color(0xFF2A0F45), Color(0xFF120A1F)], const [0, .42, 1]));
    final sr = math.min(s.width, s.height) * .22;
    c.save();
    c.clipPath(Path()..addArc(Rect.fromCircle(center: Offset(s.width / 2, horizon), radius: sr), math.pi, math.pi)..close());
    c.drawRect(
        Rect.fromLTWH(0, horizon - sr, s.width, sr),
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, horizon - sr), Offset(0, horizon),
              const [Color(0xFFFFD166), Color(0xFFFF3FA4)]));
    final bande = Paint()..color = const Color(0xFF2A0F45);
    for (var i = 0; i < 6; i++) {
      c.drawRect(Rect.fromLTWH(0, horizon - sr * (.15 + i * .13), s.width, 2 + i * 1.2), bande);
    }
    c.restore();
    c.drawRect(
        Rect.fromLTWH(0, horizon - 40, s.width, 100),
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, horizon - 40), Offset(0, horizon + 60),
              const [Color(0x00FF3FA4), Color(0x59FF3FA4), Color(0x00FF3FA4)], const [0, .5, 1]));
    final ligne = Paint()
      ..color = const Color(0x8CFF3FA4)
      ..strokeWidth = 1;
    for (var i = -10; i <= 10; i++) {
      c.drawLine(Offset(s.width / 2 + i * 14, horizon), Offset(s.width / 2 + i * s.width * .22, s.height), ligne);
    }
    final avance = (t * .012) % 1;
    for (var k = 0; k < 14; k++) {
      final p = math.pow((k + avance) / 14, 2.2).toDouble();
      final y = horizon + p * (s.height - horizon);
      ligne.color = Color.fromRGBO(255, 63, 164, .25 + .6 * p);
      c.drawLine(Offset(0, y), Offset(s.width, y), ligne);
    }
  }
}

/// Aurore boréale : des voiles qui ondulent sur un ciel d'étoiles fixes.
class _Aurore extends _Effet {
  final _etoiles = <Offset>[];
  final _rayons = <double>[];
  static const _voiles = [
    [.30, .08, .010, .012, 93.0, 242.0, 166.0, .22],
    [.38, .10, .007, -.009, 60.0, 220.0, 200.0, .16],
    [.46, .07, .013, .015, 190.0, 110.0, 255.0, .13],
  ];

  @override
  void init(Size s) {
    _etoiles.clear(); _rayons.clear();
    for (var i = 0; i < (s.width * s.height / 7000).round(); i++) {
      _etoiles.add(Offset(_hasard.nextDouble() * s.width, _hasard.nextDouble() * s.height * .7));
      _rayons.add(_entre(.3, 1.3));
    }
  }

  @override
  void image(Canvas c, Size s, int t) {
    c.drawRect(Offset.zero & s,
        _degradeVertical(s, const [Color(0xFF03060F), Color(0xFF07101F), Color(0xFF0C1A2C)], const [0, .6, 1]));
    final etoile = Paint()..color = const Color(0xB3FFFFFF);
    for (var i = 0; i < _etoiles.length; i++) { c.drawCircle(_etoiles[i], _rayons[i], etoile); }
    for (final v in _voiles) {
      for (var x = 0.0; x < s.width; x += 5) {
        final haut = s.height * (v[0] + v[1] * (math.sin(x * v[2] + t * v[3]) + .5 * math.sin(x * v[2] * 2.3 - t * v[3] * 1.7)));
        final long = s.height * (.18 + .08 * math.sin(x * .02 + t * .01));
        c.drawRect(
            Rect.fromLTWH(x, haut, 5, long),
            Paint()
              ..shader = ui.Gradient.linear(Offset(0, haut), Offset(0, haut + long), [
                Color.fromRGBO(v[4].toInt(), v[5].toInt(), v[6].toInt(), 0),
                Color.fromRGBO(v[4].toInt(), v[5].toInt(), v[6].toInt(), v[7]),
                Color.fromRGBO(v[4].toInt(), v[5].toInt(), v[6].toInt(), 0),
              ], const [0, .25, 1]));
      }
    }
  }
}

/// Nuit d'été : des lucioles qui dérivent et respirent dans l'herbe.
class _Lucioles extends _Effet {
  final _mouches = <List<double>>[]; // x, y, vx, vy, phase, v, r

  @override
  void init(Size s) {
    _mouches
      ..clear()
      ..addAll(List.generate((26 * s.width * s.height / (390 * 844)).round(), (_) => [
            _hasard.nextDouble() * s.width, s.height * (.25 + _hasard.nextDouble() * .75),
            _entre(-.4, .4), _entre(-.25, .25), _hasard.nextDouble() * math.pi * 2, _entre(.03, .07), _entre(1.2, 2.4),
          ]));
  }

  @override
  void image(Canvas c, Size s, int t) {
    c.drawRect(Offset.zero & s,
        _degradeVertical(s, const [Color(0xFF04100F), Color(0xFF0A1A16), Color(0xFF13261C)], const [0, .7, 1]));
    final herbe = Paint()
      ..color = const Color(0xE6143223)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (var i = 0.0; i < s.width; i += 9) {
      final h = 30 + 40 * math.sin(i * .37).abs();
      c.drawPath(
          Path()..moveTo(i, s.height)..quadraticBezierTo(i + 4 + math.sin(t * .02 + i) * 3, s.height - h / 2, i + 2, s.height - h),
          herbe);
    }
    for (final m in _mouches) {
      final a = math.pow(math.max(0, math.sin(m[4] + t * m[5])), 3).toDouble();
      final r = m[6] * 7;
      c.drawCircle(
          Offset(m[0], m[1]), r,
          Paint()
            ..shader = ui.Gradient.radial(Offset(m[0], m[1]), r, [
              Color.fromRGBO(255, 230, 120, .9 * a),
              Color.fromRGBO(255, 220, 90, .35 * a),
              const Color(0x00FFDC5A),
            ], const [0, .3, 1]));
      m[2] = (m[2] + _entre(-.04, .04)).clamp(-.6, .6);
      m[3] = (m[3] + _entre(-.03, .03)).clamp(-.4, .4);
      m[0] = (m[0] + m[2] + s.width) % s.width;
      m[1] = (m[1] + m[3]).clamp(s.height * .2, s.height - 10);
    }
  }
}

/// Savane : le soleil qui se couche, des acacias en ombre, des oiseaux.
class _Savane extends _Effet {
  final _oiseaux = <List<double>>[]; // x, y, v, s, phase
  final _arbres = <List<double>>[];  // x, h, l

  @override
  void init(Size s) {
    _oiseaux
      ..clear()
      ..addAll(List.generate(7, (_) => [_hasard.nextDouble() * s.width, s.height * _entre(.12, .45), _entre(.5, 1.1), _entre(5, 9), _hasard.nextDouble() * 6]));
    _arbres
      ..clear()
      ..addAll(List.generate(4, (i) => [s.width * (.1 + i * .27) + _entre(-20, 20), _entre(55, 95), _entre(70, 130)]));
  }

  @override
  void image(Canvas c, Size s, int t) {
    c.drawRect(
        Offset.zero & s,
        _degradeVertical(s, const [Color(0xFF3A1C3F), Color(0xFFB8432B), Color(0xFFF29A3C), Color(0xFF2A1612), Color(0xFF1A0D0A)],
            const [0, .35, .62, .66, 1]));
    final sy = s.height * (.60 + .03 * math.sin(t * .003));
    c.drawRect(
        Rect.fromLTWH(0, 0, s.width, s.height * .66),
        Paint()
          ..shader = ui.Gradient.radial(Offset(s.width / 2, sy), s.width * .45,
              const [Color(0x8CFFD278), Color(0x00FF963C)]));
    c.save();
    c.clipRect(Rect.fromLTWH(0, 0, s.width, s.height * .655));
    c.drawCircle(Offset(s.width / 2, sy), math.min(s.width, s.height) * .13, Paint()..color = const Color(0xFFFFD97A));
    c.restore();
    c.drawRect(Rect.fromLTWH(0, s.height * .655, s.width, s.height), Paint()..color = const Color(0xFF1A0D0A));
    for (final a in _arbres) { _dessineAcacia(c, a[0], s.height * .655, a[1], a[2]); }
    final herbe = Paint()
      ..color = const Color(0xFF120806)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (var i = 0.0; i < s.width; i += 7) {
      final hh = 6 + 10 * math.sin(i * .61).abs();
      c.drawLine(Offset(i, s.height * .655 + 1), Offset(i + math.sin(i) * 3, s.height * .655 - hh), herbe);
    }
    final oiseau = Paint()
      ..color = const Color(0xE61E0A0A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final o in _oiseaux) {
      final b = math.sin(t * .25 + o[4]) * o[3] * .5;
      c.drawPath(
          Path()
            ..moveTo(o[0] - o[3], o[1] + b)
            ..quadraticBezierTo(o[0] - o[3] / 2, o[1] - b, o[0], o[1])
            ..quadraticBezierTo(o[0] + o[3] / 2, o[1] - b, o[0] + o[3], o[1] + b),
          oiseau);
      o[0] += o[2];
      if (o[0] > s.width + 20) { o[0] = -20; o[1] = s.height * _entre(.12, .45); }
    }
  }
}

/// Un décor fixe : peint une fois à la taille, puis recopié tel quel.
abstract class _Fixe extends _Effet {
  ui.Picture? _fait;
  void peint(Canvas c, Size s);

  @override
  void init(Size s) {
    final enregistreur = ui.PictureRecorder();
    peint(Canvas(enregistreur), s);
    _fait = enregistreur.endRecording();
  }

  @override
  void image(Canvas c, Size s, int t) {
    final f = _fait;
    if (f != null) c.drawPicture(f);
  }
}

/// Aquarelle : des taches de couleur diluées sur du papier. Rien ne bouge.
class _Aquarelle extends _Fixe {
  static const _teintes = [[79, 143, 207], [232, 131, 121], [246, 196, 83], [98, 184, 142], [171, 124, 205], [240, 150, 190]];

  @override
  void peint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFFFFFDF8));
    for (var i = 0; i < 14; i++) {
      final x = _hasard.nextDouble() * s.width, y = _hasard.nextDouble() * s.height, r = _entre(70, 170);
      final t = _teintes[i % _teintes.length];
      final p = Path();
      for (var k = 0; k <= 24; k++) {
        final ang = k / 24 * math.pi * 2;
        final rr = r * (.85 + .15 * math.sin(k * 2.7 + i));
        k == 0 ? p.moveTo(x + math.cos(ang) * rr, y + math.sin(ang) * rr) : p.lineTo(x + math.cos(ang) * rr, y + math.sin(ang) * rr);
      }
      p.close();
      c.drawPath(
          p,
          Paint()
            ..shader = ui.Gradient.radial(Offset(x, y), r, [
              Color.fromRGBO(t[0], t[1], t[2], .28),
              Color.fromRGBO(t[0], t[1], t[2], .16),
              Color.fromRGBO(t[0], t[1], t[2], 0),
            ], const [0, .7, 1]));
    }
    final grain = Paint();
    for (var i = 0; i < s.width * s.height / 60; i++) {
      grain.color = Color.fromRGBO(120, 100, 80, _entre(.02, .06));
      c.drawRect(Rect.fromLTWH(_hasard.nextDouble() * s.width, _hasard.nextDouble() * s.height, 1, 1), grain);
    }
  }
}

/// Lagon : la lumière qui danse au fond d'une eau claire.
class _Lagon extends _Effet {
  @override
  void init(Size s) {}

  @override
  void image(Canvas c, Size s, int t) {
    c.drawRect(Offset.zero & s, _degradeVertical(s, const [Color(0xFFBFEEEE), Color(0xFFE4F7F5)]));
    final trait = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final n in const [[.045, .03, 26.0, .5, 0.0], [.03, -.02, 34.0, .35, 13.0]]) {
      trait.color = Color.fromRGBO(255, 255, 255, n[3]);
      for (var y = n[4]; y < s.height + 40; y += n[2]) {
        final p = Path();
        for (var x = 0.0; x <= s.width; x += 6) {
          final yy = y + math.sin(x * n[0] + t * n[1] + y * .05) * 9 + math.sin(x * n[0] * 2.1 - t * n[1] * 1.4) * 4;
          x == 0 ? p.moveTo(x, yy) : p.lineTo(x, yy);
        }
        c.drawPath(p, trait);
      }
    }
    final reflet = Paint()..color = const Color(0x2EFFFFFF);
    for (var i = 0; i < 40; i++) {
      final x = (i * 97 + t * .7) % s.width, y = (i * 61 + t * .4) % s.height;
      c.save();
      c.translate(x, y);
      c.rotate(math.sin(i.toDouble()));
      c.drawOval(Rect.fromCenter(center: Offset.zero, width: 20, height: 8), reflet);
      c.restore();
    }
  }
}

/// Nébuleuse : des nuées de couleur fixes, et un champ d'étoiles qui dérive
/// devant, très lentement.
class _Nebuleuse extends _Effet {
  final _nuees = _Nuees();
  final _etoiles = <List<double>>[]; // x, y, r, v, phase, p

  @override
  void init(Size s) {
    _nuees.taille = s;
    _nuees.init(s);
    _etoiles
      ..clear()
      ..addAll(List.generate((s.width * s.height / 3200).round(), (_) => [
            _hasard.nextDouble() * s.width, _hasard.nextDouble() * s.height,
            _entre(.3, 1.5), _entre(.03, .12), _hasard.nextDouble() * 6, _entre(.02, .08),
          ]));
  }

  @override
  void image(Canvas c, Size s, int t) {
    _nuees.image(c, s, t);
    final p = Paint();
    for (final e in _etoiles) {
      final a = .5 + .5 * math.pow(math.sin(e[4] + t * e[5]), 2);
      p.color = Color.fromRGBO(255, 255, 255, a);
      c.drawCircle(Offset(e[0], e[1]), e[2], p);
      e[0] -= e[3] * e[2];
      if (e[0] < 0) { e[0] = s.width; e[1] = _hasard.nextDouble() * s.height; }
    }
  }
}

class _Nuees extends _Fixe {
  static const _teintes = [[199, 125, 255], [255, 110, 170], [90, 140, 255], [120, 220, 255], [255, 170, 90]];

  @override
  void peint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF0D0A1F));
    for (var i = 0; i < 9; i++) {
      final x = _hasard.nextDouble() * s.width, y = _hasard.nextDouble() * s.height, r = _entre(90, 220);
      final tn = _teintes[i % _teintes.length];
      c.drawRect(
          Rect.fromLTWH(x - r, y - r, r * 2, r * 2),
          Paint()
            ..shader = ui.Gradient.radial(Offset(x, y), r, [
              Color.fromRGBO(tn[0], tn[1], tn[2], .30),
              Color.fromRGBO(tn[0], tn[1], tn[2], .12),
              Color.fromRGBO(tn[0], tn[1], tn[2], 0),
            ], const [0, .5, 1]));
    }
  }
}
