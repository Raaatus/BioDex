import 'dart:math';
import '../i18n.dart';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// La fête qui suit une découverte, jouée **par-dessus la page**.
///
/// Pas de nouvel écran : les confettis tombent sur le contenu déjà affiché, et
/// le résultat reste lisible pendant l'animation. On enveloppe la page dans une
/// [ZoneCelebration], et on déclenche depuis sa clé :
///
/// ```dart
/// final cle = GlobalKey<ZoneCelebrationState>();
/// ...
/// cle.currentState?.fete(4);
/// ```
class ReglageFete {
  const ReglageFete({
    required this.nombre,
    required this.couleurs,
    required this.explosion,
    required this.vitesse,
    required this.calibre,
    required this.titre,
    this.eclat = false,
  });

  final int nombre;
  final List<Color> couleurs;

  /// Vrai : les particules jaillissent du centre. Faux : elles tombent du haut.
  final bool explosion;
  final double vitesse;

  /// Taille de base des confettis. Les paliers discrets compensent leur petit
  /// nombre par de plus gros morceaux : trois confettis minuscules ne se
  /// voient pas, trois gros si.
  final double calibre;
  final String titre;

  /// Un halo lumineux derrière le texte, réservé au sommet.
  final bool eclat;

  /// Le réglage correspondant à une qualité, de 1 (commun) à 5 (légendaire).
  static ReglageFete pour(int qualite) => switch (qualite) {
        1 => ReglageFete(
            nombre: 110,
            couleurs: [Palette.qualite(1), const Color(0xFF7D8590)],
            explosion: false,
            vitesse: .55,
            calibre: 16,
            titre: T('Trouvé'),
          ),
        2 => ReglageFete(
            nombre: 130,
            couleurs: [Palette.qualite(2), const Color(0xFF2E9E4A)],
            explosion: false,
            vitesse: .6,
            calibre: 16,
            titre: T('Trouvé'),
          ),
        3 => ReglageFete(
            nombre: 150,
            couleurs: [Palette.qualite(3), Palette.qualite(2),
                       const Color(0xFF1D6FE0)],
            explosion: false,
            vitesse: .75,
            calibre: 15,
            titre: T('Belle prise'),
          ),
        4 => ReglageFete(
            nombre: 130,
            couleurs: [Palette.qualite(4), Palette.qualite(3),
                       const Color(0xFF7B2FBF), const Color(0xFF1D6FE0)],
            explosion: true,
            vitesse: 1.0,
            calibre: 13,
            titre: T('Rare !'),
          ),
        _ => ReglageFete(
            nombre: 260,
            couleurs: [Palette.qualite(5), const Color(0xFFFFC530),
                       const Color(0xFFE0A800), const Color(0xFFFFE9A8)],
            explosion: true,
            vitesse: 1.15,
            calibre: 13,
            titre: T('LÉGENDAIRE'),
            eclat: true,
          ),
      };
}

class _Particule {
  _Particule({
    required this.position,
    required this.vitesse,
    required this.couleur,
    required this.taille,
    required this.rotation,
    required this.tournoie,
    required this.forme,
  });

  Offset position;
  Offset vitesse;
  final Color couleur;
  final double taille;
  double rotation;
  final double tournoie;

  /// 0 rectangle, 1 disque, 2 étoile — les étoiles sont réservées à l'or.
  final int forme;
}

/// Enveloppe une page et y joue les confettis à la demande.
class ZoneCelebration extends StatefulWidget {
  const ZoneCelebration({super.key, required this.enfant});
  final Widget enfant;

  @override
  State<ZoneCelebration> createState() => ZoneCelebrationState();
}

