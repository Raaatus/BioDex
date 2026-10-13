import 'dart:async';
import '../i18n.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import '../api.dart';
import '../modeles.dart';
import '../reglages.dart';
import '../theme.dart';
import '../widgets/apercu_espece.dart';
import '../widgets/apercu_lieu.dart';
import '../widgets/celebration.dart';
import '../widgets/detourage.dart';
import '../widgets/identifier_amis.dart';
import '../widgets/lancer_sphere.dart';
import '../widgets/reactions.dart';
import '../widgets/regnes.dart';
import '../widgets/relacher.dart';
import '../widgets/viseur.dart';
import 'choix_espece.dart';
import 'detail_case.dart';
import 'mes_captures.dart';
import 'situer.dart';

/// Prendre une photo, l'envoyer, attendre le verdict.
///
/// L'analyse dure une quinzaine de secondes côté serveur, on ne peut donc pas
/// la faire tenir dans une requête : la photo est déposée, puis on interroge
/// régulièrement son état. Si l'application se ferme entre-temps, l'analyse se
/// poursuit et le résultat sera là au retour.
class EcranCapture extends StatefulWidget {
  const EcranCapture({super.key, this.visible = true});

  /// Vrai quand l'onglet est à l'écran. Les écrans restent montés dans la pile,
  /// si bien que sans cette information la caméra s'allumerait au lancement de
  /// l'application et resterait ouverte derrière les autres onglets.
  final bool visible;

  @override
  State<EcranCapture> createState() => _EcranCaptureState();
}

class _EcranCaptureState extends State<EcranCapture> {
  final _appareil = ImagePicker();

  File? _photo;
  Capture? _resultat;

  /// Vrai quand la case était déjà remplie avant cette photo : les points ne
  /// tombent qu'à la première découverte, autant le dire franchement.
  bool _dejaAuDex = false;

  /// Les propositions du modèle ne s'affichent que si le verdict est incertain,
  /// ou si le joueur les demande.
  bool _pistesVisibles = false;

  /// La case trouvée, pour connaître sa qualité et ses points.
  CaseDex? _case;

  /// Le règne déclaré pour la photo en attente d'envoi. Tant qu'il est nul, la
  /// photo est cadrée mais pas encore partie : c'est ce choix qui décide du
  /// moteur, et le deviner à partir de l'image coûterait trois analyses.
  String? _regne;

  /// Le dernier règne choisi, proposé par défaut au coup suivant : on
  /// photographie rarement une plante entre deux oiseaux.
  String _dernierRegne = 'animal';

  /// Le titre saisi avant l'envoi. On le donne pendant que le souvenir est
  /// frais — « le héron du canal » ne revient plus le soir venu — et il reste
  /// modifiable ensuite.
  final _titre = TextEditingController();

  /// Pilote les confettis, qui tombent par-dessus la page.
  final _fete = GlobalKey<ZoneCelebrationState>();

  /// Les illustrations Wikipédia des pistes, par case.
  ///
  /// Le serveur ne les a pas toujours en cache au moment du verdict : on les
  /// demande après coup, pour que les propositions ne soient pas une liste de
  /// binômes latins interchangeables.
  final _apercus = <int, String>{};
  bool _envoi = false;
  bool _galerie = false;

  /// Vrai pendant que le raccourci « ici, à l'instant » cherche le point GPS.
  /// Sans ce verrou, un doigt impatient lance trois relevés concurrents.
  bool _situeIciMaintenant = false;

  /// Vrai pendant le téléchargement de la photo à retoucher, puis pendant son
  /// renvoi. Sans ce verrou, deux appuis lancent deux analyses concurrentes.
  bool _retouche = false;

  /// La retouche préparée avant l'envoi, s'il y en a une.
  ///
  /// Elle ne remplace jamais [_photo] : l'originale part au serveur telle
  /// quelle, et c'est elle qu'on gardera. La retouche ne sert qu'à poser la
  /// question au moteur — et, quand elle porte un tracé, à faire la vignette.
  PhotoRetouchee? _retouchee;

  /// Le volet regardé dans l'aperçu avant envoi : 0 la découpe, 1 l'originale.
  final PageController _volets = PageController();
  int _volet = 0;

  /// L'étape de l'animation de capture, ou null quand elle ne joue pas.
  EtatCapture? _animation;

  /// Vrai pendant l'animation de relâche, qui rend la bête à la nature.
  bool _relache = false;
  String? _erreur;
  Timer? _sondage;

  @override
  void dispose() {
    _sondage?.cancel();
    _titre.dispose();
    _volets.dispose();
    super.dispose();
  }

  Future<void> _prend(ImageSource source) async {
    final galerie = source == ImageSource.gallery;
    final choisie = await _appareil.pickImage(
      source: source,
      // Réduire l'image la fait recompresser, ce qui efface l'EXIF au passage.
      // Sur une photo prise à l'instant c'est sans importance : l'heure est
      // maintenant et la position celle du téléphone. Sur une photo tirée de
      // la galerie, ce sont les seules traces de quand et où elle a été prise,
      // et le serveur sait très bien redimensionner lui-même.
      maxWidth: galerie ? null : 2048,
      maxHeight: galerie ? null : 2048,
      imageQuality: galerie ? null : 88,
      requestFullMetadata: true,
    );
    if (choisie == null) return;
    setState(() {
      _photo = File(choisie.path);
      _resultat = null;
      _retouchee = null;
      _case = null;
      _pistesVisibles = false;
      _erreur = null;
      _regne = null;              // la photo attend qu'on dise ce que c'est
      _galerie = galerie;
      _titre.clear();
    });
  }

