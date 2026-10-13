import 'dart:convert';
import 'i18n.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Client du backend Biodex.
///
/// L'adresse du serveur n'est pas figée dans le code : elle se règle sur l'écran
/// de connexion et se retient d'une fois sur l'autre. Sur un téléphone qui passe
/// du wifi de la maison à la 4G, c'est le réglage qu'on change le plus souvent.
class Api {
  Api._();
  static final Api instance = Api._();

  static const _cleAdresse = 'adresse';
  static const _cleJeton = 'jeton';
  static const _clePseudo = 'pseudo';

  /// Valeur de départ : l'API publique. Elle se change sur l'écran de
  /// connexion, sans recompiler, pour taper une machine de développement sur
  /// le réseau local.
  ///
  /// Vide tant que personne ne l'a saisie : Biodex s'auto-héberge, il n'y a
  /// pas de serveur public à proposer d'office. L'écran de connexion la
  /// demande, et elle reste ensuite dans les préférences du téléphone.
  String adresse = '';
  String? jeton;
  String? pseudo;

  bool get connecte => jeton != null;

  Future<void> charge() async {
    final p = await SharedPreferences.getInstance();
    adresse = p.getString(_cleAdresse) ?? adresse;
    jeton = p.getString(_cleJeton);
    pseudo = p.getString(_clePseudo);
  }

