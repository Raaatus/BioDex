import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import '../widgets/regnes.dart';
import '../widgets/case_dex.dart';
import '../widgets/reactions.dart';
import 'situer.dart';
import '../widgets/identifier_amis.dart';
import 'visionneuse_galerie.dart';
import '../reglages.dart';

/// Les critères de tri de la galerie, tels que le serveur les comprend.
enum TriGalerie {
  recent('recent', 'Plus récentes'),
  ancien('ancien', 'Plus anciennes'),
  espece('espece', 'Par espèce'),
  qualite('qualite', 'Par qualité'),
  auteur('auteur', 'Par joueur'),
  lieu('lieu', 'Par lieu');

  const TriGalerie(this.cle, this.etiquette);
  final String cle;
  final String etiquette;
}

/// L'état des filtres. Tout est facultatif et tout se combine : un ami sur une
/// période, une zone de la carte pour une espèce donnée.
class FiltresGalerie {
  String qui = 'tous';
  DateTime? depuis;
  DateTime? jusqua;
  int? espece;

  /// animal, plante ou champignon — null pour les trois.
  String? regne;
  int? qualite;
  String? lieu;
  bool favoris = false;
  bool? situees;
  bool? datees;
  TriGalerie tri = TriGalerie.recent;

  bool get actifs =>
      qui != 'tous' ||
      depuis != null ||
      jusqua != null ||
      espece != null ||
      regne != null ||
      qualite != null ||
      lieu != null ||
      situees != null ||
      datees != null;

  int get nombre => [
        qui != 'tous',
        depuis != null || jusqua != null,
        espece != null,
        regne != null,
        qualite != null,
        lieu != null,
        situees != null,
        datees != null,
      ].where((x) => x).length;

  Map<String, dynamic> versParametres() => {
        'qui': qui,
        if (depuis != null) 'depuis': _jour(depuis!),
        if (jusqua != null) 'jusqua': _jour(jusqua!),
        if (espece != null) 'espece': espece,
        if (regne != null) 'regne': regne,
        if (qualite != null) 'qualite': qualite,
        if (lieu != null) 'lieu': lieu,
        if (situees != null) 'situees': situees,
        if (datees != null) 'datees': datees,
        if (favoris) 'favoris': true,
        'tri': tri.cle,
      };

  static String _jour(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  FiltresGalerie copie() => FiltresGalerie()
    ..qui = qui
    ..depuis = depuis
    ..jusqua = jusqua
    ..espece = espece
    ..qualite = qualite
    ..lieu = lieu
    ..favoris = favoris
    ..situees = situees
    ..datees = datees
    ..tri = tri;
}

/// La galerie : toutes les photos qu'on a le droit de voir.
///
/// Rien n'est chargé d'avance — les pages arrivent au fil du défilement, parce
/// qu'à cinq mille photos on ne rapatrie pas tout d'un coup.
class EcranGalerie extends StatefulWidget {
  const EcranGalerie({super.key});

  @override
  State<EcranGalerie> createState() => _EcranGalerieState();
}

class _EcranGalerieState extends State<EcranGalerie> {
  static const _parPage = 60;

  final _defilement = ScrollController();
  final _photos = <PhotoGalerie>[];
  final _filtres = FiltresGalerie();

  ReperesGalerie? _reperes;
  bool _charge = false;
  bool _fin = false;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _defilement.addListener(() {
      if (_defilement.position.pixels >
          _defilement.position.maxScrollExtent - 700) {
        _chargeSuite();
      }
    });
    _recommence();
    _chargeReperes();
  }

  @override
  void dispose() {
    _defilement.dispose();
    super.dispose();
  }

  Future<void> _chargeReperes() async {
    try {
      final d = await Api.instance.get('/galerie/reperes');
      if (mounted) setState(() => _reperes = ReperesGalerie.depuisJson(d));
    } catch (_) {
      // Les menus de filtres se passent de leurs suggestions au besoin.
    }
  }

