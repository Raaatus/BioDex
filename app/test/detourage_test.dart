import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:biodex/widgets/detourage.dart';

/// La géométrie du détourage au doigt.
///
/// Elle est vérifiée à part du widget qui la dessine, et ce n'est pas un
/// arrangement : les tests de widget ne savent pas décoder d'image — le
/// décodage est un vrai travail asynchrone, que l'horloge simulée des tests ne
/// fait jamais avancer, et l'écran resterait bloqué sur son indicateur de
/// chargement. Ce qui compte est de toute façon ici : passer du doigt à
/// l'image, refermer la forme, trouver sa boîte. Le reste est du dessin.
void main() {
  group('du doigt vers l\'image', () {
    // Une photo carrée dans une boîte plus large : des bandes à gauche et à
    // droite, qui n'appartiennent à rien.
    final cadre = Trace.cadreContain(const Size(100, 100), const Size(300, 100));

    test('la photo est centrée dans sa boîte', () {
      expect(cadre.width, 100);
      expect(cadre.height, 100);
      expect(cadre.left, 100, reason: 'centrée horizontalement');
      expect(cadre.top, 0);
    });

    test('le centre de la photo est le centre de l\'image', () {
      final p = Trace.versImage(cadre.center, cadre);
      expect(p!.dx, closeTo(0.5, 0.001));
      expect(p.dy, closeTo(0.5, 0.001));
    });

    test('un doigt dans les bandes latérales ne compte pas', () {
      // À gauche de la photo : c'est du fond noir, pas de l'image.
      expect(Trace.versImage(const Offset(10, 50), cadre), isNull);
      expect(Trace.versImage(const Offset(290, 50), cadre), isNull);
    });

    test('un doigt qui frôle le bord est ramené dedans', () {
      // On entoure volontiers une bête qui touche le bord du cadre : deux
      // pixels dehors ne doivent pas interrompre le tracé.
      final p = Trace.versImage(Offset(cadre.left - 2, 50), cadre);
      expect(p, isNotNull);
      expect(p!.dx, 0, reason: 'ramené sur le bord, pas rejeté');
    });

    test('une photo plus haute que large occupe toute la hauteur', () {
      final c = Trace.cadreContain(const Size(50, 100), const Size(200, 100));
      expect(c.height, 100);
      expect(c.width, 50);
      expect(c.left, 75);
    });
  });

  group('la forme tracée', () {
    /// Un cercle de rayon donné, centré, en fractions de l'image.
    List<Offset> cercle(double cx, double cy, double r, {int points = 24}) => [
          for (var i = 0; i < points; i++)
            Offset(cx + r * math.cos(i / points * 2 * math.pi),
                cy + r * math.sin(i / points * 2 * math.pi)),
        ];

    test('la boîte serre le tracé, à un pixel près', () {
      final trace = cercle(0.5, 0.5, 0.25);
      final b = Trace.boite(trace, 400, 400);
      // Un cercle de rayon 0,25 sur 400 pixels : de 100 à 300.
      expect(b.left, closeTo(99, 1.5));
      expect(b.top, closeTo(99, 1.5));
      expect(b.right, closeTo(301, 1.5));
      expect(b.bottom, closeTo(301, 1.5));
    });

    test('la boîte ne sort jamais de l\'image', () {
      // Un tracé qui déborde : la boîte doit rester dans le cadre, sinon le
      // rendu hors écran découperait dans le vide.
      final trace = cercle(0.05, 0.05, 0.2);
      final b = Trace.boite(trace, 400, 400);
      expect(b.left, greaterThanOrEqualTo(0));
      expect(b.top, greaterThanOrEqualTo(0));
      expect(b.right, lessThanOrEqualTo(400));
      expect(b.bottom, lessThanOrEqualTo(400));
    });

    test('la boîte est plus petite que l\'image : c\'est tout l\'intérêt', () {
      final b = Trace.boite(cercle(0.5, 0.5, 0.2), 400, 400);
      expect(b.width, lessThan(400));
      expect(b.height, lessThan(400));
    });

    test('le chemin se referme tout seul', () {
      // On ne demande pas au joueur de revenir exactement à son point de
      // départ, ce qu'aucun doigt ne réussit : un point du centre doit être
      // dedans même si le tracé s'arrête loin de son début.
      final ouvert = cercle(0.5, 0.5, 0.25).take(20).toList();
      final chemin = Trace.chemin(ouvert, 400, 400);
      expect(chemin.contains(const Offset(200, 200)), isTrue,
          reason: 'le centre doit être dans la forme');
      expect(chemin.contains(const Offset(5, 5)), isFalse,
          reason: 'le coin doit être dehors');
    });

    test('une boucle bouclée est reconnue fermée', () {
      // Le doigt revient près de son point de départ, sans l'atteindre
      // exactement — ce qu'aucun doigt ne réussit.
      final trace = cercle(0.5, 0.5, 0.25);
      expect(Trace.estFermee(trace), isTrue);
    });

    test('un demi-cercle est reconnu ouvert', () {
      // On s'arrête à mi-course : les deux bouts sont aux antipodes.
      final trace = cercle(0.5, 0.5, 0.25).take(12).toList();
      expect(Trace.estFermee(trace), isFalse,
          reason: 'la forme ne doit pas être déclarée fermée d\'office');
    });

    test('la fermeture se juge à l\'échelle du tracé', () {
      // Le même écart absolu ferme une grande forme et laisse ouverte une
      // petite : deux centimètres n'ont pas le même sens sur un cerf et sur
      // un escargot.
      final grand = cercle(0.5, 0.5, 0.4).take(23).toList();
      final petit = cercle(0.5, 0.5, 0.03).take(23).toList();
      expect(Trace.estFermee(grand), isTrue);
      expect(Trace.estFermee(petit), isTrue);
      // Un tracé qui s'arrête au quart reste ouvert quelle que soit sa taille.
      expect(Trace.estFermee(cercle(0.5, 0.5, 0.4).take(9).toList()), isFalse);
      expect(Trace.estFermee(cercle(0.5, 0.5, 0.03).take(9).toList()), isFalse);
    });

    test('on referme quand même pour découper', () {
      // L'écran montre la forme ouverte, mais découper demande un dedans :
      // `chemin` referme, et c'est de cela qu'on prévient le joueur.
      final ouvert = cercle(0.5, 0.5, 0.25).take(14).toList();
      expect(Trace.estFermee(ouvert), isFalse);
      expect(Trace.chemin(ouvert, 400, 400).contains(const Offset(200, 200)),
          isTrue);
      // `contains` referme implicitement pour calculer un remplissage : il ne
      // dit donc rien de la fermeture. On compare les longueurs — le chemin
      // fermé porte en plus le segment de retour.
      double longueur(Path c) =>
          c.computeMetrics().fold(0.0, (t, m) => t + m.length);
      expect(longueur(Trace.chemin(ouvert, 400, 400)),
          greaterThan(longueur(Trace.chemin(ouvert, 400, 400, ferme: false))),
          reason: 'la fermeture ajoute le segment de retour');
    });

    test('huit points au moins pour que ce soit une forme', () {
      // En deçà, c'est un doigt qui a glissé : l'écran efface le tracé plutôt
      // que de découper la photo en triangle.
      expect(Trace.minimum, greaterThanOrEqualTo(4));
    });
  });

  group('lumière et contraste', () {
    test('sans réglage, le filtre ne change rien', () {
      final f = Trace.filtre(luminosite: 1, contraste: 1);
      // L'identité : chaque canal se recopie, sans décalage.
      expect(f, ColorFilter.matrix(const [
        1, 0, 0, 0, 0,
        0, 1, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, 1, 0,
      ]));
    });

    test('deux réglages différents donnent deux filtres différents', () {
      expect(Trace.filtre(luminosite: 1.5, contraste: 1),
          isNot(Trace.filtre(luminosite: 1, contraste: 1)));
      expect(Trace.filtre(luminosite: 1, contraste: 1.5),
          isNot(Trace.filtre(luminosite: 1, contraste: 1)));
    });

    test('le contraste pivote autour du gris moyen', () {
      // Un contraste supérieur à 1 doit assombrir les tons sombres autant
      // qu'il éclaircit les clairs : le décalage doit donc être négatif.
      // Sans lui, monter le contraste blanchirait toute l'image.
      final f = Trace.filtre(luminosite: 1, contraste: 2);
      final identite = Trace.filtre(luminosite: 1, contraste: 1);
      expect(f, isNot(identite));
      // Le décalage vaut (1 - c) × 127,5 = -127,5 pour c = 2.
      expect((1 - 2) * 127.5, lessThan(0));
    });
  });
}
