import 'dart:io';
import '../i18n.dart';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import '../widgets/reactions.dart';
import 'classement.dart';
import 'credits.dart';
import 'parametres.dart';

/// Profil : avancement, réglages, déconnexion.
class EcranProfil extends StatefulWidget {
  const EcranProfil({super.key, required this.surDeconnexion});
  final VoidCallback surDeconnexion;

  @override
  State<EcranProfil> createState() => _EcranProfilState();
}

class _EcranProfilState extends State<EcranProfil> {
  Joueur? _moi;
  ResumeDex? _resume;
  int _points = 0;
  bool _envoiAvatar = false;

  /// Change sa photo de profil : c'est elle qui apparaît en médaillon sur la
  /// carte, pour qu'on sache à qui appartient chaque trouvaille.
  Future<void> _changeAvatar() async {
    final choisie = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 800, maxHeight: 800);
    if (choisie == null) return;
    setState(() => _envoiAvatar = true);
    try {
      await Api.instance.envoieAvatar(File(choisie.path));
      await _charge();
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _envoiAvatar = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _charge();
  }

  Future<void> _charge() async {
    try {
      final r = await Future.wait([
        Api.instance.get('/moi'),
        Api.instance.get('/dex/resume'),
      ]);
      if (!mounted) return;
      setState(() {
        _moi = Joueur.depuisJson(r[0]);
        _resume = ResumeDex.depuisJson(r[1]);
        _points = r[0]['points'] ?? 0;
      });
    } catch (_) {
      // Écran informatif : s'il ne se charge pas, il reste vide.
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _moi;
    final r = _resume;
    return Scaffold(
      appBar: AppBar(title: Text(T('Profil'))),
      body: RefreshIndicator(
        onRefresh: _charge,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Row(children: [
              GestureDetector(
                onTap: _envoiAvatar ? null : _changeAvatar,
                child: Stack(children: [
                  Avatar(
                    pseudo: m?.pseudo ?? Api.instance.pseudo ?? '?',
                    chemin: m?.avatar,
                    taille: 64,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Palette.accent,
                        shape: BoxShape.circle,
                      ),
                      child: _envoiAvatar
                          ? SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Palette.surAccent))
                          : Icon(Icons.photo_camera,
                              size: 12, color: Palette.surAccent),
                    ),
                  ),
                ]),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m?.pseudo ?? Api.instance.pseudo ?? '',
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800)),
                    if (m != null)
                      Text(T('{0} photos · {1} amis', [m.captures, m.amis]),
                          style: TextStyle(
                              color: Palette.texteDoux, fontSize: 13)),
                    if (_points > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Palette.accent.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(T('{0} points', [_points]),
                              style: TextStyle(
                                  color: Palette.accentSombre,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12)),
                        ),
                      ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 28),
            if (r != null) ...[
              _avancement(r),
              const SizedBox(height: 28),
              Text(T('Par groupe'),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              // On ne montre que les groupes déjà entamés : la liste complète
              // ferait quarante lignes à zéro, ce qui n'apprend rien.
              for (final g in r.classes.where((g) => g.trouve > 0))
                _ligneGroupe(g),
              if (r.classes.every((g) => g.trouve == 0))
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text(T('Aucune espèce trouvée pour l\'instant.'),
                      style: TextStyle(color: Palette.texteDoux)),
                ),
            ],
            const SizedBox(height: 28),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.settings_outlined),
              title: Text(T('Paramètres')),
              subtitle: Text(
                  T('Thème, affichage des cases, clé Pl@ntNet'),
                  style: TextStyle(fontSize: 12)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => EcranParametres(
                    surDeconnexion: widget.surDeconnexion),
              )).then((_) {
                // Le thème a pu changer, et les réglages d'affichage aussi :
                // on se redessine au retour plutôt que de laisser un écran
                // qui contredit ce qu'on vient de régler.
                if (mounted) setState(() {});
              }),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.emoji_events_outlined),
              title: Text(T('Classement')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const EcranClassement())),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.info_outline),
              title: Text(T('Crédits')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const EcranCredits())),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avancement(ResumeDex r) {
    final part = r.total == 0 ? 0.0 : r.trouve / r.total;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Palette.fondSecondaire,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${r.trouve}',
                  style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      height: 1,
                      color: Palette.accent)),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(T('espèce{0} trouvée{1}', [r.trouve > 1 ? 's' : '', r.trouve > 1 ? 's' : '']),
                    style: TextStyle(color: Palette.texteDoux)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              // À 376 000 cases, la barre reste presque vide très longtemps :
              // c'est honnête, et le compteur ci-dessus porte la fierté.
              value: part.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: Palette.caseVide,
              valueColor: AlwaysStoppedAnimation(Palette.accent),
            ),
          ),
          const SizedBox(height: 8),
          Text(T('sur {0} cases du dex', [r.total]),
              style: TextStyle(color: Palette.texteDoux, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _ligneGroupe(GroupeDex g) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          SizedBox(
            width: 140,
            child: Text(nomDeClasse(g.classe),
                style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: g.total == 0 ? 0 : (g.trouve / g.total).clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: Palette.caseVide,
                valueColor: AlwaysStoppedAnimation(Palette.accent),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('${g.trouve}',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Palette.texteDoux)),
        ]),
      );
}
