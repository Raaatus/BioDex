import 'dart:async';
import '../i18n.dart';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../modeles.dart';
import '../theme.dart';

/// Les photos qui n'ont ni position ni heure fiable, et de quoi les compléter.
///
/// Beaucoup de photos arrivent sans coordonnées : appareil sans GPS, position
/// coupée, ou métadonnées effacées en passant par une messagerie. Plutôt que de
/// les laisser hors du monde, on laisse le joueur poser le point lui-même.
class EcranAsituer extends StatefulWidget {
  const EcranAsituer({super.key, required this.captures});
  final List<CaptureOrpheline> captures;

  @override
  State<EcranAsituer> createState() => _EcranAsituerState();
}

class _EcranAsituerState extends State<EcranAsituer> {
  // Copie modifiable : les photos disparaissent de la liste au fur et à mesure
  // qu'on les situe.
  late final List<CaptureOrpheline> _restantes = List.of(widget.captures);

  /// Les photos cochées. Vide = pas de sélection, l'écran se comporte comme
  /// avant : on tape une photo, on la situe.
  final Set<int> _choisies = {};

  Future<void> _situe(CaptureOrpheline c) async {
    final fait = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => EcranSituerUne(capture: c),
    ));
    if (fait == true && mounted) {
      setState(() => _restantes.removeWhere((x) => x.captureId == c.captureId));
    }
  }

  /// Poser le même lieu et la même date sur tout le lot.
  ///
  /// C'est la même route que la galerie emprunte déjà : `EcranSituerUne` sait
  /// traiter un lot par son paramètre `aussi`. Cet écran-ci ne savait pas s'en
  /// servir, et il fallait passer par la galerie pour situer dix photos d'une
  /// même sortie — alors que c'est précisément ici qu'on arrive en voyant
  /// qu'il y en a dix à situer.
  Future<void> _situeChoisies() async {
    final lot = _restantes.where((c) => _choisies.contains(c.captureId)).toList();
    if (lot.isEmpty) return;
    final fait = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => EcranSituerUne(
        capture: lot.first,
        aussi: [for (final c in lot.skip(1)) c.captureId],
      ),
    ));
    if (fait == true && mounted) {
      setState(() {
        _restantes.removeWhere((x) => _choisies.contains(x.captureId));
        _choisies.clear();
      });
    }
  }

  void _bascule(int id) => setState(() {
        if (!_choisies.remove(id)) _choisies.add(id);
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_choisies.isEmpty
            ? 'Photos à situer'
            : '${_choisies.length} sélectionnée${_choisies.length > 1 ? 's' : ''}'),
        leading: _choisies.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close),
                tooltip: T('Annuler la sélection'),
                onPressed: () => setState(_choisies.clear),
              ),
        actions: [
          if (_restantes.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                if (_choisies.length == _restantes.length) {
                  _choisies.clear();
                } else {
                  _choisies
                    ..clear()
                    ..addAll(_restantes.map((c) => c.captureId));
                }
              }),
              child: Text(_choisies.length == _restantes.length
                  ? 'Aucune'
                  : 'Tout'),
            ),
        ],
      ),
      // Le bouton n'apparaît qu'une fois quelque chose de coché : une barre
      // d'action permanente sur un écran où l'on tape surtout les photos une
      // par une ne ferait que masquer la dernière de la liste.
      floatingActionButton: _choisies.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _situeChoisies,
              icon: const Icon(Icons.edit_location_alt_outlined),
              label: Text(T('Situer {0}', [_choisies.length])),
            ),
      body: _restantes.isEmpty
          ? Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle_outline,
                      size: 46, color: Palette.accent),
                  SizedBox(height: 14),
                  Text(T('Tout est situé.'),
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ]),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _restantes.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final c = _restantes[i];
                final choisie = _choisies.contains(c.captureId);
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _choisies.isEmpty
                      ? () => _situe(c)
                      : () => _bascule(c.captureId),
                  onLongPress: () => _bascule(c.captureId),
                  child: Row(children: [
                    if (_choisies.isNotEmpty) ...[
                      Icon(
                        choisie
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: choisie ? Palette.accent : Palette.texteDoux,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                    ],
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        Api.instance.image(c.vignette).toString(),
                        headers: Api.instance.entetes,
                        width: 62,
                        height: 62,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                            width: 62, height: 62, color: Palette.caseVide),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c.nom,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 3),
                          Wrap(spacing: 6, runSpacing: 4, children: [
                            if (c.sansPosition) _manque('Sans lieu'),
                            if (c.sansHeure) _manque('Sans heure'),
                          ]),
                          const SizedBox(height: 3),
                          Text(T('envoyée le {0}', [c.creeLe.split(' ').first]),
                              style: TextStyle(
                                  fontSize: 11, color: Palette.texteDoux)),
                        ],
                      ),
                    ),
                    if (_choisies.isEmpty)
                      Icon(Icons.chevron_right, color: Palette.texteDoux),
                  ]),
                );
              },
            ),
    );
  }

  Widget _manque(String texte) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFB08A00).withValues(alpha: .12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(texte,
            style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF8A6A00),
                fontWeight: FontWeight.w600)),
      );
}

