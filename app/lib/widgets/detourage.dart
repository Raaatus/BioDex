import 'dart:math' as math;
import 'dart:typed_data';
import '../i18n.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'chargement.dart';

/// La géométrie du tracé, séparée de l'écran qui la dessine.
///
/// Elle est sortie du widget pour pouvoir être vérifiée : les tests de widget
/// ne savent pas décoder d'image — le décodage est un vrai travail asynchrone,
/// que l'horloge simulée des tests ne fait jamais avancer. Or c'est là que
/// sont les erreurs possibles : passer de la position d'un doigt à un point de
/// l'image, refermer la forme, trouver sa boîte. Le reste n'est que du dessin.
class Trace {
  /// Le nombre de points en deçà duquel ce n'est pas une forme mais un doigt
  /// qui a glissé.
  static const minimum = 8;

  /// Un point de l'écran, ramené en fraction de l'image.
  ///
  /// Rend `null` quand le doigt sort franchement du cadre : la photo est posée
  /// en « contain », et les bandes autour d'elle n'appartiennent à rien. On
  /// tolère cinq pour cent de débordement, parce qu'on entoure volontiers une
  /// bête qui touche le bord.
  static Offset? versImage(Offset local, Rect cadre) {
    if (cadre.isEmpty) return null;
    final x = (local.dx - cadre.left) / cadre.width;
    final y = (local.dy - cadre.top) / cadre.height;
    if (x < -0.05 || x > 1.05 || y < -0.05 || y > 1.05) return null;
    return Offset(x.clamp(0, 1), y.clamp(0, 1));
  }

  /// La zone qu'occupe une image posée en « contain » dans une boîte.
  static Rect cadreContain(Size image, Size boite) {
    final rapportImage = image.width / image.height;
    final rapportBoite = boite.width / boite.height;
    final double l, h;
    if (rapportImage > rapportBoite) {
      l = boite.width;
      h = l / rapportImage;
    } else {
      h = boite.height;
      l = h * rapportImage;
    }
    return Rect.fromLTWH(
        (boite.width - l) / 2, (boite.height - h) / 2, l, h);
  }

  /// La boucle est-elle bouclée ?
  ///
  /// On mesure l'écart entre le premier et le dernier point, rapporté à la
  /// diagonale du tracé : un écart de deux centimètres n'a pas le même sens
  /// sur un escargot que sur un cerf.
  ///
  /// Refermer d'office était plus simple et donnait un geste faux : on
  /// s'arrêtait n'importe où, le trait sautait à travers l'image et coupait la
  /// bête en deux. Le doigt ferme, l'écran prévient — il ne décide pas.
  static bool estFermee(List<Offset> trace) {
    if (trace.length < minimum) return false;
    final ecart = (trace.last - trace.first).distance;
    final boite = boiteRelative(trace);
    final diagonale =
        math.sqrt(boite.width * boite.width + boite.height * boite.height);
    if (diagonale <= 0) return false;
    // Deux dixièmes et demi de la diagonale.
    //
    // Réglé sur un tracé à qui il manque un vingt-quatrième de tour : à 0,18
    // il était déclaré ouvert, ce qui est faux — le doigt était revenu. Un
    // quart de cercle manquant reste largement au-dessus du seuil.
    return ecart / diagonale < 0.22;
  }

  /// La boîte du tracé, en fractions — sans les dimensions de l'image.
  static Rect boiteRelative(List<Offset> trace) {
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    for (final p in trace) {
      x0 = math.min(x0, p.dx);
      y0 = math.min(y0, p.dy);
      x1 = math.max(x1, p.dx);
      y1 = math.max(y1, p.dy);
    }
    return Rect.fromLTRB(x0, y0, x1, y1);
  }

  /// Le chemin correspondant au tracé, aux dimensions de l'image.
  ///
  /// `ferme` décide si l'on relie le dernier point au premier. À l'écran on ne
  /// le fait pas : montrer une forme fermée quand elle ne l'est pas mentirait
  /// sur ce que le geste a produit. Au découpage il le faut — une figure
  /// ouverte ne délimite rien.
  static Path chemin(List<Offset> trace, double l, double h,
      {bool ferme = true}) {
    final chemin = Path();
    for (var i = 0; i < trace.length; i++) {
      final p = Offset(trace[i].dx * l, trace[i].dy * h);
      if (i == 0) {
        chemin.moveTo(p.dx, p.dy);
      } else {
        chemin.lineTo(p.dx, p.dy);
      }
    }
    if (ferme) chemin.close();
    return chemin;
  }

