import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../theme.dart';
import 'case_dex.dart';
import 'regnes.dart';

/// L'aperçu d'une espèce proposée, avant de la choisir.
///
/// Devant « Pica pica » et « Corvus corone », une vignette de 46 pixels ne
/// permet pas de trancher. Il fallait sélectionner l'espèce pour la voir, donc
/// se tromper pour comparer. Cet aperçu montre la photo en grand et l'article
/// Wikipédia, et ne valide rien tant qu'on ne le demande pas.
class ApercuEspece extends StatefulWidget {
  const ApercuEspece({
    super.key,
    required this.caseId,
    required this.nom,
    required this.latin,
    this.image,
    this.resume = '',
    this.regne = 'animal',
    this.toxique = false,
    this.rarete = 0,
    this.points = 0,
    this.proba,
  });

  final int caseId;
  final String nom;
  final String latin;
  final String? image;
  final String resume;
  final String regne;
  final bool toxique;
  final int rarete;
  final int points;

  /// La confiance du moteur, quand l'aperçu vient d'une proposition.
  final double? proba;

  @override
  State<ApercuEspece> createState() => _ApercuEspeceState();
}

class _ApercuEspeceState extends State<ApercuEspece> {
  late String _resume = widget.resume;
  String? _image;
  String _url = '';
  bool _charge = false;

  @override
  void initState() {
    super.initState();
    _image = widget.image;
    // L'article n'est pas toujours arrivé avec la liste : on le complète ici,
    // pendant que la photo s'affiche.
    if (_resume.isEmpty || _image == null) _chargeFiche();
  }

  Future<void> _chargeFiche() async {
    setState(() => _charge = true);
    try {
      final d = await Api.instance.get('/dex/${widget.caseId}/fiche');
      if (!mounted || d['trouvee'] != true) return;
      setState(() {
        _resume = d['resume'] ?? _resume;
        _image = (d['image'] as String?)?.isNotEmpty == true
            ? d['image']
            : _image;
        _url = d['url'] ?? '';
      });
    } catch (_) {
      // Sans article, l'aperçu se contente du nom et de la silhouette.
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (image != null)
                // On peut se promener dans la photo : c'est souvent un détail
                // — une nervure, une tache d'aile — qui départage deux espèces
                // voisines, et il disparaît dans une vignette figée.
                SizedBox(
                  height: 240,
                  width: double.infinity,
                  child: Stack(children: [
                    Positioned.fill(
                      child: InteractiveViewer(
                        minScale: 1,
                        maxScale: 6,
                        child: Image.network(image, fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => ColoredBox(
                                color: Palette.caseVide,
                                child: Icon(Icons.image_not_supported_outlined,
                                    color: Palette.silhouette))),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.pinch_outlined, size: 12, color: Colors.white),
                          SizedBox(width: 4),
                          Text(T('pincez pour zoomer'),
                              style: TextStyle(
                                  color: Colors.white, fontSize: 10.5)),
                        ]),
                      ),
                    ),
                  ]),
                )
              else
                Container(
                  height: 140,
                  width: double.infinity,
                  color: Palette.caseVide,
                  child: Icon(Icons.help_outline,
                      size: 44, color: Palette.silhouette),
                ),
              // Le bandeau ne s'affiche que quand l'espèce est signalée. Un
              // « non toxique » serait une promesse que personne ne peut tenir.
              if (widget.toxique)
                Container(
                  width: double.infinity,
                  color: Palette.alerte,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(children: [
                    Icon(Icons.dangerous_outlined, color: Colors.white, size: 19),
                    SizedBox(width: 9),
                    Expanded(
                      child: Text(T('ESPÈCE SIGNALÉE TOXIQUE'),
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: .6)),
                    ),
                  ]),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.nom,
                        style: const TextStyle(
                            fontSize: 21, fontWeight: FontWeight.w800, height: 1.15)),
                    if (widget.latin.isNotEmpty && widget.latin != widget.nom)
                      Text(widget.latin,
                          style: TextStyle(
                              fontStyle: FontStyle.italic,
                              color: Palette.texteDoux,
                              fontSize: 13)),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      PastilleRegne(regne: widget.regne),
                      if (widget.rarete > 0)
                        PastilleRarete(rarete: widget.rarete, points: widget.points),
                      if (widget.proba != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Palette.fondSecondaire,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                              T('confiance {0} %', [(widget.proba! * 100).toStringAsFixed(0)]),
                              style: TextStyle(
                                  fontSize: 12, color: Palette.texteDoux)),
                        ),
                    ]),
                    const SizedBox(height: 12),
                    if (_charge && _resume.isEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      )
                    else if (_resume.isNotEmpty)
                      Text(_resume,
                          style: const TextStyle(fontSize: 13.5, height: 1.45))
                    else
                      Text(T('Pas d\'article Wikipédia pour cette espèce.'),
                          style: TextStyle(
                              fontSize: 13, color: Palette.texteDoux)),
                    if (_url.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(T('Source : Wikipédia'),
                            style: TextStyle(
                                fontSize: 11, color: Palette.texteDoux)),
                      ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ]),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Row(children: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(T('Fermer'))),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.check, size: 18),
              label: Text(T('C\'est celle-ci')),
            ),
          ]),
        ),
      ]),
    );
  }
}
