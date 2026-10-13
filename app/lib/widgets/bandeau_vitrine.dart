import 'package:flutter/material.dart';
import '../i18n.dart';

import '../modeles.dart';
import '../theme.dart';
import 'badge_palier.dart';
import 'tourneur.dart';

/// La bannière de la vitrine, jumelle de celle du rang.
///
/// Elle occupe la même place et la même hauteur : la bascule d'une bannière à
/// l'autre ne doit pas faire sauter tout ce qui est en dessous.
///
/// Ce qu'elle dit est différent, et c'est le but. Le rang du dex compte des
/// espèces ; la vitrine ne regarde que les dix meilleures. Un joueur à deux
/// cents banalités monte au dex et stagne ici — c'est exactement le genre de
/// chose qu'on veut pouvoir se dire entre amis.
class BandeauVitrine extends StatelessWidget {
  const BandeauVitrine({
    super.key,
    required this.vitrine,
    required this.surAppui,
    this.surBascule,
  });

  final Vitrine vitrine;
  final VoidCallback surAppui;

  /// Non nul : pose la pastille qui ramène au rang du dex.
  final VoidCallback? surBascule;

  @override
  Widget build(BuildContext context) {
    final r = vitrine.rang;
    // La part parcourue dans le palier courant, pas depuis zéro : sinon la
    // barre est déjà pleine aux trois quarts dès le premier rang et ne bouge
    // plus visiblement.
    final part = r.objectif != null && r.objectif! > r.depuis
        ? ((vitrine.score - r.depuis) / (r.objectif! - r.depuis)).clamp(0.0, 1.0)
        : 1.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: surAppui,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
          decoration: BoxDecoration(
            color: Palette.fondSecondaire,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(children: [
            Stack(clipBehavior: Clip.none, children: [
              _piece(),
              if (surBascule != null)
                BasculeBandeau(surVitrine: true, surBascule: surBascule!),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(r.nom,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16.5, fontWeight: FontWeight.w800)),
                    ),
                    const SizedBox(width: 6),
                    Text('#${r.numero}/${r.total}',
                        style:
                            TextStyle(fontSize: 11, color: Palette.texteDoux)),
                  ]),
                  Row(children: [
                    Icon(Icons.workspace_premium_outlined,
                        size: 12, color: Palette.texteDoux),
                    const SizedBox(width: 4),
                    Text(T('{0} pts de vitrine', [vitrine.score]),
                        style: TextStyle(
                            fontSize: 12,
                            color: Palette.texteDoux,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 10),
                    Text(
                        T('{0}/{1} pièce{2}', [vitrine.pieces.length, vitrine.taille, vitrine.pieces.length > 1 ? 's' : '']),
                        style: TextStyle(
                            fontSize: 12, color: Palette.texteDoux)),
                  ]),
                  if (r.suivant != null) ...[
                    const SizedBox(height: 7),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: part,
                        minHeight: 6,
                        backgroundColor: Palette.caseVide,
                        valueColor:
                            const AlwaysStoppedAnimation(Color(0xFF9B6BDF)),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(T('Encore {0} pts avant {1}', [r.reste, r.suivant]),
                        style: TextStyle(
                            fontSize: 11, color: Palette.texteDoux)),
                  ],
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// L'aperçu de la pièce, à la place qu'occupe l'écusson du rang.
  ///
  /// Le modèle lui-même, pas une icône : c'est ce qu'on a gagné, autant le
  /// voir. Mais pas de `model-viewer` ici — il embarque une WebView entière, et
  /// en poser une dans un bandeau qui défile coûterait très cher pour
  /// cinquante-six pixels. On dessine des images rendues à l'avance.
  ///
  /// Noir tant que la vitrine est vide : la silhouette dit qu'il y a quelque
  /// chose à gagner sans le montrer.
  Widget _piece() => Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFF9B6BDF).withValues(alpha: .14),
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child: Tourneur(
          planche: 'assets/modeles/grenouille_tour.webp',
          taille: 56,
          noir: vitrine.pieces.isEmpty,
        ),
      );
}
