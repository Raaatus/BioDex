import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Le cristal d'un succès, et sa rupture.
///
/// Le rendu est dans `assets/shaders/cristal.frag` ; ce fichier ne fait que le
/// cadencer. La séparation vaut d'être gardée : le shader ne sait rien des
/// succès, il reçoit deux nombres entre zéro et un.
///
/// **La chorégraphie.** Trois temps, et leur durée relative fait tout :
///
///   0 → 1,5 s   les fissures gagnent du centre vers le bord. C'est la partie
///               longue, celle qu'on regarde. Précipitée, on ne voit rien.
///   1,5 → 2,3 s l'éclatement, puis la dissipation des fragments.
///
/// Au repos le cristal respire seul, sans rien consommer d'autre qu'une trame :
/// c'est ce qui donne envie d'y toucher.
class Cristal extends StatefulWidget {
  const Cristal({
    super.key,
    this.taille = 190,
    this.teinte = const Color(0xFF7FD4FF),
    this.lueur = const Color(0xFFFFD27F),
    this.brise = false,
    this.surFin,
  });

  final double taille;

  /// La couleur de la matière — celle du corps de la grenouille enfermée
  /// dedans. Trois teintes selon la difficulté rendaient vingt-neuf gemmes
  /// interchangeables ; ici chacune annonce ce qu'elle contient.
  final Color teinte;

  /// La couleur de la lumière qui sort des fissures : la couleur d'accent du
  /// modèle — le chapeau, l'écharpe. Voir `outils/couleurs_succes.py`.
  final Color lueur;

  /// Passe à vrai pour déclencher la rupture. Le retour à faux réassemble le
  /// cristal — utile quand on rouvre la même fiche.
  final bool brise;

  /// Appelé quand les fragments ont fini de se dissiper : c'est le moment où
  /// le modèle 3D prend la place.
  final VoidCallback? surFin;

  @override
  State<Cristal> createState() => _CristalState();
}

class _CristalState extends State<Cristal> with SingleTickerProviderStateMixin {
  static const _duree = Duration(milliseconds: 2300);

  ui.FragmentShader? _shader;
  late final Ticker _horloge;
  Duration _ecoule = Duration.zero;

  /// Quand la rupture a commencé. Nul tant que le cristal est intact.
  Duration? _rupture;
  bool _finiAnnonce = false;

  @override
  void initState() {
    super.initState();
    _horloge = createTicker((d) => setState(() => _ecoule = d))..start();
    _charge();
  }

  Future<void> _charge() async {
    try {
      final programme =
          await ui.FragmentProgram.fromAsset('assets/shaders/cristal.frag');
      if (!mounted) return;
      setState(() => _shader = programme.fragmentShader());
    } catch (_) {
      // Un shader qui ne charge pas ne doit pas emporter l'écran : on laisse la
      // place vide et le modèle s'affichera sans mise en scène.
    }
  }

  @override
  void didUpdateWidget(Cristal vieux) {
    super.didUpdateWidget(vieux);
    if (widget.brise && !vieux.brise) {
      _rupture = _ecoule;
      _finiAnnonce = false;
    } else if (!widget.brise && vieux.brise) {
      _rupture = null;
    }
  }

  @override
  void dispose() {
    _horloge.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _shader;
    if (s == null) return SizedBox.square(dimension: widget.taille);

    final t = _ecoule.inMicroseconds / 1e6;
    var fissure = 0.0;
    var eclat = 0.0;

    final debut = _rupture;
    if (debut != null) {
      final depuis = (_ecoule - debut).inMicroseconds / 1e6;
      // Les fissures d'abord, seules : c'est le suspense. L'éclatement ne
      // commence qu'une fois la fracture arrivée au bord.
      fissure = (depuis / 1.5).clamp(0.0, 1.0);
      eclat = ((depuis - 1.5) / 0.8).clamp(0.0, 1.0);
      if (depuis >= _duree.inMilliseconds / 1000 && !_finiAnnonce) {
        _finiAnnonce = true;
        // Après la trame : prévenir pendant la peinture ferait reconstruire
        // l'arbre au milieu d'un rendu.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.surFin?.call();
        });
      }
    }

    return SizedBox.square(
      dimension: widget.taille,
      child: CustomPaint(
        painter: _PeintreCristal(
          shader: s,
          temps: t,
          fissure: fissure,
          eclat: eclat,
          teinte: widget.teinte,
          lueur: widget.lueur,
        ),
      ),
    );
  }
}

class _PeintreCristal extends CustomPainter {
  _PeintreCristal({
    required this.shader,
    required this.temps,
    required this.fissure,
    required this.eclat,
    required this.teinte,
    required this.lueur,
  });

  final ui.FragmentShader shader;
  final double temps;
  final double fissure;
  final double eclat;
  final Color teinte;
  final Color lueur;

  @override
  void paint(Canvas canvas, Size size) {
    // L'ordre des `setFloat` suit exactement celui des `uniform` dans le
    // shader : il n'y a pas de nom côté Dart, seulement un index. Ajouter un
    // uniforme au milieu du fichier décale tout ce qui suit, en silence.
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, temps)
      ..setFloat(3, fissure)
      ..setFloat(4, eclat)
      ..setFloat(5, teinte.r)
      ..setFloat(6, teinte.g)
      ..setFloat(7, teinte.b)
      ..setFloat(8, lueur.r)
      ..setFloat(9, lueur.g)
      ..setFloat(10, lueur.b);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_PeintreCristal vieux) =>
      vieux.temps != temps ||
      vieux.fissure != fissure ||
      vieux.eclat != eclat ||
      vieux.teinte != teinte ||
      vieux.lueur != lueur;
}
