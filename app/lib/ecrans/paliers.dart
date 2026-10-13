import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets/badge_palier.dart';
import '../widgets/chargement.dart';

/// Les cinquante rangs, du premier au dernier.
///
/// Voir la suite donne un horizon. Le rapport au total ne disait qu'une chose,
/// qu'on n'y arriverait jamais ; la liste des rangs dit où l'on est, ce qui
/// vient ensuite, et à quoi ressemble le bout du chemin.
class EcranPaliers extends StatefulWidget {
  const EcranPaliers({super.key});

  @override
  State<EcranPaliers> createState() => _EcranPaliersState();
}

class _EcranPaliersState extends State<EcranPaliers> {
  List<Map<String, dynamic>> _paliers = [];
  int _trouve = 0;
  int _atteint = 0;
  bool _charge = true;

  @override
  void initState() {
    super.initState();
    _lit();
  }

  Future<void> _lit() async {
    try {
      final d = await Api.instance.get('/paliers');
      if (!mounted) return;
      setState(() {
        _paliers = (d['paliers'] as List).cast<Map<String, dynamic>>();
        _trouve = d['trouve'] ?? 0;
        _atteint = d['atteint'] ?? 0;
      });
    } catch (_) {
      // Écran de consultation : sans réseau, il reste vide.
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(T('Les rangs'))),
      body: _charge
          ? const Chargement()
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              itemCount: _paliers.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) return _entete();
                return _ligne(_paliers[i - 1]);
              },
            ),
    );
  }

  Widget _entete() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(
        T('{0} espèce{1} trouvée{2} · rang {3} sur {4}', [_trouve, _trouve > 1 ? 's' : '', _trouve > 1 ? 's' : '', _atteint, _paliers.length]),
        style: TextStyle(color: Palette.texteDoux, fontSize: 13),
      ),
    );
  }

  Widget _ligne(Map<String, dynamic> p) {
    final atteint = p['atteint'] == true;
    final courant = p['numero'] == _atteint;
    // Le rang suivant reste net : c'est celui qu'on vise, il doit donner envie.
    // Ceux d'après s'estompent, sans jamais disparaître — savoir ce qui existe
    // plus loin fait partie du plaisir.
    final prochain = p['numero'] == _atteint + 1;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
      decoration: BoxDecoration(
        color: courant ? Palette.accent.withValues(alpha: .09) : null,
        borderRadius: BorderRadius.circular(14),
        border: courant
            ? Border.all(color: Palette.accent.withValues(alpha: .5), width: 1.4)
            : null,
      ),
      child: Opacity(
        // Les rangs à venir restent lisibles : c'est le badge qui est éteint,
        // pas la ligne entière.
        opacity: atteint || prochain ? 1.0 : .75,
        child: Row(children: [
          BadgePalier(chemin: p['badge'], taille: 56, eteint: !atteint),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p['nom'],
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: courant ? FontWeight.w800 : FontWeight.w600)),
                Text(
                  T('{0} espèce{1}', [_millier(p['seuil']), p['seuil'] > 1 ? 's' : '']),
                  style: TextStyle(
                      fontSize: 11.5, color: Palette.texteDoux),
                ),
              ],
            ),
          ),
          if (atteint)
            Icon(Icons.check_circle, color: Palette.accent, size: 19)
          else
            Text('#${p['numero']}',
                style: TextStyle(
                    fontSize: 12, color: Palette.texteDoux)),
        ]),
      ),
    );
  }

  String _millier(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
      b.write(s[i]);
    }
    return b.toString();
  }
}
