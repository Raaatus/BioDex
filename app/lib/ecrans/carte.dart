import 'package:flutter/material.dart';
import '../i18n.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';

import '../reglages.dart';
import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import '../widgets/regnes.dart';
import '../widgets/case_dex.dart';
import '../widgets/reactions.dart';
import 'detail_case.dart';
import 'situer.dart';
import 'visionneuse.dart';

/// La carte des trouvailles.
///
/// Les photos apparaissent là où elles ont été prises. Dézoomé, elles se
/// regroupent en bulles qui portent leur nombre ; en zoomant, les bulles se
/// scindent jusqu'à laisser voir les animaux un par un. Un appui ouvre la fiche :
/// qui a photographié quoi, quand, et où.
///
/// Le fond est satellite par défaut — c'est celui qui donne envie de fouiller —
/// avec un plan classique en second choix, plus lisible en ville.
class EcranCarte extends StatefulWidget {
  const EcranCarte({super.key});

  @override
  State<EcranCarte> createState() => _EcranCarteState();
}

/// Fonds de carte. Aucun ne demande de clé : ni compte à créer, ni facture.
enum FondCarte {
  satellite(
    'Satellite',
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    'Esri, Maxar, Earthstar Geographics',
    19,
  ),
  plan(
    'Plan',
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    '© OpenStreetMap',
    19,
  ),
  relief(
    'Relief',
    'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    '© OpenTopoMap, OpenStreetMap',
    17,
  );

  const FondCarte(this.etiquette, this.gabarit, this.credit, this.zoomMax);
  final String etiquette;
  final String gabarit;
  final String credit;
  final int zoomMax;
}

class _EcranCarteState extends State<EcranCarte> {
  final _carte = MapController();

  List<PointCarte> _points = [];
  List<CaptureOrpheline> _orphelines = [];
  FondCarte _fond = FondCarte.satellite;
  String _qui = 'tous';

  /// Le règne affiché, ou null pour les trois. Se combine avec « qui » : on
  /// peut vouloir les champignons de ses amis seulement.
  String? _regne;
  double _zoom = 5;
  bool _charge = true;
  String? _erreur;

  /// Les marqueurs, fabriqués une fois puis gardés.
  ///
  /// Ils étaient reconstruits à chaque `setState`, donc à chaque changement de
  /// palier de zoom : deux mille objets recréés, et le regroupement obligé de
  /// refaire son arbre par-dessus. C'est là que partait la fluidité. On ne les
  /// refait plus que quand les données changent, ou quand la taille des
  /// pastilles change vraiment.
  List<Marker>? _marqueurs;
  double? _tailleDesMarqueurs;

  /// Où se trouve le téléphone, une fois qu'on l'a demandé.
  LatLng? _maPosition;
  bool _suitPosition = false;
  bool _chercheMoi = false;

  /// Vrai jusqu'au premier chargement réussi : après, la vue appartient au
  /// joueur et on n'y touche plus sans qu'il le demande.
  bool _premiereFois = true;

  @override
  void dispose() {
    _carte.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _rafraichit();
  }

