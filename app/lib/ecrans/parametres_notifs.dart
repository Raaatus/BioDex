import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets/chargement.dart';

/// Ce dont on accepte d'être prévenu.
///
/// L'écran existe parce que le défaut est avare, et qu'un défaut avare doit
/// pouvoir s'ouvrir. L'inverse — tout allumer et laisser couper — ne marche
/// pas : on coupe la catégorie qui déborde, puis toutes, et le jour où quelque
/// chose compte vraiment le message se perd avec le reste.
class EcranParametresNotifs extends StatefulWidget {
  const EcranParametresNotifs({super.key});

  @override
  State<EcranParametresNotifs> createState() => _EcranParametresNotifsState();
}

class _EcranParametresNotifsState extends State<EcranParametresNotifs> {
  List<Map<String, dynamic>> _categories = [];
  bool _charge = true;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _lit();
  }

  Future<void> _lit() async {
    try {
      final d = await Api.instance.get('/notifications/reglages');
      if (!mounted) return;
      setState(() {
        _categories = List<Map<String, dynamic>>.from(d['categories']);
        _charge = false;
      });
    } on ErreurApi catch (e) {
      if (mounted) setState(() { _erreur = e.message; _charge = false; });
    }
  }

  /// Change une catégorie, en montrant le résultat tout de suite.
  ///
  /// L'interrupteur bascule avant la réponse du serveur : attendre un
  /// aller-retour pour voir bouger un interrupteur donne l'impression que
  /// l'appui n'a pas été pris. En cas d'échec on le remet, et on le dit.
  Future<void> _change(String cle, bool valeur) async {
    final avant = _categories;
    setState(() {
      _categories = [
        for (final c in _categories)
          if (c['cle'] == cle) {...c, 'actif': valeur} else c,
      ];
    });
    try {
      await Api.instance.put(
          '/notifications/reglages', {'reglages': {cle: valeur}});
    } on ErreurApi catch (e) {
      if (!mounted) return;
      setState(() => _categories = avant);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(T('Notifications'))),
      body: _charge
          ? const Chargement()
          : _erreur != null
              ? Center(child: Text(_erreur!))
              : ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: Text(
                        T('Par défaut, on ne vous prévient que de ce qui vous concerne directement, et de ce qui va disparaître si vous ne faites rien. Le reste est ici, si vous en voulez.'),
                        style: TextStyle(
                            fontSize: 12.5,
                            color: Palette.texteDoux,
                            height: 1.4),
                      ),
                    ),
                    for (final c in _categories)
                      SwitchListTile(
                        title: Text(c['nom'] ?? ''),
                        subtitle: Text(c['detail'] ?? '',
                            style: const TextStyle(fontSize: 12)),
                        value: c['actif'] == true,
                        onChanged: (v) => _change(c['cle'], v),
                      ),
                  ],
                ),
    );
  }
}
