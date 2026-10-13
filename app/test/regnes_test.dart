import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:biodex/widgets/regnes.dart';

/// Le règne aquatique s'est ajouté aux trois autres. Ces tests tiennent surtout
/// à deux choses qu'on casse sans s'en apercevoir : le nom d'un règne qui se
/// fait tronquer sur un écran étroit, et l'idée fausse qu'un poisson serait
/// rangé ailleurs qu'avec les animaux.
void main() {
  testWidgets('les quatre règnes sont proposés', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChoixRegne(choisi: null, surChoix: (_) {}),
      ),
    ));
    for (final nom in ['Animal', 'Plante', 'Champignon', 'Aquatique']) {
      expect(find.text(nom), findsOneWidget, reason: '$nom doit être proposé');
    }
  });

  testWidgets('aucun nom n\'est tronqué sur un écran étroit', (t) async {
    // 320 points de large : le plus petit écran qu'on ait à supporter. C'est là
    // que la quatrième carte fait mal — chacune n'a plus que 74 points.
    t.view.physicalSize = const Size(320, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);

    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: ChoixRegne(choisi: null, surChoix: (_) {})),
    ));
    await t.pumpAndSettle();

    for (final nom in ['Animal', 'Plante', 'Champignon', 'Aquatique']) {
      final w = t.widget<Text>(find.text(nom));
      expect(w.overflow, isNot(TextOverflow.ellipsis),
          reason: '$nom doit se réduire, pas se faire couper');
    }
    // Un débordement de mise en page lève une exception que le harnais met de
    // côté au lieu de la propager. Si elle est là, les cartes ne tiennent pas.
    expect(t.takeException(), isNull,
        reason: 'les quatre cartes doivent tenir sur 320 points');
  });

  test('le choix renvoie bien la clé attendue', () {
    expect(Regne.de('aquatique').cle, 'aquatique');
    expect(Regne.de('aquatique').nom, 'Aquatique');
    // Une clé inconnue retombe sur animal plutôt que de faire planter l'écran.
    expect(Regne.de('poisson').cle, 'animal');
  });
}
