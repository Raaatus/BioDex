import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import '../widgets/case_dex.dart';
import '../widgets/tourneur.dart';

/// Le profil d'un joueur : ce qu'il a choisi de montrer.
///
/// Toucher un ami ouvrait directement son dex — une grille de silhouettes, sans
/// rien qui dise **qui** on regarde. Le dex reste à un bouton d'ici ; c'est
/// désormais le profil qui accueille.
///
/// Trois blocs, dans cet ordre parce que c'est l'ordre de ce qu'on cherche :
/// sa vitrine (ce dont il est fier), ses succès, puis ses trouvailles.
///
/// **La confidentialité ne change pas.** Le serveur décide seul de ce qui part :
/// il dit qu'un succès est décroché, mais n'envoie sa grenouille que si le
/// regardeur l'a lui aussi. Rien n'est filtré ici — filtrer à l'affichage
/// laisserait tout lisible dans la réponse.
class EcranProfilJoueur extends StatefulWidget {
  const EcranProfilJoueur({super.key, required this.joueurId, this.pseudo});

  final int joueurId;
  final String? pseudo;

  @override
  State<EcranProfilJoueur> createState() => _EcranProfilJoueurState();
}

class _EcranProfilJoueurState extends State<EcranProfilJoueur> {
  Map<String, dynamic>? _profil;
  DetailJoueur? _detail;
  String? _erreur;

  final List<dynamic> _trouvailles = [];
  bool _chargeTrouvailles = false;
  bool _finTrouvailles = false;

  final _defilement = ScrollController();

  @override
  void initState() {
    super.initState();
    _charge();
    _defilement.addListener(() {
      if (_defilement.position.pixels >
          _defilement.position.maxScrollExtent - 320) {
        _chargeLaSuite();
      }
    });
  }

  @override
  void dispose() {
    _defilement.dispose();
    super.dispose();
  }

  Future<void> _charge() async {
    try {
      final p = await Api.instance.get('/utilisateurs/${widget.joueurId}');
      if (!mounted) return;
      setState(() => _profil = Map<String, dynamic>.from(p));
      // Le détail des points arrive après : le profil suffit à ouvrir l'écran,
      // et faire attendre les deux pour n'en montrer qu'un plus tard serait une
      // lenteur gratuite.
      final d = await Api.instance.get('/classement/joueur/${widget.joueurId}');
      if (!mounted) return;
      setState(() => _detail = DetailJoueur.depuisJson(d));
    } catch (e) {
      if (mounted) setState(() => _erreur = '$e');
    }
  }