class ZoneCelebrationState extends State<ZoneCelebration>
    with SingleTickerProviderStateMixin {
  /// Un battement et l'horloge réelle, plutôt qu'un `AnimationController`.
  ///
  /// Ce dernier obéit à l'échelle d'animation du système — celle des options
  /// développeur d'Android. Réglée bas, les six secondes de confettis
  /// passaient en quelques images, ce qui donnait exactement l'impression
  /// qu'ils disparaissaient aussitôt lancés.
  Ticker? _battement;
  Duration _origine = Duration.zero;
  double _avancement = 0;
  bool _joue = false;

  static const _duree = 6000;

  final _particules = <_Particule>[];
  final _hasard = Random();
  Size _taille = Size.zero;
  Duration _dernier = Duration.zero;

  @override
  void initState() {
    super.initState();
    _battement = createTicker(_avance);
  }

  @override
  void dispose() {
    _battement?.dispose();
    super.dispose();
  }

  /// Combien de confettis se trouvent réellement dans l'écran.
  ///
  /// Une animation peut tourner sans que rien ne se voie, si les particules
  /// sont encore au-dessus du champ ou déjà passées dessous. C'est ce qui est
  /// arrivé : la pluie démarrait hors cadre et mettait une seconde à entrer.
  /// Le test s'appuie là-dessus pour vérifier qu'il y a quelque chose à voir
  /// tout de suite.
  int get particulesDansLeChamp {
    final taille = _taille.isEmpty ? const Size(400, 800) : _taille;
    return _particules
        .where((p) =>
            p.position.dy > -p.taille &&
            p.position.dy < taille.height + p.taille &&
            p.position.dx > -p.taille &&
            p.position.dx < taille.width + p.taille)
        .length;
  }

  /// Lance la fête pour une qualité donnée.
  void fete(int qualite) {
    final r = ReglageFete.pour(qualite);
    if (qualite >= 5) {
      HapticFeedback.heavyImpact();
    } else if (qualite >= 4) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.lightImpact();
    }

    _particules.clear();
    _dernier = Duration.zero;
    // Faute de mesure disponible au tout premier appel, on part d'une taille
    // d'écran plausible : elle sera corrigée dès la première image.
    final taille = _taille.isEmpty ? const Size(400, 800) : _taille;
    final centre = Offset(taille.width / 2, taille.height * .34);

    for (var i = 0; i < r.nombre; i++) {
      final couleur = r.couleurs[_hasard.nextInt(r.couleurs.length)];
      final calibre = r.calibre * (.75 + _hasard.nextDouble() * .6);
      if (r.explosion) {
        final angle = _hasard.nextDouble() * pi * 2;
        // Poussée modérée, et l'air freine ensuite : à pleine puissance, les
        // particules quittaient l'écran en une seconde et la fête passait
        // inaperçue. Avec ces valeurs, la gerbe reste dense cinq secondes.
        final force = (90 + _hasard.nextDouble() * 200) * r.vitesse;
        _particules.add(_Particule(
          position: centre,
          vitesse: Offset(cos(angle) * force, sin(angle) * force),
          couleur: couleur,
          taille: calibre,
          rotation: _hasard.nextDouble() * pi,
          tournoie: (_hasard.nextDouble() - .5) * 10,
          forme: qualite >= 5 && i % 3 == 0 ? 2 : _hasard.nextInt(2),
        ));
      } else {
        // La pluie démarre déjà installée, et la réserve s'étend loin au-dessus
        // du cadre : celles qui sont hors champ descendent pendant que les
        // premières traversent, ce qui entretient le flux au lieu de le vider
        // d'un coup. Sans cette réserve, tout passait en une seconde.
        _particules.add(_Particule(
          position: Offset(
              taille.width * (.06 + _hasard.nextDouble() * .88),
              -taille.height * 1.2 +
                  _hasard.nextDouble() * (taille.height * 1.65)),
          vitesse: Offset((_hasard.nextDouble() - .5) * 30,
              (30 + _hasard.nextDouble() * 35) * r.vitesse),
          couleur: couleur,
          taille: calibre,
          rotation: _hasard.nextDouble() * pi,
          tournoie: (_hasard.nextDouble() - .5) * 4,
          forme: _hasard.nextInt(2),
        ));
      }
    }
    _origine = Duration.zero;
    _avancement = 0;
    _joue = true;
    _battement?.stop();
    _battement?.start();
  }

  void _avance(Duration total) {
    if (_origine == Duration.zero) {
      _origine = total;
      _dernier = Duration.zero;
    }
    final maintenant = total - _origine;
    var dt = (maintenant - _dernier).inMicroseconds / 1e6;
    _dernier = maintenant;
    _avancement = (maintenant.inMilliseconds / _duree).clamp(0.0, 1.0);
    if (_avancement >= 1) {
      _joue = false;
      _battement?.stop();
    }
    // Une image très longue (application mise en pause) ne doit pas téléporter
    // les particules à l'autre bout de l'écran.
    dt = dt.clamp(0.0, 0.05);

    for (final p in _particules) {
      p.position += p.vitesse * dt;
      // Gravité très douce pour les chutes, plus ferme pour les explosions —
      // bien en deçà d'une vraie chute libre, qui viderait l'écran avant qu'on
      // ait eu le temps de regarder. L'air freine aussi la descente, sinon les
      // confettis finissent par accélérer et tout se termine d'un coup.
      p.vitesse = Offset(
          p.vitesse.dx * (1 - 1.1 * dt),
          (p.vitesse.dy + (p.vitesse.dy.abs() > 150 ? 90 : 28) * dt) *
              (1 - 0.55 * dt));
      p.rotation += p.tournoie * dt;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, contraintes) {
      _taille = contraintes.biggest;
      return Stack(children: [
        widget.enfant,
        if (_joue)
          // Sans IgnorePointer, la couche de confettis avalerait les appuis
          // destinés à la page qui est dessous.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                size: contraintes.biggest,
                painter: _PeintreParticules(
                  particules: _particules,
                  avancement: _avancement,
                ),
              ),
            ),
          ),
      ]);
    });
  }
}

