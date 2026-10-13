import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets/chargement.dart';

/// Les sources et les auteurs.
///
/// PhyloPic verse l'essentiel de son fonds au domaine public, mais pas tout :
/// certaines silhouettes sont sous CC-BY, qui impose de citer leur auteur. Cet
/// écran est ce qui rend cette obligation tenable — et c'est bien le moins,
/// vu le travail que ces dessins représentent.
class EcranCredits extends StatefulWidget {
  const EcranCredits({super.key});

  @override
  State<EcranCredits> createState() => _EcranCreditsState();
}

class _EcranCreditsState extends State<EcranCredits> {
  List<dynamic> _silhouettes = [];
  List<dynamic> _sources = [];
  bool _charge = true;

  @override
  void initState() {
    super.initState();
    _chargeCredits();
  }

  Future<void> _chargeCredits() async {
    try {
      final d = await Api.instance.get('/credits');
      if (!mounted) return;
      setState(() {
        _silhouettes = d['silhouettes'] ?? [];
        _sources = d['sources'] ?? [];
      });
    } catch (_) {
      // Écran informatif : sans réseau, il reste vide.
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(T('Crédits'))),
      body: _charge
          ? const Chargement()
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Text(T('Sources'),
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                for (final s in _sources)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('· '),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${s['nom']}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              Text('${s['role']}',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Palette.texteDoux)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 26),
                Text(T('Auteurs des silhouettes'),
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  T('Chaque silhouette du dex a été dessinée par quelqu\'un, et versée à PhyloPic sous licence libre.'),
                  style: TextStyle(
                      fontSize: 12, color: Palette.texteDoux, height: 1.4),
                ),
                const SizedBox(height: 12),
                if (_silhouettes.isEmpty)
                  Text(T('Aucune silhouette chargée pour l\'instant.'),
                      style: TextStyle(color: Palette.texteDoux))
                else
                  for (final s in _silhouettes)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        Expanded(
                          child: Text('${s['auteur']}',
                              style: const TextStyle(fontSize: 13)),
                        ),
                        Text('${s['images']}',
                            style: TextStyle(
                                fontSize: 12,
                                color: Palette.texteDoux,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 76,
                          child: Text(_licenceCourte('${s['licence']}'),
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  fontSize: 10, color: Palette.texteDoux)),
                        ),
                      ]),
                    ),
              ],
            ),
    );
  }

  /// « https://creativecommons.org/publicdomain/zero/1.0/ » ne dit rien à
  /// personne ; « CC0 » si.
  static String _licenceCourte(String url) {
    if (url.contains('publicdomain/zero')) return 'CC0';
    if (url.contains('publicdomain/mark')) return T('domaine public');
    if (url.contains('by-sa')) return T('CC BY-SA');
    if (url.contains('by-nc')) return T('CC BY-NC');
    if (url.contains('/by/')) return T('CC BY');
    return url.isEmpty ? '' : 'libre';
  }
}