  /// La boîte englobante du tracé, en pixels de l'image.
  ///
  /// Elle sert à rogner : garder les marges vides donnerait une vignette où la
  /// bête occupe un dixième du cadre, et une image d'analyse aux trois quarts
  /// blanche. La marge d'un pixel évite une frange en escalier au ras du bord.
  static Rect boite(List<Offset> trace, double l, double h) {
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    for (final p in trace) {
      x0 = math.min(x0, p.dx * l);
      y0 = math.min(y0, p.dy * h);
      x1 = math.max(x1, p.dx * l);
      y1 = math.max(y1, p.dy * h);
    }
    return Rect.fromLTRB(
        math.max(0, x0 - 1), math.max(0, y0 - 1),
        math.min(l, x1 + 1), math.min(h, y1 + 1));
  }

  /// La matrice qui applique luminosité et contraste.
  ///
  /// Le contraste pivote autour du gris moyen : sans ce décalage, l'augmenter
  /// éclaircirait toute l'image au lieu d'en écarter les tons.
  static ColorFilter filtre({required double luminosite, required double contraste}) {
    final t = (1 - contraste) * 127.5;
    return ColorFilter.matrix([
      contraste * luminosite, 0, 0, 0, t * luminosite,
      0, contraste * luminosite, 0, 0, t * luminosite,
      0, 0, contraste * luminosite, 0, t * luminosite,
      0, 0, 0, 1, 0,
    ]);
  }
}

/// Ce que l'éditeur rend une fois qu'on valide.
class PhotoRetouchee {
  const PhotoRetouchee({required this.analyse, this.decoupe});

  /// L'image à soumettre au moteur : réglages appliqués, et rognée au tracé
  /// s'il y en a un. Le fond y est blanc plutôt que transparent — les moteurs
  /// rendent le transparent en noir, et un animal sur fond noir ressemble à
  /// une photo de nuit ratée.
  final Uint8List analyse;

  /// Le tracé sur fond transparent, quand le joueur en a fait un. C'est lui
  /// qui deviendra la vignette de la case.
  final Uint8List? decoupe;
}

/// Retoucher une photo avant de l'envoyer, ou refaire sa vignette.
///
/// Trois gestes, et un seul vraiment nouveau : régler la lumière, pincer pour
/// regarder de près, et **entourer la bête au doigt**. Le tracé se referme
/// tout seul entre son dernier point et le premier ; ce qui est dedans est
/// gardé, le reste tombe.
///
/// L'originale n'est jamais modifiée. On produit deux images à côté d'elle :
/// une pour le moteur, une pour la vignette. Un recadrage regretté doit rester
/// réparable — c'est la photo qui est le témoignage, pas ce qu'on en a fait.
class EcranDetourage extends StatefulWidget {
  const EcranDetourage({
    super.key,
    required this.image,
    this.titre,
    this.traceSeul = false,
  });

  /// La photo d'origine, en octets.
  final Uint8List image;
  final String? titre;

  /// Vrai quand on ne vient que refaire une vignette : les réglages de lumière
  /// n'auraient alors aucun sens, la vignette devant rester fidèle à la photo.
  final bool traceSeul;

  @override
  State<EcranDetourage> createState() => _EcranDetourageState();
}

class _EcranDetourageState extends State<EcranDetourage> {
  ui.Image? _image;

  /// Le tracé, en fractions de l'image : indépendant de la taille d'affichage,
  /// donc juste sur tous les écrans.
  final List<Offset> _trace = [];
  bool _enCours = false;

  double _luminosite = 1;
  double _contraste = 1;
  bool _travaille = false;

