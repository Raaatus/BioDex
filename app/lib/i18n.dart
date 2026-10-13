import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// La langue de l'application.
///
/// Le français est la langue source : chaque texte de l'interface est écrit en
/// français dans le code, et c'est ce texte qui sert de clé. `T('Se connecter')`
/// rend la traduction si le dictionnaire de la langue en cours en a une, et le
/// français sinon — un texte oublié dans une traduction reste lisible.
///
/// Les dictionnaires sont dans `assets/lang/<code>.json`, générés depuis
/// `i18n/<code>.json` à la racine du dépôt (voir `i18n/genere.py`).
///
/// Les textes à trous : `T('{0} photos', [n])`. Numérotés et non nommés, parce
/// qu'une traduction peut les réordonner.
class I18n {
  static const langues = {'fr': 'Français', 'en': 'English'};
  static const source = 'fr';

  static Map<String, String> _dico = {};
  static String courante = source;

  /// Charge le dictionnaire de la langue voulue (`auto` : celle du téléphone).
  static Future<void> charge(String choix) async {
    var l = choix;
    if (l == 'auto') {
      final sys = ui.PlatformDispatcher.instance.locale.languageCode;
      l = langues.containsKey(sys) ? sys : source;
    }
    courante = l;
    if (l == source) {
      _dico = {};
      return;
    }
    try {
      final brut = await rootBundle.loadString('assets/lang/$l.json');
      _dico = (jsonDecode(brut) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      _dico = {};
    }
  }
}

/// Traduit un texte source, avec ses trous `{0}`, `{1}`…
String T(String cle, [List<Object?>? args]) {
  var s = I18n._dico[cle] ?? cle;
  if (args != null) {
    for (var i = 0; i < args.length; i++) {
      s = s.replaceAll('{$i}', args[i]?.toString() ?? '');
    }
  }
  return s;
}