/// Poser une photo sur la carte, et corriger sa date.
class EcranSituerUne extends StatefulWidget {
  const EcranSituerUne({super.key, required this.capture, this.aussi = const []});

  /// La photo qui donne le point et la date de départ.
  final CaptureOrpheline capture;

  /// Les autres photos à situer du même coup.
  ///
  /// Une sortie donne dix photos au même endroit, à quelques minutes près :
  /// les situer une par une, c'est dix fois la même carte et la même heure à
  /// repointer. On pose le lieu une fois, il s'applique à tout le lot.
  final List<int> aussi;

  @override
  State<EcranSituerUne> createState() => _EcranSituerUneState();
}

class _EcranSituerUneState extends State<EcranSituerUne> {
  final _carte = MapController();
  final _adresse = TextEditingController();
  Timer? _attente;

  late LatLng _point =
      LatLng(widget.capture.lat ?? 46.6, widget.capture.lon ?? 2.4);
  late DateTime _quand = DateTime.tryParse(
          (widget.capture.priseLe ?? widget.capture.creeLe).replaceFirst(' ', 'T')) ??
      DateTime.now();

  List<LieuTrouve> _propositions = [];
  String _nomLieu = '';
  bool _cherche = false;
  bool _envoi = false;
  bool _positionPosee = false;

  @override
  void initState() {
    super.initState();
    _positionPosee = widget.capture.lat != null;
  }

  @override
  void dispose() {
    _attente?.cancel();
    _adresse.dispose();
    _carte.dispose();
    super.dispose();
  }

  void _differe(String texte) {
    _attente?.cancel();
    if (texte.trim().length < 3) {
      setState(() => _propositions = []);
      return;
    }
    _attente = Timer(const Duration(milliseconds: 500), () => _chercheAdresse(texte));
  }