  Future<void> _chargeLaSuite() async {
    if (_chargeTrouvailles || _finTrouvailles) return;
    setState(() => _chargeTrouvailles = true);
    try {
      final d = await Api.instance.get(
          '/utilisateurs/${widget.joueurId}/trouvailles',
          {'limite': 20, 'depuis': _trouvailles.length});
      if (!mounted) return;
      setState(() {
        _trouvailles.addAll(d['trouvailles'] as List? ?? const []);
        _finTrouvailles = d['fin'] ?? true;
      });
    } catch (_) {
      // Une page qui ne vient pas ne doit pas bloquer le reste du profil.
      if (mounted) setState(() => _finTrouvailles = true);
    } finally {
      if (mounted) setState(() => _chargeTrouvailles = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _profil;
    return Scaffold(
      appBar: AppBar(title: Text(p?['pseudo'] ?? widget.pseudo ?? 'Profil')),
      body: _erreur != null
          ? Center(child: Padding(
              padding: const EdgeInsets.all(24), child: Text(_erreur!)))
          : p == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  controller: _defilement,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                  children: [
                    _entete(p),
                    _vitrine(p),
                    _succes(p),
                    _lesTrouvailles(p),
                  ],
                ),
    );
  }

  Widget _entete(Map<String, dynamic> p) {
    final d = _detail;
    return Column(children: [
      CircleAvatar(
        radius: 44,
        backgroundColor: Palette.caseVide,
        backgroundImage: p['avatar'] != null
            ? NetworkImage(Api.instance.image(p['avatar']).toString(),
                headers: Api.instance.entetes)
            : null,
        child: p['avatar'] == null
            ? Text((p['pseudo'] ?? '?').toString().characters.first.toUpperCase(),
                style: TextStyle(
                    fontSize: 32, color: Palette.texte,
                    fontWeight: FontWeight.w800))
            : null,
      ),
      const SizedBox(height: 10),
      Text(p['pseudo'] ?? '',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      Text(T('{0} espèces trouvées', [p['cases'] ?? 0]),
          style: TextStyle(color: Palette.texteDoux, fontSize: 13)),
      if ((p['bio'] ?? '').toString().isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(p['bio'], textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13.5)),
        ),
      if (d != null) ...[
        const SizedBox(height: 12),
        Text(T('{0} points · {1} photos', [d.total, d.photos]),
            style: TextStyle(color: Palette.texteDoux, fontSize: 12.5)),
      ],
      const SizedBox(height: 14),
      // Le dex reste accessible : c'est ce que faisait l'écran avant, et
      // quelqu'un qui vient comparer ses trouvailles ne doit pas le perdre.
      OutlinedButton.icon(
        onPressed: () => Navigator.of(context).pop('dex'),
        icon: const Icon(Icons.grid_view_outlined, size: 18),
        label: Text(T('Voir son dex')),
      ),
    ]);
  }

  Widget _titre(String texte, [String? suffixe]) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 22, 0, 8),
        child: Row(children: [
          Text(texte.toUpperCase(),
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w800,
                  letterSpacing: .5, color: Palette.texteDoux)),
          if (suffixe != null) ...[
            const SizedBox(width: 6),
            Text(suffixe, style: TextStyle(
                fontSize: 11.5, color: Palette.texteDoux)),
          ],
        ]),
      );

  Widget _vitrine(Map<String, dynamic> p) {
    final v = p['vitrine'] as List? ?? const [];
    if (v.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _titre(T('Sa vitrine')),
      GridView.count(
        crossAxisCount: 2, shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 4 / 3,
        children: [
          for (final x in v)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ImageServeur(chemin: x['decoupe'] ?? x['vignette']),
            ),
        ],
      ),
    ]);
  }

  Widget _succes(Map<String, dynamic> p) {
    final s = p['succes'] as List? ?? const [];
    if (s.isEmpty) return const SizedBox.shrink();
    final caches = s.where((x) => x['montrable'] != true).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _titre(T('Ses succès'), '${s.length}'),
      GridView.count(
        crossAxisCount: 4, shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: .82,
        children: [for (final x in s) _tuileSucces(x)],
      ),
      if (caches > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
              caches == 1
                  ? 'Un succès reste caché : on ne dévoile pas une récompense que tu n\'as pas encore gagnée.'
                  : '$caches succès restent cachés : on ne dévoile pas une récompense que tu n\'as pas encore gagnée.',
              style: TextStyle(fontSize: 11.5, color: Palette.texteDoux)),
        ),
    ]);
  }

  Widget _tuileSucces(dynamic x) {
    final montrable = x['montrable'] == true;
    final teinte = _couleur(x['couleurs']?['corps']) ?? Palette.bordureTrouvee;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        color: Palette.fondSecondaire,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: montrable ? teinte : Palette.bordureTrouvee, width: 1),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Expanded(
          child: montrable
              ? Tourneur(
                  planche: 'assets/modeles/${x['modele']}_tour.webp',
                  taille: 44)
              // Un point d'interrogation, et non la silhouette du vrai modèle :
              // une ombre reconnaissable en dirait déjà trop.
              : Center(
                  child: Text('?',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w900,
                          color: Palette.silhouette))),
        ),
        const SizedBox(height: 3),
        Text('${x['emoji'] ?? ''} ${x['nom'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _lesTrouvailles(Map<String, dynamic> p) {
    final total = p['nb_trouvailles'] ?? 0;
    if (total == 0) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _titre(T('Ses trouvailles'), '$total'),
      for (final t in _trouvailles)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: SizedBox(
            width: 32, height: 32,
            child: t['visuel'] != null
                ? ImageServeur(chemin: t['visuel'], fit: BoxFit.contain)
                : null,
          ),
          title: Text(t['nom_fr'] ?? t['latin'] ?? '',
              style: const TextStyle(fontSize: 14)),
          subtitle: Text((t['trouve_le'] ?? '').toString().split(' ').first,
              style: TextStyle(fontSize: 11.5, color: Palette.texteDoux)),
          trailing: Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
              color: Palette.qualite(t['rarete'] ?? 2), shape: BoxShape.circle),
          ),
        ),
      if (_chargeTrouvailles)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_trouvailles.isEmpty)
        OutlinedButton(
          onPressed: _chargeLaSuite,
          child: Text(T('Voir ses trouvailles')),
        ),
    ]);
  }

  /// « #a1b2c3 » tel que l'envoie le serveur, ou rien quand il ne l'envoie pas —
  /// ce qui est le cas des succès qu'on n'a pas soi-même.
  Color? _couleur(dynamic hexa) {
    if (hexa is! String) return null;
    final n = int.tryParse(hexa.replaceFirst('#', ''), radix: 16);
    return n == null ? null : Color(0xFF000000 | n);
  }
}
