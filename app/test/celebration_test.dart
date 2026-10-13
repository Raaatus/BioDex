import 'package:biodex/theme.dart';
import 'package:biodex/widgets/celebration.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// L'animation ne se juge qu'à l'œil, sur un téléphone. Ce que ces tests
/// garantissent, c'est qu'elle se joue par-dessus la page sans la remplacer,
/// que la couche de confettis a bien une surface où dessiner, et qu'elle
/// n'intercepte pas les appuis destinés au contenu.
void main() {
  testWidgets('les réglages suivent la qualité', (t) async {
    final commun = ReglageFete.pour(1);
    final legendaire = ReglageFete.pour(5);

    expect(commun.explosion, isFalse);
    expect(legendaire.explosion, isTrue);
    expect(legendaire.eclat, isTrue);
    expect(legendaire.nombre, greaterThan(100));

    // Les paliers discrets compensent leur petit nombre par de plus gros
    // confettis : sans ça, trois miettes rapides ne se voient pas.
    expect(commun.calibre, greaterThan(legendaire.calibre));
    expect(commun.vitesse, lessThan(legendaire.vitesse));

    // La montée en puissance ne se lit pas dans le nombre brut : une pluie
    // garde une réserve hors cadre, une explosion met tout à l'écran d'un
    // coup. Ce qui doit croître, c'est ce qu'on voit et la vivacité.
    var vitesse = 0.0;
    for (var q = 1; q <= 5; q++) {
      final r = ReglageFete.pour(q);
      expect(r.nombre, greaterThan(50), reason: 'assez pour se voir');
      expect(r.vitesse, greaterThan(vitesse));
      expect(r.couleurs, isNotEmpty);
      vitesse = r.vitesse;
    }
    // Les deux paliers du haut passent en explosion, les autres en pluie.
    for (final q in [1, 2, 3]) {
      expect(ReglageFete.pour(q).explosion, isFalse);
    }
    for (final q in [4, 5]) {
      expect(ReglageFete.pour(q).explosion, isTrue);
    }
  });

  for (final qualite in [1, 3, 5]) {
    testWidgets('la fête de qualité $qualite se joue sur la page', (t) async {
      final cle = GlobalKey<ZoneCelebrationState>();
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ZoneCelebration(
            key: cle,
            enfant: const Center(child: Text('contenu de la page')),
          ),
        ),
      ));

      // Rien ne se dessine tant qu'on n'a rien fêté.
      expect(find.byType(CustomPaint).evaluate().length, lessThan(3));

      cle.currentState!.fete(qualite);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      // La page reste visible : la fête ne la remplace pas.
      expect(find.text('contenu de la page'), findsOneWidget);

      // La couche de confettis existe et couvre bien une surface : un
      // CustomPaint de taille nulle ne dessinerait rien du tout.
      final couche = find.descendant(
        of: find.byType(IgnorePointer),
        matching: find.byType(CustomPaint),
      );
      expect(couche, findsOneWidget);
      final taille = t.getSize(couche.first);
      expect(taille.width, greaterThan(0));
      expect(taille.height, greaterThan(0));

      // Une fois l'animation finie, la couche disparaît.
      await t.pump(const Duration(seconds: 8));
      expect(find.descendant(
        of: find.byType(IgnorePointer),
        matching: find.byType(CustomPaint),
      ), findsNothing);
    });
  }

  // Le défaut qui a fait passer l'animation pour cassée : elle tournait, mais
  // les confettis n'étaient pas encore entrés dans le champ. Rien ne se voyait
  // pendant la première seconde, ce qui revient à ne rien jouer du tout.
  for (final qualite in [1, 2, 3, 4, 5]) {
    testWidgets('la qualité $qualite se voit dès la première image', (t) async {
      final cle = GlobalKey<ZoneCelebrationState>();
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ZoneCelebration(key: cle, enfant: const SizedBox.expand()),
        ),
      ));

      cle.currentState!.fete(qualite);
      await t.pump();

      // Un seuil absolu, pas une fraction du total : pour les pluies, une
      // grande part des confettis attend volontairement au-dessus du cadre.
      // Ce qui compte est le nombre qu'on voit à l'instant t.
      expect(cle.currentState!.particulesDansLeChamp, greaterThanOrEqualTo(25),
          reason: 'il doit y avoir de quoi regarder dès la première image');

      // …et surtout, il en reste tout du long. Une animation qui démarre bien
      // puis se vide en une seconde donne l'impression de n'avoir rien joué.
      // On avance image par image : sauter le temps d'un bloc bornerait le pas
      // d'intégration et fausserait la mesure.
      for (final seconde in [1, 2, 3, 4]) {
        for (var i = 0; i < 60; i++) {
          await t.pump(const Duration(milliseconds: 16));
        }
        expect(cle.currentState!.particulesDansLeChamp, greaterThanOrEqualTo(25),
            reason: 'à $seconde s, il ne reste presque plus rien à regarder');
      }
      await t.pump(const Duration(seconds: 4));
    });
  }

  testWidgets('la fête dure plusieurs secondes', (t) async {
    final cle = GlobalKey<ZoneCelebrationState>();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: ZoneCelebration(key: cle, enfant: const SizedBox.expand())),
    ));

    cle.currentState!.fete(3);
    await t.pump();

    // Toujours en cours à quatre secondes… en avançant image par image,
    // puisque l'animation suit désormais l'horloge réelle.
    for (var i = 0; i < 250; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(find.descendant(
      of: find.byType(IgnorePointer),
      matching: find.byType(CustomPaint),
    ), findsOneWidget, reason: 'quatre secondes, c\'est le minimum attendu');

    // …et terminée ensuite, sans laisser la couche traîner.
    for (var i = 0; i < 200; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(find.descendant(
      of: find.byType(IgnorePointer),
      matching: find.byType(CustomPaint),
    ), findsNothing);
  });

  testWidgets('les confettis n\'avalent pas les appuis', (t) async {
    final cle = GlobalKey<ZoneCelebrationState>();
    var appuis = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ZoneCelebration(
          key: cle,
          enfant: Center(
            child: ElevatedButton(
                onPressed: () => appuis++, child: const Text('appuyer')),
          ),
        ),
      ),
    ));

    cle.currentState!.fete(5);
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));

    await t.tap(find.text('appuyer'));
    expect(appuis, 1, reason: 'la couche de confettis doit laisser passer');
    await t.pump(const Duration(seconds: 8));
  });

  testWidgets('le compteur de points s\'égrène jusqu\'au total', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: GainPoints(points: 150, qualite: 5))),
    ));

    await t.pump();
    expect(find.text('+0 points'), findsOneWidget);
    expect(find.text('LÉGENDAIRE'), findsOneWidget);

    // Le compteur démarre après un court délai, puis monte jusqu'au total.
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 1600));
    expect(find.text('+150 points'), findsOneWidget);
  });

  test('chaque qualité a sa couleur', () {
    final vues = <Color>{};
    for (var q = 1; q <= 5; q++) {
      vues.add(Palette.qualite(q));
    }
    expect(vues.length, 5, reason: 'deux qualités ne doivent pas se confondre');
  });
}