  Future<void> _rafraichit() async {
    setState(() {
      _charge = true;
      _erreur = null;
    });
    try {
      final r = await Future.wait([
        Api.instance.get('/carte',
            {'qui': _qui, if (_regne != null) 'regne': _regne}),
        Api.instance.get('/carte/orphelines'),
      ]);
      if (!mounted) return;
      setState(() {
        _marqueurs = null;          // les données changent : on les refera
        _points =
            (r[0]['points'] as List).map((p) => PointCarte.depuisJson(p)).toList();
        _orphelines = (r[1]['captures'] as List)
            .map((c) => CaptureOrpheline.depuisJson(c))
            .toList();
      });
      // On ne recadre qu'à l'ouverture.
      //
      // Recadrer à chaque rafraîchissement paraissait serviable et se
      // retournait contre le joueur : penché sur un bosquet, il touchait
      // « Amis » et la carte le renvoyait au niveau du pays. Le filtre change
      // ce qu'on voit, pas où l'on regarde.
      if (_premiereFois) {
        _premiereFois = false;
        _cadre();
      }
    } on ErreurApi catch (e) {
      if (mounted) setState(() => _erreur = e.message);
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  /// Recentre la vue sur l'ensemble des points, pour ne pas s'ouvrir au milieu
  /// de l'Atlantique quand toutes les photos sont dans le même département.
  void _cadre() {
    if (_points.isEmpty) return;
    final positions = _points.map((p) => LatLng(p.lat, p.lon)).toList();
    if (positions.length == 1) {
      _carte.move(positions.first, 13);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _carte.fitCamera(CameraFit.coordinates(
        coordinates: positions,
        padding: const EdgeInsets.all(60),
        maxZoom: 14,
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(T('Carte')),
        actions: [
          if (_orphelines.isNotEmpty)
            IconButton(
              tooltip: T('{0} photo(s) à situer', [_orphelines.length]),
              icon: Badge.count(
                count: _orphelines.length,
                child: const Icon(Icons.wrong_location_outlined),
              ),
              onPressed: _ouvreOrphelines,
            ),
          PopupMenuButton<FondCarte>(
            tooltip: T('Fond de carte'),
            icon: const Icon(Icons.layers_outlined),
            initialValue: _fond,
            onSelected: (f) => setState(() => _fond = f),
            itemBuilder: (_) => [
              for (final f in FondCarte.values)
                PopupMenuItem(value: f, child: Text(f.etiquette)),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          _plan(),
          if (_charge) const LinearProgressIndicator(minHeight: 2),
          if (_erreur != null) _bandeauErreur(),
          Positioned(left: 12, top: 12, child: _filtreQui()),
          if (_points.isNotEmpty)
            Positioned(left: 12, top: 60, child: _compteur()),
          Positioned(right: 12, bottom: 24, child: _boutons()),
          if (!_charge && _points.isEmpty && _erreur == null) _vide(),
        ],
      ),
    );
  }

  Widget _plan() {
    return FlutterMap(
      mapController: _carte,
      options: MapOptions(
        initialCenter: const LatLng(46.6, 2.4),   // la France, faute de mieux
        initialZoom: 5,
        maxZoom: _fond.zoomMax.toDouble(),
        minZoom: 2,
        // La rotation à deux doigts fait tourner la carte, comme sur un globe.
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all,
        ),
        // On ne reconstruit qu'aux paliers de taille des marqueurs, pas à
        // chaque pixel de zoom : sinon la carte se reconstruirait sans cesse.
        onPositionChanged: (camera, _) {
          final avant = _taillePastille;
          _zoom = camera.zoom;
          if (_taillePastille != avant) setState(() {});
        },
      ),
      children: [
        TileLayer(
          urlTemplate: _fond.gabarit,
          subdomains: const ['a', 'b', 'c'],
          userAgentPackageName: 'fr.biodex.app',
          maxNativeZoom: _fond.zoomMax,
        ),
        _pointDeMoi(),
        _bulles(),
        RichAttributionWidget(
          alignment: AttributionAlignment.bottomLeft,
          attributions: [TextSourceAttribution(_fond.credit, onTap: null)],
        ),
      ],
    );
  }

  /// Taille des marqueurs selon le zoom.
  ///
  /// Dézoomé, la carte doit rester lisible : des pastilles minuscules qui
  /// piquent l'endroit sans le masquer. Plus on approche, plus il y a de place,
  /// et plus l'animal mérite d'être vu.
  double get _taillePastille {
    final zoom = _zoom;
    if (zoom < 8) return 22;
    if (zoom < 11) return 30;
    if (zoom < 14) return 40;
    return 54;
  }

  Widget _bulles() {
    final taille = _taillePastille;
    // Les marqueurs ne se refont que si leur taille a changé de palier, ou si
    // les données ont bougé (`_marqueurs` remis à null par `_rafraichit`).
    if (_marqueurs == null || _tailleDesMarqueurs != taille) {
      _tailleDesMarqueurs = taille;
      _marqueurs = [
        for (final p in _points)
          Marker(
            point: LatLng(p.lat, p.lon),
            width: taille,
            // De la place sous la pastille pour le médaillon de l'auteur,
            // qui déborde légèrement en bas.
            height: taille + (taille >= 40 ? 10 : 0),
            child: RepaintBoundary(
              child: GestureDetector(
                onTap: () => _fiche([p]),
                child: _Pastille(point: p, taille: taille),
              ),
            ),
          ),
      ];
    }

    return MarkerClusterLayerWidget(
      options: MarkerClusterLayerOptions(
        maxClusterRadius: 55,
        size: Size(taille * .8, taille * .8),
        padding: const EdgeInsets.all(50),
        // Sans ça, le regroupement s'arrête de zoomer à 17 — sa valeur par
        // défaut — alors que le fond de carte va jusqu'à 19. Les bulles
        // serrées ne se séparaient donc jamais : on appuyait, la carte
        // avançait d'un cran, et rien ne se dénouait.
        maxZoom: _fond.zoomMax.toDouble(),
        // Tout en haut du zoom, on veut voir les photos une à une plutôt
        // qu'une bulle « 3 » posée sur un buisson.
        disableClusteringAtZoom: _fond.zoomMax - 1,
        // On pilote le zoom nous-mêmes, cf. `onClusterTap`. Laissé à `true`,
        // le paquet zoomait *en plus* de ce qu'on faisait, et la liste
        // s'ouvrait pendant que la carte glissait dessous.
        zoomToBoundsOnClick: false,
        spiderfyCluster: false,
        markers: _marqueurs!,
        builder: (context, marqueurs) => _Bulle(nombre: marqueurs.length),
        onClusterTap: _ouvreBulle,
      ),
    );
  }

  /// Ce que fait un appui sur une bulle.
  ///
  /// Deux cas, et c'est la distinction qui manquait. Si les photos qu'elle
  /// contient sont réparties sur une vraie surface, on cadre cette surface :
  /// la bulle s'ouvre en plusieurs, là où on a appuyé. Si elles sont toutes au
  /// même endroit — le même arbre, le même étang — aucun zoom ne les séparera
  /// jamais, et continuer à grossir ne ferait qu'égarer le joueur. On montre
  /// alors la liste.
  void _ouvreBulle(MarkerClusterNode bulle) {
    final coins = bulle.bounds;
    final memeEndroit = coins.north - coins.south < _memePoint &&
        coins.east - coins.west < _memePoint;

    if (memeEndroit || _zoom >= _fond.zoomMax - 1) {
      _fiche(_pointsDe(bulle));
      return;
    }
    _carte.fitCamera(CameraFit.bounds(
      bounds: coins,
      padding: const EdgeInsets.all(60),
      maxZoom: _fond.zoomMax.toDouble(),
    ));
  }

  /// En degrés : en deçà, deux photos comptent comme prises au même endroit.
  ///
  /// Deux dix-millièmes de degré font une vingtaine de mètres sous nos
  /// latitudes — l'ordre de grandeur de l'erreur d'un GPS de téléphone. En
  /// dessous, l'écart entre deux points ne veut plus rien dire, et zoomer
  /// dessus ne séparerait que du bruit de mesure.
  static const _memePoint = 0.0002;

  /// Les points d'une bulle, retrouvés depuis ses marqueurs.
  ///
  /// La correspondance se fait sur les coordonnées, faute de mieux : le paquet
  /// ne rend que des `Marker`, sans lien vers ce qu'on lui a donné. Deux
  /// photos exactement au même point rendraient donc la même première, d'où le
  /// passage par un index qui les garde toutes.
  List<PointCarte> _pointsDe(MarkerClusterNode bulle) {
    final par = <String, List<PointCarte>>{};
    for (final p in _points) {
      par.putIfAbsent('${p.lat},${p.lon}', () => []).add(p);
    }
    final vus = <PointCarte>{};
    for (final m in bulle.markers) {
      final cle = '${m.point.latitude},${m.point.longitude}';
      vus.addAll(par[cle] ?? const []);
    }
    return vus.toList();
  }

  Widget _filtreQui() {
    return SafeArea(
      child: Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(20),
        color: Palette.fond,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final (valeur, etiquette) in const [
              ('tous', 'Tous'),
              ('moi', 'Moi'),
              ('amis', 'Amis'),
            ])
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  setState(() => _qui = valeur);
                  _rafraichit();
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(etiquette,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: _qui == valeur
                            ? FontWeight.w700
                            : FontWeight.w400,
                        color:
                            _qui == valeur ? Palette.accent : Palette.texteDoux,
                      )),
                ),
              ),
            const SizedBox(
                height: 22, child: VerticalDivider(width: 12, thickness: 1)),
            // Le règne, en emojis : trois pastilles tiennent là où trois mots
            // auraient débordé de la barre.
            for (final r in [null, ...Regne.tous])
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  setState(() => _regne = r?.cle);
                  _rafraichit();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 8),
                  child: Opacity(
                    opacity: _regne == r?.cle ? 1 : .38,
                    child: r == null
                        ? Icon(Icons.all_inclusive,
                            size: 17,
                            color: _regne == null
                                ? Palette.accent
                                : Palette.texteDoux)
                        : Text(r.emoji, style: const TextStyle(fontSize: 15)),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _boutons() {
    return Column(children: [
      // Se retrouver sur la carte est le premier geste en balade : on veut
      // savoir ce qu'on a déjà photographié *ici*, pas au niveau du pays.
      FloatingActionButton.small(
        heroTag: 'moi',
        backgroundColor: Palette.fond,
        foregroundColor: _suitPosition ? Palette.accent : Palette.texte,
        tooltip: T('Aller à ma position'),
        onPressed: _vaVersMoi,
        child: _chercheMoi
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.my_location),
      ),
      const SizedBox(height: 8),
      FloatingActionButton.small(
        heroTag: 'nord',
        backgroundColor: Palette.fond,
        foregroundColor: Palette.texte,
        tooltip: T('Remettre le nord en haut'),
        onPressed: () => _carte.rotate(0),
        child: const Icon(Icons.explore_outlined),
      ),
      const SizedBox(height: 8),
      FloatingActionButton.small(
        heroTag: 'cadre',
        backgroundColor: Palette.fond,
        foregroundColor: Palette.texte,
        tooltip: T('Tout voir'),
        onPressed: _cadre,
        child: const Icon(Icons.fit_screen_outlined),
      ),
    ]);
  }

  /// Centre la carte sur le téléphone.
  ///
  /// Le point reste affiché ensuite : savoir où l'on est ne sert à rien si la
  /// marque disparaît au premier glissement.
  Future<void> _vaVersMoi() async {
    setState(() => _chercheMoi = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(T('Localisation refusée.'))));
        }
        return;
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 8)),
      );
      if (!mounted) return;
      setState(() {
        _maPosition = LatLng(p.latitude, p.longitude);
        _suitPosition = true;
      });
      // Zoom de quartier : assez près pour reconnaître le chemin, assez large
      // pour voir ce qu'on a trouvé alentour.
      _carte.move(_maPosition!, _zoom < 14 ? 15 : _zoom);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(T('Position introuvable. Réessayez à ciel ouvert.'))));
      }
    } finally {
      if (mounted) setState(() => _chercheMoi = false);
    }
  }

  /// La marque de position, sous les photos : un point bleu et son halo, comme
  /// partout ailleurs — c'est une convention qu'on ne gagne rien à réinventer.
  Widget _pointDeMoi() {
    final p = _maPosition;
    if (p == null) return const SizedBox.shrink();
    return MarkerLayer(markers: [
      Marker(
        point: p,
        width: 26,
        height: 26,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF2C7BE5),
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                  color: const Color(0xFF2C7BE5).withValues(alpha: .35),
                  blurRadius: 10,
                  spreadRadius: 3),
            ],
          ),
        ),
      ),
    ]);
  }

  /// Ce que la carte montre en ce moment, en une pastille.
  ///
  /// Un filtre qui ne rend rien ressemble à une panne ; un compte affiché dit
  /// que la carte a bien répondu, et que c'est la réponse qui est vide.
  Widget _compteur() {
    final especes = {for (final p in _points) p.caseId}.length;
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(20),
      color: Palette.fond,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        child: Text(
          T('{0} photo{1} · {2} espèce{3}', [_points.length, _points.length > 1 ? 's' : '', especes, especes > 1 ? 's' : '']),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _bandeauErreur() => Positioned(
        left: 16,
        right: 16,
        bottom: 90,
        child: Material(
          borderRadius: BorderRadius.circular(12),
          color: Palette.alerte,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_erreur!,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ),
      );

  Widget _vide() => Center(
        child: Container(
          margin: const EdgeInsets.all(32),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Palette.fond.withValues(alpha: .92),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.public_off, size: 40, color: Palette.silhouette),
            const SizedBox(height: 12),
            Text(T('Aucune photo située'),
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              _orphelines.isEmpty
                  ? 'Les photos prises avec la position activée\napparaîtront ici.'
                  : '${_orphelines.length} photo(s) attendent d\'être situées.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Palette.texteDoux, fontSize: 13, height: 1.4),
            ),
            if (_orphelines.isNotEmpty) ...[
              const SizedBox(height: 12),
              FilledButton(
                  onPressed: _ouvreOrphelines, child: Text(T('Les situer'))),
            ],
          ]),
        ),
      );

  Future<void> _ouvreOrphelines() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EcranAsituer(captures: _orphelines),
    ));
    _rafraichit();
  }

  /// La fiche d'un ou plusieurs points au même endroit.
  void _fiche(List<PointCarte> points) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
        children: [
          if (points.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 4),
              child: Text(T('{0} photos ici', [points.length]),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          for (final p in points) _ligneFiche(p),
        ],
      ),
    );
  }

  Widget _ligneFiche(PointCarte p) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 56,
          height: 56,
          child: ImageServeur(chemin: p.vignette, taille: 160),
        ),
      ),
      title: Row(children: [
        Expanded(
          child: Text(p.nom,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        PastilleRarete(rarete: p.rarete, dense: true),
      ]),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${p.moi ? 'Moi' : p.pseudo} · ${p.quand.split(' ').first}${p.heureSure ? ' à ${p.quand.split(' ').last.substring(0, 5)}' : ''}',
            style: const TextStyle(fontSize: 12),
          ),
          if (p.lieu.isNotEmpty)
            Text(p.lieu,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: Palette.texteDoux)),
          if (!p.heureSure)
            Text(T('heure approximative'),
                style: TextStyle(fontSize: 10, color: Palette.texteDoux)),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.pop(context);
        if (p.caseId != null) {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => EcranDetailCase(caseId: p.caseId!)));
        } else {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => Visionneuse(
              captures: [],
              titre: p.nom,
            ),
          ));
        }
      },
    );
  }
}

