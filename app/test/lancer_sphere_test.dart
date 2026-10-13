import 'package:biodex/widgets/lancer_sphere.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Le défaut de la première version : la sphère ne partait qu'à l'arrivée du
/// verdict, si bien que le lancer — ce qu'on attend — passait en quelques
/// images à la toute fin. Ces tests mesurent le temps où elle est réellement
/// à l'écran, et vérifient que l'attente ne se termine jamais toute seule.
void main() {
  testWidgets('le lancer occupe près d\'une seconde', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 260,
          child: LancerSphere(etat: EtatCapture.attente, couleur: Colors.green),
        ),
      ),
    ));

    // Visée jusqu'à 0,91 s ; vol de 0,91 s à 2,16 s ; impact ensuite.
    var imagesDeVol = 0;
    for (var ms = 0; ms < 2400; ms += 16) {
      await t.pump(const Duration(milliseconds: 16));
      if (ms >= 912 && ms < 2160) imagesDeVol++;
    }
    expect(imagesDeVol, greaterThan(65),
        reason: 'le vol doit durer, pas passer en quatre images');
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('les secousses attendent le verdict sans fin', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: LancerSphere(etat: EtatCapture.attente, couleur: Colors.green),
      ),
    ));
    // Bien après la fin du lancer, l'animation tient toujours l'écran :
    // l'analyse dure une quinzaine de secondes.
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(find.byType(LancerSphere), findsOneWidget);
  });

  for (final (etat, nom) in [
    (EtatCapture.reussi, 'réussie'),
    (EtatCapture.manque, 'manquée'),
  ]) {
    testWidgets('une capture $nom rend la main', (t) async {
      var fini = false;
      Widget page(EtatCapture e) => MaterialApp(
            home: Scaffold(
              body: LancerSphere(
                  etat: e, couleur: Colors.amber, surFin: () => fini = true),
              ),
          );
      // L'animation suit l'horloge réelle : elle n'avance qu'aux images
      // effectivement rendues, comme sur un écran.
      Future<void> avance(int ms) async {
        for (var i = 0; i < ms ~/ 16; i++) {
          await t.pump(const Duration(milliseconds: 16));
        }
      }

      await t.pumpWidget(page(EtatCapture.attente));
      await avance(2500);                                 // visée + lancer
      await avance(2000);                                 // secousses
      expect(fini, isFalse, reason: 'le moteur travaille encore');

      await t.pumpWidget(page(etat));
      await avance(1700);
      expect(fini, isTrue,
          reason: 'sans rappel, l\'animation resterait sur la photo');
    });
  }

  testWidgets('un verdict très rapide n\'escamote pas le lancer', (t) async {
    var fini = false;
    Widget page(EtatCapture e) => MaterialApp(
          home: Scaffold(
            body: LancerSphere(
                etat: e, couleur: Colors.amber, surFin: () => fini = true),
          ),
        );
    Future<void> avance(int ms) async {
      for (var i = 0; i < ms ~/ 16; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
    }

    await t.pumpWidget(page(EtatCapture.attente));
    await avance(200);
    // Le verdict tombe pendant la visée : la sphère part quand même, puis
    // l'issue s'enchaîne — on ne saute jamais le lancer.
    await t.pumpWidget(page(EtatCapture.reussi));
    await avance(900);
    expect(fini, isFalse, reason: 'le lancer doit se jouer d\'abord');
    await avance(4200);
    expect(fini, isTrue);
  });
}
