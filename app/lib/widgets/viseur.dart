import 'dart:io';
import '../i18n.dart';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';


/// L'aperçu de l'appareil photo, intégré à la page.
///
/// Ouvrir l'appareil système faisait sortir de l'application, attendre, puis y
/// revenir : trois écrans pour une bête qui, elle, ne vous attend pas. Ici
/// l'image est déjà là, et le déclencheur est sous le pouce.
///
/// La résolution est réglée au maximum de ce que l'appareil sait faire —
/// [ResolutionPreset.max] — parce que le classificateur travaille sur un
/// recadrage : ce qui est perdu au moment de la prise ne se rattrape pas, et
/// une aile de papillon fait vingt pixels dans une photo médiocre.
class Viseur extends StatefulWidget {
  const Viseur({
    super.key,
    required this.surPhoto,
    this.actif = true,
  });

  /// Appelé avec le fichier pris, à pleine résolution.
  final void Function(File) surPhoto;

  /// Faux quand la page n'est pas visible : la caméra se libère alors, elle
  /// consomme trop pour rester allumée dans un onglet qu'on ne regarde pas.
  final bool actif;

  @override
  State<Viseur> createState() => _ViseurState();
}

class _ViseurState extends State<Viseur> with WidgetsBindingObserver {
  CameraController? _appareil;
  List<CameraDescription> _disponibles = const [];
  bool _prepare = false;
  bool _declenche = false;
  String? _erreur;

  /// Les réglages de l'appareil, tels que le pilote les expose. On ne
  /// réimplémente rien : le zoom, le flash et la mise au point sont ceux du
  /// capteur, pas des effets appliqués après coup.
  FlashMode _flash = FlashMode.off;
  double _zoom = 1;
  double _zoomMin = 1;
  double _zoomMax = 1;
  double _zoomAuDebut = 1;

  /// Le viseur peut occuper plus de place : une bête cadrée sur un tiers
  /// d'écran se distingue mal.
  bool _agrandi = false;

