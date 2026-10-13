import 'package:flutter/material.dart';
import '../i18n.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import '../api.dart';
import '../modeles.dart';
import '../reglages.dart';
import '../theme.dart';
import '../widgets/case_dex.dart';
import '../widgets/chargement.dart';
import '../widgets/tourneur.dart';
import '../widgets/cristal.dart';

/// La vitrine d'un joueur : sa pièce en trois dimensions, et ce qui l'a méritée.
///
/// Ouvrable sur soi comme sur un ami — le serveur vérifie l'amitié, l'écran ne
/// fait que passer l'identifiant.
class EcranVitrine extends StatefulWidget {
  const EcranVitrine({super.key, this.joueur, this.pseudo});

  /// Null pour sa propre vitrine.
  final int? joueur;
  final String? pseudo;

  @override
  State<EcranVitrine> createState() => _EcranVitrineState();
}

class _EcranVitrineState extends State<EcranVitrine> {
  Vitrine? _v;
  Palmares? _p;
  String? _erreur;

  /// Les succès tombés à l'ouverture. On les montre une fois, en tête, puis
  /// ils rejoignent la grille : un bandeau permanent finirait par ne plus
  /// rien dire.
  final Set<String> _fetes = {};

  /// Les cristaux en cours de rupture, et ceux déjà ouverts.
  ///
  /// Les cristaux déjà brisés, tenus par les réglages pour survivre à la
  /// fermeture de l'application. Une copie locale servait de mémoire : elle
  /// repartait vide à chaque lancement, et l'animation se rejouait sur des
  /// succès décrochés depuis des semaines.
  Set<String> get _ouverts => Reglages.instance.cristauxOuverts;

  @override
  void initState() {
    super.initState();
    _charge();
  }

