import 'package:flutter/material.dart';
import '../i18n.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Les trois règnes du dex, et ce qui les distingue à l'écran.
///
/// Le règne n'est pas deviné à partir de l'image : le joueur le déclare. Faire
/// tourner les trois chaînes d'analyse sur chaque photo coûterait trois fois le
/// temps pour une information qu'il connaît déjà en cadrant.
class Regne {
  const Regne(this.cle, this.nom, this.emoji, this.couleur, this.quoi);

  final String cle;
  final String nom;
  final String emoji;
  final Color couleur;

  /// Ce qu'on identifie, dit en trois mots.
  final String quoi;

  static const animal = Regne('animal', 'Animal', '🐾',
      Color(0xFF0EA5A4), 'oiseau, insecte, mammifère…');
  static const plante = Regne('plante', 'Plante', '🌿',
      Color(0xFF22A34B), 'fleur, arbre, herbe…');
  static const champignon = Regne('champignon', 'Champignon', '🍄',
      Color(0xFFE08A0B), 'chapeau, lichen, moisissure…');

  /// Les poissons ne forment pas un règne : ce sont des animaux, et leur case
  /// est une case animale — le poisson-clown existe déjà au dex. Cette carte
  /// n'ouvre pas un dex parallèle, elle change de moteur : le catalogue passe
  /// de 411 743 espèces à 22 766, ce qui écarte les insectes et les oiseaux
  /// qui pouvaient l'emporter sur un reflet derrière une vitre.
  static const aquatique = Regne('aquatique', 'Aquatique', '🐟',
      Color(0xFF2E86DE), 'poisson d\'eau douce ou de mer…');

  static const tous = [animal, plante, champignon, aquatique];

  static Regne de(String cle) =>
      tous.firstWhere((r) => r.cle == cle, orElse: () => animal);
}

/// Le choix du règne, en trois cartes.
///
/// Posé sous la photo plutôt que dans une boîte de dialogue : le joueur voit ce
/// qu'il vient de cadrer pendant qu'il choisit, et rien ne lui coupe la route
/// s'il veut reprendre la photo.
class ChoixRegne extends StatelessWidget {
  const ChoixRegne({super.key, required this.choisi, required this.surChoix});

  final String? choisi;
  final ValueChanged<Regne> surChoix;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(T('C\'est quoi ?'),
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(T('Chaque règne a son spécialiste.'),
            style: TextStyle(fontSize: 12, color: Palette.texteDoux)),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final r in Regne.tous) ...[
              Expanded(child: _carte(context, r)),
              if (r != Regne.tous.last) const SizedBox(width: 10),
            ],
          ],
        ),
      ],
    );
  }

  Widget _carte(BuildContext context, Regne r) {
    final actif = choisi == r.cle;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        HapticFeedback.selectionClick();
        surChoix(r);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        // Quatre cartes au lieu de trois : chacune perd un quart de sa largeur,
        // et « Champignon » ne tient plus. On rogne la marge intérieure ; le
        // texte, lui, se réduit plutôt que de se faire couper (voir plus bas).
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
        decoration: BoxDecoration(
          color: actif
              ? r.couleur.withValues(alpha: .12)
              : Palette.fondSecondaire,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: actif ? r.couleur : Colors.transparent,
            width: 1.6,
          ),
        ),
        child: Column(children: [
          Text(r.emoji, style: const TextStyle(fontSize: 26)),
          const SizedBox(height: 6),
          // `FittedBox` plutôt qu'`ellipsis` : « Champ… » ne dit rien à
          // personne, alors qu'un « Champignon » d'un point plus petit se lit
          // encore très bien. Le nom du règne est l'information, pas sa taille.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(r.nom,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: actif ? r.couleur : Palette.texte,
                )),
          ),
        ]),
      ),
    );
  }
}

/// La pastille qui rappelle le règne d'une case ou d'une photo.
class PastilleRegne extends StatelessWidget {
  const PastilleRegne({super.key, required this.regne, this.dense = false});

  final String regne;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final r = Regne.de(regne);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: dense ? 6 : 9, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(
        color: r.couleur.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(r.emoji, style: TextStyle(fontSize: dense ? 10 : 12)),
        SizedBox(width: dense ? 3 : 5),
        Text(r.nom,
            style: TextStyle(
                fontSize: dense ? 10 : 12,
                fontWeight: FontWeight.w700,
                color: r.couleur)),
      ]),
    );
  }
}

/// L'avertissement qui accompagne tout résultat de champignon.
///
/// Il ne s'affiche que pour ce règne, et jamais en pied de page : une mise en
/// garde qu'on ne lit qu'après avoir décidé ne sert à rien. Le ton est direct
/// parce que l'enjeu l'est : des espèces mortelles sont visuellement
/// indiscernables d'espèces comestibles, et aucun modèle d'image ne sait les
/// séparer de façon fiable.
class AvertissementChampignon extends StatelessWidget {
  const AvertissementChampignon({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      decoration: BoxDecoration(
        color: Palette.alerte.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Palette.alerte.withValues(alpha: .35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.warning_amber_rounded, size: 18, color: Palette.alerte),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            T('Fiable à 85 % environ. Jouer sa vie sur les 15 % restants serait stupide : ne mangez que ce que vous connaissez déjà. Ce résultat ne doit jamais servir à décider si un champignon se mange.'),
            style: TextStyle(
                fontSize: 11.5, height: 1.35, color: Color(0xFF8C2A2A)),
          ),
        ),
      ]),
    );
  }
}
