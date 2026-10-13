import 'package:flutter/material.dart';
import '../i18n.dart';

import '../modeles.dart';
import '../theme.dart';
import '../widgets/case_dex.dart';
import '../widgets/reactions.dart';
import 'detail_case.dart';

/// Une sortie dépliée : ses photos, une par une.
///
/// C'est la moitié « détail » du fil regroupé. La carte du fil dit ce qui
/// s'est passé — qui, quand, combien — et cet écran laisse regarder chaque
/// cliché et réagir dessus.
///
/// Les réactions restent attachées à la photo, jamais au groupe : applaudir un
/// lot de six aurait rapporté six fois les points d'un seul geste, et surtout
/// on n'aurait plus pu distinguer la belle photo des cinq autres. Le
/// regroupement est ergonomique, pas comptable.
class EcranSortie extends StatefulWidget {
  const EcranSortie({super.key, required this.sortie, this.debut = 0});

  final SortieFil sortie;

  /// L'index de la photo par laquelle on entre : on ouvre sur la vignette
  /// qu'on a touchée, pas sur la première du lot.
  final int debut;

  @override
  State<EcranSortie> createState() => _EcranSortieState();
}

class _EcranSortieState extends State<EcranSortie> {
  late final PageController _pages =
      PageController(initialPage: widget.debut);
  late int _courante = widget.debut;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.sortie.photos;
    final p = photos[_courante];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF101114),
        surfaceTintColor: const Color(0xFF101114),
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: const TextStyle(
            color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.sortie.titre),
            Text(T('{0} sur {1}', [_courante + 1, photos.length]),
                style: const TextStyle(
                    fontSize: 12, color: Colors.white54,
                    fontWeight: FontWeight.w400)),
          ],
        ),
      ),
      body: Column(children: [
        Expanded(
          child: PageView.builder(
            controller: _pages,
            itemCount: photos.length,
            onPageChanged: (i) => setState(() => _courante = i),
            itemBuilder: (context, i) => InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(
                child: ImageServeur(
                    chemin: photos[i].vignette,
                    fit: BoxFit.contain,
                    taille: 512),
              ),
            ),
          ),
        ),
        // La pellicule : elle situe où l'on en est dans le lot et permet de
        // sauter directement à une photo, ce qu'un simple balayage ne fait pas
        // quand la sortie en compte quinze.
        if (photos.length > 1) _pellicule(photos),
        _pied(p),
      ]),
    );
  }

  Widget _pellicule(List<PhotoFil> photos) {
    return SizedBox(
      height: 62,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final actif = i == _courante;
          return GestureDetector(
            onTap: () => _pages.animateToPage(i,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut),
            child: Container(
              width: 46,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: actif ? Palette.accent : Colors.white24,
                    width: actif ? 2 : 1),
              ),
              clipBehavior: Clip.antiAlias,
              child: ImageServeur(chemin: photos[i].vignette, taille: 96),
            ),
          );
        },
      ),
    );
  }

  Widget _pied(PhotoFil p) {
    return Container(
      width: double.infinity,
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: p.caseId == null
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => EcranDetailCase(caseId: p.caseId!),
                        )),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.titre.isEmpty ? p.nom : p.titre,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                    if (p.titre.isNotEmpty)
                      Text(p.nom,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12.5)),
                    Text(
                      [
                        p.pseudo,
                        if (p.lieu.isNotEmpty) p.lieu,
                        p.quand.split(' ').first,
                      ].join(' · '),
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ),
            PastilleRarete(rarete: p.rarete, dense: true),
          ]),
          const SizedBox(height: 10),
          BarreReactions(
            captureId: p.captureId,
            resume: p.reactions,
            surChangement: (r) => setState(() => p.reactions = r),
          ),
        ],
      ),
    );
  }
}