  Future<void> _charge() async {
    try {
      final d = await Api.instance.get(widget.joueur == null
          ? '/vitrine'
          : '/vitrine?joueur=${widget.joueur}');
      if (mounted) setState(() => _v = Vitrine.depuisJson(d));
      final s = await Api.instance.get(widget.joueur == null
          ? '/succes'
          : '/succes?joueur=${widget.joueur}');
      if (!mounted) return;
      final palmares = Palmares.depuisJson(s);
      setState(() {
        _p = palmares;
        _fetes.addAll(palmares.nouveaux);
      });
    } on ErreurApi catch (e) {
      if (mounted) setState(() => _erreur = e.message);
    } catch (_) {
      if (mounted) setState(() => _erreur = T('Vitrine indisponible.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pseudo == null
            ? 'Mes succès'
            : 'Succès de ${widget.pseudo}'),
      ),
      body: _erreur != null
          ? Center(
              child: Padding(
                  padding: const EdgeInsets.all(32), child: Text(_erreur!)))
          : v == null
              ? const Chargement()
              : ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    if (_p != null) ..._succesEtPieces(v, _p!),
                  ],
                ),
    );
  }

  /// Le corps de l'écran : le rang, puis les trente succès.
  ///
  /// Le rang reste en tête parce qu'il mesure autre chose — la rareté de ce
  /// qu'on a rapporté — et qu'il se lit d'un coup d'œil. Les succès, eux,
  /// demandent qu'on s'y attarde.
  List<Widget> _succesEtPieces(Vitrine v, Palmares p) {
    final parDifficulte = <String, List<Succes>>{};
    for (final s in p.liste) {
      parDifficulte.putIfAbsent(s.difficulte, () => []).add(s);
    }
    const titres = {
      'facile': 'Faciles',
      'moyen': 'Moyens',
      'difficile': 'Difficiles',
    };
    return [
      // Plus de gros modèle en tête : il faisait doublon avec la grille, et
      // ses `cameraControls` capturaient le geste de défilement — la page
      // restait immobile pendant que la grenouille tournait sous le doigt.
      _entete(v),
      const Divider(height: 28),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
        child: Row(children: [
          Text('${p.obtenus} / ${p.total}',
              style: const TextStyle(
                  fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          Text(T('succès'), style: TextStyle(color: Palette.texteDoux)),
        ]),
      ),
      if (_fetes.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
          child: Text(
              _fetes.length == 1
                  ? 'Un succès vient de tomber.'
                  : '${_fetes.length} succès viennent de tomber.',
              style: TextStyle(
                  color: Palette.accent, fontWeight: FontWeight.w700)),
        ),
      for (final d in ['facile', 'moyen', 'difficile'])
        if (parDifficulte[d] != null) ...[
          _titre(titres[d]!),
          _grille(parDifficulte[d]!),
        ],
      const SizedBox(height: 20),
      _titre(T('Les {0} pièces qui comptent', [v.taille])),
      if (v.pieces.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(
              T('Rien encore. La première espèce trouvée ouvrira la vitrine.'),
              style: TextStyle(fontSize: 13, color: Palette.texteDoux)),
        ),
      for (var i = 0; i < v.pieces.length; i++) _ligne(i + 1, v.pieces[i]),
    ];
  }

  Widget _grille(List<Succes> l) => GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: .72,
        ),
        itemCount: l.length,
        itemBuilder: (_, i) => _carte(l[i]),
      );

  /// Une tuile de succès.
  ///
  /// Verrouillé, on montre le modèle en silhouette noire, le nom et l'emoji —
  /// jamais la condition. C'est le principe du spoiler : on doit pouvoir
  /// deviner, et choisir de ne pas savoir.
  Widget _carte(Succes s) {
    final tombe = _fetes.contains(s.cle);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _ouvre(s),
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
        decoration: BoxDecoration(
          color: s.obtenu ? Palette.fond : Palette.fondSecondaire,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: tombe
                ? Palette.accent
                : s.obtenu
                    ? Palette.accent.withValues(alpha: .45)
                    : Palette.bordureTrouvee.withValues(alpha: .35),
            width: tombe ? 1.8 : 1,
          ),
        ),
        child: Column(children: [
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                child: Opacity(
                  // Verrouillé, le sujet est déjà noir : on l'atténue encore
                  // pour qu'il se lise comme une absence, pas comme une image
                  // sombre.
                  opacity: s.obtenu ? 1 : .38,
                  child: LayoutBuilder(
                    builder: (_, c) => Tourneur(
                      // La planche de chaque succès, plus celle de la
                      // grenouille pour tous : la silhouette d'un verrouillé
                      // doit être celle de sa propre récompense, sinon la
                      // grille montre trente fois le même animal et n'apprend
                      // rien de ce qu'on peut gagner.
                      planche: 'assets/modeles/${s.modele}_tour.webp',
                      taille: c.maxWidth,
                      noir: !s.obtenu,
                      automatique: tombe,
                      manipulable: s.obtenu,
                    ),
                  ),
                ),
              ),
              if (!s.obtenu)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Icon(Icons.lock_outline,
                      size: 12, color: Palette.texteDoux),
                ),
            ]),
          ),
          const SizedBox(height: 4),
          Text('${s.emoji} ${s.nom}',
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 10.5,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                  color: s.obtenu ? Palette.texte : Palette.texteDoux)),
          if (!s.obtenu && s.avancement != null && s.seuil > 1) ...[
            const SizedBox(height: 4),
            // Une barre plutôt qu'un rapport seul : « 12/15 » se lit, une
            // barre se voit.
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: s.part,
                minHeight: 3,
                backgroundColor: Palette.caseVide,
                valueColor: AlwaysStoppedAnimation(Palette.accent),
              ),
            ),
            const SizedBox(height: 2),
            Text('${s.avancement}/${s.seuil}',
                style: TextStyle(fontSize: 9.5, color: Palette.texteDoux)),
          ],
        ]),
      ),
    );
  }

  /// La rupture, plein écran.
  ///
  /// On quitte la feuille pour une route opaque : le cristal occupe alors les
  /// trois quarts de la largeur, sur un fond sombre qui laisse la lumière des
  /// fissures ressortir. C'est la seule mise en scène de l'application qui
  /// mérite qu'on lui donne tout l'écran.
  Future<void> _ouvreLeCristal(
      BuildContext context, Succes s, void Function(VoidCallback) refais) async {
    await Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (c, _, _) => _RuptureCristal(succes: s, teinte: s.teinte, lueur: s.lueur),
    ));
    // Au retour, la gemme est ouverte : la feuille montre le modèle.
    Reglages.instance.retiensCristalOuvert(s.cle);
    refais(() {});
  }

  /// La fiche d'un succès, avec le bouton qui révèle la condition.
  Future<void> _ouvre(Succes s) async {
    var courant = s;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => StatefulBuilder(
        builder: (c, refais) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 34),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Débloqué : le vrai rendu, avec son éclairage et son ombre.
            // C'est l'écran qu'on ouvre exprès pour regarder la pièce — le
            // même raisonnement que le socle. Verrouillé, la silhouette
            // suffit, et charger un demi-mégaoctet de glTF pour la peindre en
            // noir serait absurde.
            SizedBox(
              height: 190,
              // Trois états, dans l'ordre où on les rencontre.
              //
              // Verrouillé : la silhouette, rien d'autre. Débloqué mais pas
              // encore ouvert : le cristal, qu'on touche pour le briser.
              // Ouvert : le modèle, en vrai rendu 3D.
              //
              // On ne saute l'étape du cristal que si le joueur a déjà ouvert
              // ce succès-là — casser deux fois la même gemme n'a rien d'une
              // récompense, c'est une porte qu'on referme sur quelqu'un.
              child: !courant.obtenu
                  ? Tourneur(
                      planche: 'assets/modeles/${courant.modele}_tour.webp',
                      taille: 190,
                      noir: true,
                    )
                  : (_ouverts.contains(courant.cle)
                      ? ModelViewer(
                          src: 'assets/modeles/${courant.modele}.glb',
                          alt: courant.nom,
                          autoRotate: true,
                          cameraControls: true,
                          disableZoom: true,
                          disablePan: true,
                          autoRotateDelay: 1200,
                          rotationPerSecond: '18deg',
                          backgroundColor: Colors.transparent,
                          ar: false,
                        )
                      : GestureDetector(
                          // La rupture ne se joue pas dans la feuille : elle
                          // prend tout l'écran. Une gemme de cent quatre-vingt-
                          // dix pixels au fond d'un panneau ne se regarde pas,
                          // et c'est le moment le plus fort de l'écran.
                          onTap: () => _ouvreLeCristal(context, courant, refais),
                          child: Cristal(
                            taille: 190,
                            teinte: courant.teinte,
                            lueur: courant.lueur,
                          ),
                        )),
            ),
            if (courant.obtenu && !_ouverts.contains(courant.cle))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(T('Touche le cristal'),
                    style: TextStyle(
                        fontSize: 12,
                        color: Palette.texteDoux,
                        fontStyle: FontStyle.italic)),
              ),
            const SizedBox(height: 12),
            Text('${courant.emoji}  ${courant.nom}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            if (courant.obtenu)
              Text(T('Débloqué le {0}', [(courant.obtenuLe ?? '').split(' ').first]),
                  style: TextStyle(fontSize: 12.5, color: Palette.accent))
            else if (courant.avancement != null && courant.seuil > 1)
              Text(T('{0} sur {1}', [courant.avancement, courant.seuil]),
                  style:
                      TextStyle(fontSize: 12.5, color: Palette.texteDoux)),
            const SizedBox(height: 16),
            if (courant.comment != null)
              Text(courant.comment!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13.5,
                      height: 1.4,
                      color: Palette.texteDoux))
            else ...[
              Text(
                  T('La condition est cachée. À toi de deviner — ou de regarder, si tu préfères savoir.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: Palette.texteDoux,
                      fontStyle: FontStyle.italic)),
              const SizedBox(height: 12),
              // Le bouton que la documentation de cette méthode promettait
              // depuis le début sans qu'il existe : le site l'avait, pas
              // l'application. Regarder reste un choix, donc il faut un
              // geste — mais un geste qu'on puisse trouver.
              FilledButton.tonal(
                onPressed: () async {
                  try {
                    await Api.instance.post('/succes/${courant.cle}/reveler');
                    await _charge();
                    if (!mounted) return;
                    // La condition arrive avec le catalogue rechargé : on
                    // remplace l'exemplaire que la feuille tient en main,
                    // sinon elle continuerait d'afficher l'ancien.
                    final maj = _p?.liste.firstWhere(
                        (x) => x.cle == courant.cle,
                        orElse: () => courant);
                    refais(() => courant = maj ?? courant);
                  } on ErreurApi catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(e.message)));
                  }
                },
                child: Text(T('Comment le débloquer ?')),
              ),
              const SizedBox(height: 14),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _entete(Vitrine v) {
    final r = v.rang;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.nom,
              style:
                  const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(T('Rang {0} sur {1} · {2} points', [r.numero, r.total, v.score]),
              style: TextStyle(fontSize: 13, color: Palette.texteDoux)),
          if (r.suivant != null) ...[
            const SizedBox(height: 3),
            Text(T('Encore {0} pts avant {1}', [r.reste, r.suivant]),
                style: TextStyle(fontSize: 12, color: Palette.texteDoux)),
          ],
          const SizedBox(height: 10),
          // Dire ce que la jauge mesure, parce qu'elle ne mesure pas la même
          // chose que celle du dex et que rien à l'écran ne le laisse deviner.
          Text(
              T('La vitrine ne compte que vos {0} plus belles trouvailles. Le rang du dex, lui, compte toutes les espèces.', [v.taille]),
              style: TextStyle(
                  fontSize: 12, color: Palette.texteDoux, height: 1.35)),
        ],
      ),
    );
  }

  Widget _titre(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                letterSpacing: .5,
                color: Palette.texteDoux)),
      );

  Widget _ligne(int rang, PieceVitrine p) {
    // Détourée ou entière : c'est le réglage du joueur qui tranche, le même que
    // pour les cases du dex. Une vitrine qui montrerait ses prises autrement
    // que son dex serait déroutante.
    final chemin = p.photo(entiere: Reglages.instance.casesEntieres);
    return ListTile(
        dense: true,
        leading: SizedBox(
          width: 46,
          height: 46,
          child: chemin == null
              // Sans photo — une espèce trouvée puis la capture supprimée — on
              // garde le numéro plutôt qu'un carré vide.
              ? Center(
                  child: Text('$rang',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Palette.texteDoux)))
              : ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    color: Palette.caseVide,
                    child: ImageServeur(chemin: chemin, taille: 128),
                  ),
                ),
        ),
        title: Text(p.nom,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(p.latin,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 11.5,
                fontStyle: FontStyle.italic,
                color: Palette.texteDoux)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: (Palette.qualites[p.qualite] ?? Palette.texteDoux)
                .withValues(alpha: .16),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(T('{0} pts', [p.points]),
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Palette.qualites[p.qualite] ?? Palette.texteDoux)),
        ),
      );
  }
}


