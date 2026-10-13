import 'package:cached_network_image/cached_network_image.dart';
import '../i18n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../reglages.dart';
import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import '../widgets/case_dex.dart';
import '../widgets/reactions.dart';
import '../widgets/regnes.dart';
import 'visionneuse.dart';
import 'visionneuse_galerie.dart';
import '../widgets/chargement.dart';

/// Le détail d'une case : ce qu'elle regroupe, et toutes les photos qu'on y a
/// rangées.
///
/// C'est ici qu'apparaît l'intérêt du regroupement : si on a photographié une
/// vache puis un zébu, les deux clichés sont là, dans la même case, parce que
/// c'est la même espèce.
class EcranDetailCase extends StatefulWidget {
  const EcranDetailCase({super.key, required this.caseId, this.joueur});
  final int caseId;
  final int? joueur;

  @override
  State<EcranDetailCase> createState() => _EcranDetailCaseState();
}

class _EcranDetailCaseState extends State<EcranDetailCase> {
  DetailCase? _detail;
  FicheEspece? _fiche;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _charge();
    _chargeFiche();
  }

  /// Le résumé encyclopédique arrive séparément : il vient de Wikipédia via le
  /// serveur, et rien ne justifie de faire attendre le reste de l'écran.
  Future<void> _chargeFiche() async {
    try {
      final d = await Api.instance.get('/dex/${widget.caseId}/fiche');
      if (mounted) setState(() => _fiche = FicheEspece.depuisJson(d));
    } catch (_) {
      // Sans article, l'écran se passe très bien de cette section.
    }
  }

  Future<void> _charge() async {
    try {
      final d = await Api.instance.get('/dex/${widget.caseId}',
          {if (widget.joueur != null) 'joueur': widget.joueur});
      if (mounted) setState(() => _detail = DetailCase.depuisJson(d));
    } on ErreurApi catch (e) {
      if (mounted) setState(() => _erreur = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    return Scaffold(
      appBar: AppBar(
        title: Text(d?.nom ?? ''),
        actions: [
          // L'image de la case se règle ici, à portée immédiate : elle était
          // enfouie derrière l'ouverture d'une photo, là où personne n'allait
          // la chercher.
          if (d != null && d.decouvert && widget.joueur == null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) => _regleImage(d, v),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'photo',
                  child: ListTile(
                      dense: true,
                      leading: Icon(Icons.image_outlined),
                      title: Text(T('Changer la photo')),
                      subtitle: Text(T('Les vôtres, ou celles de vos amis'),
                          style: TextStyle(fontSize: 11))),
                ),
                // MegaDetector recadre parfois de travers : on doit pouvoir
                // reprendre la photo telle qu'elle a été prise. Trois entrées
                // depuis qu'un réglage général existe — « détouré » et
                // « suivre le réglage » ne sont plus la même chose.
                _cadrage('auto', Icons.auto_awesome_outlined,
                    'Suivre mon réglage', d.cadrage),
                _cadrage('decoupe', Icons.crop,
                    'Toujours l\'animal détouré', d.cadrage),
                _cadrage('entier', Icons.crop_free,
                    'Toujours la photo entière', d.cadrage),
              ],
            ),
        ],
      ),
      body: _erreur != null
          ? Center(child: Text(_erreur!))
          : d == null
              ? const Chargement()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  children: [
                    if (d.regne == 'champignon') const AvertissementChampignon(),
                    // Une case créée par un joueur : on le dit, en orange.
                    //
                    // Personne ne valide ces ajouts — c'est le prix de pouvoir
                    // indexer un cultivar que GBIF ignorera toujours. En
                    // échange, la provenance est affichée : on sait de qui l'on
                    // tient l'information, et on peut lui en parler.
                    if (d.ajouteParPseudo != null)
                      Container(
                        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE08A0B).withValues(alpha: .13),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: const Color(0xFFE08A0B)
                                  .withValues(alpha: .45)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.person_add_alt_1_outlined,
                              size: 17, color: Color(0xFFB06B00)),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              T('Ajouté par {0}. Cette espèce ne vient pas du référentiel : aucune analyse ne la proposera, on l\'y range à la main.', [d.ajouteParPseudo]),
                              style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  color: Color(0xFF8A5200)),
                            ),
                          ),
                        ]),
                      ),
                    _entete(d),
                    const SizedBox(height: 24),
                    if (d.captures.isNotEmpty) ...[
                      Text(T('Mes photos ({0})', [d.captures.length]),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 10),
                      _photos(d),
                      const SizedBox(height: 24),
                    ],
                    if (d.chezLesAmis.isNotEmpty) ...[
                      _chezLesAmis(d),
                      const SizedBox(height: 24),
                    ],
                    _encyclopedie(),
                    _ficheTechnique(d),
                  ],
                ),
    );
  }

  /// Une entrée du menu de cadrage, cochée quand c'est le mode en vigueur.
  PopupMenuItem<String> _cadrage(
      String mode, IconData icone, String libelle, String actuel) {
    final actif = actuel == mode;
    return PopupMenuItem(
      value: mode,
      child: ListTile(
        dense: true,
        leading: Icon(icone, color: actif ? Palette.accent : null),
        title: Text(libelle,
            style: TextStyle(
                color: actif ? Palette.accent : null,
                fontWeight: actif ? FontWeight.w700 : null)),
        subtitle: Text(T('Sur cette case seulement'),
            style: TextStyle(fontSize: 11)),
        trailing: actif
            ? Icon(Icons.check, size: 18, color: Palette.accent)
            : null,
      ),
    );
  }

  /// Une rangée de vignettes à choisir, sous son intertitre.
  ///
  /// `auteur` n'est renseigné que pour les photos des amis : sur les siennes,
  /// répéter son propre pseudo n'apprendrait rien.
  Widget _rangeePhotos({
    required String titre,
    required List<({int id, String vignette, String? auteur})> photos,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Text(titre,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Palette.texteDoux)),
        ),
        SizedBox(
          height: photos.any((p) => p.auteur != null) ? 132 : 116,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            itemCount: photos.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final p = photos[i];
              return InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => Navigator.pop(context, p.id),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox(
                        width: 92,
                        height: 92,
                        child: ImageServeur(chemin: p.vignette, taille: 256),
                      ),
                    ),
                    if (p.auteur != null)
                      SizedBox(
                        width: 92,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(p.auteur!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 11, color: Palette.texteDoux)),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Régler ce que montre la case : quelle photo, et sous quel cadrage.
  Future<void> _regleImage(DetailCase d, String action) async {
    if (action == 'photo') {
      if (d.captures.isEmpty && d.chezLesAmis.isEmpty) return;
      final choisie = await showModalBottomSheet<int>(
        context: context,
        builder: (_) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(T('Quelle photo pour la case ?'),
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
            if (d.captures.isNotEmpty)
              _rangeePhotos(
                titre: T('Les miennes'),
                photos: [
                  for (final c in d.captures)
                    (id: c.id, vignette: c.vignette, auteur: null),
                ],
              ),
            // Sur une espèce que plusieurs ont trouvée, l'un a souvent bien
            // mieux réussi son cliché. S'interdire de le mettre en avant
            // n'avait aucune raison d'être — la case reste la nôtre, et le
            // crédit va à qui a pris la photo.
            if (d.chezLesAmis.isNotEmpty)
              _rangeePhotos(
                titre: T('Chez mes amis'),
                photos: [
                  for (final a in d.chezLesAmis)
                    (id: a.id, vignette: a.vignette, auteur: a.pseudo),
                ],
              ),
            const SizedBox(height: 10),
          ]),
        ),
      );
      if (choisie == null || !mounted) return;
      await Api.instance.post('/dex/${widget.caseId}/vedette/$choisie');
    } else {
      await Api.instance.post('/dex/${widget.caseId}/cadrage/$action');
    }
    if (!mounted) return;
    await _charge();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(switch (action) {
        'entier' => T('La case montre la photo entière.'),
        'decoupe' => T('La case montre l\'animal détouré.'),
        'auto' => T('La case suit votre réglage général.'),
        _ => T('Photo de la case changée.'),
      }),
    ));
  }

  Widget _entete(DetailCase d) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 104,
          height: 104,
          decoration: BoxDecoration(
            color: Palette.caseVide,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: d.decouvert ? Palette.bordureTrouvee : Colors.transparent,
              width: 1.5,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: d.decouvert && _image(d).chemin != null
              ? (_image(d).detouree
                  ? Padding(
                      padding: const EdgeInsets.all(8),
                      child: Image.network(
                          Api.instance.image(_image(d).chemin!).toString(),
                          headers: Api.instance.entetes, fit: BoxFit.contain),
                    )
                  : Image.network(Api.instance.image(_image(d).chemin!).toString(),
                      headers: Api.instance.entetes, fit: BoxFit.cover))
              : Padding(
                  padding: const EdgeInsets.all(14),
                  child: d.visuel == null
                      ? Icon(Icons.help_outline, color: Palette.silhouette)
                      : SvgPicture.network(
                          Api.instance.image(d.visuel!).toString(),
                          colorFilter: ColorFilter.mode(
                              Palette.silhouette, BlendMode.srcIn),
                        ),
                ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(d.decouvert ? d.nom : T('Espèce non trouvée'),
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800, height: 1.2)),
              const SizedBox(height: 2),
              Text(d.latin,
                  style: TextStyle(
                      fontStyle: FontStyle.italic,
                      color: Palette.texteDoux,
                      fontSize: 14)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 6, children: [
                PastilleRarete(rarete: d.rarete, points: d.points),
                PastilleRegne(regne: d.regne),
                if (d.classe.isNotEmpty)
                  _etiquette(nomDeClasse(d.classe)),
              ]),
            ],
          ),
        ),
      ],
    );
  }

  Widget _etiquette(String texte) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Palette.fondSecondaire,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(texte,
            style: TextStyle(fontSize: 12, color: Palette.texteDoux)),
      );

  Widget _photos(DetailCase d) {
    // Le dex d'un ami se regarde, ne se modifie pas.
    final aMoi = widget.joueur == null;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: d.captures.length,
      itemBuilder: (context, i) {
        final c = d.captures[i];
        return GestureDetector(
          // Appui long : cette photo devient l'image de la case. Si elle n'a
          // pas encore été détourée, le serveur s'en charge à ce moment-là,
          // sans relancer d'analyse.
          onLongPress: aMoi ? () => _changeImageDeCase(c.id) : null,
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Visionneuse(
                captures: d.captures,
                depart: i,
                titre: d.nom,
                surVedette: aMoi
                    ? (id) async {
                        await Api.instance.post('/dex/${widget.caseId}/vedette/$id');
                      }
                    : null,
                cadrage: d.cadrage,
                surCadrage: aMoi
                    ? (mode) async {
                        await Api.instance
                            .post('/dex/${widget.caseId}/cadrage/$mode');
                      }
                    : null,
                surSuppression: aMoi
                    ? (id) async => Api.instance.supprime('/captures/$id')
                    : null,
              ),
            ));
            _charge();
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(fit: StackFit.expand, children: [
              Image.network(
                Api.instance.image(c.vignette).toString(),
                headers: Api.instance.entetes,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(color: Palette.caseVide),
              ),
              // Le titre en bandeau bas, sur un fond dégradé : il se lit sur
              // n'importe quelle photo sans recouvrir la bête, contrairement à
              // une pastille posée en plein milieu.
              if (c.titre.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(6, 12, 6, 5),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: .62),
                        ],
                      ),
                    ),
                    child: Text(
                      c.titre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ]),
          ),
        );
      },
    );
  }

  /// Choisit la photo qui représente la case, en la détourant au besoin.
  Future<void> _changeImageDeCase(int captureId) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          duration: Duration(seconds: 1),
          content: Text(T('Découpe de la photo…'))),
    );
    try {
      final d = await Api.instance
          .post('/dex/${widget.caseId}/vedette/$captureId');
      if (!mounted) return;
      await _charge();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(d['decoupe'] != null
              ? 'Image de la case remplacée.'
              : 'Photo mise en avant (détourage impossible, la vignette est utilisée).'),
        ),
      );
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Widget _ficheTechnique(DetailCase d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(T('Fiche'),
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        _ligne('Famille', d.famille.isEmpty ? '—' : d.famille),
        _ligne('Groupe', d.classe.isEmpty ? '—' : nomDeClasse(d.classe)),
        _ligne('Observations', '${d.obs}'),
        if (d.trouveLe != null) _ligne('Trouvée le', d.trouveLe!.split(' ').first),
        if (d.alias.length > 1) ...[
          const SizedBox(height: 16),
          Text(T('Regroupe aussi'),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            T('Ces noms désignent la même espèce : sous-espèces et anciens noms scientifiques partagent une seule case.'),
            style:
                TextStyle(color: Palette.texteDoux, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in d.alias.skip(1))
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Palette.fondSecondaire,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(a,
                      style: TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: Palette.texteDoux)),
                ),
            ],
          ),
        ],
        if (d.captures.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: 20),
            child: Text(T('Touchez une photo pour la voir en grand, appui long pour en faire l\'image de la case.'),
                style: TextStyle(color: Palette.texteDoux, fontSize: 12)),
          ),
      ],
    );
  }

  /// Les photos que des amis ont prises de la même espèce.
  ///
  /// C'est là que la case prend tout son sens : deux personnes qui ont trouvé
  /// le même bœuf voient leurs clichés côte à côte, et peuvent se congratuler
  /// sans quitter l'écran.
  /// Une rangée qui défile, pas un mur.
  ///
  /// Une carte dépliée par photo devenait illisible au-delà de quatre ou cinq :
  /// ici chaque photo tient dans une vignette, et c'est l'appui qui l'ouvre en
  /// grand. On y réagit dans la visionneuse, où l'on voit vraiment ce qu'on
  /// commente.
  Widget _chezLesAmis(DetailCase d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text(T('Chez vos amis ({0})', [d.chezLesAmis.length]),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (d.chezLesAmis.length > 3)
            Text(T('faites glisser →'),
                style: TextStyle(fontSize: 11, color: Palette.texteDoux)),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: 148,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: d.chezLesAmis.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) => _vignetteAmi(d, i),
          ),
        ),
      ],
    );
  }

  Widget _vignetteAmi(DetailCase d, int index) {
    final p = d.chezLesAmis[index];
    return SizedBox(
      width: 116,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _ouvreChezLesAmis(d, index),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: ImageServeur(chemin: p.vignette, taille: 256),
                    ),
                  ),
                  if (p.titre.isNotEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(7, 5, 7, 12),
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(14)),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: .6),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Text(p.titre,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                  // L'auteur en médaillon, posé sur l'image : on sait de qui
                  // est la photo sans ligne de texte supplémentaire.
                  Positioned(
                    left: 5,
                    bottom: 5,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                          color: Palette.fond, shape: BoxShape.circle),
                      child: Avatar(
                          pseudo: p.pseudo, chemin: p.avatar, taille: 24),
                    ),
                  ),
                  // Ce que la photo a déjà récolté. Une pastille vide serait du
                  // bruit : elle n'apparaît que s'il y a des réactions.
                  if (p.reactions.total > 0)
                    Positioned(
                      right: 5,
                      bottom: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .62),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(
                          '${p.reactions.emojisEnTete(2)} ${p.reactions.total}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  // Un liseré quand j'ai déjà réagi : d'un coup d'œil je vois
                  // les photos qu'il me reste à saluer.
                  if (p.reactions.maReaction != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Palette.accent, width: 2),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            p.titre.isNotEmpty ? '« ${p.titre} »' : p.pseudo,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
          Text(
            p.titre.isNotEmpty ? p.pseudo : p.creeLe.split(' ').first,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: Palette.texteDoux),
          ),
        ],
      ),
    );
  }

  /// Ouvre la rangée en plein écran, à la photo touchée. On y feuillette les
  /// autres du doigt.
  Future<void> _ouvreChezLesAmis(DetailCase d, int index) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VisionneuseGalerie(
        photos: [
          for (final a in d.chezLesAmis)
            a.versGalerie(
                espece: d.nom,
                caseId: d.id,
                qualite: d.rarete),
        ],
        depart: index,
      ),
    ));
    // Les réactions posées en plein écran doivent se retrouver sur la rangée.
    if (mounted) _charge();
  }

  /// Ce que Wikipédia dit de l'espèce.
  /// L'illustration en grand, qu'on peut déplacer et agrandir.
  void _ouvreImage(FicheEspece f) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 8,
              child: Center(
                child: CachedNetworkImage(imageUrl: f.image, fit: BoxFit.contain),
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: 8,
            child: SafeArea(
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: .4),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _encyclopedie() {
    final f = _fiche;
    if (f == null || !f.trouvee) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(T('En bref'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            if (f.langue != 'fr')
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Palette.fondSecondaire,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(f.langue.toUpperCase(),
                    style: TextStyle(
                        fontSize: 10, color: Palette.texteDoux)),
              ),
          ]),
          const SizedBox(height: 10),
          // L'article peut porter sur le genre faute d'article d'espèce : on
          // le dit, plutôt que de laisser croire que la fiche décrit
          // exactement ce qu'on a photographié.
          if (f.approximation == 'genre')
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFB08A00).withValues(alpha: .10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                const Text('*',
                    style: TextStyle(
                        color: Color(0xFFB08A00),
                        fontSize: 16,
                        fontWeight: FontWeight.w900)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    T('Pas d\'article pour cette espèce : voici celui du genre {0}.', [f.titre]),
                    style: const TextStyle(
                        fontSize: 11.5, color: Color(0xFF8A6D00), height: 1.3),
                  ),
                ),
              ]),
            ),
          if (f.image.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GestureDetector(
                // L'image s'ouvre en grand : sur une planche botanique, le
                // détail qui distingue deux espèces ne tient pas dans 170
                // pixels de haut.
                onTap: () => _ouvreImage(f),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Stack(children: [
                    CachedNetworkImage(imageUrl: f.image,
                        width: double.infinity,
                        height: 170,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => const SizedBox.shrink()),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.zoom_out_map,
                            size: 14, color: Colors.white),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          Text(f.resume,
              style: const TextStyle(fontSize: 14, height: 1.5)),
          const SizedBox(height: 8),
          if (f.url.isNotEmpty)
            InkWell(
              onTap: () => launchUrl(Uri.parse(f.url),
                  mode: LaunchMode.externalApplication),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Icon(Icons.open_in_new,
                      size: 13, color: Palette.accent),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(T('Lire sur Wikipédia — {0}', [f.titre]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: Palette.accent,
                            fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
            )
          else
            Text(T('Source : Wikipédia — {0}', [f.titre]),
                style: TextStyle(fontSize: 11, color: Palette.texteDoux)),
        ],
      ),
    );
  }

  Widget _ligne(String cle, String valeur) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          SizedBox(
            width: 120,
            child: Text(cle,
                style:
                    TextStyle(color: Palette.texteDoux, fontSize: 13)),
          ),
          Expanded(
              child: Text(valeur, style: const TextStyle(fontSize: 13))),
        ]),
      );
}

/// La photo de la fiche : le même choix que la grille du dex — réglage
/// « photo entière » et cadrage de la case — et non la découpe d'office.
({String? chemin, bool detouree}) _image(CaseDex d) =>
    d.imageDeCase(entieresParDefaut: Reglages.instance.casesEntieres);