  Future<void> _chercheAdresse(String texte) async {
    setState(() => _cherche = true);
    try {
      final d = await Api.instance.get('/geocodage', {'q': texte.trim()});
      if (!mounted) return;
      setState(() => _propositions =
          (d['lieux'] as List).map((l) => LieuTrouve.depuisJson(l)).toList());
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _cherche = false);
    }
  }

  void _choisit(LieuTrouve l) {
    setState(() {
      _point = LatLng(l.lat, l.lon);
      _nomLieu = l.nom;
      _positionPosee = true;
      _propositions = [];
      _adresse.text = l.nom;
    });
    _carte.move(_point, 14);
    FocusScope.of(context).unfocus();
  }

  /// Le nom du lieu se retrouve après coup, pour afficher « Bois de Vincennes »
  /// plutôt qu'un couple de coordonnées.
  Future<void> _nomme(LatLng p) async {
    try {
      final d = await Api.instance
          .get('/geocodage/inverse', {'lat': p.latitude, 'lon': p.longitude});
      if (mounted) setState(() => _nomLieu = d['nom'] ?? '');
    } catch (_) {
      // Un point sans nom reste utilisable.
    }
  }

  Future<void> _choisitDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _quand,
      firstDate: DateTime(1990),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    final heure = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_quand),
    );
    if (!mounted) return;
    setState(() => _quand = DateTime(date.year, date.month, date.day,
        heure?.hour ?? _quand.hour, heure?.minute ?? _quand.minute));
  }

  Future<void> _valide() async {
    setState(() => _envoi = true);
    try {
      String deux(int n) => n.toString().padLeft(2, '0');
      final corps = {
        if (_positionPosee) 'lat': _point.latitude,
        if (_positionPosee) 'lon': _point.longitude,
        if (_positionPosee && _nomLieu.isNotEmpty) 'lieu': _nomLieu,
        'prise_le': '${_quand.year}-${deux(_quand.month)}-${deux(_quand.day)} ${deux(_quand.hour)}:${deux(_quand.minute)}:00',
      };
      // Une requête par photo : le serveur n'a pas de route de lot, et lui en
      // ajouter une pour économiser quelques allers-retours sur une poignée
      // de photos serait payer cher une optimisation qu'on ne mesurerait pas.
      for (final id in [widget.capture.captureId, ...widget.aussi]) {
        await Api.instance.patch('/captures/$id/lieu', corps);
      }
      if (mounted) Navigator.pop(context, true);
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _envoi = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.aussi.isEmpty
            ? widget.capture.nom
            : T('{0} photos', [widget.aussi.length + 1])),
        // En lot, on rappelle que le point vaudra pour toutes : sans ça, on
        // croit régler la seule photo dont on voit le nom.
        bottom: widget.aussi.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(26),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    T('Le lieu et la date s\'appliqueront aux {0} photos.', [widget.aussi.length + 1]),
                    style: TextStyle(
                        fontSize: 12, color: Palette.texteDoux),
                  ),
                ),
              ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(children: [
              FlutterMap(
                mapController: _carte,
                options: MapOptions(
                  initialCenter: _point,
                  initialZoom: widget.capture.lat != null ? 13 : 5,
                  maxZoom: 19,
                  minZoom: 2,
                  onTap: (_, p) {
                    setState(() {
                      _point = p;
                      _positionPosee = true;
                    });
                    _nomme(p);
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                    userAgentPackageName: 'fr.biodex.app',
                    maxNativeZoom: 19,
                  ),
                  if (_positionPosee)
                    MarkerLayer(markers: [
                      Marker(
                        point: _point,
                        width: 46,
                        height: 46,
                        // Un réticule centré sur le point, plutôt qu'une
                        // épingle dont la pointe désigne un autre endroit que
                        // son centre.
                        child: Icon(Icons.my_location,
                            color: Palette.alerte, size: 38),
                      ),
                    ]),
                ],
              ),
              Positioned(left: 12, right: 12, top: 12, child: _recherche()),
              if (!_positionPosee)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 12,
                  child: Center(
                    child: Card(
                      color: Palette.fond,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        child: Text(T('Touchez la carte pour poser le point'),
                            style: TextStyle(fontSize: 13)),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          _pied(),
        ],
      ),
    );
  }

  Widget _recherche() {
    return Column(children: [
      Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(12),
        child: TextField(
          controller: _adresse,
          onChanged: _differe,
          decoration: InputDecoration(
            hintText: T('Chercher une adresse, une ville…'),
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _cherche
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : null,
            filled: true,
            fillColor: Palette.fond,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
      if (_propositions.isNotEmpty)
        Container(
          constraints: const BoxConstraints(maxHeight: 220),
          margin: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(
            color: Palette.fond,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _propositions.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => ListTile(
              dense: true,
              title: Text(_propositions[i].nom,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
              onTap: () => _choisit(_propositions[i]),
            ),
          ),
        ),
    ]);
  }

  Widget _pied() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: BoxDecoration(
        color: Palette.fond,
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_nomLieu.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Icon(Icons.place_outlined,
                  size: 16, color: Palette.texteDoux),
              const SizedBox(width: 6),
              Expanded(
                child: Text(_nomLieu,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: Palette.texteDoux)),
              ),
            ]),
          ),
        InkWell(
          onTap: _choisitDate,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              const Icon(Icons.schedule, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${_quand.day.toString().padLeft(2, '0')}/${_quand.month.toString().padLeft(2, '0')}/${_quand.year} à ${_quand.hour.toString().padLeft(2, '0')}:${_quand.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (widget.capture.sansHeure)
                Text(T('à confirmer'),
                    style: TextStyle(fontSize: 11, color: Palette.texteDoux)),
              const Icon(Icons.edit_outlined, size: 16),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: _envoi ? null : _valide,
          child: _envoi
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(T('Enregistrer')),
        ),
      ]),
    );
  }
}