  /// La zone réellement occupée par la photo à l'écran, calculée au rendu.
  /// Sans elle, un doigt posé dans les bandes noires donnerait des
  /// coordonnées hors de l'image.
  Rect _cadre = Rect.zero;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.image);
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _image = frame.image);
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Offset? _versImage(Offset local) => Trace.versImage(local, _cadre);

  void _debute(Offset p) {
    final q = _versImage(p);
    if (q == null) return;
    setState(() {
      _trace
        ..clear()
        ..add(q);
      _enCours = true;
    });
  }

  void _suit(Offset p) {
    if (!_enCours) return;
    final q = _versImage(p);
    if (q == null) return;
    // On ne garde pas chaque pixel : un tracé de deux mille points fait ramer
    // le rendu sans rien ajouter à la forme.
    if (_trace.isNotEmpty && (q - _trace.last).distance < 0.004) return;
    setState(() => _trace.add(q));
  }

  void _finit() {
    if (!_enCours) return;
    setState(() {
      _enCours = false;
      // Trois points ne font pas une forme : c'est un doigt qui a glissé.
      if (_trace.length < Trace.minimum) _trace.clear();
    });
  }

  ColorFilter get _filtre =>
      Trace.filtre(luminosite: _luminosite, contraste: _contraste);

  @override
  Widget build(BuildContext context) {
    final img = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF101114),
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: const TextStyle(
            color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
        title: Text((widget.titre ?? T('Retoucher'))),
        actions: [
          if (_trace.isNotEmpty)
            IconButton(
              tooltip: T('Effacer le tracé'),
              icon: const Icon(Icons.undo),
              onPressed: () => setState(_trace.clear),
            ),
        ],
      ),
      body: img == null
          ? const Chargement()
          : Column(children: [
              Expanded(child: _toile(img)),
              _outils(),
            ]),
    );
  }

  Widget _toile(ui.Image img) {
    return LayoutBuilder(builder: (context, bornes) {
      // La photo est posée en « contain » : on calcule sa zone une fois, et
      // le tracé s'y rapporte.
      _cadre = Trace.cadreContain(
          Size(img.width.toDouble(), img.height.toDouble()),
          Size(bornes.maxWidth, bornes.maxHeight));

      return GestureDetector(
        onPanStart: (d) => _debute(d.localPosition),
        onPanUpdate: (d) => _suit(d.localPosition),
        onPanEnd: (_) => _finit(),
        child: CustomPaint(
          size: Size(bornes.maxWidth, bornes.maxHeight),
          painter: _PeintreDetourage(
            image: img,
            cadre: _cadre,
            trace: _trace,
            enCours: _enCours,
            filtre: _filtre,
          ),
        ),
      );
    });
  }

  Widget _outils() {
    return Container(
      color: const Color(0xFF101114),
      padding: EdgeInsets.fromLTRB(
          16, 10, 16, 16 + MediaQuery.paddingOf(context).bottom),
      child: Column(children: [
        _consigne(),
        if (!widget.traceSeul) ...[
          const SizedBox(height: 6),
          _glissiere('Lumière', _luminosite, 0.4, 2,
              (v) => setState(() => _luminosite = v)),
          _glissiere('Contraste', _contraste, 0.4, 2.2,
              (v) => setState(() => _contraste = v)),
        ],
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _travaille ? null : () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
              ),
              child: Text(T('Annuler')),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: FilledButton(
              onPressed: _travaille ? null : _valide,
              child: _travaille
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(widget.traceSeul ? 'Garder ce tracé' : 'Utiliser'),
            ),
          ),
        ]),
      ]),
    );
  }

  /// Ce que l'écran a à dire sur le tracé en cours.
  ///
  /// Trois états, trois phrases. On prévient qu'une forme ouverte sera
  /// refermée pour découper, sans l'interdire : c'est le geste du joueur, on
  /// lui dit ce qu'il produira plutôt que de le corriger dans son dos.
  Widget _consigne() {
    if (_trace.isEmpty) {
      return Text(T('Entoure la bête avec ton doigt, et reviens à ton point de départ.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70, fontSize: 12.5));
    }
    if (Trace.estFermee(_trace)) {
      return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.check_circle, size: 15, color: Palette.accent),
        const SizedBox(width: 6),
        Text(T('Forme fermée.'),
            style: TextStyle(color: Palette.accent, fontSize: 12.5)),
      ]);
    }
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.warning_amber_rounded, size: 15, color: Color(0xFFE8A317)),
      SizedBox(width: 6),
      Flexible(
        child: Text(
            T('Forme ouverte : elle sera refermée en ligne droite.'),
            style: TextStyle(color: Color(0xFFE8A317), fontSize: 12.5)),
      ),
    ]);
  }

  Widget _glissiere(String nom, double valeur, double mini, double maxi,
      ValueChanged<double> surChangement) {
    return Row(children: [
      SizedBox(
        width: 74,
        child: Text(nom,
            style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
      ),
      Expanded(
        child: Slider(
          value: valeur,
          min: mini,
          max: maxi,
          onChanged: surChangement,
        ),
      ),
    ]);
  }

  /// Fabrique les deux images et rend la main.
  Future<void> _valide() async {
    final img = _image;
    if (img == null) return;
    setState(() => _travaille = true);
    try {
      final analyse = await _rend(img, transparent: false);
      final decoupe =
          _trace.length >= Trace.minimum
              ? await _rend(img, transparent: true)
              : null;
      if (mounted) {
        Navigator.pop(context,
            PhotoRetouchee(analyse: analyse, decoupe: decoupe));
      }
    } finally {
      if (mounted) setState(() => _travaille = false);
    }
  }

  /// Dessine l'image finale hors écran.
  ///
  /// Deux rendus du même tracé : sur blanc pour le moteur, sur transparent
  /// pour la vignette. On rogne sur la boîte du tracé — garder les marges
  /// vides donnerait une vignette où la bête occupe un dixième du cadre, et
  /// une image d'analyse aux trois quarts blanche.
  Future<Uint8List> _rend(ui.Image img, {required bool transparent}) async {
    final aTrace = _trace.length >= Trace.minimum;
    final boite = aTrace
        ? Trace.boite(_trace, img.width.toDouble(), img.height.toDouble())
        : Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());

    final recorder = ui.PictureRecorder();
    final toile = Canvas(recorder);

    if (!transparent) {
      toile.drawRect(Rect.fromLTWH(0, 0, boite.width, boite.height),
          Paint()..color = Colors.white);
    }
    toile.translate(-boite.left, -boite.top);

    if (aTrace) {
      toile.save();
      toile.clipPath(Trace.chemin(
          _trace, img.width.toDouble(), img.height.toDouble()));
    }
    toile.drawImage(img, Offset.zero, Paint()..colorFilter = _filtre);
    if (aTrace) toile.restore();

    final rendue = await recorder
        .endRecording()
        .toImage(boite.width.round(), boite.height.round());
    // PNG dans les deux cas : le canal alpha est indispensable à la vignette,
    // et Flutter ne sait pas encoder en JPEG. Le serveur ré-encode ensuite.
    final octets = await rendue.toByteData(format: ui.ImageByteFormat.png);
    rendue.dispose();
    return octets!.buffer.asUint8List();
  }

}