/// Le marqueur d'une photo : l'animal détouré dans une pastille ronde, posée
/// directement sur le lieu — sans tige, pour que les marqueurs voisins ne se
/// chevauchent pas.
class _Pastille extends StatelessWidget {
  const _Pastille({required this.point, required this.taille});
  final PointCarte point;
  final double taille;

  @override
  Widget build(BuildContext context) {
    final couleur = Palette.qualite(point.rarete);

    final rond = Container(
      width: taille,
      height: taille,
      decoration: BoxDecoration(
        color: Palette.fond,
        shape: BoxShape.circle,
        // La bordure porte la qualité de la bête ; les siennes en trait franc,
        // celles des amis plus fines.
        border: Border.all(
            color: couleur, width: taille < 30 ? 1.5 : (point.moi ? 3 : 2)),
        boxShadow: [
          BoxShadow(
              color: point.rarete >= 4
                  ? couleur.withValues(alpha: .5)
                  : Colors.black26,
              blurRadius: point.rarete >= 4 ? 7 : 3,
              offset: const Offset(0, 1)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(taille < 30 ? 1.5 : 3),
        // Taille réduite demandée au serveur : un marqueur de cinquante pixels
        // n'a que faire d'une découpe pleine résolution, et c'est ce qui rendait
        // la carte poussive.
        child: point.decoupe != null && !Reglages.instance.casesEntieres
            ? ImageServeur(
                chemin: point.decoupe!,
                fit: BoxFit.contain,
                taille: taille < 40 ? 96 : 160)
            : ImageServeur(
                chemin: point.vignette, taille: taille < 40 ? 96 : 160),
      ),
    );

    // En dessous d'une certaine taille, le médaillon d'auteur ne serait qu'une
    // tache : on s'en passe et la pastille reste un simple point.
    if (taille < 40) return rond;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        rond,
        Transform.translate(
          offset: const Offset(0, -7),
          child: Avatar(
            pseudo: point.pseudo,
            chemin: point.avatar,
            taille: 18,
            bordure: Palette.fond,
          ),
        ),
      ],
    );
  }
}

/// Une bulle qui regroupe plusieurs photos voisines.
class _Bulle extends StatelessWidget {
  const _Bulle({required this.nombre});
  final int nombre;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Palette.accent,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 5, offset: Offset(0, 2)),
        ],
      ),
      child: Center(
        child: Text('$nombre',
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 15)),
      ),
    );
  }
}