  void _recommence() {
    setState(() {
      _photos.clear();
      _fin = false;
      _erreur = null;
    });
    _chargeSuite();
  }

  Future<void> _chargeSuite() async {
    if (_charge || _fin) return;
    setState(() => _charge = true);
    try {
      final d = await Api.instance.get('/galerie', {
        ..._filtres.versParametres(),
        'limite': _parPage,
        'decalage': _photos.length,
      });
      final page =
          (d['photos'] as List).map((p) => PhotoGalerie.depuisJson(p)).toList();
      if (!mounted) return;
      setState(() {
        _photos.addAll(page);
        _fin = d['fin'] == true;
      });
      _reprend();
    } on ErreurApi catch (e) {
      if (mounted) setState(() => _erreur = e.message);
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  /// Rouvrir la photo quittée la fois d'avant, une seule fois par lancement.
  ///
  /// Trois conditions, et chacune a coûté une réflexion : il faut qu'un
  /// repère existe, que la photo soit encore dans la liste — elle a pu être
  /// supprimée, ou sortir par un filtre — et qu'on ne l'ait pas déjà fait,
  /// sinon fermer la visionneuse la rouvrirait aussitôt en boucle.
  bool _repriseFaite = false;

  void _reprend() {
    if (_repriseFaite) return;
    _repriseFaite = true;
    final vise = Reglages.instance.dernierePhoto;
    if (vise == null) return;
    final i = _photos.indexWhere((p) => p.captureId == vise);
    if (i < 0) return;
    // Après la trame courante : on est encore dans un `setState` de
    // chargement, et pousser une route depuis là déclenche une assertion.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ouvre(i);
    });
  }

