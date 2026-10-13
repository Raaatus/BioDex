import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i18n.dart';

/// Les préférences d'affichage, gardées sur le téléphone.
///
/// Elles ne concernent que le confort de l'écran et n'ont rien à faire sur le
/// serveur : un même compte peut vouloir l'animation sur son téléphone et s'en
/// passer sur celui qu'il prête.
class Reglages extends ChangeNotifier {
  Reglages._();
  static final Reglages instance = Reglages._();

  static const _cleAnimation = 'animation_capture';
  static const _cleConfettis = 'confettis';
  static const _cleCasesEntieres = 'cases_entieres';
  static const _cleTheme = 'theme';
  static const _cleDecorAnime = 'decor_anime';
  static const _cleLangue = 'langue';
  static const _cleDateNotifs = 'date_notifs_prise';

  // ------------------------------------------------------- reprise de session
  //
  // Ce ne sont pas des préférences mais des traces : où j'en étais quand j'ai
  // fermé. Elles vivent ici parce que le mécanisme est le même, et parce qu'un
  // second magasin de clés pour trois valeurs ne se justifierait pas.
  //
  // Ce qui se retient est délibérément court. La position exacte dans le dex ou
  // le filtre d'une recherche ne se retiennent pas : rouvrir l'application sur
  // un écran filtré dont on a oublié le filtre est déroutant. On ne garde que
  // ce qu'on quitte en se disant « j'y reviens ».
  static const _cleVitrine = 'bandeau_vitrine';
  static const _cleDernierePhoto = 'derniere_photo';
  static const _cleCristauxOuverts = 'cristaux_ouverts';

  /// La bannière affichée sur le dex : rang du dex, ou vitrine.
  bool bandeauVitrine = false;

  /// La capture ouverte en dernier dans la galerie, pour y revenir. Null quand
  /// on n'a rien ouvert, ou quand la photo a disparu depuis.
  int? dernierePhoto;

  /// L'animation de lancer pendant l'analyse. Elle occupe les quinze secondes
  /// d'attente ; certains préfèrent voir la photo sans rien dessus.
  bool animationCapture = true;

  /// Les confettis de découverte.
  bool confettis = true;

  /// Les cases du dex montrent la photo entière plutôt que l'animal détouré.
  ///
  /// Le détourage donne une planche d'autocollants, très lisible tant qu'il
  /// réussit ; il rate sur les plantes, les insectes posés et tout ce qui se
  /// confond avec son fond. Le choix reste au joueur, case par case s'il veut
  /// (cf. `cadrage`), et ici pour tout le dex d'un coup.
  bool casesEntieres = false;

  /// Le thème voulu, par sa clé : `systeme`, ou l'une de celles de `THEMES`.
  ///
  /// « Système » par défaut : c'est le seul réglage qui n'oblige à rien, et
  /// quelqu'un qui a mis son téléphone en sombre pour la nuit ne veut pas
  /// qu'une application lui brûle les yeux.
  String theme = 'systeme';

  /// Le décor animé derrière les écrans, pour les thèmes qui en ont un.
  bool decorAnime = true;

  /// La langue : `auto` (celle du téléphone), ou un code de `I18n.langues`.
  String langue = 'auto';

  /// La date qu'affiche une notification : celle où la photo a été prise
  /// plutôt que celle de sa publication. Les deux répondent à une question
  /// différente — « c'était quand, cette sortie » contre « qu'est-ce qui est
  /// arrivé récemment » — d'où le réglage plutôt qu'un choix imposé.
  bool dateNotifsSelonPrise = false;

  /// Les succès dont on a déjà brisé le cristal.
  ///
  /// L'animation est une révélation : elle ne vaut que la première fois. La
  /// rejouer à chaque ouverture de la fiche la transformerait en péage, et il
  /// faudrait attendre trois secondes pour relire une condition qu'on connaît.
  ///
  /// Retenu sur l'appareil et non sur le serveur : c'est un souvenir
  /// d'affichage, pas un fait de jeu. Le serveur n'a pas à savoir ce qu'on a
  /// regardé, et cette liste peut se perdre sans dommage — on reverrait
  /// simplement une belle animation.
  Set<String> cristauxOuverts = {};

  Future<void> charge() async {
    final p = await SharedPreferences.getInstance();
    animationCapture = p.getBool(_cleAnimation) ?? true;
    confettis = p.getBool(_cleConfettis) ?? true;
    casesEntieres = p.getBool(_cleCasesEntieres) ?? false;
    bandeauVitrine = p.getBool(_cleVitrine) ?? false;
    dernierePhoto = p.getInt(_cleDernierePhoto);
    cristauxOuverts = (p.getStringList(_cleCristauxOuverts) ?? []).toSet();
    dateNotifsSelonPrise = p.getBool(_cleDateNotifs) ?? false;
    theme = p.getString(_cleTheme) ?? 'systeme';
    decorAnime = p.getBool(_cleDecorAnime) ?? true;
    langue = p.getString(_cleLangue) ?? 'auto';
    await I18n.charge(langue);
    notifyListeners();
  }

  Future<void> changeLangue(String valeur) async {
    langue = valeur;
    await I18n.charge(valeur);
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_cleLangue, valeur);
  }

  Future<void> changeDecorAnime(bool valeur) async {
    decorAnime = valeur;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_cleDecorAnime, valeur);
  }

  Future<void> changeTheme(String valeur) async {
    theme = valeur;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_cleTheme, valeur);
  }

  Future<void> retiensBandeauVitrine(bool valeur) async {
    bandeauVitrine = valeur;
    // Pas de `notifyListeners` : l'écran qui appelle vient déjà de se
    // reconstruire, et prévenir tout le monde ferait clignoter le thème.
    final p = await SharedPreferences.getInstance();
    await p.setBool(_cleVitrine, valeur);
  }

  Future<void> retiensPhoto(int? capture) async {
    dernierePhoto = capture;
    final p = await SharedPreferences.getInstance();
    if (capture == null) {
      await p.remove(_cleDernierePhoto);
    } else {
      await p.setInt(_cleDernierePhoto, capture);
    }
  }

  Future<void> retiensCristalOuvert(String cle) async {
    if (!cristauxOuverts.add(cle)) return;
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_cleCristauxOuverts, cristauxOuverts.toList());
  }

  Future<void> changeCasesEntieres(bool valeur) async {
    casesEntieres = valeur;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_cleCasesEntieres, valeur);
  }

  Future<void> changeAnimation(bool valeur) async {
    animationCapture = valeur;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_cleAnimation, valeur);
  }

  Future<void> changeConfettis(bool valeur) async {
    confettis = valeur;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_cleConfettis, valeur);
  }

  Future<void> changeDateNotifsSelonPrise(bool valeur) async {
    dateNotifsSelonPrise = valeur;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_cleDateNotifs, valeur);
  }
}
