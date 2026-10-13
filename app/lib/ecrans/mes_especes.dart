import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets/chargement.dart';
import 'nouvelle_espece.dart';

/// Les espèces que j'ai indexées moi-même.
///
/// Les désactivées restent dans la liste, grisées. C'est le seul endroit d'où
/// on peut les remettre en service, et les faire disparaître donnerait
/// l'impression qu'elles sont perdues alors qu'elles ne le sont pas.
class EcranMesEspeces extends StatefulWidget {
  const EcranMesEspeces({super.key});

  @override
  State<EcranMesEspeces> createState() => _EcranMesEspecesState();
}

class _EcranMesEspecesState extends State<EcranMesEspeces> {
  List<Map<String, dynamic>>? _especes;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _charge();
  }

  Future<void> _charge() async {
    try {
      final d = await Api.instance.get('/especes/miennes');
      if (mounted) {
        setState(() =>
            _especes = (d['especes'] as List).cast<Map<String, dynamic>>());
      }
    } on ErreurApi catch (e) {
      if (mounted) setState(() => _erreur = e.message);
    }
  }

  Future<void> _ajoute() async {
    final creee = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(builder: (_) => const EcranNouvelleEspece()));
    if (creee != null) _charge();
  }

  Future<void> _modifie(Map<String, dynamic> e) async {
    final maj = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(builder: (_) => EcranNouvelleEspece(existante: e)));
    if (maj != null) _charge();
  }

  Future<void> _retire(Map<String, dynamic> e) async {
    final captures = e['captures'] as int? ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(T('Retirer « {0} » ?', [e['nom']])),
        content: Text(
          captures == 0
              ? 'Personne n\'y a rangé de photo : elle disparaîtra complètement du dex.'
              // La distinction compte : le joueur doit savoir qu'il ne détruit
              // rien, surtout si les photos sont celles de quelqu'un d'autre.
              : '$captures photo${captures > 1 ? 's y sont rangées' : ' y est rangée'}. L\'espèce sera désactivée, pas supprimée : les photos resteront où elles sont, et vous pourrez la remettre.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(T('Annuler'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Palette.alerte),
            onPressed: () => Navigator.pop(c, true),
            child: Text(T('Retirer')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.supprime('/especes/${e['id']}');
      _charge();
    } on ErreurApi catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err.message)));
      }
    }
  }

  Future<void> _reactive(Map<String, dynamic> e) async {
    try {
      await Api.instance.post('/especes/${e['id']}/reactive', const {});
      _charge();
    } on ErreurApi catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _especes;
    return Scaffold(
      appBar: AppBar(title: Text(T('Espèces indexées'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _ajoute,
        icon: const Icon(Icons.add),
        label: Text(T('Ajouter')),
      ),
      body: _erreur != null
          ? Center(
              child: Padding(
                  padding: const EdgeInsets.all(32), child: Text(_erreur!)))
          : l == null
              ? const Chargement()
              : RefreshIndicator(
                  onRefresh: _charge,
                  child: l.isEmpty ? _vide() : _liste(l),
                ),
    );
  }

  Widget _vide() => ListView(
        padding: const EdgeInsets.fromLTRB(28, 60, 28, 0),
        children: [
          Icon(Icons.local_florist_outlined,
              size: 46, color: Palette.texteDoux),
          const SizedBox(height: 16),
          Text(T('Rien indexé pour l\'instant.'),
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(
            T('Quand le moteur se trompe parce qu\'il ne connaît pas l\'espèce — un cultivar de rosier, une race, une variété — ajoutez-la vous-même. Elle entrera au dex pour tout le monde.'),
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: 13, color: Palette.texteDoux, height: 1.4),
          ),
        ],
      );

  Widget _liste(List<Map<String, dynamic>> l) => ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
        itemCount: l.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final e = l[i];
          final actif = e['actif'] as bool? ?? true;
          final captures = e['captures'] as int? ?? 0;
          return Opacity(
            opacity: actif ? 1 : .55,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
              decoration: BoxDecoration(
                color: Palette.fondSecondaire,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(e['nom'] as String? ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        if (!actif) ...[
                          const SizedBox(width: 8),
                          Text(T('retirée'),
                              style: TextStyle(
                                  fontSize: 11, color: Palette.alerte)),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if ((e['latin'] as String? ?? '').isNotEmpty)
                            e['latin'] as String,
                          if (captures > 0)
                            T('{0} photo{1}', [captures, captures > 1 ? 's' : '']),
                          if ((e['wikipedia'] as String? ?? '').isNotEmpty)
                            T('Wikipédia'),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(fontSize: 11.5, color: Palette.texteDoux),
                      ),
                    ],
                  ),
                ),
                if (actif)
                  IconButton(
                    tooltip: T('Modifier'),
                    icon: const Icon(Icons.edit_outlined, size: 19),
                    onPressed: () => _modifie(e),
                  ),
                IconButton(
                  tooltip: actif ? 'Retirer' : 'Remettre',
                  icon: Icon(
                      actif ? Icons.delete_outline : Icons.restore_outlined,
                      size: 19,
                      color: actif ? Palette.alerte : null),
                  onPressed: () => actif ? _retire(e) : _reactive(e),
                ),
              ]),
            ),
          );
        },
      );
}
