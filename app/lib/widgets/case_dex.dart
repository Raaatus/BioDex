import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../api.dart';
import '../modeles.dart';
import '../reglages.dart';
import '../theme.dart';

/// Image du serveur, gardée en cache sur le téléphone.
///
/// Sans cache, la grille et surtout la carte retéléchargeaient les mêmes
/// vignettes à chaque défilement. `taille` demande au serveur une version
/// réduite : inutile de tirer une découpe de 512 pixels pour un marqueur qui en
/// fait cinquante.
class ImageServeur extends StatelessWidget {
  const ImageServeur({
    super.key,
    required this.chemin,
    this.fit = BoxFit.cover,
    this.taille,
    this.repli,
    this.largeur,
    this.hauteur,
    this.attente,
  });

  final String chemin;
  final BoxFit fit;

  /// Taille demandée au serveur, qui fabrique une version réduite une fois
  /// puis la sert du cache.
  final int? taille;
  final Widget? repli;

  /// Dimensions à l'écran. Séparées de `taille` : on peut vouloir une image
  /// serveur de 256 px affichée dans un carré de 62, sur un écran dense.
  final double? largeur;
  final double? hauteur;

  /// Ce qu'on montre pendant le téléchargement. Rien par défaut : un carré
  /// vide vaut mieux qu'un clignotement sur une grille qui défile.
  final Widget? attente;

  @override
  Widget build(BuildContext context) {
    final url = Api.instance
        .image(chemin, taille == null ? null : {'taille': taille})
        .toString();
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: Api.instance.entetes,
      fit: fit,
      width: largeur,
      height: hauteur,
      fadeInDuration: const Duration(milliseconds: 120),
      placeholder: (_, _) => attente ?? const SizedBox.shrink(),
      errorWidget: (_, _, _) =>
          repli ??
          Icon(Icons.broken_image_outlined, color: Palette.silhouette),
    );
  }
}

/// Une case de la grille.
///
/// Trois états d'un seul fichier : silhouette grise tant que l'espèce manque,
/// animal détouré une fois trouvée. La bordure porte la couleur de la qualité —
/// c'est elle qui fait qu'une prise rare se repère au milieu de la grille.
class CaseDexVignette extends StatelessWidget {
  const CaseDexVignette(
      {super.key, required this.item, this.onTap, this.compacte = false});

  final CaseDex item;
  final VoidCallback? onTap;

  /// Sans le nom sous la case : pour les listes, où le nom est déjà à côté.
  final bool compacte;

  @override
  Widget build(BuildContext context) {
    final trouve = item.decouvert;
    final couleur = Palette.qualite(item.rarete);

    final vignette = AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: Palette.caseVide,
          borderRadius: BorderRadius.circular(compacte ? 14 : 18),
          // Une case vide garde une bordure très pâle de sa qualité : on devine
          // ce qui se cache derrière sans que ça crie.
          border: Border.all(
            color: trouve ? couleur : couleur.withValues(alpha: .18),
            width: trouve ? 2 : 1.2,
          ),
          // Un halo de la couleur de qualité, discret sur les cases vides et
          // franc sur les trouvailles : c'est ce qui fait ressortir une belle
          // prise au milieu de la grille, sans avoir à lire quoi que ce soit.
          boxShadow: [
            BoxShadow(
              color: couleur.withValues(
                  alpha: trouve ? (item.rarete >= 4 ? .45 : .3) : .12),
              blurRadius: trouve ? (item.rarete >= 4 ? 10 : 6) : 4,
              spreadRadius: trouve && item.rarete >= 4 ? 0 : -1,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: _contenu(trouve),
      ),
    );

    if (compacte) return GestureDetector(onTap: onTap, child: vignette);

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          vignette,
          const SizedBox(height: 4),
          SizedBox(
            height: 26,
            child: Text(
              // Une case vide ne dit pas ce qu'elle cache : c'est tout l'intérêt.
              trouve ? item.nom : '???',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                height: 1.2,
                fontWeight: trouve ? FontWeight.w600 : FontWeight.w400,
                color: trouve ? Palette.texte : Palette.texteDoux,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _contenu(bool trouve) {
    if (!trouve) return _Silhouette(chemin: item.visuel);
    final image = item.imageDeCase(
        entieresParDefaut: Reglages.instance.casesEntieres);
    final chemin = image.chemin;
    if (chemin == null) return _Silhouette(chemin: item.visuel);
    if (image.detouree) {
      return Padding(
        padding: const EdgeInsets.all(7),
        // `contain` et non `cover` : on veut voir la bête en entier, pas un
        // gros plan sur son flanc.
        child: ImageServeur(chemin: chemin, fit: BoxFit.contain, taille: 256),
      );
    }
    return ImageServeur(chemin: chemin, taille: 256);
  }
}

class _Silhouette extends StatelessWidget {
  const _Silhouette({required this.chemin});
  final String? chemin;

  @override
  Widget build(BuildContext context) {
    if (chemin == null) {
      return Icon(Icons.help_outline, color: Palette.silhouette, size: 28);
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: SvgPicture.network(
        Api.instance.image(chemin!).toString(),
        // Le filtre écrase toute la couleur du tracé : la silhouette devient un
        // aplat gris uniforme, y compris les détails clairs du dessin.
        colorFilter: ColorFilter.mode(Palette.silhouette, BlendMode.srcIn),
        placeholderBuilder: (_) => const SizedBox.shrink(),
      ),
    );
  }
}

/// Pastille de qualité : le nom du palier dans sa couleur.
class PastilleRarete extends StatelessWidget {
  const PastilleRarete(
      {super.key, required this.rarete, this.points, this.dense = false});

  final int rarete;
  final int? points;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final couleur = Palette.qualite(rarete);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: dense ? 7 : 10, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: couleur.withValues(alpha: .45)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (rarete >= 4)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(rarete == 5 ? Icons.auto_awesome : Icons.star,
                size: dense ? 10 : 12, color: couleur),
          ),
        Text(
          points == null
              ? Palette.nomQualite(rarete)
              : '${Palette.nomQualite(rarete)} · $points pts',
          style: TextStyle(
              color: couleur,
              fontSize: dense ? 10 : 12,
              fontWeight: FontWeight.w700),
        ),
      ]),
    );
  }
}