  Future<void> _ouvreFiltres() async {
    final retour = await showModalBottomSheet<FiltresGalerie>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PanneauFiltres(
          filtres: _filtres.copie(), reperes: _reperes),
    );
    if (retour == null) return;
    setState(() {
      _filtres
        ..qui = retour.qui
        ..depuis = retour.depuis
        ..jusqua = retour.jusqua
        ..espece = retour.espece
        ..qualite = retour.qualite
        ..lieu = retour.lieu
        ..situees = retour.situees
        ..tri = retour.tri;
    });
    _recommence();
  }

  /// Les photos cochées. Vide = pas de sélection, la galerie se comporte
  /// comme avant.
  final Set<int> _choisies = {};

  /// Pose la même date et le même lieu sur tout le lot.
  Future<void> _situeChoisies() async {
    final lot = _photos.where((p) => _choisies.contains(p.captureId)).toList();
    if (lot.isEmpty) return;
    final tete = lot.first;
    final fait = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => EcranSituerUne(
        capture: CaptureOrpheline.depuisJson({
          'capture_id': tete.captureId,
          'nom': tete.nom,
          'cree_le': tete.quand,
          'prise_le': tete.heureSure ? tete.quand : null,
          'lat': tete.lat,
          'lon': tete.lon,
          'vignette': tete.vignette,
        }),
        aussi: [for (final p in lot.skip(1)) p.captureId],
      ),
    ));
    if (fait != true || !mounted) return;
    setState(_choisies.clear);
    _recommence();
  }

  /// Signe tout le lot des mêmes amis.
  Future<void> _identifieChoisies() async {
    final lot = _photos.where((p) => _choisies.contains(p.captureId)).toList();
    if (lot.isEmpty) return;
    final fait = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => IdentifierAmis(
        captureId: lot.first.captureId,
        dejaLa: const [],
        aussi: [for (final p in lot.skip(1)) p.captureId],
      ),
    ));
    if (fait != true || !mounted) return;
    setState(_choisies.clear);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(T('{0} photo{1} partagée{2}.', [lot.length, lot.length > 1 ? 's' : '', lot.length > 1 ? 's' : '']))));
    }
  }

  Future<void> _ouvre(int index) async {
    // On note la photo ouverte pour pouvoir y revenir au prochain lancement.
    // Le repère est l'identifiant de la capture et non son rang dans la liste :
    // l'ordre change avec les filtres, et rouvrir « la douzième » enverrait
    // ailleurs.
    Reglages.instance.retiensPhoto(_photos[index].captureId);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VisionneuseGalerie(
        photos: _photos,
        depart: index,
        surChangement: () => setState(() {}),
        surSuppression: (id) {
          setState(() => _photos.removeWhere((p) => p.captureId == id));
        },
      ),
    ));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _entete(),
            _onglets(),
            Expanded(child: _grille()),
          ],
        ),
      ),
    );
  }

  Widget _entete() {
    if (_choisies.isNotEmpty) return _enteteSelection();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(T('Galerie'),
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              Text(
                _filtres.favoris
                    ? '${_photos.length} favorite${_photos.length > 1 ? 's' : ''}'
                    : '${_photos.length}${_fin ? '' : '+'} photo${_photos.length > 1 ? 's' : ''}',
                style: TextStyle(color: Palette.texteDoux, fontSize: 13),
              ),
            ],
          ),
        ),
        PopupMenuButton<TriGalerie>(
          tooltip: T('Trier'),
          icon: const Icon(Icons.swap_vert),
          initialValue: _filtres.tri,
          onSelected: (t) {
            setState(() => _filtres.tri = t);
            _recommence();
          },
          itemBuilder: (_) => [
            for (final t in TriGalerie.values)
              PopupMenuItem(value: t, child: Text(t.etiquette)),
          ],
        ),
        IconButton(
          tooltip: T('Filtrer'),
          onPressed: _ouvreFiltres,
          icon: Badge.count(
            count: _filtres.nombre,
            isLabelVisible: _filtres.nombre > 0,
            child: Icon(Icons.tune,
                color: _filtres.actifs ? Palette.accent : Palette.texte),
          ),
        ),
      ]),
    );
  }

  /// L'en-tête de sélection : on y agit sur ce qui est coché, et les filtres
  /// disparaissent — changer de filtre viderait la liste en gardant des photos
  /// cochées devenues invisibles.
  Widget _enteteSelection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
      child: Row(children: [
        IconButton(
          tooltip: T('Annuler la sélection'),
          icon: const Icon(Icons.close),
          onPressed: () => setState(_choisies.clear),
        ),
        Expanded(
          child: Text(T('{0} sélectionnée{1}', [_choisies.length, _choisies.length > 1 ? 's' : '']),
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700)),
        ),
        IconButton(
          tooltip: T('Date et lieu'),
          icon: const Icon(Icons.edit_calendar_outlined),
          onPressed: _situeChoisies,
        ),
        IconButton(
          tooltip: T('Identifier des amis'),
          icon: const Icon(Icons.group_add_outlined),
          onPressed: _identifieChoisies,
        ),
      ]),
    );
  }

  Widget _onglets() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(children: [
        ChoiceChip(
          label: Text(T('Toutes')),
          selected: !_filtres.favoris,
          onSelected: (_) {
            setState(() => _filtres.favoris = false);
            _recommence();
          },
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          avatar: Icon(Icons.star,
              size: 16,
              color: _filtres.favoris ? Palette.accent : Palette.texteDoux),
          label: Text(_reperes == null || _reperes!.favoris == 0
              ? 'Favorites'
              : 'Favorites (${_reperes!.favoris})'),
          selected: _filtres.favoris,
          onSelected: (_) {
            setState(() => _filtres.favoris = true);
            _recommence();
          },
        ),
        const Spacer(),
        // Le règne en emojis : trois pastilles au lieu de trois mots, la barre
        // est déjà chargée.
        for (final r in [null, ...Regne.tous])
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              setState(() => _filtres.regne = r?.cle);
              _recommence();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Opacity(
                opacity: _filtres.regne == r?.cle ? 1 : .35,
                child: r == null
                    ? Icon(Icons.all_inclusive,
                        size: 17,
                        color: _filtres.regne == null
                            ? Palette.accent
                            : Palette.texteDoux)
                    : Text(r.emoji, style: const TextStyle(fontSize: 16)),
              ),
            ),
          ),
        const Spacer(),
        if (_filtres.actifs)
          TextButton(
            onPressed: () {
              setState(() {
                final favoris = _filtres.favoris;
                _filtres
                  ..qui = 'tous'
                  ..depuis = null
                  ..jusqua = null
                  ..espece = null
                  ..qualite = null
                  ..lieu = null
                  ..situees = null
                  ..datees = null
                  ..favoris = favoris;
              });
              _recommence();
            },
            child: Text(T('Effacer')),
          ),
      ]),
    );
  }

  Widget _grille() {
    if (_erreur != null && _photos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off, size: 44, color: Palette.silhouette),
            const SizedBox(height: 12),
            Text(_erreur!, textAlign: TextAlign.center),
            TextButton(onPressed: _recommence, child: Text(T('Réessayer'))),
          ]),
        ),
      );
    }
    if (_photos.isEmpty && !_charge) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(_filtres.favoris ? Icons.star_border : Icons.photo_library_outlined,
                size: 46, color: Palette.silhouette),
            const SizedBox(height: 14),
            Text(
              _filtres.favoris
                  ? 'Aucune photo en favori.'
                  : _filtres.actifs
                      ? 'Aucune photo ne correspond à ces filtres.'
                      : 'Aucune photo pour l\'instant.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Palette.texteDoux, height: 1.4),
            ),
          ]),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        _chargeReperes();
        _recommence();
      },
      child: GridView.builder(
        controller: _defilement,
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
        ),
        itemCount: _photos.length + (_charge ? 3 : 0),
        itemBuilder: (context, i) {
          if (i >= _photos.length) {
            return DecoratedBox(
              decoration: BoxDecoration(
                color: Palette.caseVide,
                borderRadius: BorderRadius.circular(12),
              ),
            );
          }
          final photo = _photos[i];
          return _Vignette(
            photo: photo,
            choisie: _choisies.contains(photo.captureId),
            enSelection: _choisies.isNotEmpty,
            // On ne coche que ses propres photos : le lieu, la date et les
            // amis d'une photo appartiennent à celui qui l'a prise.
            onLongPress: photo.moi
                ? () => setState(() => _choisies.add(photo.captureId))
                : null,
            onTap: _choisies.isEmpty
                ? () => _ouvre(i)
                : (photo.moi
                    ? () => setState(() {
                          if (_choisies.contains(photo.captureId)) {
                            _choisies.remove(photo.captureId);
                          } else {
                            _choisies.add(photo.captureId);
                          }
                        })
                    : () => _ouvre(i)),
          );
        },
      ),
    );
  }
}