  Future<void> _retiens() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_cleAdresse, adresse);
    if (jeton == null) {
      await p.remove(_cleJeton);
      await p.remove(_clePseudo);
    } else {
      await p.setString(_cleJeton, jeton!);
      await p.setString(_clePseudo, pseudo ?? '');
    }
  }

  Uri _url(String chemin, [Map<String, dynamic>? params]) {
    final base = Uri.parse(adresse.trim().replaceAll(RegExp(r'/+$'), ''));
    // Le chemin peut déjà porter des paramètres — les illustrations de rang
    // arrivent avec une empreinte qui renouvelle leur adresse quand les
    // dessins changent. Les fusionner, sinon le « ? » finissait dans le
    // chemin et le serveur ne reconnaissait plus la route.
    final coupe = chemin.indexOf('?');
    final nu = coupe < 0 ? chemin : chemin.substring(0, coupe);
    final deja = coupe < 0
        ? const <String, String>{}
        : Uri.splitQueryString(chemin.substring(coupe + 1));
    final tous = <String, String>{
      ...deja,
      ...?params?.map((k, v) => MapEntry(k, '$v')),
    };
    return base.replace(
      path: '${base.path}$nu',
      queryParameters: tous.isEmpty ? null : tous,
    );
  }

  Map<String, String> get entetes => {
        if (jeton != null) 'Authorization': 'Bearer $jeton',
        // Le serveur traduit ce qu'il sert comme données — succès, rangs —
        // dans la langue de l'application.
        'Accept-Language': I18n.courante,
      };

  /// URL complète d'une image servie par le backend. Le jeton voyage en
  /// en-tête via [entetes] ; ici on ne construit que l'adresse.
  ///
  /// `params` permet de demander une taille réduite : les marqueurs de la carte
  /// n'ont pas besoin d'une découpe pleine résolution.
  Uri image(String chemin, [Map<String, dynamic>? params]) =>
      _url(chemin, params);

  dynamic _lis(http.Response r) {
    dynamic corps;
    try {
      corps = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException {
      // Une réponse qui n'est pas du JSON vient d'un intermédiaire — portail
      // Wi-Fi, page d'erreur d'un proxy — pas du backend. Le dire, plutôt que
      // de laisser remonter une panne de décodage incompréhensible.
      throw ErreurApi(
          'Réponse inattendue du serveur (HTTP ${r.statusCode}).', r.statusCode);
    }
    if (r.statusCode >= 400) {
      final detail = corps is Map && corps['detail'] != null
          ? '${corps['detail']}'
          : null;
      // Un serveur qui répond « non » n'est pas un serveur injoignable : la
      // confusion entre les deux envoyait chercher une panne de réseau là où
      // c'était l'application qui demandait quelque chose d'invalide.
      final message = switch (r.statusCode) {
        401 => detail ?? 'Session expirée, reconnectez-vous.',
        403 => detail ?? 'Accès refusé.',
        404 => detail ?? 'Introuvable.',
        >= 500 => detail ?? 'Le serveur a rencontré une erreur.',
        _ => detail ?? 'Requête refusée (HTTP ${r.statusCode}).',
      };
      throw ErreurApi(T(message), r.statusCode);
    }
    return corps;
  }

  Future<dynamic> get(String chemin, [Map<String, dynamic>? params]) async {
    final url = _url(chemin, params);
    try {
      return _lis(await http.get(url, headers: entetes));
    } on SocketException {
      throw ErreurApi('Serveur injoignable. Vérifiez l\'adresse et le réseau.', 0);
    }
  }

  Future<dynamic> post(String chemin, [Object? corps]) async {
    try {
      return _lis(await http.post(_url(chemin),
          headers: {...entetes, 'Content-Type': 'application/json'},
          body: corps == null ? null : jsonEncode(corps)));
    } on SocketException {
      throw ErreurApi('Serveur injoignable. Vérifiez l\'adresse et le réseau.', 0);
    }
  }

  Future<dynamic> put(String chemin, [Object? corps]) async {
    try {
      return _lis(await http.put(_url(chemin),
          headers: {...entetes, 'Content-Type': 'application/json'},
          body: corps == null ? null : jsonEncode(corps)));
    } on SocketException {
      throw ErreurApi('Serveur injoignable.', 0);
    }
  }

  Future<dynamic> patch(String chemin, [Object? corps]) async {
    try {
      return _lis(await http.patch(_url(chemin),
          headers: {...entetes, 'Content-Type': 'application/json'},
          body: corps == null ? null : jsonEncode(corps)));
    } on SocketException {
      throw ErreurApi('Serveur injoignable.', 0);
    }
  }

  Future<dynamic> supprime(String chemin) async {
    try {
      return _lis(await http.delete(_url(chemin), headers: entetes));
    } on SocketException {
      throw ErreurApi('Serveur injoignable.', 0);
    }
  }

  // ------------------------------------------------------------------ comptes

  Future<void> inscription(String pseudoVoulu, String mdp) async {
    final d = await post('/inscription',
        {'pseudo': pseudoVoulu, 'mdp': mdp, 'appareil': Platform.operatingSystem});
    jeton = d['jeton'];
    pseudo = d['pseudo'];
    await _retiens();
  }

  Future<void> connexion(String pseudoVoulu, String mdp) async {
    final d = await post('/connexion',
        {'pseudo': pseudoVoulu, 'mdp': mdp, 'appareil': Platform.operatingSystem});
    jeton = d['jeton'];
    pseudo = d['pseudo'];
    await _retiens();
  }

  Future<void> deconnexion() async {
    try {
      await post('/deconnexion');
    } catch (_) {
      // Peu importe que le serveur réponde : localement on oublie le jeton.
    }
    jeton = null;
    pseudo = null;
    await _retiens();
  }

  Future<void> changeAdresse(String nouvelle) async {
    adresse = nouvelle;
    await _retiens();
  }

  // ----------------------------------------------------------------- captures

  /// Envoie une photo et renvoie l'identifiant de la capture créée.
  /// Envoie une photo, et éventuellement sa retouche.
  ///
  /// Trois images pour une seule observation : `photo` est l'originale, la
  /// seule qu'on garde ; `analyse` est la version retouchée qu'on soumet au
  /// moteur ; `decoupe` est le tracé du joueur, qui deviendra la vignette.
  /// Les deux dernières sont facultatives.
  Future<int> envoiePhoto(File photo,
      {double? lat, double? lon, String regne = 'animal',
      String titre = '', bool instantanee = true,
      Uint8List? analyse, Uint8List? decoupe}) async {
    final requete = http.MultipartRequest('POST', _url('/captures'))
      ..headers.addAll(entetes)
      ..files.add(await http.MultipartFile.fromPath('photo', photo.path));
    if (analyse != null) {
      requete.files.add(http.MultipartFile.fromBytes('analyse', analyse,
          filename: 'analyse.png'));
    }
    if (decoupe != null) {
      requete.files.add(http.MultipartFile.fromBytes('decoupe', decoupe,
          filename: 'decoupe.png'));
    }
    if (lat != null) requete.fields['lat'] = '$lat';
    if (lon != null) requete.fields['lon'] = '$lon';
    // Le règne décide du moteur côté serveur : Pl@ntNet, FungiTastic ou
    // MegaDetector. Il est déclaré, pas deviné.
    requete.fields['regne'] = regne;
    // Photo prise à l'instant ou tirée de la galerie : c'est ce qui décide si
    // la position du téléphone vaut vérité ou simple pis-aller.
    requete.fields['instantanee'] = instantanee ? 'true' : 'false';
    if (titre.trim().isNotEmpty) requete.fields['titre'] = titre.trim();

    final reponse = await http.Response.fromStream(await requete.send());
    return _lis(reponse)['id'] as int;
  }

  /// Récupère les octets d'une image servie par le backend.
  ///
  /// L'éditeur travaille en mémoire : il lui faut la photo elle-même, pas son
  /// adresse. On demande l'originale et non la vignette — recadrer une image
  /// de 512 pixels ne laisserait plus rien au moteur.
  Future<Uint8List> octets(String chemin) async {
    try {
      final r = await http.get(_url(chemin), headers: entetes);
      if (r.statusCode >= 400) {
        throw ErreurApi('Image inaccessible.', r.statusCode);
      }
      return r.bodyBytes;
    } on SocketException {
      throw ErreurApi('Serveur injoignable.', 0);
    }
  }

  /// Remplace la vignette détourée par un tracé fait à la main.
  ///
  /// Rien d'autre ne bouge : ni l'espèce, ni la photo d'origine, ni la date.
  /// C'est une décision d'affichage, pas une correction de fond.
  Future<Map<String, dynamic>> redecoupe(int captureId, Uint8List decoupe) async {
    final requete = http.MultipartRequest(
        'PUT', _url('/captures/$captureId/decoupe'))
      ..headers.addAll(entetes)
      ..files.add(http.MultipartFile.fromBytes('decoupe', decoupe,
          filename: 'decoupe.png'));
    final reponse = await http.Response.fromStream(await requete.send());
    return _lis(reponse) as Map<String, dynamic>;
  }

  /// Remplace l'image d'une capture non identifiée et relance l'analyse.
  ///
  /// La date, le lieu, le titre et les participants sont conservés côté
  /// serveur : c'est la même observation, seule l'image change.
  Future<Map<String, dynamic>> reprend(int captureId, Uint8List image) async {
    final requete = http.MultipartRequest(
        'POST', _url('/captures/$captureId/reprise'))
      ..headers.addAll(entetes)
      ..files.add(http.MultipartFile.fromBytes('photo', image,
          filename: 'retouche.jpg'));
    final reponse = await http.Response.fromStream(await requete.send());
    return _lis(reponse) as Map<String, dynamic>;
  }

  /// Envoie une photo de profil et renvoie son chemin d'accès.
  Future<String> envoieAvatar(File photo) async {
    final requete = http.MultipartRequest('POST', _url('/moi/avatar'))
      ..headers.addAll(entetes)
      ..files.add(await http.MultipartFile.fromPath('photo', photo.path));
    final reponse = await http.Response.fromStream(await requete.send());
    return _lis(reponse)['avatar'] as String;
  }
}

class ErreurApi implements Exception {
  ErreurApi(this.message, this.code);
  final String message;
  final int code;

  @override
  String toString() => message;
}
