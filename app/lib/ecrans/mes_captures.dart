import 'dart:async';
import '../i18n.dart';

import 'package:flutter/material.dart';

import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import 'choix_espece.dart';
import 'detail_case.dart';
import 'situer.dart';
import '../widgets/identifier_amis.dart';
import 'visionneuse.dart';
import 'mes_especes.dart';

/// Toutes les photos envoyées, dans l'ordre inverse.
///
/// L'écran de capture ne montre que la dernière ; il manquait un endroit où
/// retrouver les précédentes — notamment celles que le moteur n'a pas su lire
/// et qu'on peut encore rattraper à la main.
class EcranMesCaptures extends StatefulWidget {
  const EcranMesCaptures({super.key});

  @override
  State<EcranMesCaptures> createState() => _EcranMesCapturesState();
}

class _EcranMesCapturesState extends State<EcranMesCaptures> {
  final List<Capture> _captures = [];
  final _defilement = ScrollController();

  String _filtre = 'tout';

  /// Combien de photos ne sont rattachées à aucune espèce, et sous combien de
  /// jours elles seront effacées.
  int _nonIdentifiees = 0;
  int _joursAvantPurge = 0;
  bool _charge = false;
  bool _fin = false;
  Timer? _sondage;

  /// Les photos cochées. Vide = pas de sélection en cours, et l'écran se
  /// comporte comme avant.
  final Set<int> _choisies = {};

  @override
  void initState() {
    super.initState();
    _defilement.addListener(() {
      if (_defilement.position.pixels >
          _defilement.position.maxScrollExtent - 400) {
        _chargeSuite();
      }
    });
    _recommence();
    _compteNonIdentifiees();
  }

  Future<void> _compteNonIdentifiees() async {
    try {
      final d = await Api.instance.get('/captures/non-identifiees');
      if (!mounted) return;
      setState(() {
        _nonIdentifiees = (d['captures'] as List).length;
        _joursAvantPurge = d['jours_avant_purge'] ?? 0;
      });
    } catch (_) {
      // Bandeau d'information : son absence ne gêne rien.
    }
  }