class _PeintreParticules extends CustomPainter {
  _PeintreParticules({required this.particules, required this.avancement});

  final List<_Particule> particules;
  final double avancement;

  @override
  void paint(Canvas toile, Size taille) {
    // Les confettis s'effacent sur la fin plutôt que de disparaître d'un coup.
    // Le fondu reste tardif : c'est la durée pleine qui fait la fête, pas
    // l'extinction.
    final opacite = avancement < .78 ? 1.0 : (1 - (avancement - .78) / .22);
    final pinceau = Paint();

    for (final p in particules) {
      if (p.position.dy > taille.height + 40) continue;
      pinceau.color = p.couleur.withValues(alpha: opacite.clamp(0.0, 1.0));
      toile.save();
      toile.translate(p.position.dx, p.position.dy);
      toile.rotate(p.rotation);
      switch (p.forme) {
        case 1:
          toile.drawCircle(Offset.zero, p.taille / 2, pinceau);
        case 2:
          _etoile(toile, p.taille, pinceau);
        default:
          toile.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                  center: Offset.zero, width: p.taille, height: p.taille * .62),
              const Radius.circular(2),
            ),
            pinceau,
          );
      }
      toile.restore();
    }
  }

  void _etoile(Canvas toile, double taille, Paint pinceau) {
    final chemin = Path();
    final rayon = taille / 2;
    for (var i = 0; i < 10; i++) {
      final r = i.isEven ? rayon : rayon * .45;
      final angle = i * pi / 5 - pi / 2;
      final point = Offset(cos(angle) * r, sin(angle) * r);
      i == 0 ? chemin.moveTo(point.dx, point.dy) : chemin.lineTo(point.dx, point.dy);
    }
    chemin.close();
    toile.drawPath(chemin, pinceau);
  }

  @override
  bool shouldRepaint(covariant _PeintreParticules ancien) => true;
}

/// La bannière d'une espèce jamais vue.
///
/// Une ligne de texte et une coche ne rendaient pas justice au moment : c'est
/// la seule fois où cette espèce entre au dex. La bannière arrive en grandissant,
/// dans la couleur de sa qualité, avec l'animal détouré posé dessus et le gain
/// qui s'égrène. Les paliers hauts gagnent un halo qui respire ; les communs
/// restent sobres, sans quoi trouver un pigeon vaudrait trouver un lynx.
class BanniereDecouverte extends StatefulWidget {
  const BanniereDecouverte({
    super.key,
    required this.nom,
    required this.latin,
    required this.qualite,
    required this.points,
    this.vignette,
  });

  final String nom;
  final String latin;
  final int qualite;
  final int points;

  /// L'animal détouré, s'il l'a été. Posé au centre de la bannière.
  final Widget? vignette;

  @override
  State<BanniereDecouverte> createState() => _BanniereDecouverteState();
}

