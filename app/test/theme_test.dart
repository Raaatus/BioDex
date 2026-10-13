import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:biodex/theme.dart';
import 'package:biodex/widgets/fond_anime.dart';

/// La palette repose sur une variable globale — [Palette.jeu] — que `theme()`
/// écrase en se construisant. C'est efficace et fragile : ces vérifications
/// tiennent la fragilité en laisse, et passent chaque thème au même crible.
/// Elles ne jugent pas du goût des couleurs, seulement de leur lisibilité.
void main() {
  setUp(() => Palette.jeu = themes.first);

  test('la palette suit le jeu de couleurs', () {
    final fondClair = Palette.fond;
    Palette.jeu = themeParCle('sombre');
    expect(Palette.fond, isNot(fondClair));
    expect(Palette.sombre, isTrue);
    Palette.jeu = themeParCle('clair');
    expect(Palette.fond, fondClair);
  });

  test('une clé inconnue retombe sur le clair', () {
    expect(themeParCle('n_existe_pas').cle, 'clair');
  });

  test('chaque thème est lisible : texte sur fond, contenu sur accent', () {
    for (final jeu in themes) {
      Palette.jeu = jeu;
      // Un texte de la même luminosité que son fond est un texte invisible.
      expect(
        ThemeData.estimateBrightnessForColor(Palette.texte),
        isNot(ThemeData.estimateBrightnessForColor(Palette.fond)),
        reason: 'texte illisible en thème ${jeu.cle}',
      );
      expect(
        ThemeData.estimateBrightnessForColor(Palette.surAccent),
        isNot(ThemeData.estimateBrightnessForColor(Palette.accent)),
        reason: 'contenu illisible sur l\'accent en thème ${jeu.cle}',
      );
      expect(ThemeData.estimateBrightnessForColor(jeu.fond),
          jeu.sombre ? Brightness.dark : Brightness.light,
          reason: 'le thème ${jeu.cle} se dit ${jeu.sombre ? 'sombre' : 'clair'}');
    }
  });

  test('les qualités ne bougent pas avec le thème', () {
    // Ce sont des repères de jeu, pas des couleurs d'interface.
    Palette.jeu = themeParCle('clair');
    final claires = [for (var i = 1; i <= 5; i++) Palette.qualite(i)];
    Palette.jeu = themeParCle('hacker');
    expect([for (var i = 1; i <= 5; i++) Palette.qualite(i)], claires);
  });

  test('construire un thème pose la palette dessus', () {
    theme(themeParCle('abysses'));
    expect(Palette.jeu.cle, 'abysses');
    theme(themeParCle('clair'));
    expect(Palette.jeu.cle, 'clair');
  });

  testWidgets('décor figé quand le réglage est éteint', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: FondAnime(effet: 'etoiles', anime: false)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final etat = tester.state(find.byType(FondAnime)) as dynamic;
    expect(etat.temps, 40);
  });

  testWidgets('chaque thème se monte sans erreur, décor compris', (tester) async {
    for (final jeu in themes) {
      await tester.pumpWidget(MaterialApp(
        theme: theme(jeu),
        builder: (context, enfant) => jeu.fondAnime == null
            ? enfant!
            : Stack(children: [
                Positioned.fill(child: FondAnime(key: ValueKey(jeu.fondAnime), effet: jeu.fondAnime!)),
                enfant!,
              ]),
        home: Scaffold(
          appBar: AppBar(title: const Text('Essai')),
          body: Column(children: [
            const Text('Texte'),
            FilledButton(onPressed: () {}, child: const Text('Bouton')),
            const TextField(),
          ]),
        ),
      ));
      // Quelques images : le décor doit peindre sans lever, et avancer.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull, reason: 'le thème ${jeu.cle} ne doit pas lever');
      if (jeu.fondAnime != null) {
        final etat = tester.state(find.byType(FondAnime)) as dynamic;
        expect(etat.temps, greaterThan(3),
            reason: 'le décor ${jeu.fondAnime} doit avancer d\'une image à l\'autre');
      }
    }
  });
}
