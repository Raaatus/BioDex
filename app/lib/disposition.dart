import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// L'arrangement libre du dex — comme des icônes sur un bureau.
///
/// **Pourquoi seulement les trouvailles.** Le catalogue compte 977 416 cases ;
/// les charger toutes ferait 396 Mo. Une disposition libre ne peut pas paginer
/// — déplacer une vignette suppose de savoir où sont les autres. Les espèces
/// découvertes, elles, tiennent en mémoire : mille font 415 Ko. Et de toute
/// façon, on n'arrange pas ce qu'on n'a pas trouvé.
///
/// **En cellules, jamais en pixels.** La grille logique fait cinq colonnes,
/// exactement comme la grille ordinaire ; c'est la taille des cellules qui suit
/// l'écran. Un arrangement fait sur un téléphone se retrouve identique sur une
/// tablette, et sur le site.
///
/// **On ne stocke que les exceptions.** Une case sans position suit la
/// disposition automatique et se pose à la suite : une nouvelle découverte ne
/// défait jamais un arrangement.
class Place {
  Place({
    required this.colonne,
    required this.rangee,
    this.largeur = 1,
    this.hauteur = 1,
    this.forme,
    this.masque = false,
  });

  Place.depuisJson(Map<String, dynamic> j)
      : colonne = j['colonne'] ?? 0,
        rangee = j['rangee'] ?? 0,
        largeur = j['largeur'] ?? 1,
        hauteur = j['hauteur'] ?? 1,
        // Le serveur rend toujours une forme ; « arrondi » est sa valeur par
        // défaut et signifie « rien de choisi ».
        forme = (j['forme'] == null || j['forme'] == 'arrondi') ? null : j['forme'],
        masque = j['masque'] ?? false;

  int colonne;
  int rangee;
  int largeur;
  int hauteur;

  /// `null` = l'apparence d'origine. Ce n'est pas une forme de plus, c'est
  /// l'absence de réglage — une case à laquelle on n'a pas touché doit
  /// ressembler exactement à ce qu'elle était avant que ce mode existe.
  String? forme;

  bool masque;

  Place copie() => Place(
      colonne: colonne, rangee: rangee, largeur: largeur, hauteur: hauteur,
      forme: forme, masque: masque);

  Map<String, dynamic> versJson() => {
        'colonne': colonne, 'rangee': rangee,
        'largeur': largeur, 'hauteur': hauteur,
        'forme': forme ?? 'arrondi', 'masque': masque,
      };

  bool croise(Place a) =>
      colonne < a.colonne + a.largeur &&
      a.colonne < colonne + largeur &&
      rangee < a.rangee + a.hauteur &&
      a.rangee < rangee + hauteur;
}

/// Une case vide : un trou qu'on pose soi-même, pour aérer ou caler une ligne.
/// Elle n'affiche rien mais occupe la place, ce qui est tout ce qu'on lui
/// demande.
class Vide extends Place {
  Vide({required super.colonne, required super.rangee,
        super.largeur, super.hauteur});

  Vide.depuisJson(super.j) : super.depuisJson();

  @override
  Vide copie() => Vide(colonne: colonne, rangee: rangee,
                       largeur: largeur, hauteur: hauteur);
}

class Disposition {
  Disposition._();
  static final Disposition instance = Disposition._();

  static const _cache = 'dex_disposition';

  /// Les formes proposées, servies par le serveur pour que les deux clients
  /// offrent exactement les mêmes.
  static const formes = <String, String>{
    'arrondi': 'Arrondi',
    'carre': 'Carré',
    'rond': 'Rond',
    'hexagone': 'Hexagone',
    'losange': 'Losange',
    'goutte': 'Goutte',
  };

  int colonnes = 5;
  int tailleMax = 3;
  Map<int, Place> places = {};
  List<Vide> vides = [];

  /// L'arrangement vit sur le serveur : c'est le seul moyen qu'il suive d'un
  /// appareil à l'autre, entre l'application et le site. Le cache local sert
  /// uniquement à dessiner tout de suite, sans attendre l'aller-retour.
  Future<void> charge() async {
    final p = await SharedPreferences.getInstance();
    final local = p.getString(_cache);
    if (local != null) {
      try {
        _lis(jsonDecode(local));
      } catch (_) {
        // Un cache abîmé ne doit pas empêcher de jouer : le serveur corrigera.
      }
    }
    try {
      final d = await Api.instance.get('/dex/disposition');
      _lis(d);
      await p.setString(_cache, jsonEncode(d));
    } catch (_) {
      // Hors ligne : le cache fait le travail, et l'arrangement reste modifiable.
    }
  }

  void _lis(dynamic d) {
    colonnes = d['colonnes'] ?? 5;
    tailleMax = d['taille_max'] ?? 3;
    places = {
      for (final e in (d['places'] as Map? ?? {}).entries)
        int.parse(e.key): Place.depuisJson(Map<String, dynamic>.from(e.value)),
    };
    vides = [
      for (final v in (d['vides'] as List? ?? []))
        Vide.depuisJson(Map<String, dynamic>.from(v)),
    ];
  }

  /// Enregistre l'arrangement.
  ///
  /// `partiel` dit au serveur de ne toucher qu'aux cases envoyées. Le dex ne
  /// charge que ses trois cents premières trouvailles : enregistrer en
  /// remplaçant tout effacerait la position de celles qui n'étaient pas à
  /// l'écran — une perte silencieuse, et la pire qui soit.
  Future<void> enregistre(Map<int, Place> nouvelles, List<Vide> nouveauxVides,
      {required bool partiel}) async {
    await Api.instance.put('/dex/disposition', {
      'cases': [
        for (final e in nouvelles.entries)
          {'case_id': e.key, ...e.value.versJson()},
      ],
      'vides': [for (final v in nouveauxVides) v.versJson()],
      'partiel': partiel,
    });
    places = {for (final e in nouvelles.entries) e.key: e.value.copie()};
    if (!partiel) vides = [for (final v in nouveauxVides) v.copie()];
    await _ecritLeCache();
  }

  Future<void> remiseAZero() async {
    await Api.instance.supprime('/dex/disposition');
    places = {};
    vides = [];
    await _ecritLeCache();
  }

  Future<void> _ecritLeCache() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_cache, jsonEncode({
      'colonnes': colonnes, 'taille_max': tailleMax,
      'places': {for (final e in places.entries) '${e.key}': e.value.versJson()},
      'vides': [for (final v in vides) v.versJson()],
    }));
  }
}