class _PeintreDetourage extends CustomPainter {
  _PeintreDetourage({
    required this.image,
    required this.cadre,
    required this.trace,
    required this.enCours,
    required this.filtre,
  });

  final ui.Image image;
  final Rect cadre;
  final List<Offset> trace;
  final bool enCours;
  final ColorFilter filtre;

  @override
  void paint(Canvas toile, Size taille) {
    toile.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      cadre,
      Paint()..colorFilter = filtre,
    );
    if (trace.length < 2) return;

    final ferme = Trace.estFermee(trace);
    final chemin = Path();
    for (var i = 0; i < trace.length; i++) {
      final p = Offset(
          cadre.left + trace[i].dx * cadre.width,
          cadre.top + trace[i].dy * cadre.height);
      if (i == 0) {
        chemin.moveTo(p.dx, p.dy);
      } else {
        chemin.lineTo(p.dx, p.dy);
      }
    }
    // On ne referme le trait que si le doigt l'a fermé. Le tracer fermé quand
    // il ne l'est pas donnerait à croire que le geste a réussi.
    if (ferme) chemin.close();

    // Ce qui tombe s'assombrit : on voit d'un coup ce que le tracé garde, au
    // lieu d'avoir à imaginer le résultat. Sur une forme ouverte on s'en
    // abstient — l'assombrissement supposerait un dedans et un dehors qui
    // n'existent pas encore.
    if (!enCours && ferme) {
      final dehors = Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & taille),
        chemin,
      );
      toile.drawPath(dehors, Paint()..color = Colors.black.withValues(alpha: .6));
    }
    toile.drawPath(
      chemin,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = ferme ? Palette.accent : const Color(0xFFE8A317),
    );

    // Sur une forme ouverte, on marque les deux bouts et on montre où il
    // reste à revenir. Un trait en pointillé dit l'écart mieux qu'une phrase.
    if (!ferme && trace.length >= 2) {
      final debut = Offset(cadre.left + trace.first.dx * cadre.width,
          cadre.top + trace.first.dy * cadre.height);
      final fin = Offset(cadre.left + trace.last.dx * cadre.width,
          cadre.top + trace.last.dy * cadre.height);
      final pointille = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFFE8A317).withValues(alpha: .7);
      const pas = 8.0;
      final total = (fin - debut).distance;
      for (var d = 0.0; d < total; d += pas * 2) {
        final a = Offset.lerp(debut, fin, d / total)!;
        final b = Offset.lerp(debut, fin, math.min(1, (d + pas) / total))!;
        toile.drawLine(a, b, pointille);
      }
      for (final bout in [debut, fin]) {
        toile.drawCircle(bout, 5, Paint()..color = const Color(0xFFE8A317));
        toile.drawCircle(
            bout,
            5,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = Colors.white);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PeintreDetourage ancien) =>
      ancien.image != image ||
      ancien.cadre != cadre ||
      ancien.enCours != enCours ||
      ancien.filtre != filtre ||
      ancien.trace.length != trace.length;
}