class _BanniereDecouverteState extends State<BanniereDecouverte>
    with TickerProviderStateMixin {
  late final AnimationController _entree = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  )..forward();

  /// Le halo des paliers hauts, qui va et vient sans jamais s'arrêter.
  late final AnimationController _souffle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _entree.dispose();
    _souffle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final couleur = Palette.qualite(widget.qualite);
    final remarquable = widget.qualite >= 4;

    return AnimatedBuilder(
      animation: Listenable.merge([_entree, _souffle]),
      builder: (context, _) {
        final entree = Curves.easeOutBack.transform(_entree.value.clamp(0, 1));
        final respire = remarquable ? _souffle.value : 0.0;
        return Transform.scale(
          scale: .88 + .12 * entree,
          child: Opacity(
            opacity: Curves.easeOut.transform(_entree.value.clamp(0, 1)),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    couleur.withValues(alpha: .22),
                    couleur.withValues(alpha: .06),
                  ],
                ),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                    color: couleur.withValues(alpha: .55), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: couleur.withValues(alpha: .18 + .22 * respire),
                    blurRadius: 18 + 14 * respire,
                    spreadRadius: 1 + 2 * respire,
                  ),
                ],
              ),
              child: Column(children: [
                // Le ruban : ce qui vient d'arriver, dit en toutes lettres.
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                  decoration: BoxDecoration(
                    color: couleur,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                        widget.qualite == 5
                            ? Icons.auto_awesome
                            : remarquable
                                ? Icons.star
                                : Icons.new_releases_outlined,
                        size: 15,
                        color: Colors.white),
                    const SizedBox(width: 6),
                    Text(T('NOUVELLE ESPÈCE'),
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.1)),
                  ]),
                ),
                if (widget.vignette != null) ...[
                  const SizedBox(height: 14),
                  SizedBox(height: 118, child: widget.vignette),
                ],
                const SizedBox(height: 12),
                Text(widget.nom,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: widget.nom.length > 22 ? 22 : 27,
                      fontWeight: FontWeight.w900,
                      height: 1.12,
                      color: Palette.texte,
                    )),
                if (widget.latin.isNotEmpty && widget.latin != widget.nom) ...[
                  const SizedBox(height: 2),
                  Text(widget.latin,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: Palette.texteDoux,
                          fontSize: 13)),
                ],
                const SizedBox(height: 14),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: couleur.withValues(alpha: .18),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: couleur.withValues(alpha: .5)),
                    ),
                    // Le palier seul : le cri de joie (« Rare ! ») est porté
                    // juste en dessous par le compteur de points.
                    child: Text(
                      Palette.nomQualite(widget.qualite),
                      style: TextStyle(
                          color: couleur,
                          fontSize: 12,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                GainPoints(points: widget.points, qualite: widget.qualite),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// Le gain, dans la couleur de sa qualité, égrené comme un compteur de machine
/// à sous. S'affiche dans la carte de résultat, pas dans un écran à part.
class GainPoints extends StatefulWidget {
  const GainPoints({super.key, required this.points, required this.qualite});

  final int points;
  final int qualite;

  @override
  State<GainPoints> createState() => _GainPointsState();
}

class _GainPointsState extends State<GainPoints>
    with SingleTickerProviderStateMixin {
  late final AnimationController _compteur = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.points > 60 ? 1200 : 700),
  );

  @override
  void initState() {
    super.initState();
    // Un souffle avant de lancer le compteur : le verdict s'installe d'abord.
    Future.delayed(const Duration(milliseconds: 260), () {
      if (mounted) _compteur.forward();
    });
  }

  @override
  void dispose() {
    _compteur.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final couleur = Palette.qualite(widget.qualite);
    final reglage = ReglageFete.pour(widget.qualite);

    return AnimatedBuilder(
      animation: _compteur,
      builder: (context, _) {
        final avance = Curves.easeOutCubic.transform(_compteur.value);
        final valeur = (widget.points * avance).round();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: couleur.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: couleur.withValues(alpha: .55), width: 1.5),
            boxShadow: reglage.eclat
                ? [BoxShadow(color: couleur.withValues(alpha: .35), blurRadius: 18)]
                : null,
          ),
          child: Row(children: [
            if (widget.qualite >= 4)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Icon(
                    widget.qualite == 5 ? Icons.auto_awesome : Icons.star,
                    color: couleur,
                    size: 24),
              ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(reglage.titre,
                    style: TextStyle(
                        color: couleur,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: widget.qualite >= 5 ? 1.6 : .4)),
                Text(T('+{0} points', [valeur]),
                    style: TextStyle(
                      color: couleur,
                      fontSize: widget.qualite >= 5 ? 30 : 25,
                      fontWeight: FontWeight.w900,
                      height: 1.1,
                    )),
              ],
            ),
          ]),
        );
      },
    );
  }
}
