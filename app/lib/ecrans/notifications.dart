import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../modeles.dart';
import '../reglages.dart';
import '../theme.dart';
import '../widgets/case_dex.dart';
import '../widgets/reactions.dart';
import 'detail_case.dart';
import 'profil_joueur.dart';
import 'visionneuse.dart';
import '../widgets/chargement.dart';

/// Ce qui s'est passé sur ses photos pendant qu'on ne regardait pas.
///
/// Les notifications vivent sur le serveur et l'application vient les chercher :
/// ce ne sont pas des notifications système. En faire apparaître sur l'écran
/// verrouillé demanderait de passer par le service de messagerie de Google,
/// donc un compte, des clés et un détour par leurs serveurs — beaucoup pour un
/// jeu qui tourne sur le réseau de la maison.
class EcranNotifications extends StatefulWidget {
  const EcranNotifications({super.key});

  @override
  State<EcranNotifications> createState() => _EcranNotificationsState();
}

class _EcranNotificationsState extends State<EcranNotifications> {
  List<NotificationRecue> _notifications = [];
  bool _charge = true;

  /// Copie locale du réglage, pour que le bouton change l'écran tout de suite
  /// sans dépendre de la reconstruction globale déclenchée ailleurs.
  bool _selonPrise = Reglages.instance.dateNotifsSelonPrise;

  @override
  void initState() {
    super.initState();
    _rafraichit();
  }