/// L'écran de rupture : le cristal, puis le modèle.
///
/// Séparé de la feuille pour une raison précise — il a son propre cycle de vie.
/// La feuille peut se reconstruire à chaque `setState` ; ici l'animation doit
/// aller jusqu'au bout sans être interrompue.
class _RuptureCristal extends StatefulWidget {
  const _RuptureCristal({
    required this.succes,
    required this.teinte,
    required this.lueur,
  });

  final Succes succes;
  final Color teinte;
  final Color lueur;

  @override
  State<_RuptureCristal> createState() => _RuptureCristalState();
}

class _RuptureCristalState extends State<_RuptureCristal> {
  bool _brise = false;
  bool _ouvert = false;

  @override
  void initState() {
    super.initState();
    // La rupture part seule, après un souffle : on arrive sur cet écran parce
    // qu'on a touché le cristal, le redemander serait un appui de trop.
    Future.delayed(const Duration(milliseconds: 420), () {
      if (mounted) setState(() => _brise = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.succes;
    // Les trois quarts de la largeur, plafonnés : sur une tablette, une gemme
    // de huit cents pixels remplirait l'écran sans rien gagner.
    final cote = (MediaQuery.of(context).size.shortestSide * 0.78).clamp(240.0, 420.0);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        // On ne peut sortir qu'une fois ouvert : couper l'animation au milieu
        // gâcherait la seule chose qu'on est venu voir.
        onTap: _ouvert ? () => Navigator.of(context).pop() : null,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: cote,
              height: cote,
              child: _ouvert
                  ? ModelViewer(
                      src: 'assets/modeles/${s.modele}.glb',
                      alt: s.nom,
                      autoRotate: true,
                      cameraControls: true,
                      disableZoom: true,
                      disablePan: true,
                      autoRotateDelay: 800,
                      rotationPerSecond: '22deg',
                      backgroundColor: Colors.transparent,
                      ar: false,
                    )
                  : Cristal(
                      taille: cote,
                      teinte: widget.teinte,
                      lueur: widget.lueur,
                      brise: _brise,
                      surFin: () => setState(() => _ouvert = true),
                    ),
            ),
            const SizedBox(height: 26),
            // Le nom n'apparaît qu'à l'ouverture : l'annoncer avant volerait
            // la surprise que toute la mise en scène construit.
            AnimatedOpacity(
              opacity: _ouvert ? 1 : 0,
              duration: const Duration(milliseconds: 420),
              child: Column(children: [
                Text('${s.emoji}  ${s.nom}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(T('Succès débloqué'),
                    style: TextStyle(
                        color: widget.teinte, fontWeight: FontWeight.w700)),
                const SizedBox(height: 18),
                Text(T('Touche pour continuer'),
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