  /// L'objectif utilisé. On garde l'arrière par défaut — on photographie une
  /// bête, pas soi-même — mais la façade sert pour un insecte posé sur sa main,
  /// ou simplement pour se cadrer.
  CameraLensDirection _objectif = CameraLensDirection.back;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.actif) _ouvre();
  }

  @override
  void didUpdateWidget(Viseur ancien) {
    super.didUpdateWidget(ancien);
    if (widget.actif && !ancien.actif) {
      _ouvre();
    } else if (!widget.actif && ancien.actif) {
      _ferme();
    }
  }

  /// Mise en veille, appel entrant, application en arrière-plan : le système
  /// reprend la caméra de toute façon, autant la rendre proprement.
  @override
  void didChangeAppLifecycleState(AppLifecycleState etat) {
    if (!widget.actif) return;
    if (etat == AppLifecycleState.inactive) {
      _ferme();
    } else if (etat == AppLifecycleState.resumed) {
      _ouvre();
    }
  }

  Future<void> _ouvre() async {
    if (_appareil != null || _prepare) return;
    setState(() {
      _prepare = true;
      _erreur = null;
    });
    try {
      _disponibles = await availableCameras();
      if (_disponibles.isEmpty) {
        throw CameraException('aucune', 'Aucun appareil photo détecté.');
      }
      final choisi = _disponibles.firstWhere(
        (c) => c.lensDirection == _objectif,
        orElse: () => _disponibles.first,
      );
      final c = CameraController(
        choisi,
        ResolutionPreset.max,
        enableAudio: false,
      );
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      _zoomMin = await c.getMinZoomLevel();
      _zoomMax = await c.getMaxZoomLevel();
      _zoom = _zoomMin;
      await c.setFlashMode(_flash);
      setState(() => _appareil = c);
    } on CameraException catch (e) {
      if (mounted) {
        setState(() => _erreur = e.description ?? 'Appareil photo indisponible.');
      }
    } finally {
      if (mounted) setState(() => _prepare = false);
    }
  }

  Future<void> _ferme() async {
    final c = _appareil;
    _appareil = null;
    if (mounted) setState(() {});
    await c?.dispose();
  }

  /// Agrandit ou réduit l'aperçu, puis le ramène au centre de l'écran.
  ///
  /// Sans le recentrage, l'agrandissement ne faisait que pousser le bas de la
  /// page : le viseur débordait sous l'écran et l'on ne voyait plus ce qu'on
  /// cadrait. Le geste attendu est que l'image prenne la place, pas qu'elle
  /// s'étire vers le bas.
  void _basculeTaille() {
    setState(() => _agrandi = !_agrandi);
    // Le recentrage attend que la nouvelle hauteur soit posée : calculé sur
    // l'ancienne, il viserait à côté.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final defilement = Scrollable.maybeOf(context);
      if (defilement == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,             // au milieu de la zone visible
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// Bascule entre l'objectif avant et l'objectif arrière.
  Future<void> _retourne() async {
    if (_disponibles.length < 2 || _prepare) return;
    _objectif = _objectif == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    // Le contrôleur est lié à un objectif : on en referme un pour en ouvrir
    // un autre, il n'y a pas de bascule à chaud.
    await _ferme();
    _flash = FlashMode.off;      // la façade n'a en général pas de flash
    await _ouvre();
  }

  /// Fait le tour des modes du flash proposés par l'appareil.
  Future<void> _changeFlash() async {
    final c = _appareil;
    if (c == null) return;
    const suite = [FlashMode.off, FlashMode.auto, FlashMode.always,
                   FlashMode.torch];
    final prochain = suite[(suite.indexOf(_flash) + 1) % suite.length];
    try {
      await c.setFlashMode(prochain);
      setState(() => _flash = prochain);
    } on CameraException {
      // Tous les appareils n'ont pas les quatre modes : on passe au suivant.
    }
  }

  Future<void> _changeZoom(double valeur) async {
    final c = _appareil;
    if (c == null) return;
    final v = valeur.clamp(_zoomMin, _zoomMax);
    await c.setZoomLevel(v);
    setState(() => _zoom = v);
  }

  /// La mise au point là où l'on touche, comme dans l'appareil du téléphone.
  Future<void> _viseLe(Offset position, Size taille) async {
    final c = _appareil;
    if (c == null) return;
    final point = Offset(
        (position.dx / taille.width).clamp(0, 1),
        (position.dy / taille.height).clamp(0, 1));
    try {
      await c.setFocusPoint(point);
      await c.setExposurePoint(point);
    } on CameraException {
      // Appareil sans mise au point réglable : sans conséquence.
    }
  }

  Future<void> _prend() async {
    final c = _appareil;
    if (c == null || _declenche || !c.value.isInitialized) return;
    setState(() => _declenche = true);
    try {
      final fichier = await c.takePicture();
      widget.surPhoto(File(fichier.path));
    } on CameraException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(T('Prise impossible : {0}', [e.description]))));
      }
    } finally {
      if (mounted) setState(() => _declenche = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appareil?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _appareil;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        // Le viseur s'agrandit à la demande : cadrer une mésange sur un tiers
        // d'écran ne permet pas de voir ce qu'on photographie.
        height: _agrandi
            ? MediaQuery.of(context).size.height * .78
            : MediaQuery.of(context).size.width * 4 / 3,
        child: Stack(fit: StackFit.expand, children: [
          if (c != null && c.value.isInitialized)
            // La prévisualisation garde son propre rapport ; on la recadre au
            // cadre plutôt que de la déformer.
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: c.value.previewSize?.height ?? 1080,
                height: c.value.previewSize?.width ?? 1440,
                child: CameraPreview(c),
              ),
            )
          else
            ColoredBox(
              color: const Color(0xFF15171B),
              child: Center(
                child: _erreur != null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_erreur!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70)),
                      )
                    : const CircularProgressIndicator(color: Colors.white24),
              ),
            ),
          if (c != null && c.value.isInitialized) ...[
            // La mise au point suit le doigt, et le pincement règle le zoom
            // optique du capteur — ce sont les commandes de l'appareil, pas
            // des effets ajoutés après coup.
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, contraintes) => GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapDown: (d) =>
                      _viseLe(d.localPosition, contraintes.biggest),
                  onScaleStart: (_) => _zoomAuDebut = _zoom,
                  onScaleUpdate: (d) {
                    if (d.pointerCount < 2) return;
                    _changeZoom(_zoomAuDebut * d.scale);
                  },
                ),
              ),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: Row(children: [
                _pastille(
                  icone: switch (_flash) {
                    FlashMode.off => Icons.flash_off,
                    FlashMode.auto => Icons.flash_auto,
                    FlashMode.always => Icons.flash_on,
                    FlashMode.torch => Icons.highlight,
                  },
                  actif: _flash != FlashMode.off,
                  surAppui: _changeFlash,
                ),
                if (_zoomMax > _zoomMin + .1) ...[
                  const SizedBox(width: 6),
                  _pastille(
                    texte: '${_zoom.toStringAsFixed(1)}×',
                    surAppui: () => _changeZoom(
                        _zoom >= _zoomMax - .1 ? _zoomMin : _zoom + 1),
                  ),
                ],
              ]),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: Row(children: [
                if (_disponibles.length > 1) ...[
                  _pastille(
                    icone: Icons.cameraswitch_outlined,
                    actif: _objectif == CameraLensDirection.front,
                    surAppui: _retourne,
                  ),
                  const SizedBox(width: 6),
                ],
                _pastille(
                  icone: _agrandi ? Icons.close_fullscreen : Icons.open_in_full,
                  surAppui: _basculeTaille,
                ),
              ]),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(child: _declencheur()),
            ),
          ],
        ]),
      ),
    );
  }

  /// Une commande posée sur l'aperçu : ronde, sombre, lisible sur n'importe
  /// quelle scène.
  Widget _pastille({
    IconData? icone,
    String? texte,
    bool actif = false,
    required VoidCallback surAppui,
  }) {
    return Material(
      color: actif
          ? Colors.white.withValues(alpha: .85)
          : Colors.black.withValues(alpha: .42),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: surAppui,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Center(
            child: icone != null
                ? Icon(icone,
                    size: 19,
                    color: actif ? Colors.black87 : Colors.white)
                : Text(texte!,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700)),
          ),
        ),
      ),
    );
  }

  /// Le déclencheur : un anneau blanc, comme dans l'appareil du téléphone.
  Widget _declencheur() {
    return GestureDetector(
      onTap: _declenche ? null : _prend,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: _declenche ? 66 : 76,
        height: _declenche ? 66 : 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: .2),
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: Center(
          child: Container(
            width: _declenche ? 38 : 52,
            height: _declenche ? 38 : 52,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