  Future<void> _rafraichit({bool marquerLues = true}) async {
    try {
      final d = await Api.instance.get('/notifications');
      if (!mounted) return;
      setState(() => _notifications = (d['notifications'] as List)
          .map((n) => NotificationRecue.depuisJson(n))
          .toList());
      // On les marque lues après affichage : le badge tombe, mais la liste
      // garde la mise en avant des nouvelles jusqu'à la prochaine visite.
      if (marquerLues && (d['non_lues'] ?? 0) > 0) {
        await Api.instance.post('/notifications/lues');
      }
    } catch (_) {
      // Écran de consultation : sans réseau, il reste vide.
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  Future<void> _vide() async {
    final confirme = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(T('Tout effacer ?')),
        content: Text(T('Les réactions elles-mêmes ne sont pas touchées.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(T('Annuler'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(T('Effacer'))),
        ],
      ),
    );
    if (confirme != true) return;
    await Api.instance.supprime('/notifications');
    if (mounted) setState(() => _notifications = []);
  }

  /// Ce que dit une alerte de purge.
  ///
  /// On n'annonce un délai que si toutes les photos concernées ont le même :
  /// dire « 2 jours » quand la moitié en a six ferait courir pour rien, et
  /// l'inverse — dire « 6 jours » — en ferait perdre.
  String _textepurge(NotificationRecue n) {
    final j = n.joursRestants;
    if (j == null || j < 0) {
      return T('Vos photos sans espèce vont bientôt être effacées');
    }
    if (j <= 0) return T('Vos photos sans espèce seront effacées aujourd\'hui');
    if (j == 1) return T('Vos photos sans espèce seront effacées demain');
    return T('Vos photos sans espèce seront effacées dans {0} jours', [j]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(T('Notifications')),
        actions: [
          // Publication ou prise de vue : les deux répondent à une question
          // différente, et rien ne dit laquelle chacun préfère.
          IconButton(
              onPressed: () {
                setState(() => _selonPrise = !_selonPrise);
                Reglages.instance.changeDateNotifsSelonPrise(_selonPrise);
              },
              tooltip: _selonPrise
                  ? 'Date affichée : prise de vue'
                  : 'Date affichée : publication',
              icon: Icon(_selonPrise
                  ? Icons.camera_alt_outlined
                  : Icons.publish_outlined)),
          if (_notifications.isNotEmpty)
            IconButton(
                onPressed: _vide,
                tooltip: T('Tout effacer'),
                icon: const Icon(Icons.clear_all)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _rafraichit(marquerLues: false),
        child: _charge
            ? const Chargement()
            : _notifications.isEmpty
                ? ListView(children: [
                    SizedBox(height: 100),
                    Icon(Icons.notifications_none,
                        size: 48, color: Palette.silhouette),
                    SizedBox(height: 14),
                    Center(
                      child: Text(T('Rien de neuf.'),
                          style: TextStyle(color: Palette.texteDoux)),
                    ),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _notifications.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _ligne(_notifications[i]),
                  ),
      ),
    );
  }

  /// Où mène le clic, s'il mène quelque part.
  ///
  /// La photo précise quand la notification en désigne une — une réaction,
  /// une identification — c'est elle qui a provoqué la notification, pas une
  /// autre trouvée au hasard dans l'espèce. Avant, le clic n'ouvrait que la
  /// fiche de l'espèce via `caseId`, qui manque pour ces deux types : on ne
  /// pouvait jamais atteindre la photo réagie, seulement deviner.
  bool _peutOuvrir(NotificationRecue n) =>
      n.captureId != null ||
      (n.type == 'ami_actif' && n.auteur != 0) ||
      n.caseId != null;

  Future<void> _ouvre(NotificationRecue n) async {
    if (n.captureId != null) {
      try {
        final d = await Api.instance.get('/captures/${n.captureId}');
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => Visionneuse(captures: [Capture.depuisJson(d)]),
        ));
      } on ErreurApi catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    // `ami_actif` ne désigne aucune photo précise — un ami a été actif, pas
    // une trouvaille en particulier — le clic mène donc à son profil.
    if (n.type == 'ami_actif' && n.auteur != 0) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            EcranProfilJoueur(joueurId: n.auteur, pseudo: n.pseudo),
      ));
      return;
    }
    if (n.caseId != null) {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => EcranDetailCase(caseId: n.caseId!)));
    }
  }

  Widget _ligne(NotificationRecue n) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: _peutOuvrir(n) ? () => _ouvre(n) : null,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          // Les nouvelles gardent un fond teinté jusqu'à la prochaine visite.
          color: n.lu ? Colors.transparent : Palette.accent.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Avatar(pseudo: n.pseudo, chemin: n.avatar, taille: 42),
              Positioned(
                right: -4,
                bottom: -4,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                      color: Palette.fond, shape: BoxShape.circle),
                  child: Text(
                      switch (n.type) {
                        'identifie' => '👥',
                        'purge' => '🗑',
                        'espece_ajoutee' => '🌱',
                        'ami_actif' => '📷',
                        'ami_demande' || 'ami_accepte' => '🤝',
                        _ => n.emoji,
                      },
                      style: const TextStyle(fontSize: 15)),
                ),
              ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (n.type == 'purge')
                  Text(_textepurge(n),
                      style: const TextStyle(fontWeight: FontWeight.w600))
                else
                Text.rich(TextSpan(children: [
                  TextSpan(
                      text: n.pseudo,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  // Plusieurs motifs partagent cette ligne, et ils ne se
                  // racontent pas de la même façon.
                  if (n.type == 'ami_demande')
                    TextSpan(
                        text: T(' vous a envoyé une demande d\'ami'),
                        style: TextStyle(color: Palette.texteDoux))
                  else if (n.type == 'ami_accepte')
                    TextSpan(
                        text: T(' a accepté votre demande'),
                        style: TextStyle(color: Palette.texteDoux))
                  else if (n.type == 'identifie')
                    TextSpan(
                        text: T(' vous a identifié sur sa photo'),
                        style: TextStyle(color: Palette.texteDoux))
                  else if (n.type == 'espece_ajoutee')
                    TextSpan(
                        text: T(' a indexé une espèce absente du dex'),
                        style: TextStyle(color: Palette.texteDoux))
                  // Une seule ligne par ami, quel que soit le nombre de
                  // photos : le serveur fait grossir son compteur au lieu
                  // d'ouvrir une notification par trouvaille.
                  else if (n.type == 'ami_actif')
                    TextSpan(
                        text: n.nbTrouvailles > 1
                            ? ' a partagé ${n.nbTrouvailles} nouvelles trouvailles'
                            : ' a partagé une nouvelle trouvaille',
                        style: TextStyle(color: Palette.texteDoux))
                  else ...[
                    TextSpan(
                        text: T(' a trouvé votre photo '),
                        style: TextStyle(color: Palette.texteDoux)),
                    TextSpan(
                        text: n.reaction.toLowerCase(),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ])),
                const SizedBox(height: 2),
                Text(
                  [
                    if (n.type == 'purge')
                      T('Rangez-les dans une espèce pour les garder')
                    else if (n.type == 'espece_ajoutee')
                      T('Elle est visible par tout le monde')
                    else if (n.titre.isNotEmpty)
                      '« ${n.titre} »'
                    else
                      n.espece,
                    if (n.type == 'identifie') T('ajoutée à votre dex'),
                    // `prisePle` manque pour beaucoup de types — une demande
                    // d'ami n'a pas de date de prise de vue — d'où le repli.
                    ((_selonPrise ? n.prisePle : null) ?? n.creeLe)
                        .split(' ')
                        .first,
                  ].where((t) => t.isNotEmpty).join(' · '),
                  style:
                      TextStyle(fontSize: 12, color: Palette.texteDoux),
                ),
              ],
            ),
          ),
          if (n.points > 0)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('+${n.points}',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Palette.accentSombre)),
            ),
          if (n.vignette != null) ...[
            const SizedBox(width: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 44,
                height: 44,
                child: ImageServeur(chemin: n.vignette!, taille: 96),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