  /// Vrai tant que l'onglet capture est à l'écran. La caméra consomme trop
  /// pour rester allumée dans un onglet qu'on ne regarde pas.
  bool get _viseurActif =>
      widget.visible && _photo == null && _resultat == null && !_envoi;

  /// Repartir sur une prise neuve : le viseur revient, la page se vide.
  void _reprend() {
    _sondage?.cancel();
    setState(() {
      _photo = null;
      _resultat = null;
      _retouchee = null;
      _case = null;
      _pistesVisibles = false;
      _erreur = null;
      _regne = null;
      _envoi = false;
      _animation = null;
    });
  }

  /// Une photo prise par le viseur intégré, déjà à pleine résolution.
  void _photoDuViseur(File fichier) {
    setState(() {
      _photo = fichier;
      _resultat = null;
      _retouchee = null;
      _case = null;
      _pistesVisibles = false;
      _erreur = null;
      _regne = null;
      // Prise à l'instant : l'heure est maintenant et la position est celle
      // du téléphone, comme pour l'appareil système.
      _galerie = false;
    });
  }

  /// Le joueur a dit ce qu'il photographiait : la photo peut partir.
  void _confirme(Regne r) {
    setState(() {
      _regne = r.cle;
      _dernierRegne = r.cle;
    });
    // La position part dans les deux cas, mais pas avec le même statut.
    //
    // On ne la joignait qu'aux photos prises sur place, de peur d'affirmer
    // qu'une vieille photo de galerie avait été prise ici. Le résultat était
    // pire : ces photos n'avaient aucun lieu, et n'apparaissaient nulle part.
    // Elles portent désormais le lieu de l'envoi, marqué « par défaut », et
    // l'application propose de le corriger.
    _envoie();
  }

