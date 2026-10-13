import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../modeles.dart';
import '../reglages.dart';
import '../theme.dart';
import '../version.dart';
import 'parametres_notifs.dart';

/// Tous les réglages, au même endroit.
///
/// Ils vivaient éparpillés au bas du profil, après les statistiques et la
/// répartition par groupe : le réglage du cadrage des cases existait depuis
/// des jours sans que personne le trouve. Un écran dédié coûte un appui de
/// plus et rend les réglages consultables — ce qui est tout l'inverse d'un
/// compromis.
///
/// Deux natures s'y côtoient, et la séparation est délibérée. Ce qui touche à
/// l'affichage reste sur le téléphone : un même compte peut vouloir le thème
/// sombre ici et le clair sur la tablette. Ce qui touche au compte part au
/// serveur et suit le joueur partout.
class EcranParametres extends StatefulWidget {
  const EcranParametres({super.key, required this.surDeconnexion});
  final VoidCallback surDeconnexion;

  @override
  State<EcranParametres> createState() => _EcranParametresState();
}

class _EcranParametresState extends State<EcranParametres> {
  Joueur? _moi;

  @override
  void initState() {
    super.initState();
    _charge();
  }

  Future<void> _charge() async {
    try {
      final d = await Api.instance.get('/moi');
      if (mounted) setState(() => _moi = Joueur.depuisJson(d));
    } catch (_) {
      // Sans le compte, les réglages d'affichage restent utilisables : c'est
      // justement ceux-là qui ne dépendent pas du réseau.
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = Reglages.instance;
    return Scaffold(
      appBar: AppBar(title: Text(T('Paramètres'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _titre(T('Affichage')),
          _langue(r),
          _theme(r),
          SwitchListTile(
            secondary: const Icon(Icons.animation_outlined),
            title: Text(T('Décor animé')),
            subtitle: Text(
                T('La pluie, les étoiles, les feuilles… derrière les écrans des thèmes qui en ont. Éteint, le décor reste mais ne bouge plus.'),
                style: TextStyle(fontSize: 12)),
            value: r.decorAnime,
            onChanged: (v) async {
              await r.changeDecorAnime(v);
              if (mounted) setState(() {});
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.crop_original_outlined),
            title: Text(T('Cases en photo entière')),
            subtitle: Text(
                T('Plutôt que l\'animal détouré. Les cases réglées à la main gardent leur choix.'),
                style: TextStyle(fontSize: 12)),
            value: r.casesEntieres,
            onChanged: (v) async {
              await r.changeCasesEntieres(v);
              if (mounted) setState(() {});
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.catching_pokemon_outlined),
            title: Text(T('Animation de capture')),
            subtitle: Text(T('Le lancer pendant l\'analyse de la photo'),
                style: TextStyle(fontSize: 12)),
            value: r.animationCapture,
            onChanged: (v) async {
              await r.changeAnimation(v);
              if (mounted) setState(() {});
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.celebration_outlined),
            title: Text(T('Confettis')),
            subtitle: Text(T('À chaque nouvelle espèce'),
                style: TextStyle(fontSize: 12)),
            value: r.confettis,
            onChanged: (v) async {
              await r.changeConfettis(v);
              if (mounted) setState(() {});
            },
          ),

          const Divider(height: 32),
          _titre(T('Notifications')),
          ListTile(
            leading: const Icon(Icons.notifications_none),
            title: Text(T('Ce dont je veux être prévenu')),
            subtitle: Text(
                T('Sobre par défaut : seulement ce qui vous concerne.'),
                style: TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const EcranParametresNotifs())),
          ),

          const Divider(height: 32),
          _titre(T('Identification')),
          ListTile(
            leading: Icon(Icons.vpn_key_outlined,
                color: _moi?.plantnetActive == true
                    ? const Color(0xFF22A34B)
                    : null),
            title: Text(T('Clé Pl@ntNet')),
            subtitle: Text(
              _moi == null
                  ? '…'
                  : _moi!.plantnetActive
                      ? 'Active ${_moi!.plantnetApercu} — plantes identifiées par Pl@ntNet'
                      : 'Absente — les plantes passent par BioCLIP',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _moi == null ? null : _clePlantnet,
          ),

          const Divider(height: 32),
          _titre(T('À propos')),
          // La version installée, pour savoir ce qu'on teste : deux APK
          // portaient le même nom, l'un d'un ancien projet, et l'on
          // réinstallait le mauvais sans pouvoir s'en apercevoir.
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(T('Version')),
            subtitle: const Text(versionApp, style: TextStyle(fontSize: 12)),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(T('Serveur')),
            subtitle: Text(Api.instance.adresse,
                style: const TextStyle(fontSize: 12)),
          ),

          const Divider(height: 32),
          ListTile(
            leading: Icon(Icons.logout, color: Palette.alerte),
            title: Text(T('Se déconnecter'),
                style: TextStyle(color: Palette.alerte)),
            onTap: () async {
              await Api.instance.deconnexion();
              widget.surDeconnexion();
            },
          ),
        ],
      ),
    );
  }

  Widget _titre(String texte) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
        child: Text(texte.toUpperCase(),
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                letterSpacing: .5,
                color: Palette.texteDoux)),
      );

  /// La langue : celle du téléphone, ou une de celles qu'on a.
  Widget _langue(Reglages r) {
    final choix = {'auto': T('Automatique'), ...I18n.langues};
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Row(children: [
        const Icon(Icons.translate_outlined),
        const SizedBox(width: 16),
        Expanded(
          child: Wrap(spacing: 6, children: [
            for (final e in choix.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: r.langue == e.key,
                onSelected: (_) => r.changeLangue(e.key),
              ),
          ]),
        ),
      ]),
    );
  }

  /// Le choix du thème : une carte par thème, avec un aperçu en vraies
  /// couleurs — en-tête, trois cases, une ligne de texte, un point d'accent.
  /// On choisit ce qu'on voit ; un nom comme « Abysses » ne dit rien.
  Widget _theme(Reglages r) {
    final cartes = <Widget>[
      _CarteTheme(
        nom: T('Système'), detail: T('Suit le téléphone'),
        jeu: themeParCle('clair'), moitie: themeParCle('sombre'),
        actif: r.theme == 'systeme', quand: () => r.changeTheme('systeme'),
      ),
      for (final j in themes)
        _CarteTheme(
          nom: T(j.nom), detail: T(j.detail), jeu: j,
          actif: r.theme == j.cle, quand: () => r.changeTheme(j.cle),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.45,
        children: cartes,
      ),
    );
  }

  /// Saisir ou retirer sa clé Pl@ntNet.
  ///
  /// Elle est personnelle parce que le quota l'est : 500 identifications par
  /// jour et par clé. Une clé unique partagée entre tous les joueurs serait
  /// épuisée en une après-midi.
  Future<void> _clePlantnet() async {
    final champ = TextEditingController();
    final action = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(T('Clé Pl@ntNet')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            T('Pl@ntNet identifie les plantes bien mieux qu\'un modèle généraliste, mais son quota gratuit est de 500 identifications par jour et par clé. La vôtre reste la vôtre.\\n\\nClé gratuite sur my.plantnet.org.'),
            style: TextStyle(fontSize: 13, height: 1.35),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: champ,
            autofocus: true,
            autocorrect: false,
            decoration: InputDecoration(
                hintText: '2b10…', labelText: T('Clé API')),
          ),
        ]),
        actions: [
          if (_moi!.plantnetActive)
            TextButton(
              onPressed: () => Navigator.pop(c, '__retirer__'),
              child: Text(T('Retirer'), style: TextStyle(color: Palette.alerte)),
            ),
          TextButton(
              onPressed: () => Navigator.pop(c), child: Text(T('Annuler'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, champ.text.trim()),
              child: Text(T('Enregistrer'))),
        ],
      ),
    );
    champ.dispose();
    if (action == null || !mounted) return;
    try {
      if (action == '__retirer__') {
        await Api.instance.supprime('/moi/plantnet');
      } else if (action.isNotEmpty) {
        await Api.instance.put('/moi/plantnet', {'cle': action});
      } else {
        return;
      }
      await _charge();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(action == '__retirer__'
            ? 'Clé retirée.'
            : 'Clé enregistrée. Les plantes passeront par Pl@ntNet.'),
      ));
    } on ErreurApi catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }
}

