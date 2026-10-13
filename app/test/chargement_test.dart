import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:biodex/widgets/chargement.dart';

/// L'attente s'affiche dans vingt écrans : une erreur ici se voit partout.
///
/// Ces tests existent surtout à cause d'un vrai incident. L'animation était un
/// GIF, elle ne tournait pas dans l'application, et **aucun test ne pouvait le
/// dire** : le harnais ne décode pas les images animées, donc tout passait au
/// vert pendant que l'écran affichait une image figée. Le sujet est maintenant
/// dessiné image par image depuis une planche de tuiles, ce qui rend la
/// rotation observable.
void main() {
  /// L'indice de tuile réellement dessiné, lu sur le peintre.
  int? imageAffichee(WidgetTester t) {
    final peint = t.widget<CustomPaint>(find.descendant(
      of: find.byType(Pastille),
      matching: find.byType(CustomPaint),
    ));
    return (peint.painter as dynamic)?.image as int?;
  }

  testWidgets('le sujet tourne : l\'image change avec le temps', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Chargement()),
    ));
    await t.pump();
    final depart = imageAffichee(t);
    expect(depart, isNotNull);

    // Un tiers de tour : l'indice doit avoir bougé. C'est exactement ce que le
    // GIF ne faisait pas.
    await t.pump(Pastille.tour ~/ 3);
    expect(imageAffichee(t), isNot(depart),
        reason: 'le sujet doit avoir pivoté après un tiers de tour');

    // Et il repasse par le début : la boucle boucle.
    await t.pump(Pastille.tour);
    expect(imageAffichee(t), isNotNull);
  });

  testWidgets('l\'indice reste dans la planche', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Chargement()),
    ));
    await t.pump();
    // Plusieurs tours d'affilée : un modulo mal posé sortirait de la planche
    // et dessinerait du vide.
    for (var i = 0; i < 12; i++) {
      await t.pump(Pastille.tour ~/ 5);
      final n = imageAffichee(t)!;
      expect(n, inInclusiveRange(0, Pastille.images - 1));
    }
  });

  testWidgets('le message ne s\'affiche que s\'il y en a un', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Chargement()),
    ));
    await t.pump();
    expect(find.byType(Text), findsNothing);

    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Chargement(message: 'On cherche la bête…')),
    ));
    await t.pump();
    expect(find.text('On cherche la bête…'), findsOneWidget);
  });

  testWidgets('la taille demandée est respectée', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Chargement(taille: 64)),
    ));
    await t.pump();
    final boite = t.widget<SizedBox>(find.descendant(
      of: find.byType(Pastille),
      matching: find.byType(SizedBox),
    ));
    expect(boite.width, 64);
    expect(boite.height, 64);
  });

  testWidgets('le petit format reste un cercle', (t) async {
    // À vingt pixels le personnage n'est plus qu'une tache : le cercle est le
    // seul qui reste lisible, et ce test empêche qu'on « harmonise » un jour
    // les deux sans regarder le résultat.
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: PetitChargement()),
    ));
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Pastille), findsNothing);
  });

  testWidgets('l\'anneau se coupe quand on le demande', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Pastille(anneau: false)),
    ));
    await t.pump();
    final peint = t.widget<CustomPaint>(find.descendant(
      of: find.byType(Pastille),
      matching: find.byType(CustomPaint),
    ));
    expect((peint.painter as dynamic).anneau, isNull);
  });
}