/// Une photo dans la grille : l'image, et ce qu'il faut savoir d'un coup d'œil.
class _Vignette extends StatelessWidget {
  const _Vignette({
    required this.photo,
    required this.onTap,
    this.onLongPress,
    this.choisie = false,
    this.enSelection = false,
  });
  final PhotoGalerie photo;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Cochée pour une action de lot.
  final bool choisie;

  /// Vrai dès qu'au moins une photo est cochée : les autres se voilent
  /// légèrement, sinon on ne distingue plus ce qui est pris de ce qui reste.
  final bool enSelection;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(fit: StackFit.expand, children: [
          ImageServeur(chemin: photo.vignette, taille: 256),
          // Un voile sombre en bas : sans lui, le texte blanc disparaît sur les
          // photos claires.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(6, 12, 6, 5),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black54],
                ),
              ),
              child: Row(children: [
                if (!photo.moi) ...[
                  Avatar(
                      pseudo: photo.pseudo, chemin: photo.avatar, taille: 14),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  // Le titre prime sur l'espèce : c'est lui que le joueur a
                  // choisi.
                  child: Text(photo.titre.isEmpty ? photo.nom : photo.titre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ),
          // Le repère « à situer », en haut à gauche.
          //
          // Il n'apparaît que sur ses propres photos : on ne peut corriger que
          // les siennes, et signaler un manque qu'on ne peut pas combler ne
          // sert qu'à encombrer la grille.
          //
          // Deux pictogrammes plutôt qu'un seul générique : savoir s'il manque
          // le lieu, la date ou les deux évite d'ouvrir la photo pour le
          // découvrir.
          if (photo.moi && photo.aSituer)
            Positioned(
              top: 5,
              left: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (photo.sansPosition)
                    const Icon(Icons.location_off_outlined,
                        size: 12, color: Color(0xFFFFC24D)),
                  if (photo.sansPosition && photo.sansHeure)
                    const SizedBox(width: 3),
                  if (photo.sansHeure)
                    const Icon(Icons.event_busy_outlined,
                        size: 12, color: Color(0xFFFFC24D)),
                ]),
              ),
            ),
          if (enSelection && !choisie)
            const ColoredBox(color: Color(0x55FFFFFF)),
          if (choisie)
            Container(
              decoration: BoxDecoration(
                color: Palette.accent.withValues(alpha: .28),
                border: Border.all(color: Palette.accent, width: 3),
              ),
              alignment: Alignment.topLeft,
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.check_circle,
                  size: 20, color: Palette.surAccent),
            ),
          if (photo.favori && !enSelection)
            const Positioned(
              right: 4,
              top: 4,
              child: Icon(Icons.star, size: 15, color: Color(0xFFE8A317)),
            ),
          if (photo.qualite >= 4)
            Positioned(
              left: 4,
              top: 4,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: Palette.qualite(photo.qualite),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white70, width: 1),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Le panneau de filtres, ouvert depuis l'en-tête.
