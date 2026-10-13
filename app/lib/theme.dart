import 'package:flutter/material.dart';

import 'i18n.dart';
import 'themes.dart';

export 'themes.dart';

/// Palette et thème.
///
/// Sobre par principe : dans une grille de plusieurs centaines de cases, la
/// couleur doit venir des animaux trouvés, pas du décor. Les seules couleurs
/// franches sont celles des qualités, justement pour qu'une belle prise saute
/// aux yeux au milieu du tout-venant.
///
/// ## Pourquoi des accesseurs plutôt que des constantes
///
/// Les teintes de fond et de texte étaient des `const`, ce qui rendait un
/// thème sombre impossible : une constante ne change pas d'avis. On aurait pu
/// tout passer par `Theme.of(context)`, mais cela demandait de toucher trois
/// cent quarante endroits et d'avoir un `context` sous la main partout — y
/// compris dans des peintres et des fonctions utilitaires qui n'en ont pas.
///
/// Ces accesseurs lisent [sombre], que l'application pose au démarrage et à
/// chaque bascule. Le prix à payer est qu'ils ne sont plus utilisables dans un
/// contexte `const` ; c'est le seul, et il est mécanique.
class Palette {
  /// Le jeu de couleurs en vigueur.
  ///
  /// Posé par l'application avant le premier rendu, et à chaque changement de
  /// thème. Une variable globale se défend mal d'ordinaire ; ici elle décrit
  /// une propriété qui *est* globale — il n'y a qu'un thème à la fois — et la
  /// remplacer par un héritage de contexte coûterait bien plus qu'elle ne
  /// rapporte.
  static JeuDeCouleurs jeu = themes.first;

  /// Vrai quand le thème part du sombre.
  static bool get sombre => jeu.sombre;

  /// Le fond principal des écrans.
  static Color get fond => jeu.fond;

  /// Le fond des cartes et des champs : un cran détaché du fond principal.
  static Color get fondSecondaire => jeu.fondSecondaire;

  /// Le gris des cases vides et de leur silhouette.
  static Color get caseVide => jeu.caseVide;
  static Color get silhouette => jeu.silhouette;
  static Color get bordureTrouvee => jeu.bordure;

  static Color get texte => jeu.texte;
  static Color get texteDoux => jeu.texteDoux;

  static Color get accent => jeu.accent;
  static Color get accentSombre => jeu.accentSombre;
  static Color get alerte => jeu.alerte;

  /// Ce qu'on écrit ou dessine **sur** l'accent.
  static Color get surAccent => jeu.surAccent;

  /// Le fond des barres — en-tête, barre du bas, en-tête du dex.
  ///
  /// Opaque d'ordinaire. Sur un thème à décor animé, transparente : une barre
  /// pleine faisait un bloc noir en haut de l'écran, tranché net sur le décor
  /// qui bougeait dessous.
  static Color get barre =>
      jeu.fondAnime == null ? jeu.fond : Colors.transparent;

  /// Les cinq qualités. Le dégradé gris → vert → bleu → violet → or est celui
  /// que tout joueur reconnaît d'instinct, et il se lit même en petit.
  ///
  /// Elles ne changent pas avec le thème : ce sont des repères de jeu, pas des
  /// couleurs d'interface. Un joueur qui bascule en sombre ne doit pas avoir à
  /// réapprendre ce que « violet » veut dire.
  static const qualites = <int, Color>{
    1: Color(0xFF9AA1AC),   // commun
    2: Color(0xFF3FAE5A),   // basique
    3: Color(0xFF3B82F6),   // peu commun
    4: Color(0xFF9B51E0),   // rare
    5: Color(0xFFE8A317),   // légendaire
  };

  static const nomsQualite = <int, String>{
    1: 'Commun',
    2: 'Basique',
    3: 'Peu commun',
    4: 'Rare',
    5: 'Légendaire',
  };

  static Color qualite(int niveau) => qualites[niveau] ?? qualites[2]!;
  static String nomQualite(int niveau) => T(nomsQualite[niveau] ?? '');
}

/// Le thème Material construit sur un jeu de couleurs.
///
/// Tous les thèmes partagent leur construction : ce qui les sépare tient dans
/// la [Palette], et écrire dix-sept fois les mêmes rayons et les mêmes
/// graisses aurait garanti qu'ils divergent au premier ajustement.
ThemeData theme(JeuDeCouleurs jeu) {
  // La palette est lue pendant la construction : on la règle d'abord.
  Palette.jeu = jeu;
  final sombre = jeu.sombre;

  final base = ThemeData(
    useMaterial3: true,
    brightness: sombre ? Brightness.dark : Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Palette.accent,
      brightness: sombre ? Brightness.dark : Brightness.light,
      surface: Palette.fond,
    ),
    // Un fond animé derrière : les écrans deviennent transparents pour le
    // laisser voir. Chaque surface garde son fond opaque.
    scaffoldBackgroundColor: jeu.fondAnime != null ? Colors.transparent : Palette.fond,
    fontFamily: jeu.police,
  );
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: Palette.barre,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: Palette.texte,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
      iconTheme: IconThemeData(color: Palette.texte),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: Palette.texte,
      displayColor: Palette.texte,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.fondSecondaire,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Palette.accent,
        foregroundColor: Palette.surAccent,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    // Les feuilles et les menus suivent le fond, sinon ils restent blancs sur
    // un écran sombre.
    dialogTheme: DialogThemeData(backgroundColor: Palette.fond),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: Palette.fond),
    popupMenuTheme: PopupMenuThemeData(color: Palette.fond),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Palette.barre,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Palette.accent.withValues(alpha: .14),
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: Palette.accent),
  );
}