/// Une carte du sélecteur de thème.
class _CarteTheme extends StatelessWidget {
  const _CarteTheme({
    required this.nom, required this.detail, required this.jeu,
    required this.actif, required this.quand, this.moitie,
  });
  final String nom, detail;
  final JeuDeCouleurs jeu;

  /// « Système » montre ses deux moitiés : la seconde est le jeu sombre.
  final JeuDeCouleurs? moitie;
  final bool actif;
  final VoidCallback quand;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: quand,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Palette.fondSecondaire,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: actif ? Palette.accent : Palette.bordureTrouvee,
              width: actif ? 2 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _apercu()),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: Text(nom,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
            ),
            if (actif) Icon(Icons.check, size: 15, color: Palette.accent),
          ]),
          Text(detail,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Palette.texteDoux)),
        ]),
      ),
    );
  }

  Widget _apercu() {
    final d = moitie;
    Widget case_(Color c, {Color? bord}) => Container(
          width: 20, height: 20,
          decoration: BoxDecoration(
              color: c, borderRadius: BorderRadius.circular(5),
              border: bord == null ? null : Border.all(color: bord, width: 1.5)),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Stack(children: [
        Positioned.fill(
          child: d == null
              ? ColoredBox(color: jeu.fond)
              : Row(children: [
                  Expanded(child: ColoredBox(color: jeu.fond)),
                  Expanded(child: ColoredBox(color: d.fond)),
                ]),
        ),
        Positioned(
            left: 0, right: 0, top: 0, height: 11,
            child: ColoredBox(color: jeu.fondSecondaire)),
        Positioned(
          left: 7, top: 18,
          child: Row(children: [
            case_(jeu.caseVide),
            const SizedBox(width: 5),
            case_(jeu.caseVide, bord: jeu.accent),
            const SizedBox(width: 5),
            case_(d?.caseVide ?? jeu.caseVide),
          ]),
        ),
        Positioned(
          left: 7, bottom: 8,
          child: Container(
              width: 46, height: 4,
              decoration: BoxDecoration(
                  color: jeu.texte.withValues(alpha: .75),
                  borderRadius: BorderRadius.circular(2))),
        ),
        Positioned(
          right: 7, bottom: 7,
          child: Container(
              width: 10, height: 10,
              decoration: BoxDecoration(color: jeu.accent, shape: BoxShape.circle)),
        ),
      ]),
    );
  }
}