class _PanneauFiltres extends StatefulWidget {
  const _PanneauFiltres({required this.filtres, required this.reperes});
  final FiltresGalerie filtres;
  final ReperesGalerie? reperes;

  @override
  State<_PanneauFiltres> createState() => _PanneauFiltresState();
}

class _PanneauFiltresState extends State<_PanneauFiltres> {
  late final FiltresGalerie _f = widget.filtres;

  Future<void> _periode() async {
    final plage = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: _f.depuis != null && _f.jusqua != null
          ? DateTimeRange(start: _f.depuis!, end: _f.jusqua!)
          : null,
    );
    if (plage == null) return;
    setState(() {
      _f.depuis = plage.start;
      _f.jusqua = plage.end;
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.reperes;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .75,
      maxChildSize: .92,
      builder: (context, defilement) => ListView(
        controller: defilement,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        children: [
          Text(T('Filtrer'),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 18),

          _titre(T('Qui')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _puce('Tout le monde', _f.qui == 'tous', () => _f.qui = 'tous'),
            _puce('Moi', _f.qui == 'moi', () => _f.qui = 'moi'),
            _puce('Mes amis', _f.qui == 'amis', () => _f.qui = 'amis'),
            // Plusieurs personnes à la fois, et non l'une ou l'autre : ce
            // qu'on veut revoir, c'est la sortie de dimanche — celle qu'on a
            // faite à quatre. Choisir un ami puis recommencer pour le suivant
            // obligeait à refaire le tour de la galerie pour chacun.
            if (r != null)
              for (final a in r.auteurs.where((a) => !a.moi))
                _puce('${a.pseudo} (${a.photos})', _amiCoche(a.id),
                    () => _basculeAmi(a.id)),
          ]),
          const SizedBox(height: 20),

          _titre(T('Quand')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ActionChip(
              avatar: const Icon(Icons.date_range, size: 16),
              label: Text(_f.depuis == null
                  ? 'Choisir une période'
                  : '${FiltresGalerie._jour(_f.depuis!)} → ${FiltresGalerie._jour(_f.jusqua!)}'),
              onPressed: _periode,
            ),
            if (_f.depuis != null)
              InputChip(
                label: Text(T('Effacer')),
                onDeleted: () => setState(() {
                  _f.depuis = null;
                  _f.jusqua = null;
                }),
                onPressed: () => setState(() {
                  _f.depuis = null;
                  _f.jusqua = null;
                }),
              ),
          ]),
          const SizedBox(height: 20),

          _titre(T('Où')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _puce('Peu importe', _f.situees == null, () => _f.situees = null),
            _puce('Situées', _f.situees == true, () => _f.situees = true),
            _puce('Sans lieu', _f.situees == false, () => _f.situees = false),
          ]),
          const SizedBox(height: 14),

          // Deux manques distincts, deux filtres distincts.
          //
          // « Sans lieu » couvre aussi les photos posées par défaut : elles ont
          // des coordonnées, s'affichent donc sur la carte, mais à un endroit
          // que personne n'a choisi. Ce sont celles qu'on cherche le plus
          // souvent, et aucun écran ne savait les désigner jusqu'ici.
          _titre(T('À situer')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _puce('Peu importe', _f.datees == null, () => _f.datees = null),
            _puce('Datées', _f.datees == true, () => _f.datees = true),
            _puce('Sans date', _f.datees == false, () => _f.datees = false),
          ]),
          if (r != null && r.lieux.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final l in r.lieux.take(12))
                _puce(_court(l), _f.lieu == l,
                    () => _f.lieu = _f.lieu == l ? null : l),
            ]),
          ],
          const SizedBox(height: 20),

          _titre(T('Qualité')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _puce('Toutes', _f.qualite == null, () => _f.qualite = null),
            for (var q = 5; q >= 1; q--)
              _puce(Palette.nomQualite(q), _f.qualite == q,
                  () => _f.qualite = _f.qualite == q ? null : q,
                  couleur: Palette.qualite(q)),
          ]),
          const SizedBox(height: 20),

          if (r != null && r.especes.isNotEmpty) ...[
            _titre(T('Espèce')),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _puce('Toutes', _f.espece == null, () => _f.espece = null),
              for (final e in r.especes.take(20))
                _puce('${e.nom} (${e.photos})', _f.espece == e.caseId,
                    () => _f.espece = _f.espece == e.caseId ? null : e.caseId),
            ]),
            const SizedBox(height: 20),
          ],

          _titre(T('Trier par')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final t in TriGalerie.values)
              _puce(t.etiquette, _f.tri == t, () => _f.tri = t),
          ]),
          const SizedBox(height: 26),

          FilledButton(
            onPressed: () => Navigator.pop(context, _f),
            child: Text(T('Appliquer')),
          ),
        ],
      ),
    );
  }

  static String _court(String lieu) {
    // Nominatim rend des adresses à rallonge : on garde les deux premiers
    // éléments, qui suffisent à reconnaître l'endroit.
    final morceaux = lieu.split(',').map((m) => m.trim()).toList();
    return morceaux.take(2).join(', ');
  }

  /// Les auteurs cochés, lus depuis `qui`. Une seule source de vérité : un
  /// second champ qui dirait la même chose finirait par la dire autrement.
  List<int> _amisChoisis() => [
        for (final x in _f.qui.split(','))
          if (int.tryParse(x) != null) int.parse(x),
      ];

  bool _amiCoche(int id) => _amisChoisis().contains(id);

  void _basculeAmi(int id) {
    final l = _amisChoisis();
    l.contains(id) ? l.remove(id) : l.add(id);
    // Plus personne de coché : on revient à « tout », l'état neutre. Une liste
    // vide ne voudrait rien dire pour le serveur.
    _f.qui = l.isEmpty ? 'tous' : l.join(',');
  }

  Widget _titre(String texte) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(texte,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      );

  Widget _puce(String etiquette, bool actif, VoidCallback action,
          {Color? couleur}) =>
      ChoiceChip(
        label: Text(etiquette, style: const TextStyle(fontSize: 12)),
        selected: actif,
        selectedColor: (couleur ?? Palette.accent).withValues(alpha: .18),
        onSelected: (_) => setState(action),
      );
}
