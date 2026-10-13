import 'package:cached_network_image/cached_network_image.dart';
import '../i18n.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../modeles.dart';
import '../theme.dart';

/// L'illustration d'un rang.
///
/// Servie en couleur, contrairement aux silhouettes d'espèces qu'on reteinte :
/// c'est un dessin, pas une forme. Le serveur en prépare deux tailles ; on
/// demande la grande dès que la vignette dépasse la centaine de pixels, sinon
/// l'image paraît molle sur les écrans à forte densité.
class BadgePalier extends StatelessWidget {
  const BadgePalier({
    super.key,
    required this.chemin,
    this.taille = 44,
    this.eteint = false,
  });

  final String chemin;
  final double taille;

  /// Vrai avant la première trouvaille : le rang n'est pas encore gagné, on le
  /// montre en sourdine plutôt que de laisser la place vide.
  final bool eteint;

  @override
  Widget build(BuildContext context) {
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(taille * .18),
      child: CachedNetworkImage(
        imageUrl: Api.instance
            .image(chemin, {'taille': taille > 90 ? 512 : 256})
            .toString(),
        httpHeaders: Api.instance.entetes,
        width: taille,
        height: taille,
        fit: BoxFit.cover,
        placeholder: (_, _) => SizedBox(width: taille, height: taille),
        errorWidget: (_, _, _) => SizedBox(width: taille, height: taille),
      ),
    );
    if (!eteint) return image;
    return Opacity(
      opacity: .35,
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: image,
      ),
    );
  }
}

/// Le bandeau de progression du dex : rang atteint, points, prochain jalon.
///
/// Il remplace le « 3 sur 977 415 » d'origine, qui rappelait surtout qu'on
/// n'y arriverait jamais. Ici tout est à portée : le rang qu'on porte, et
/// combien d'espèces avant le suivant.
/// La pastille de bascule, posée sur le coin de l'écusson.
///
/// En surimpression plutôt qu'à côté : elle ne prend aucune place, et elle est
/// exactement là où l'œil regarde déjà. Discrète — un demi-voile et un
/// pictogramme de douze pixels — parce qu'elle sert une fois de temps en temps,
/// pas à chaque ouverture.
class BasculeBandeau extends StatelessWidget {
  const BasculeBandeau({
    super.key,
    required this.surVitrine,
    required this.surBascule,
  });

  /// Vrai quand c'est la vitrine qui est affichée : le pictogramme montre alors
  /// ce vers quoi on retourne, pas ce qu'on regarde.
  final bool surVitrine;
  final VoidCallback surBascule;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: -4,
      left: -4,
      child: Material(
        color: Colors.black.withValues(alpha: .55),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: surBascule,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              surVitrine ? Icons.military_tech_outlined : Icons.diamond_outlined,
              size: 13,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class BandeauPalier extends StatelessWidget {
  const BandeauPalier({
    super.key,
    required this.resume,
    required this.surAppui,
    this.surBascule,
  });

  final ResumeDex resume;
  final VoidCallback surAppui;

  /// Non nul quand une vitrine existe : pose la pastille de bascule.
  final VoidCallback? surBascule;

  @override
  Widget build(BuildContext context) {
    final p = resume.palier;
    final part = p.part(resume.trouve);
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
              BadgePalier(chemin: p.badge, taille: 56, eteint: p.numero == 0),
              if (surBascule != null)
                BasculeBandeau(surVitrine: false, surBascule: surBascule!),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(p.nom,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16.5, fontWeight: FontWeight.w800)),
                    ),
                    const SizedBox(width: 6),
                    Text('#${p.numero}/${p.total}',
                        style: TextStyle(
                            fontSize: 11, color: Palette.texteDoux)),
                  ]),
                  // Espèces et points sont deux comptes différents, et les
                  // confondre laissait croire à une erreur : le rang se gagne
                  // en espèces, les points s'accumulent à côté et incluent les
                  // applaudissements des amis.
                  Row(children: [
                    Icon(Icons.pets, size: 12, color: Palette.texteDoux),
                    const SizedBox(width: 4),
                    Text(T('{0} espèce{1}', [resume.trouve, resume.trouve > 1 ? 's' : '']),
                        style: TextStyle(
                            fontSize: 12,
                            color: Palette.texteDoux,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 10),
                    Icon(Icons.star_border,
                        size: 12, color: Palette.texteDoux),
                    const SizedBox(width: 3),
                    Text(T('{0} pts', [resume.points]),
                        style: TextStyle(
                            fontSize: 12, color: Palette.texteDoux)),
                    if (resume.pointsReactions > 0)
                      Text(T(' (dont {0} 👏)', [resume.pointsReactions]),
                          style: TextStyle(
                              fontSize: 11, color: Palette.texteDoux)),
                  ]),
                  if (p.suivant != null) ...[
                    const SizedBox(height: 7),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: part,
                        minHeight: 6,
                        backgroundColor: Palette.caseVide,
                        valueColor:
                            AlwaysStoppedAnimation(Palette.accent),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      T('Encore {0} espèce{1} avant {2}', [p.reste, p.reste! > 1 ? 's' : '', p.suivant]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: Palette.texteDoux),
                    ),
                  ] else
                    Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(T('Rang maximal atteint.'),
                          style: TextStyle(
                              fontSize: 11,
                              color: Palette.accentSombre,
                              fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
            if (p.badgeSuivant != null) ...[
              const SizedBox(width: 8),
              Opacity(
                opacity: .35,
                child: BadgePalier(chemin: p.badgeSuivant!, taille: 34),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