  Future<Position?> _position() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          // On n'attend pas indéfiniment un point GPS : la capture prime.
          timeLimit: Duration(seconds: 5),
        ),
      );
    } catch (_) {
      // La position est un bonus : sans elle la capture marche très bien.
      return null;
    }
  }

  Future<void> _envoie() async {
    if (_photo == null) return;
    setState(() {
      _envoi = true;
      _erreur = null;
    });
    if (Reglages.instance.animationCapture) {
      setState(() => _animation = EtatCapture.attente);
    }
    try {
      final p = await _position();
      final id = await Api.instance.envoiePhoto(
          _photo!, lat: p?.latitude, lon: p?.longitude,
          regne: _regne ?? _dernierRegne, instantanee: !_galerie,
          analyse: _retouchee?.analyse, decoupe: _retouchee?.decoupe);
      _suit(id);
    } on ErreurApi catch (e) {
      setState(() {
        _erreur = e.message;
        _envoi = false;
      });
    } catch (e) {
      setState(() {
        _erreur = '$e';
        _envoi = false;
      });
    }
  }

  void _suit(int id) {
    _sondage?.cancel();
    _sondage = Timer.periodic(const Duration(seconds: 2), (t) async {
      try {
        final d = await Api.instance.get('/captures/$id');
        final c = Capture.depuisJson(d);
        if (!c.enCours) {
          t.cancel();
          var deja = false;
          CaseDex? laCase;
          if (c.caseId != null) {
            try {
              laCase = CaseDex.depuisJson(
                  await Api.instance.get('/dex/${c.caseId}'));
              // Plus d'une capture sur la case : l'espèce y était déjà, et les
              // points ne tombent qu'à la première découverte.
              deja = laCase.nbCaptures > 1;
            } catch (_) {
              // Information de confort : son absence ne bloque rien.
            }
          }
          if (mounted) {
            setState(() {
              _resultat = c;
              _case = laCase;
              _dejaAuDex = deja;
              _envoi = false;
              // L'issue de l'animation est celle de l'analyse. Elle doit être
              // posée **dans** le setState : modifiée en dehors, le widget
              // n'était pas reconstruit, la sphère restait à secouer et sa
              // conclusion ne se déclenchait jamais — donc pas de confettis
              // non plus, puisqu'ils l'attendent.
              if (_animation != null) {
                _animation = laCase != null && c.reussie
                    ? EtatCapture.reussi
                    : EtatCapture.manque;
              }
            });
            // Les confettis partaient jusqu'ici en même temps que le lancer :
            // ils étaient donc largement retombés au moment où la sphère
            // s'illuminait, c'est-à-dire au moment où l'on regarde. Ils
            // attendent maintenant la fin de l'animation — ou tombent tout de
            // suite si elle est désactivée.
            if (laCase != null &&
                Reglages.instance.confettis &&
                _animation == null) {
              _fete.currentState?.fete(laCase.rarete);
            }
            _chargeApercus(c);
          }
        }
      } catch (_) {
        // Une requête ratée n'est pas grave : la suivante réessaiera.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ZoneCelebration(
        key: _fete,
        enfant: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(T('Nouvelle capture'),
                        style:
                            TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                    SizedBox(height: 4),
                    Text(T('Cadre l\'animal, le reste se fait tout seul.'),
                        style: TextStyle(color: Palette.texteDoux)),
                  ],
                ),
              ),
              IconButton(
                tooltip: T('Mes photos'),
                icon: const Icon(Icons.photo_library_outlined),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const EcranMesCaptures())),
              ),
            ]),
            const SizedBox(height: 20),
            if (_photo != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  // La scène s'ouvre pendant l'animation : le lancer a besoin
                  // de course, 260 pixels n'en donnent aucune.
                  height: _animation != null ? 400 : 260,
                  width: double.infinity,
                  child: Stack(fit: StackFit.expand, children: [
                    // Avant l'envoi, la photo s'ouvre en grand pour être
                    // retouchée. Après, elle n'est plus qu'un souvenir de ce
                    // qu'on a montré au moteur.
                    if (_retouchee?.decoupe != null &&
                        _regne == null &&
                        _resultat == null)
                      _apercuDeuxVolets()
                    else
                      GestureDetector(
                        onTap: _regne == null && _resultat == null
                            ? _ouvreDetourage
                            : null,
                        child: Image.file(_photo!, fit: BoxFit.cover),
                      ),
                    if (_retouchee != null && _retouchee!.decoupe == null)
                      Positioned(
                        left: 8,
                        top: 8,
                        child: _pastilleRetouche(),
                      ),
                    if (_relache)
                      Relacher(
                        couleur: couleurAttente(_case?.rarete),
                        enfant: Image.file(_photo!, fit: BoxFit.cover),
                        surFin: () {
                          if (!mounted) return;
                          setState(() => _relache = false);
                          _reprend();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(T('Relâchée. Bonne route.'))),
                          );
                        },
                      ),
                    if (_animation != null)
                      LancerSphere(
                        // Une clé stable : sans elle, la reconstruction de la
                        // liste au fil des sondages recréait l'état et
                        // l'animation repartait de zéro sans jamais avancer.
                        key: const ValueKey('lancer'),
                        etat: _animation!,
                        couleur: couleurAttente(_case?.rarete),
                        surFin: () {
                          if (!mounted) return;
                          setState(() => _animation = null);
                          final c = _case;
                          if (c != null &&
                              !_dejaAuDex &&
                              Reglages.instance.confettis) {
                            _fete.currentState?.fete(c.rarete);
                          }
                        },
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
            ],
            // La photo est cadrée mais pas encore partie : on demande de quoi
            // il s'agit. Sous l'image, pour qu'on la voie en choisissant.
            if (_photo != null && _regne == null && _resultat == null) ...[
              // Rien n'est présélectionné : garder le dernier règne en
              // surbrillance laissait croire qu'il était déjà retenu, et on
              // envoyait une plante au moteur animalier sans s'en apercevoir.
              // Le rappel se met sous la photo et au-dessus du choix : c'est
              // le dernier moment où l'on peut encore retoucher, et le seul
              // où l'on regarde encore l'image.
              TextButton.icon(
                onPressed: _ouvreDetourage,
                icon: const Icon(Icons.gesture, size: 18),
                label: Text(_retouchee == null
                    ? 'Retoucher · entourer la bête au doigt'
                    : 'Modifier la retouche'),
              ),
              const SizedBox(height: 4),
              ChoixRegne(choisi: _regne, surChoix: _confirme),
              const SizedBox(height: 8),
            ],
            if (_envoi) _analyse(),
            if (_erreur != null) _messageErreur(),
            // Un appui sur le verdict rejoue la fête : on rate rarement une
            // découverte, mais on rate souvent l'animation — écran verrouillé,
            // regard ailleurs, ou simple envie de la revoir.
            // L'avertissement passe avant le verdict : une mise en garde lue
            // après avoir décidé ne sert à rien.
            if (_resultat != null && _resultat!.regne == 'champignon')
              const AvertissementChampignon(),
            if (_resultat != null)
              GestureDetector(
                onTap: _case == null
                    ? null
                    : () => _fete.currentState?.fete(_case!.rarete),
                child: _verdict(_resultat!),
              ),
            const SizedBox(height: 20),
            // L'appareil est déjà ouvert dans la page : plus besoin de sortir
            // de l'application, attendre, puis y revenir — la bête, elle, ne
            // patiente pas.
            if (_photo == null && !_envoi)
              Viseur(actif: _viseurActif, surPhoto: _photoDuViseur)
            else
              FilledButton.icon(
                // On repose la photo et le verdict : le viseur reprend la
                // place, prêt pour la bête suivante.
                onPressed: _envoi ? null : _reprend,
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(T('Prendre une photo')),
              ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _envoi ? null : () => _prend(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(T('Choisir dans la galerie')),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _analyse() => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Palette.fondSecondaire,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 14),
          Expanded(
            child: Text(
              T('Analyse en cours… une quinzaine de secondes.'),
              style: TextStyle(fontSize: 14),
            ),
          ),
        ]),
      );

  Widget _messageErreur() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Palette.alerte.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          Icon(Icons.error_outline, color: Palette.alerte),
          const SizedBox(width: 12),
          Expanded(
              child: Text(_erreur!,
                  style: TextStyle(color: Palette.alerte))),
        ]),
      );

  Widget _verdict(Capture c) {
    // Une espèce jamais vue mérite mieux qu'une coche verte : c'est la seule
    // fois où elle entre au dex. Le reste de la carte — pistes, boutons —
    // vient sous la bannière.
    final nouvelle = _case != null && !_dejaAuDex && c.reussie;
    if (nouvelle) return _decouverte(c, _case!);

    // Une espèce choisie à la main ne se présente pas comme un verdict du
    // moteur : c'est le joueur qui a tranché, et l'écran doit le dire.
    final (icone, couleur, titre) = c.corrigee
        ? (Icons.edit_outlined, Palette.accent, c.verdict)
        : switch (c.etat) {
            'ok' => (Icons.check_circle, Palette.accent, c.verdict),
            'doute' => (Icons.help_outline, const Color(0xFFB08A00), c.verdict),
            'rejet' => (Icons.block, Palette.texteDoux, 'Pas d\'animal reconnu'),
            _ => (Icons.error_outline, Palette.alerte, 'Erreur d\'analyse'),
          };

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icone, color: couleur),
            const SizedBox(width: 10),
            Expanded(
              child: Text(titre,
                  style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: couleur)),
            ),
          ]),
          if (c.latin.isNotEmpty && c.latin != titre) ...[
            const SizedBox(height: 4),
            Text(c.latin,
                style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Palette.texteDoux,
                    fontSize: 13)),
          ],
          // La note du moteur (« recadré 1152×1036 px — case sûre à 91 % »)
          // reste en base pour le diagnostic, mais n'a rien à faire ici : le
          // joueur veut savoir ce qu'il a trouvé, pas comment.
          // Les autres pistes n'intéressent que celui qui doute du verdict :
          // elles restent repliées tant qu'on ne les demande pas.
          if (c.top.isNotEmpty && (_pistesVisibles || !c.reussie)) ...[
            const SizedBox(height: 14),
            Text(c.reussie ? 'Autres pistes' : 'C\'était peut-être…',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700)),
            if (!c.reussie)
              Padding(
                padding: EdgeInsets.only(top: 2, bottom: 2),
                child: Text(
                  T('Appuyez sur la bonne pour la ranger dans votre dex.'),
                  style: TextStyle(fontSize: 11.5, color: Palette.texteDoux),
                ),
              ),
            const SizedBox(height: 8),
            for (final p in c.top) _piste(c, p),
          ] else if (c.top.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InkWell(
                onTap: () => setState(() => _pistesVisibles = true),
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text(T('Voir les autres pistes'),
                      style: TextStyle(
                          fontSize: 12,
                          color: Palette.texteDoux,
                          decoration: TextDecoration.underline)),
                ),
              ),
            ),
          // Le gain, dans la couleur de la qualité. Une espèce déjà trouvée ne
          // rapporte rien : on ne montre pas de compteur pour elle.
          if (_case != null && !_dejaAuDex && c.reussie) ...[
            const SizedBox(height: 14),
            GainPoints(points: _case!.points, qualite: _case!.rarete),
          ],
          if (c.caseId != null && _dejaAuDex)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(children: [
                Icon(Icons.check_circle_outline,
                    size: 16, color: Palette.texteDoux),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    T('Déjà dans ton dex : la photo s\'y ajoute, sans nouveaux points.'),
                    style: TextStyle(
                        fontSize: 12, color: Palette.texteDoux, height: 1.3),
                  ),
                ),
              ]),
            ),
          _champTitre(c),
          _quandEtOu(c),
          _avecQui(c),
          const SizedBox(height: 14),
          if (c.caseId != null) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonal(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => EcranDetailCase(caseId: c.caseId!),
                )),
                child: Text(T('Voir la case')),
              ),
            ),
            const SizedBox(height: 10),
          ],
          _boutonsCorrection(c),
        ],
      ),
    );
  }

  /// Relâcher la bête : la photo est supprimée et l'espèce quitte le dex.
  ///
  /// Ce n'est pas un geste décoratif : la capture disparaît, et si c'était la
  /// seule de la case, l'espèce redevient à trouver et ses points sont perdus.
  /// D'où la confirmation, qui dit exactement ce qu'on abandonne.
  Widget _boutonRelache(Capture c) {
    if (!c.reussie) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: OutlinedButton.icon(
        onPressed: _relache ? null : () => _demandeRelache(c),
        icon: const Icon(Icons.flight_takeoff, size: 18),
        label: Text(T('Relâcher')),
        style: OutlinedButton.styleFrom(foregroundColor: Palette.texteDoux),
      ),
    );
  }

  Future<void> _demandeRelache(Capture c) async {
    final laCase = _case;
    final premiere = laCase != null && !_dejaAuDex;
    final confirme = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(T('Relâcher cette prise ?')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            premiere
                ? 'La photo sera supprimée et « ${c.verdict} » quittera votre dex. Vous perdrez les ${laCase.points} points de la découverte, et la case redeviendra à trouver.'
                : 'La photo sera supprimée. L\'espèce reste dans votre dex : vous en avez d\'autres clichés.',
            style: const TextStyle(fontSize: 13.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          Text(T('C\'est définitif.'),
              style: TextStyle(
                  fontSize: 12,
                  color: Palette.texteDoux,
                  fontStyle: FontStyle.italic)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: Text(T('Garder'))),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            style: FilledButton.styleFrom(backgroundColor: Palette.alerte),
            child: Text(T('Relâcher')),
          ),
        ],
      ),
    );
    if (confirme != true || !mounted) return;

    try {
      await Api.instance.supprime('/captures/${c.id}');
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted) return;
    // Le verdict s'efface avant l'animation : il ne reste que la photo, et la
    // bête qui s'en va. Garder la carte à l'écran donnerait l'impression que
    // la case est encore acquise.
    setState(() {
      _relache = true;
      _animation = null;
      _resultat = null;
      _case = null;
      _dejaAuDex = false;
    });
  }

  /// Le titre de la photo, proposé une fois l'espèce connue.
  ///
  /// Le demander avant l'envoi obligeait à nommer une bête qu'on n'avait pas
  /// encore identifiée. Ici l'espèce est affichée juste au-dessus : le titre
  /// vient s'y ajouter, il ne la remplace pas.
  Widget _champTitre(Capture c) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TextField(
        controller: _titre,
        textCapitalization: TextCapitalization.sentences,
        maxLength: 120,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _enregistreTitre(c),
        onTapOutside: (_) => _enregistreTitre(c),
        decoration: InputDecoration(
          labelText: T('Un titre pour cette photo ?'),
          hintText: T('Le héron du canal…'),
          prefixIcon: const Icon(Icons.title, size: 20),
          counterText: '',
          isDense: true,
          suffixIcon: IconButton(
            tooltip: T('Enregistrer le titre'),
            icon: const Icon(Icons.check, size: 20),
            onPressed: () => _enregistreTitre(c),
          ),
        ),
      ),
    );
  }

  Future<void> _enregistreTitre(Capture c) async {
    final voulu = _titre.text.trim();
    if (voulu == c.titre) return;
    FocusScope.of(context).unfocus();
    try {
      final d = await Api.instance
          .patch('/captures/${c.id}/titre', {'titre': voulu});
      if (!mounted) return;
      setState(() => _resultat = Capture.depuisJson(d));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(voulu.isEmpty ? 'Titre retiré.' : 'Titre enregistré.')));
    } on ErreurApi catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  /// Le rappel de quand et où, avec de quoi rectifier.
  ///
  /// Une photo tirée de la galerie arrive souvent sans EXIF : la date devient
  /// celle de l'envoi et le lieu celui d'où l'on se trouvait. Plutôt que de
  /// laisser croire à une donnée juste, on le dit et on ouvre la porte à la
  /// correction.
  Widget _quandEtOu(Capture c) {
    final incertain = c.metadonneesIncertaines;
    final quand = c.priseLe ?? c.creeLe;
    final ou = c.lieu.isNotEmpty
        ? c.lieu
        : c.situee
            ? '${c.lat!.toStringAsFixed(4)}, ${c.lon!.toStringAsFixed(4)}'
            : 'lieu inconnu';

    return Column(children: [
      if (c.situee) ...[
        const SizedBox(height: 12),
        ApercuLieu(
          lat: c.lat!,
          lon: c.lon!,
          approximatif: incertain,
          onTap: () => _situe(c),
        ),
      ],
      InkWell(
      onTap: () => _situe(c),
      borderRadius: BorderRadius.circular(12),
      child: Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: incertain
            ? const Color(0xFFB08A00).withValues(alpha: .08)
            : Palette.fondSecondaire,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(incertain ? Icons.help_outline : Icons.schedule,
            size: 16,
            color: incertain ? const Color(0xFFB08A00) : Palette.texteDoux),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                quand.length >= 16
                    ? quand.substring(0, 16).replaceFirst(' ', ' à ')
                    : quand,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              Text(ou,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, color: Palette.texteDoux)),
              if (incertain)
                Text(T('Date et lieu de l\'envoi, pas de la prise de vue.'),
                    style: TextStyle(
                        fontSize: 11, color: Color(0xFF8A6D00), height: 1.3)),
            ],
          ),
        ),
        Icon(Icons.chevron_right, size: 18, color: Palette.texteDoux),
      ]),
      ),
      ),
    ]);
  }

  /// Qui d'autre a vu la bête.
  ///
  /// Une photo prise à deux compte pour deux : la case et les points tombent
  /// dans les deux dex, sans que le fichier parte deux fois sur le serveur.
  Widget _avecQui(Capture c) {
    final gens = c.participants;
    return InkWell(
      onTap: () => _identifie(c),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Palette.fondSecondaire,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(Icons.group_add_outlined,
              size: 17, color: Palette.texteDoux),
          const SizedBox(width: 9),
          Expanded(
            child: gens.isEmpty
                ? Text(T('J\'étais avec…'),
                    style: TextStyle(fontSize: 13, color: Palette.texteDoux))
                : Text(
                    gens.length == 1
                        ? 'Avec ${gens.first.pseudo}'
                        : 'Avec ${gens.map((g) => g.pseudo).join(', ')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          for (final g in gens.take(4))
            Padding(
              padding: const EdgeInsets.only(left: 3),
              child: Avatar(pseudo: g.pseudo, chemin: g.avatar, taille: 22),
            ),
          Icon(Icons.chevron_right, size: 18, color: Palette.texteDoux),
        ]),
      ),
    );
  }

  /// Ouvre le choix des amis présents, puis recharge la capture.
  ///
  /// Le rechargement n'est pas cosmétique : les participants viennent du
  /// serveur, qui a pu en refuser certains — un ami retiré entre-temps, un
  /// pseudo qui n'existe plus.
  Future<void> _identifie(Capture c) async {
    final change = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => IdentifierAmis(captureId: c.id, dejaLa: c.participants),
    ));
    if (change != true || !mounted) return;
    try {
      final d = await Api.instance.get('/captures/${c.id}');
      if (mounted) setState(() => _resultat = Capture.depuisJson(d));
    } on ErreurApi catch (_) {
      // Sans rechargement, l'écran garde l'ancienne liste : sans gravité,
      // elle se remettra d'aplomb à la prochaine ouverture.
    }
  }

  /// Les deux corrections possibles d'un verdict, côte à côte : l'espèce, puis
  /// quand et où. Ce sont les deux seules choses que le joueur peut vouloir
  /// reprendre, elles se tiennent au même endroit.
  Widget _boutonsCorrection(Capture c) {
    return Column(children: [
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _corrige,
            child: Text(c.reussie ? 'Ce n\'est pas ça' : 'Choisir l\'espèce'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _situe(c),
            icon: const Icon(Icons.edit_calendar_outlined, size: 17),
            label: Text(T('Date et lieu')),
          ),
        ),
      ]),
      // Retoucher puis refaire analyser. Le moteur échoue souvent pour des
      // raisons qu'un humain corrige en dix secondes : la bête occupe un
      // dixième du cadre, la photo est sombre, une branche traverse le sujet.
      if (c.caseId == null) ...[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            onPressed: _retouche ? null : () => _ouvreEditeur(c),
            icon: _retouche
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.tune, size: 17),
            label: Text(T('Retoucher et réessayer')),
          ),
        ),
      ],
      // Le raccourci qui couvre le cas courant : on photographie une bête et
      // on l'envoie depuis le même endroit, quelques minutes plus tard. Passer
      // par l'écran de correction pour poser un point qu'on a sous les pieds
      // était trois écrans de trop.
      if (c.metadonneesIncertaines) ...[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            onPressed: _situeIciMaintenant ? null : () => _iciMaintenant(c),
            icon: _situeIciMaintenant
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.my_location, size: 17),
            label: Text(T('Je l\'ai vue ici, à l\'instant')),
          ),
        ),
      ],
    ]);
  }

  /// Ouvre l'éditeur avant l'envoi.
  ///
  /// Ce qui en sort ne remplace pas la photo : l'originale partira telle
  /// quelle, et c'est elle qu'on gardera. La retouche voyage à côté, pour le
  /// moteur — et son tracé, s'il y en a un, deviendra la vignette de la case.
  Future<void> _ouvreDetourage() async {
    final photo = _photo;
    if (photo == null) return;
    final octets = await photo.readAsBytes();
    if (!mounted) return;
    final resultat = await Navigator.of(context).push<PhotoRetouchee>(
      MaterialPageRoute(
        builder: (_) => EcranDetourage(
            image: octets, titre: T('Avant d\'envoyer')),
      ),
    );
    if (resultat == null || !mounted) return;
    setState(() => _retouchee = resultat);
  }

  /// L'aperçu à deux volets, avant l'envoi.
  ///
  /// À gauche ce que le moteur va voir, à droite la photo telle qu'elle a été
  /// prise. On glisse de l'un à l'autre.
  ///
  /// C'est un affichage, rien de plus : quel que soit le volet regardé, la
  /// découpe part au moteur et l'originale est gardée. Mais voir les deux côte
  /// à côte avant de valider est le seul moment où l'on peut se rendre compte
  /// qu'on a entouré la branche plutôt que l'oiseau.
  Widget _apercuDeuxVolets() {
    return Stack(fit: StackFit.expand, children: [
      PageView(
        controller: _volets,
        onPageChanged: (i) => setState(() => _volet = i),
        children: [
          ColoredBox(
            // Un damier clair sous la découpe : sur fond uni, on ne
            // distingue pas le détouré du fond de l'écran.
            color: Palette.caseVide,
            child: Image.memory(_retouchee!.decoupe!, fit: BoxFit.contain),
          ),
          Image.file(_photo!, fit: BoxFit.cover),
        ],
      ),
      Positioned(
        left: 8,
        top: 8,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            _volet == 0 ? 'Ce que le moteur verra' : 'La photo gardée',
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ),
      ),
      // Deux points, comme partout : ils disent qu'il y a autre chose à côté.
      Positioned(
        bottom: 8,
        left: 0,
        right: 0,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (var i = 0; i < 2; i++)
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _volet == i
                    ? Colors.white
                    : Colors.white.withValues(alpha: .4),
              ),
            ),
        ]),
      ),
      Positioned(
        right: 8,
        top: 8,
        child: IconButton(
          tooltip: T('Reprendre la retouche'),
          onPressed: _ouvreDetourage,
          icon: const Icon(Icons.gesture, size: 18, color: Colors.white),
          style: IconButton.styleFrom(
            backgroundColor: Colors.black.withValues(alpha: .45),
          ),
        ),
      ),
    ]);
  }

  /// Le rappel posé sur la photo quand une retouche l'accompagne.
  Widget _pastilleRetouche() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(_retouchee?.decoupe != null ? Icons.gesture : Icons.tune,
            size: 13, color: Colors.white),
        const SizedBox(width: 5),
        Text(
          _retouchee?.decoupe != null ? 'Bête entourée' : 'Lumière ajustée',
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
      ]),
    );
  }

  /// Ouvre l'éditeur sur la photo, puis renvoie le résultat au moteur.
  ///
  /// On repart de l'image **originale** et non de la vignette : recadrer un
  /// carré de 512 pixels ne laisserait plus assez de matière pour reconnaître
  /// quoi que ce soit.
  Future<void> _ouvreEditeur(Capture c) async {
    setState(() => _retouche = true);
    try {
      final octets = await Api.instance.octets(c.photo);
      if (!mounted) return;
      final retouchee = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          builder: (_) => ProImageEditor.memory(
            octets,
            callbacks: ProImageEditorCallbacks(
              onImageEditingComplete: (bytes) async {
                Navigator.of(context).pop(bytes);
              },
            ),
          ),
        ),
      );
      if (retouchee == null || !mounted) return;

      final d = await Api.instance.reprend(c.id, retouchee);
      if (!mounted) return;
      setState(() {
        _resultat = Capture.depuisJson(d);
        _case = null;
        _pistesVisibles = false;
      });
      // La photo repart en file : on reprend le suivi comme après un envoi.
      _suit(c.id);
    } on ErreurApi catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _retouche = false);
    }
  }

  /// Pose la position du téléphone et l'heure courante sur la capture.
  ///
  /// Les deux passent en « manuel » côté serveur : le joueur affirme, il ne
  /// subit plus une valeur devinée. La photo sort donc de la liste des clichés
  /// à situer, et le bandeau d'avertissement disparaît.
  Future<void> _iciMaintenant(Capture c) async {
    setState(() => _situeIciMaintenant = true);
    try {
      final p = await _position();
      if (p == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(T('Position indisponible. Autorisez la localisation, ou placez le point à la main.'))));
        return;
      }
      final d = await Api.instance.patch('/captures/${c.id}/lieu', {
        'lat': p.latitude,
        'lon': p.longitude,
        'prise_le': DateTime.now().toUtc().toIso8601String().substring(0, 19),
      });
      if (!mounted) return;
      setState(() => _resultat = Capture.depuisJson(d));
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(T('Date et lieu enregistrés.'))));
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _situeIciMaintenant = false);
    }
  }

  /// Ouvre l'écran qui sert déjà à situer les photos orphelines.
  Future<void> _situe(Capture c) async {
    final fait = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => EcranSituerUne(
        capture: CaptureOrpheline.depuisJson({
          'capture_id': c.id,
          'nom': c.verdict,
          'cree_le': c.creeLe,
          'prise_le': c.priseLe,
          'lat': c.lat,
          'lon': c.lon,
          'sans_position': !c.situee,
          'sans_heure': c.priseLe == null,
          'vignette': c.vignette,
        }),
      ),
    ));
    if (fait != true || !mounted) return;
    // On relit la capture : l'écran de correction a écrit en base, l'affichage
    // doit suivre.
    try {
      final d = await Api.instance.get('/captures/${c.id}');
      if (mounted) setState(() => _resultat = Capture.depuisJson(d));
    } catch (_) {
      // Sans relecture, l'écran garde l'ancienne valeur : sans gravité.
    }
  }

  /// Va chercher les illustrations des pistes proposées.
  Future<void> _chargeApercus(Capture c) async {
    final aDemander = c.top
        .map((p) => p.caseId)
        .whereType<int>()
        .where((id) => !_apercus.containsKey(id))
        .toList();
    if (aDemander.isEmpty) return;
    try {
      final d =
          await Api.instance.get('/fiches', {'cases': aDemander.join(',')});
      if (!mounted) return;
      final fiches = (d['fiches'] as Map?) ?? const {};
      setState(() {
        for (final e in fiches.entries) {
          final image = (e.value as Map)['image'];
          if (image is String && image.isNotEmpty) {
            _apercus[int.parse(e.key)] = image;
          }
        }
      });
    } catch (_) {
      // Sans illustration, la silhouette fait l'affaire.
    }
  }

  /// Une piste du moteur, avec de quoi la reconnaître et la choisir.
  ///
  /// Le serveur ne renvoie plus un nombre fixe de propositions mais tout ce qui
  /// dépasse cinq pour cent : sur une image nette il n'y en a qu'une, sur une
  /// image douteuse il y en a huit. L'illustration vient de Wikipédia — devant
  /// deux binômes latins, une photo tranche bien plus vite qu'un nom.
  Widget _piste(Capture c, Proposition p) {
    final couleur = Palette.qualite(p.rarete);
    final image = p.image ?? (p.caseId == null ? null : _apercus[p.caseId]);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: p.caseId == null ? null : () => _retient(c, p),
        // Un appui long regarde sans choisir : comparer deux mésanges ne doit
        // pas obliger à en sélectionner une au hasard.
        onLongPress: p.caseId == null ? null : () => _apercu(c, p),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(children: [
            // La photo, elle, n'est jamais un bouton de sélection : elle ouvre
            // toujours l'aperçu. C'est le geste naturel quand on hésite.
            GestureDetector(
              onTap: p.caseId == null ? null : () => _apercu(c, p),
              child: Stack(children: [
                SizedBox(
                  width: 46,
                  height: 46,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: ColoredBox(
                      color: Palette.caseVide,
                      child: image != null
                          ? Image.network(image,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => _silhouetteDe(p))
                          : _silhouetteDe(p),
                    ),
                  ),
                ),
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .55),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.zoom_in,
                        size: 11, color: Colors.white),
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(p.nom,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w600)),
                    ),
                    // Le marquage toxique se lit sans ouvrir la fiche.
                    if (p.toxique) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Palette.alerte,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('TOXIQUE',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w900,
                                letterSpacing: .4)),
                      ),
                    ],
                  ]),
                  if (p.nomFr != null && p.latin != p.nom)
                    Text(p.latin,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                            color: Palette.texteDoux)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // La barre dit la confiance mieux qu'un pourcentage seul : on voit
            // d'un coup si le moteur hésite entre deux pistes ou penche.
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${(p.proba * 100).toStringAsFixed(0)} %',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: p.rarete > 0 ? couleur : Palette.texteDoux)),
              const SizedBox(height: 3),
              SizedBox(
                width: 46,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: p.proba.clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: Palette.caseVide,
                    valueColor: AlwaysStoppedAnimation(
                        p.rarete > 0 ? couleur : Palette.texteDoux),
                  ),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _silhouetteDe(Proposition p) => Padding(
        padding: const EdgeInsets.all(7),
        child: p.visuel == null
            ? Icon(Icons.help_outline,
                color: Palette.silhouette, size: 16)
            : SvgPicture.network(
                Api.instance.image(p.visuel!).toString(),
                colorFilter: ColorFilter.mode(
                    Palette.silhouette, BlendMode.srcIn),
              ),
      );

  /// Regarder une piste de près, sans l'adopter.
  ///
  /// C'est le geste qui manquait : jusque-là il fallait sélectionner l'espèce
  /// pour la voir, donc se tromper volontairement pour comparer.
  Future<void> _apercu(Capture c, Proposition p) async {
    if (p.caseId == null) return;
    final choisi = await showDialog<bool>(
      context: context,
      builder: (_) => ApercuEspece(
        caseId: p.caseId!,
        nom: p.nom,
        latin: p.latin,
        image: p.image ?? _apercus[p.caseId],
        resume: p.resume,
        regne: p.regne,
        toxique: p.toxique,
        rarete: p.rarete,
        points: p.points,
        proba: p.proba,
      ),
    );
    if (choisi == true && mounted) await _retient(c, p);
  }

  /// Le joueur désigne une piste : elle devient l'espèce de la capture.
  Future<void> _retient(Capture c, Proposition p) async {
    try {
      final d = await Api.instance
          .post('/captures/${c.id}/espece', {'case_id': p.caseId});
      if (!mounted) return;
      final corrigee = Capture.depuisJson(d);
      setState(() {
        _resultat = corrigee;
        _pistesVisibles = false;
      });
      await _rafraichitCase(corrigee);
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// La carte d'une espèce qui entre au dex pour la première fois.
  Widget _decouverte(Capture c, CaseDex laCase) {
    return Column(children: [
      BanniereDecouverte(
        nom: c.verdict,
        latin: c.latin,
        qualite: laCase.rarete,
        points: laCase.points,
        // L'animal détouré plutôt que la photo entière : c'est la bête qu'on
        // fête, pas le buisson derrière.
        vignette: c.decoupe != null
            ? Image.network(Api.instance.image(c.decoupe!).toString(),
                headers: Api.instance.entetes, fit: BoxFit.contain)
            : null,
      ),
      const SizedBox(height: 14),
      if (c.caseId != null)
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonal(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => EcranDetailCase(caseId: c.caseId!),
            )),
            child: Text(T('Voir la case')),
          ),
        ),
      const SizedBox(height: 10),
      _boutonsCorrection(c),
      _boutonRelache(c),
      _champTitre(c),
      _quandEtOu(c),
      _avecQui(c),
      // Les pistes écartées restent accessibles, mais discrètement : elles
      // n'ont pas à encombrer un moment de fête.
      if (c.top.isNotEmpty)
        TextButton(
          onPressed: () => setState(() => _pistesVisibles = !_pistesVisibles),
          child: Text(_pistesVisibles ? 'Masquer les pistes' : 'Autres pistes',
              style: TextStyle(fontSize: 12, color: Palette.texteDoux)),
        ),
      if (_pistesVisibles)
        for (final p in c.top) _piste(c, p),
    ]);
  }

  /// Le joueur reprend la main sur le verdict.
  ///
  /// On pré-remplit la recherche avec la meilleure piste du moteur : quand il
  /// hésite entre deux mésanges, la bonne est souvent à une ligne de là.
  Future<void> _corrige() async {
    final c = _resultat;
    if (c == null) return;
    final piste = c.top.isNotEmpty ? c.top.first.nom : '';

    final choix = await Navigator.of(context).push<CaseDex>(MaterialPageRoute(
      builder: (_) => EcranChoixEspece(pisteInitiale: piste),
    ));
    if (choix == null) return;

    try {
      final d = await Api.instance
          .post('/captures/${c.id}/espece', {'case_id': choix.id});
      if (!mounted) return;
      final corrigee = Capture.depuisJson(d);
      setState(() {
        _resultat = corrigee;
        _pistesVisibles = false;
      });
      await _rafraichitCase(corrigee);
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Recharge la case après une correction, et fête si l'espèce est nouvelle.
  ///
  /// Désigner soi-même une espèce jamais vue reste une découverte : elle entre
  /// au dex et rapporte ses points. Rien ne justifiait que ce moment soit plus
  /// terne que lorsque le moteur trouve tout seul.
  Future<void> _rafraichitCase(Capture c) async {
    if (c.caseId == null) return;
    try {
      final laCase = CaseDex.depuisJson(
          await Api.instance.get('/dex/${c.caseId}'));
      if (!mounted) return;
      final deja = laCase.nbCaptures > 1;
      setState(() {
        _case = laCase;
        _dejaAuDex = deja;
      });
      if (!deja) _fete.currentState?.fete(laCase.rarete);
    } catch (_) {
      // Information de confort : son absence ne bloque rien.
    }
  }
}
