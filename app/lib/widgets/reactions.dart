import 'package:flutter/material.dart';
import '../i18n.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../modeles.dart';
import '../theme.dart';

/// La barre de réactions sous une photo d'ami.
///
/// Cinq degrés, de l'indifférence polie à l'admiration, et chacun rapporte des
/// points au photographe. Une seule réaction par personne : appuyer sur celle
/// qu'on a déjà mise la retire.
class BarreReactions extends StatefulWidget {
  const BarreReactions({
    super.key,
    required this.captureId,
    required this.resume,
    this.surChangement,
  });

  final int captureId;
  final ResumeReactions resume;
  final void Function(ResumeReactions)? surChangement;

  @override
  State<BarreReactions> createState() => _BarreReactionsState();
}

class _BarreReactionsState extends State<BarreReactions> {
  late ResumeReactions _resume = widget.resume;
  bool _envoi = false;

  @override
  void didUpdateWidget(BarreReactions ancien) {
    super.didUpdateWidget(ancien);
    if (ancien.captureId != widget.captureId) _resume = widget.resume;
  }

  Future<void> _pose(Reaction r) async {
    if (_envoi) return;
    setState(() => _envoi = true);
    // Un petit retour tactile : on sait qu'on a appuyé sans avoir à regarder.
    HapticFeedback.selectionClick();
    try {
      final retire = _resume.maReaction == r.valeur;
      final d = retire
          ? null
          : await Api.instance
              .put('/captures/${widget.captureId}/reaction', {'valeur': r.valeur});
      if (retire) {
        await Api.instance.supprime('/captures/${widget.captureId}/reaction');
      }
      if (!mounted) return;
      setState(() => _resume = retire
          ? ResumeReactions.depuisJson(const {})
          : ResumeReactions.depuisJson(d as Map<String, dynamic>));
      widget.surChangement?.call(_resume);
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _envoi = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (final r in reactionsPossibles) _bouton(r),
      const Spacer(),
      if (_resume.points > 0)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Palette.accent.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(T('+{0} pts', [_resume.points]),
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Palette.accentSombre)),
        ),
    ]);
  }

  Widget _bouton(Reaction r) {
    final choisie = _resume.maReaction == r.valeur;
    final combien = _resume.compte[r.valeur] ?? 0;
    return Tooltip(
      message: r.points == 0 ? r.nom : T('{0} · {1} pts', [r.nom, r.points]),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _pose(r),
        child: Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: choisie
                ? Palette.accent.withValues(alpha: .16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: choisie
                ? Border.all(color: Palette.accent.withValues(alpha: .5))
                : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(r.emoji, style: const TextStyle(fontSize: 17)),
            if (combien > 0)
              Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Text('$combien',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: choisie ? Palette.accentSombre : Palette.texteDoux)),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Pastille ronde de photo de profil, avec l'initiale en repli.
class Avatar extends StatelessWidget {
  const Avatar(
      {super.key,
      required this.pseudo,
      this.chemin,
      this.taille = 36,
      this.bordure});

  final String pseudo;
  final String? chemin;
  final double taille;
  final Color? bordure;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: taille,
      height: taille,
      decoration: BoxDecoration(
        color: Palette.caseVide,
        shape: BoxShape.circle,
        border: bordure == null
            ? null
            : Border.all(color: bordure!, width: taille > 30 ? 2 : 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: chemin == null
          ? Center(
              child: Text(
                pseudo.isEmpty ? '?' : pseudo.characters.first.toUpperCase(),
                style: TextStyle(
                    fontSize: taille * .42,
                    fontWeight: FontWeight.w800,
                    color: Palette.texteDoux),
              ),
            )
          : Image.network(
              Api.instance.image(chemin!).toString(),
              headers: Api.instance.entetes,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Center(
                child: Text(
                  pseudo.isEmpty ? '?' : pseudo.characters.first.toUpperCase(),
                  style: TextStyle(
                      fontSize: taille * .42,
                      fontWeight: FontWeight.w800,
                      color: Palette.texteDoux),
                ),
              ),
            ),
    );
  }
}
