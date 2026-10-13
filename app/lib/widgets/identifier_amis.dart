import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import 'reactions.dart';
import 'chargement.dart';

/// « Qui était avec toi ? »
///
/// Deux personnes qui marchent ensemble voient le même renard. Jusqu'ici il
/// fallait le photographier chacune de son côté pour que chacune le compte :
/// deux fichiers presque identiques sur le serveur, et le même animal deux
/// fois dans le fil des amis. Une photo peut désormais être signée par
/// plusieurs personnes — un seul fichier, plusieurs dex.
///
/// Ceux qu'on ajoute reçoivent la case et les points comme s'ils avaient pris
/// la photo. C'est le principe, pas une consolation : on y était tous les deux.
class IdentifierAmis extends StatefulWidget {
  const IdentifierAmis({
    super.key,
    required this.captureId,
    required this.dejaLa,
    this.auteur,
    this.aussi = const [],
  });

  final int captureId;

  /// Les autres photos à signer du même coup.
  ///
  /// Une balade à deux donne dix photos où l'autre était là : les cocher dix
  /// fois n'apprend rien à personne. En lot on n'ajoute que — retirer demande
  /// de savoir qui était déjà sur quoi, et ce n'est plus la même question.
  final List<int> aussi;

  /// Ceux qui sont déjà identifiés : on les montre cochés plutôt que de les
  /// masquer, sinon on ne comprend pas pourquoi un ami manque à la liste.
  final List<Personne> dejaLa;

  /// L'auteur de la photo, quand ce n'est pas nous : il apparaît en tête, non
  /// décochable. On ne retire pas quelqu'un de sa propre photo.
  final Personne? auteur;

  @override
  State<IdentifierAmis> createState() => _IdentifierAmisState();
}

class _IdentifierAmisState extends State<IdentifierAmis> {
  List<Personne> _amis = [];
  late final Set<int> _choisis = {for (final p in widget.dejaLa) p.id};
  final _initiaux = <int>{};

  bool _charge = true;
  bool _envoi = false;
  String? _erreur;
  String _filtre = '';

  @override
  void initState() {
    super.initState();
    _initiaux.addAll(_choisis);
    _chargeAmis();
  }

  Future<void> _chargeAmis() async {
    try {
      final d = await Api.instance.get('/amis', {'limite': 200});
      if (!mounted) return;
      setState(() {
        _amis = (d['amis'] as List).map((a) => Personne.depuisJson(a)).toList();
        _charge = false;
      });
    } on ErreurApi catch (e) {
      if (mounted) setState(() { _erreur = e.message; _charge = false; });
    }
  }

  /// Enregistre la différence, pas l'état complet.
  ///
  /// Le serveur a deux routes — ajouter, retirer — et aucune ne remplace la
  /// liste entière. C'est volontaire : envoyer l'état complet ferait qu'un
  /// écran ouvert un peu longtemps effacerait les ajouts faits ailleurs entre
  /// temps.
  Future<void> _enregistre() async {
    final ajouts = _choisis.difference(_initiaux);
    final retraits = _initiaux.difference(_choisis);
    if (ajouts.isEmpty && retraits.isEmpty) {
      Navigator.pop(context, false);
      return;
    }
    setState(() { _envoi = true; _erreur = null; });
    try {
      final cibles = [widget.captureId, ...widget.aussi];
      // Les retraits ne valent que pour la photo d'origine : en lot, la liste
      // de départ est vide, donc il n'y a rien à retirer.
      for (final id in retraits) {
        await Api.instance.supprime(
            '/captures/${widget.captureId}/participants/$id');
      }
      if (ajouts.isNotEmpty) {
        final pseudos = [
          for (final a in _amis)
            if (ajouts.contains(a.id)) a.pseudo,
        ];
        for (final capture in cibles) {
          await Api.instance
              .post('/captures/$capture/participants', {'pseudos': pseudos});
        }
      }
      if (mounted) Navigator.pop(context, true);
    } on ErreurApi catch (e) {
      if (mounted) setState(() { _erreur = e.message; _envoi = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibles = _filtre.isEmpty
        ? _amis
        : _amis
            .where((a) => a.pseudo.toLowerCase().contains(_filtre.toLowerCase()))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.aussi.isEmpty
            ? 'Qui était avec vous ?'
            : 'Qui était avec vous ? (${widget.aussi.length + 1} photos)'),
        actions: [
          TextButton(
            onPressed: _envoi ? null : _enregistre,
            child: _envoi
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(T('Terminé')),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: Text(
            widget.aussi.isEmpty
                ? 'La photo comptera dans leur dex aussi, avec les points. Elle ne sera pas envoyée en double : un seul cliché, plusieurs collections.'
                : 'Ces photos compteront dans leur dex aussi, avec les points. Rien n\'est envoyé en double.',
            style: TextStyle(fontSize: 12.5, color: Palette.texteDoux, height: 1.35),
          ),
        ),
        if (widget.auteur != null)
          ListTile(
            leading: Avatar(
                pseudo: widget.auteur!.pseudo,
                chemin: widget.auteur!.avatar,
                taille: 38),
            title: Text(widget.auteur!.pseudo),
            subtitle: Text(T('a pris la photo'),
                style: TextStyle(fontSize: 12)),
            trailing: Icon(Icons.photo_camera_outlined,
                size: 18, color: Palette.texteDoux),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _filtre = v),
            decoration: InputDecoration(
              isDense: true,
              hintText: T('Chercher un ami…'),
              prefixIcon: Icon(Icons.search, size: 19),
            ),
          ),
        ),
        if (_erreur != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(_erreur!,
                style: TextStyle(color: Palette.alerte, fontSize: 13)),
          ),
        Expanded(child: _liste(visibles)),
      ]),
    );
  }

  Widget _liste(List<Personne> visibles) {
    if (_charge) return const Chargement();
    if (_amis.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            T('Vous n\'avez pas encore d\'amis.\\nAjoutez-en pour partager vos trouvailles.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Palette.texteDoux, height: 1.4),
          ),
        ),
      );
    }
    if (visibles.isEmpty) {
      return Center(
        child: Text(T('Personne à ce nom.'),
            style: TextStyle(color: Palette.texteDoux)),
      );
    }
    return ListView.builder(
      itemCount: visibles.length,
      itemBuilder: (context, i) {
        final a = visibles[i];
        final coche = _choisis.contains(a.id);
        return CheckboxListTile(
          value: coche,
          onChanged: _envoi
              ? null
              : (v) => setState(() {
                    if (v == true) {
                      _choisis.add(a.id);
                    } else {
                      _choisis.remove(a.id);
                    }
                  }),
          secondary: Avatar(pseudo: a.pseudo, chemin: a.avatar, taille: 38),
          title: Text(a.pseudo),
          controlAffinity: ListTileControlAffinity.trailing,
        );
      },
    );
  }
}