  /// Jette d'un coup les photos que rien n'identifie.
  Future<void> _videNonIdentifiees() async {
    final confirme = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(T('Supprimer {0} photo{1} ?', [_nonIdentifiees, _nonIdentifiees > 1 ? 's' : ''])),
        content: Text(
            T('Ces photos ne sont rattachées à aucune espèce : elles n\'apparaissent ni sur la carte ni dans la galerie. Vous pouvez encore leur choisir une espèce à la main.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(T('Garder'))),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(backgroundColor: Palette.alerte),
            child: Text(T('Supprimer')),
          ),
        ],
      ),
    );
    if (confirme != true) return;
    try {
      await Api.instance.supprime('/captures/non-identifiees');
      if (!mounted) return;
      _recommence();
      _compteNonIdentifiees();
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  void dispose() {
    _sondage?.cancel();
    _defilement.dispose();
    super.dispose();
  }

  void _recommence() {
    setState(() {
      _captures.clear();
      _fin = false;
    });
    _chargeSuite();
  }

  Future<void> _chargeSuite() async {
    if (_charge || _fin) return;
    setState(() => _charge = true);
    try {
      final d = await Api.instance.get('/captures', {
        'limite': 40,
        'depuis': _captures.length,
        if (_filtre != 'tout') 'etat': _filtre,
      });
      final page =
          (d['captures'] as List).map((c) => Capture.depuisJson(c)).toList();
      if (!mounted) return;
      setState(() {
        _captures.addAll(page);
        _fin = page.length < 40;
      });
      _surveille();
    } catch (_) {
      if (mounted) setState(() => _fin = true);
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  /// Tant qu'une capture est en cours d'analyse, on rafraîchit doucement :
  /// le résultat arrive au bout d'une quinzaine de secondes.
  void _surveille() {
    _sondage?.cancel();
    if (!_captures.any((c) => c.enCours)) return;
    _sondage = Timer(const Duration(seconds: 4), () async {
      final enCours = _captures.where((c) => c.enCours).map((c) => c.id).toList();
      for (final id in enCours) {
        try {
          final d = await Api.instance.get('/captures/$id');
          final maj = Capture.depuisJson(d);
          if (!maj.enCours && mounted) {
            final i = _captures.indexWhere((c) => c.id == id);
            if (i >= 0) setState(() => _captures[i] = maj);
          }
        } catch (_) {
          // On réessaiera au tour suivant.
        }
      }
      if (mounted) _surveille();
    });
  }

  Future<void> _corrige(Capture c) async {
    final choix = await Navigator.of(context).push<CaseDex>(MaterialPageRoute(
      builder: (_) => EcranChoixEspece(
          pisteInitiale: c.top.isNotEmpty ? c.top.first.nom : ''),
    ));
    if (choix == null) return;
    try {
      await Api.instance.post('/captures/${c.id}/espece', {'case_id': choix.id});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(T('Rangé dans « {0} ».', [choix.nom]))));
      _recommence();
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _choisies.isEmpty ? _barreNormale() : _barreSelection(),
      body: Column(children: [
        if (_nonIdentifiees > 0 && _choisies.isEmpty) _bandeauNonIdentifiees(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              _recommence();
              _compteNonIdentifiees();
            },
            child: _captures.isEmpty && !_charge
                ? ListView(children: [
                    SizedBox(height: 100),
                    Icon(Icons.photo_library_outlined,
                        size: 48, color: Palette.silhouette),
                    SizedBox(height: 14),
                    Center(
                      child: Text(T('Aucune photo ici.'),
                          style: TextStyle(color: Palette.texteDoux)),
                    ),
                  ])
                : ListView.separated(
                    controller: _defilement,
                    padding: const EdgeInsets.all(16),
                    itemCount: _captures.length + (_charge ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      if (i >= _captures.length) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: CircularProgressIndicator(),
                          ),
                        );
                      }
                      return _ligne(_captures[i]);
                    },
                  ),
          ),
        ),
      ]),
    );
  }

  PreferredSizeWidget _barreNormale() {
    return AppBar(
      title: Text(T('Mes photos')),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(46),
        child: SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _puce('Toutes', 'tout'),
              _puce('Reconnues', 'ok'),
              _puce('À trancher', 'doute'),
              _puce('Refusées', 'rejet'),
              // Pas un filtre mais une porte : ce que j'ai indexé moi-même
              // n'est pas un état de capture, et le ranger parmi les filtres
              // laisserait croire qu'il en est un.
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: ActionChip(
                  avatar: const Icon(Icons.local_florist_outlined, size: 16),
                  label: Text(T('Espèces indexées')),
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const EcranMesEspeces())),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// La barre de sélection.
  ///
  /// Elle remplace la barre ordinaire plutôt que de s'ajouter : en sélection
  /// on ne filtre pas, on agit sur ce qu'on a coché. Garder les deux aurait
  /// donné un écran où l'on peut changer de filtre — donc vider la liste —
  /// avec des photos cochées invisibles dedans.
  PreferredSizeWidget _barreSelection() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: T('Annuler la sélection'),
        onPressed: () => setState(_choisies.clear),
      ),
      title: Text(T('{0} sélectionnée{1}', [_choisies.length, _choisies.length > 1 ? 's' : ''])),
      actions: [
        IconButton(
          tooltip: T('Tout sélectionner'),
          icon: const Icon(Icons.select_all),
          onPressed: () => setState(
              () => _choisies.addAll(_captures.map((c) => c.id))),
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
        IconButton(
          tooltip: T('Supprimer'),
          icon: const Icon(Icons.delete_outline),
          onPressed: _supprimeChoisies,
        ),
      ],
    );
  }

  /// Jette les photos cochées que rien n'identifie.
  ///
  /// Le compte annoncé est celui des photos **sans espèce** contenues dans la
  /// sélection, pas celui de la sélection : le serveur épargne les autres, et
  /// promettre vingt suppressions pour en faire trois serait mentir. « Tout
  /// sélectionner » puis « Supprimer » devient ainsi un geste sûr — il vide
  /// les indéterminées sans emporter ce qui est rangé dans le dex.
  Future<void> _supprimeChoisies() async {
    final lot = [for (final c in _selection) if (c.caseId == null) c.id];
    final gardees = _choisies.length - lot.length;
    if (lot.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(T('Aucune photo sans espèce dans la sélection.'))));
      return;
    }
    final confirme = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(T('Supprimer {0} photo{1} ?', [lot.length, lot.length > 1 ? 's' : ''])),
        content: Text(
          T('Les images et leurs données partent définitivement.{0}', [gardees > 0 ? '\n\n$gardees photo${gardees > 1 ? 's' : ''} de la sélection ${gardees > 1 ? 'sont rattachées' : 'est rattachée'} à une espèce : ${gardees > 1 ? 'elles seront gardées' : 'elle sera gardée'}.' : '']),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(T('Garder'))),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(backgroundColor: Palette.alerte),
            child: Text(T('Supprimer')),
          ),
        ],
      ),
    );
    if (confirme != true) return;
    try {
      final d = await Api.instance
          .post('/captures/non-identifiees/suppression', {'ids': lot});
      if (!mounted) return;
      setState(_choisies.clear);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(T('{0} photo(s) supprimée(s).', [d['supprimees']]))));
      _recommence();
      _compteNonIdentifiees();
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Les photos cochées, dans l'ordre où elles apparaissent.
  List<Capture> get _selection =>
      _captures.where((c) => _choisies.contains(c.id)).toList();

  /// Pose la même date et le même lieu sur tout le lot.
  ///
  /// La première photo cochée sert de point de départ à la carte : c'est
  /// souvent celle qui porte déjà une position approchée, et partir de là
  /// évite d'ouvrir sur le milieu de la France.
  Future<void> _situeChoisies() async {
    final lot = _selection;
    if (lot.isEmpty) return;
    final tete = lot.first;
    final fait = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => EcranSituerUne(
        capture: CaptureOrpheline.depuisJson({
          'capture_id': tete.id,
          'nom': tete.verdict,
          'cree_le': tete.creeLe,
          'prise_le': tete.priseLe,
          'lat': tete.lat,
          'lon': tete.lon,
          'vignette': tete.vignette,
        }),
        aussi: [for (final c in lot.skip(1)) c.id],
      ),
    ));
    if (fait != true || !mounted) return;
    setState(_choisies.clear);
    _recommence();
    _compteNonIdentifiees();
  }

  /// Signe tout le lot des mêmes amis.
  Future<void> _identifieChoisies() async {
    final lot = _selection;
    if (lot.isEmpty) return;
    final fait = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => IdentifierAmis(
        captureId: lot.first.id,
        // En lot on part d'une liste vide : « déjà identifié » n'a pas de sens
        // quand les photos n'ont pas les mêmes signataires.
        dejaLa: const [],
        aussi: [for (final c in lot.skip(1)) c.id],
      ),
    ));
    if (fait != true || !mounted) return;
    setState(_choisies.clear);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(T('{0} photo{1} partagée{2}.', [lot.length, lot.length > 1 ? 's' : '', lot.length > 1 ? 's' : '']))));
    }
  }

  /// Prévenir plutôt que d'effacer en silence : ces photos disparaîtront, le
  /// joueur doit pouvoir les rattraper avant.
  Widget _bandeauNonIdentifiees() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFB08A00).withValues(alpha: .10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFB08A00).withValues(alpha: .35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.help_outline, size: 18, color: Color(0xFF8A6A00)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              T('{0} photo{1} sans espèce', [_nonIdentifiees, _nonIdentifiees > 1 ? 's' : '']),
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: Color(0xFF8A6A00)),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Text(
          _explication(),
          style: TextStyle(
              fontSize: 12, height: 1.35, color: Palette.texteDoux),
        ),
        const SizedBox(height: 6),
        Row(children: [
          TextButton(
            onPressed: () {
              setState(() => _filtre = 'rejet');
              _recommence();
            },
            child: Text(T('Les voir')),
          ),
          TextButton(
            onPressed: _videNonIdentifiees,
            child: Text(T('Tout supprimer'),
                style: TextStyle(color: Palette.alerte)),
          ),
        ]),
      ]),
    );
  }

  Widget _puce(String etiquette, String valeur) => Padding(
        padding: const EdgeInsets.only(right: 8, top: 4, bottom: 6),
        child: ChoiceChip(
          label: Text(etiquette, style: const TextStyle(fontSize: 12)),
          selected: _filtre == valeur,
          onSelected: (_) {
            setState(() => _filtre = valeur);
            _recommence();
          },
        ),
      );

  /// Une ligne, cochable dès qu'on est en sélection.
  Widget _ligne(Capture c) {
    final choisie = _choisies.contains(c.id);
    final (icone, couleur, etiquette) = switch (c.etat) {
      'ok' => (Icons.check_circle, Palette.accent, c.verdict),
      'doute' => (Icons.help_outline, const Color(0xFFB08A00), c.verdict),
      'rejet' => (Icons.block, Palette.texteDoux, 'Pas d\'animal'),
      'erreur' => (Icons.error_outline, Palette.alerte, 'Erreur'),
      _ => (Icons.hourglass_empty, Palette.texteDoux, 'Analyse en cours…'),
    };

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      // L'appui long entre en sélection : c'est le geste qu'on connaît depuis
      // les galeries de téléphone, et il ne coûte rien à qui l'ignore.
      onLongPress: () => setState(() => _choisies.add(c.id)),
      onTap: _choisies.isEmpty
          ? () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => Visionneuse(
                  captures: [c],
                  titre: etiquette,
                  surSuppression: (id) async {
                    await Api.instance.supprime('/captures/$id');
                    _recommence();
                  },
                ),
              ))
          : () => setState(() {
                if (choisie) {
                  _choisies.remove(c.id);
                } else {
                  _choisies.add(c.id);
                }
              }),
      child: Row(children: [
        if (_choisies.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(
                choisie ? Icons.check_circle : Icons.circle_outlined,
                color: choisie ? Palette.accent : Palette.silhouette),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.network(
            Api.instance.image(c.vignette).toString(),
            headers: Api.instance.entetes,
            width: 66,
            height: 66,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                Container(width: 66, height: 66, color: Palette.caseVide),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(c.corrigee ? Icons.edit_outlined : icone,
                    size: 15, color: couleur),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(etiquette,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: 2),
              Text(c.creeLe.replaceFirst(' ', ' à '),
                  style: TextStyle(
                      color: Palette.texteDoux, fontSize: 11)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [
                if (c.caseId != null)
                  _bouton('Voir la case', () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => EcranDetailCase(caseId: c.caseId!)))),
                if (!c.enCours)
                  _bouton(c.reussie ? 'Corriger' : 'Choisir l\'espèce',
                      () => _corrige(c)),
              ]),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _bouton(String texte, VoidCallback action) => InkWell(
        onTap: action,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 6),
          child: Text(texte,
              style: TextStyle(
                  fontSize: 12,
                  color: Palette.accent,
                  fontWeight: FontWeight.w600)),
        ),
      );
}

extension _ExplicationPurge on _EcranMesCapturesState {
  /// Phrase du bandeau, montée à part : l'imbriquer dans le widget donnait une
  /// interpolation illisible.
  String _explication() {
    final base = T('Elles n\'apparaissent ni sur la carte ni dans la galerie');
    final delai = _joursAvantPurge > 0
        ? ', et seront effacées au bout de $_joursAvantPurge jours'
        : '';
    return T('{0}{1}. Choisissez-leur une espèce pour les garder.', [base, delai]);
  }
}
