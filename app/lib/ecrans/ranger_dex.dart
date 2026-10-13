import 'package:flutter/material.dart';
import '../i18n.dart';

import '../disposition.dart';
import '../modeles.dart';
import '../theme.dart';
import '../widgets/case_dex.dart';

/// Ranger son dex : déplacer, redimensionner, changer la forme des vignettes.
///
/// Un écran à part, et pas un mode posé sur le dex. Ranger et consulter sont
/// deux intentions qui ne cohabitent pas : un appui doit sélectionner **ou**
/// ouvrir une fiche, jamais les deux selon un état invisible. L'écran dédié
/// rend aussi le retour sans enregistrer évident — on quitte, rien n'a bougé.
///
/// La grille reprend exactement la géométrie du dex : cinq colonnes, mêmes
/// gouttières. Une cellule vaut une vignette d'origine, et un dex qu'on n'a
/// jamais rangé est identique à ce qu'il était.
class EcranRangerDex extends StatefulWidget {
  const EcranRangerDex({super.key, required this.trouvees, required this.partiel});

  final List<CaseDex> trouvees;

  /// Vrai quand le dex n'a chargé qu'une partie des trouvailles : le serveur ne
  /// doit alors toucher qu'aux cases qu'on lui envoie.
  final bool partiel;

  @override
  State<EcranRangerDex> createState() => _EcranRangerDexState();
}

class _EcranRangerDexState extends State<EcranRangerDex> {
  static const _gouttiere = 8.0;
  static const _espace = 10.0;
  static const _nom = 20.0;
  static const _profondeur = 40;

  late Map<int, Place> _places;
  late List<Vide> _vides;

  /// La pile des états précédents.
  ///
  /// On empile un instantané **avant** chaque geste plutôt que de décrire le
  /// geste : défaire devient une affectation au lieu d'une inversion à écrire
  /// pour chaque type d'action, et trente positions pèsent deux kilo-octets.
  final List<(Map<int, Place>, List<Vide>)> _histoire = [];

  Object? _choisie;      // un `int` (case) ou un `int` négatif décalé (vide)
  bool _sale = false;
  bool _envoie = false;

  // Le glissement en cours.
  Object? _porte;
  Offset? _doigt;
  Offset _saisie = Offset.zero;
  Size _tailleFantome = Size.zero;
  String? _derniereCellule;

  final _defilement = ScrollController();

  @override
  void initState() {
    super.initState();
    _places = _disposeTout();
    _vides = [for (final v in Disposition.instance.vides) v.copie()];
  }

  @override
  void dispose() {
    _defilement.dispose();
    super.dispose();
  }

  /// Fige la disposition courante, positions calculées d'office comprises.
  ///
  /// Sans ça, déplacer une vignette recalculerait la place de toutes les autres
  /// et l'écran sauterait à chaque geste.
  Map<int, Place> _disposeTout() {
    final colonnes = Disposition.instance.colonnes;
    final connues = Disposition.instance.places;
    final sortie = <int, Place>{};
    final occupe = <String>{};

    void marque(Place p) {
      for (var y = p.rangee; y < p.rangee + p.hauteur; y++) {
        for (var x = p.colonne; x < p.colonne + p.largeur; x++) {
          occupe.add('$x,$y');
        }
      }
    }

    final libres = <CaseDex>[];
    for (final c in widget.trouvees) {
      final p = connues[c.id];
      if (p != null) {
        sortie[c.id] = p.copie();
        marque(p);
      } else {
        libres.add(c);
      }
    }

    var col = 0;
    var rang = 0;
    for (final c in libres) {
      while (occupe.contains('$col,$rang')) {
        col += 1;
        if (col >= colonnes) {
          col = 0;
          rang += 1;
        }
      }
      final p = Place(colonne: col, rangee: rang);
      sortie[c.id] = p;
      marque(p);
    }
    return sortie;
  }

  // ------------------------------------------------------------- l'historique

  void _retiens() {
    _histoire.add((
      {for (final e in _places.entries) e.key: e.value.copie()},
      [for (final v in _vides) v.copie()],
    ));
    if (_histoire.length > _profondeur) _histoire.removeAt(0);
    _sale = true;
  }

  void _defait() {
    if (_histoire.isEmpty) return;
    final (p, v) = _histoire.removeLast();
    setState(() {
      _places = p;
      _vides = v;
      _sale = _histoire.isNotEmpty;
    });
  }

  // ------------------------------------------------------------ le démêlage

  /// Défaire **toutes** les superpositions, pas seulement celles de la vignette
  /// qu'on vient de poser.
  ///
  /// Une vignette repoussée retombe sur une autre, qui retombe sur une
  /// troisième : ne traiter que les voisines directes laissait la grille
  /// empilée dès le deuxième geste. On relit donc toutes les paires après
  /// chaque passe.
  void _demele(Object? ancree) {
    final tout = <(Object, Place)>[
      for (final e in _places.entries)
        if (!e.value.masque) (e.key, e.value),
      for (var i = 0; i < _vides.length; i++) (_cleVide(i), _vides[i]),
    ];

    for (var passe = 0; passe < 200; passe++) {
      tout.sort((a, b) => a.$2.rangee != b.$2.rangee
          ? a.$2.rangee - b.$2.rangee
          : a.$2.colonne - b.$2.colonne);
      var bouge = false;
      for (var i = 0; i < tout.length; i++) {
        for (var j = i + 1; j < tout.length; j++) {
          final (idA, a) = tout[i];
          final (idB, b) = tout[j];
          if (!a.croise(b)) continue;
          // On descend celle qui est déjà la plus basse — jamais celle qu'on
          // vient de poser, sinon on repousserait ce qu'on essaie de placer.
          final victime = idA == ancree ? b : (idB == ancree ? a : b);
          final fixe = identical(victime, b) ? a : b;
          victime.rangee = fixe.rangee + fixe.hauteur;
          bouge = true;
        }
      }
      if (!bouge) return;
    }
    // Garde-fou : une grille finie se démêle toujours, mais des données abîmées
    // ne doivent pas figer l'écran.
  }

  /// Les cases vides sont désignées par un entier négatif, pour ne jamais se
  /// confondre avec un identifiant d'espèce.
  int _cleVide(int i) => -(i + 1);
  bool _estVide(Object? cle) => cle is int && cle < 0;
  int _rangVide(Object cle) => -(cle as int) - 1;

  Place? _placeDe(Object cle) =>
      _estVide(cle) ? _vides.elementAtOrNull(_rangVide(cle)) : _places[cle];

  // ------------------------------------------------------------- les gestes

  void _pose(Object cle, int colonne, int rangee) {
    final p = _placeDe(cle);
    if (p == null) return;
    final colonnes = Disposition.instance.colonnes;
    final c = colonne.clamp(0, colonnes - p.largeur);
    final r = rangee < 0 ? 0 : rangee;
    if (p.colonne == c && p.rangee == r) return;

    // Deux vignettes de même gabarit s'échangent : c'est ce qu'on attend en
    // déposant une icône sur une autre, et c'est réversible d'un geste. Un
    // échange entre gabarits différents laisserait des trous imprévisibles.
    final vise = Place(colonne: c, rangee: r, largeur: p.largeur, hauteur: p.hauteur);
    final genants = [
      for (final e in _places.entries)
        if (e.key != cle && !e.value.masque && vise.croise(e.value)) e.value,
    ];

    _retiens();
    if (genants.length == 1 && !_estVide(cle)) {
      final autre = genants.first;
      if (autre.largeur == p.largeur && autre.hauteur == p.hauteur) {
        autre.colonne = p.colonne;
        autre.rangee = p.rangee;
        p.colonne = c;
        p.rangee = r;
        setState(() {});
        return;
      }
    }
    p.colonne = c;
    p.rangee = r;
    // Une case vide a le droit de recouvrir : c'est un trou, et l'y interdire
    // empêcherait de la sortir d'un endroit encombré.
    if (!_estVide(cle)) _demele(cle);
    setState(() {});
  }

  void _taille(Object cle, int l, int h) {
    final p = _placeDe(cle);
    if (p == null) return;
    final max = Disposition.instance.tailleMax;
    final colonnes = Disposition.instance.colonnes;
    _retiens();
    p.largeur = l.clamp(1, max);
    p.hauteur = h.clamp(1, max);
    p.colonne = p.colonne.clamp(0, colonnes - p.largeur);
    if (!_estVide(cle)) _demele(cle);
    setState(() {});
  }

  void _changeForme(Object cle, String? forme) {
    final p = _placeDe(cle);
    if (p == null) return;
    _retiens();
    p.forme = forme;
    setState(() {});
  }

  void _basculeMasque(int id) {
    final p = _places[id];
    if (p == null) return;
    _retiens();
    p.masque = !p.masque;
    _choisie = null;
    setState(() {});
  }

  void _ajouteVide() {
    _retiens();
    final colonnes = Disposition.instance.colonnes;
    final pris = <Place>[
      for (final p in _places.values)
        if (!p.masque) p,
      ..._vides,
    ];
    var c = 0;
    var r = 0;
    for (var i = 0; i < 6000; i++) {
      final essai = Place(colonne: c, rangee: r);
      if (!pris.any(essai.croise)) break;
      c += 1;
      if (c >= colonnes) {
        c = 0;
        r += 1;
      }
    }
    _vides.add(Vide(colonne: c, rangee: r));
    setState(() {});
  }

  void _retireVide(int i) {
    _retiens();
    _vides.removeAt(i);
    _choisie = null;
    setState(() {});
  }

  // ---------------------------------------------------------- enregistrement

  Future<void> _enregistre() async {
    setState(() => _envoie = true);
    try {
      await Disposition.instance
          .enregistre(_places, _vides, partiel: widget.partiel);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _envoie = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _parDefaut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(T('Revenir à la disposition automatique ?')),
        content: Text(T('Ton arrangement sera perdu.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(T('Annuler'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(T('Remettre à zéro'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Disposition.instance.remiseAZero();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<bool> _peutQuitter() async {
    if (!_sale) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(T('Quitter sans enregistrer ?')),
        content: Text(T('Les changements seront perdus.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(T('Rester'))),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(T('Quitter'))),
        ],
      ),
    );
    return ok == true;
  }

  // ------------------------------------------------------------------- rendu

  double _cote(double largeur) {
    final colonnes = Disposition.instance.colonnes;
    return (largeur - 32 - (colonnes - 1) * _gouttiere) / colonnes;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (fait, _) async {
        if (fait) return;
        // On saisit le navigateur avant l'attente : après, le contexte de
        // `build` peut ne plus être valide, et l'analyseur a raison de le dire.
        final nav = Navigator.of(context);
        if (await _peutQuitter()) nav.pop(false);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(T('Ranger mon dex')),
          actions: [
            IconButton(
              tooltip: T('Annuler la dernière action'),
              onPressed: _histoire.isEmpty ? null : _defait,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: T('Disposition automatique'),
              onPressed: _parDefaut,
              icon: const Icon(Icons.restart_alt),
            ),
            // « Enregistrer » vit dans l'en-tête, et pas seulement en bas.
            //
            // La barre du bas peut se retrouver sous la barre système, ou
            // repoussée hors de l'écran quand le panneau de réglage est
            // déplié. L'action qui conclut tout le travail ne doit dépendre
            // d'aucune de ces conditions : en haut, elle est toujours là.
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 10, 8),
              child: FilledButton.icon(
                onPressed: _envoie ? null : _enregistre,
                icon: _envoie
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check, size: 18),
                label: Text(T('Enregistrer')),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    visualDensity: VisualDensity.compact),
              ),
            ),
          ],
        ),
        body: LayoutBuilder(builder: (context, contraintes) {
          final cote = _cote(contraintes.maxWidth);
          return Stack(children: [
            _grille(cote, contraintes.maxWidth),
            // Le fantôme est dessiné par-dessus tout : le doigt cache ce qu'il
            // déplace, et sans copie sous lui on ne sait ni ce qu'on tient ni
            // où on le pose.
            if (_porte != null && _doigt != null) _fantome(),
          ]);
        }),
        bottomNavigationBar: _barre(),
      ),
    );
  }

  Widget _grille(double cote, double largeur) {
    final hauteur = cote + _nom;

    // La rangée la plus basse occupée, plus deux de marge : on doit pouvoir
    // poser une vignette en dessous de tout ce qui existe.
    var rangs = 1;
    for (final p in [..._places.values, ..._vides]) {
      if (p.rangee + p.hauteur > rangs) rangs = p.rangee + p.hauteur;
    }
    rangs += 2;

    Rect boite(Place p) => Rect.fromLTWH(
          16 + p.colonne * (cote + _gouttiere),
          p.rangee * (hauteur + _espace),
          p.largeur * cote + (p.largeur - 1) * _gouttiere,
          p.hauteur * hauteur + (p.hauteur - 1) * _espace,
        );

    final parId = {for (final c in widget.trouvees) c.id: c};

    return Listener(
      onPointerDown: (e) => _prend(e.localPosition, boite),
      onPointerMove: (e) => _suit(e.localPosition, cote, hauteur),
      onPointerUp: (_) => _lache(),
      onPointerCancel: (_) => _lache(),
      child: SingleChildScrollView(
        controller: _defilement,
        // Le doigt sert à déplacer les vignettes pendant un glissement : on
        // interdit le défilement tant qu'on en tient une.
        physics: _porte != null
            ? const NeverScrollableScrollPhysics()
            : const ClampingScrollPhysics(),
        child: SizedBox(
          height: rangs * (hauteur + _espace) + 24,
          width: largeur,
          child: Stack(children: [
            for (final e in _places.entries)
              if (parId[e.key] != null)
                _vignette(e.key, parId[e.key]!, e.value, boite(e.value)),
            for (var i = 0; i < _vides.length; i++)
              _caseVide(i, boite(_vides[i])),
          ]),
        ),
      ),
    );
  }

  Widget _vignette(int id, CaseDex c, Place p, Rect r) {
    final active = _choisie == id;
    final deplacee = _porte == id;
    return Positioned.fromRect(
      rect: r,
      child: IgnorePointer(
        // Les gestes sont captés par le `Listener` au-dessus : un
        // `GestureDetector` par vignette entrerait en conflit avec lui.
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: deplacee ? .22 : (p.masque ? .3 : 1),
          child: Container(
            decoration: active
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Palette.accent, width: 2))
                : null,
            padding: const EdgeInsets.all(1),
            child: _forme(p.forme, CaseDexVignette(item: c)),
          ),
        ),
      ),
    );
  }

  /// La forme découpe la vignette, pas la case : le nom doit rester lisible
  /// sous une goutte comme sous un carré.
  Widget _forme(String? forme, Widget enfant) {
    if (forme == null) return enfant;
    return ClipPath(clipper: DecoupeForme(forme), child: enfant);
  }

  Widget _caseVide(int i, Rect r) {
    final active = _choisie == _cleVide(i);
    return Positioned.fromRect(
      rect: r,
      child: IgnorePointer(
        child: Opacity(
          opacity: _porte == _cleVide(i) ? .22 : 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: active ? Palette.accent : Palette.bordureTrouvee,
                  width: active ? 2 : 1,
                  strokeAlign: BorderSide.strokeAlignInside),
              color: Palette.caseVide.withValues(alpha: .35),
            ),
            child: Center(
              child: Text('VIDE',
                  style: TextStyle(
                      fontSize: 10, letterSpacing: 1,
                      fontWeight: FontWeight.w700,
                      color: Palette.texteDoux)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fantome() {
    final cle = _porte!;
    final p = _placeDe(cle);
    if (p == null) return const SizedBox.shrink();
    final c = _estVide(cle) ? null : widget.trouvees
        .where((x) => x.id == cle)
        .firstOrNull;
    return Positioned(
      left: _doigt!.dx - _saisie.dx,
      top: _doigt!.dy - _saisie.dy,
      width: _tailleFantome.width,
      height: _tailleFantome.height,
      child: IgnorePointer(
        child: Opacity(
          opacity: .55,
          child: Transform.rotate(
            angle: -.035,
            child: Transform.scale(
              scale: 1.06,
              child: c == null
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: Palette.caseVide,
                      ))
                  : _forme(p.forme, CaseDexVignette(item: c)),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ le glissement

  void _prend(Offset pos, Rect Function(Place) boite) {
    // Le défilement décale le contenu : la position du doigt est dans le
    // repère de la vue, celle des vignettes dans celui du contenu.
    final p = Offset(pos.dx, pos.dy + _defilement.offset);
    for (var i = _vides.length - 1; i >= 0; i--) {
      if (boite(_vides[i]).contains(p)) {
        _demarre(_cleVide(i), p, boite(_vides[i]));
        return;
      }
    }
    for (final e in _places.entries) {
      if (!e.value.masque && boite(e.value).contains(p)) {
        _demarre(e.key, p, boite(e.value));
        return;
      }
    }
    setState(() => _choisie = null);
  }

  void _demarre(Object cle, Offset p, Rect r) {
    setState(() {
      _porte = cle;
      _doigt = Offset(p.dx, p.dy - _defilement.offset);
      // L'écart entre le doigt et le coin : sans lui, la vignette saute sous la
      // main au premier pixel.
      _saisie = Offset(p.dx - r.left, p.dy - r.top);
      _tailleFantome = r.size;
      _derniereCellule = null;
    });
  }

  void _suit(Offset pos, double cote, double hauteur) {
    if (_porte == null) return;
    setState(() => _doigt = pos);
    final p = Offset(pos.dx, pos.dy + _defilement.offset);
    final colonnes = Disposition.instance.colonnes;
    final colonne = ((p.dx - 16) / (cote + _gouttiere))
        .floor()
        .clamp(0, colonnes - 1);
    final rangee = (p.dy / (hauteur + _espace)).floor().clamp(0, 999);
    final cle = '$colonne,$rangee';
    // On ne repose que si la cellule visée change : sans ce filtre, chaque
    // pixel parcouru empilerait un pas d'historique.
    if (_derniereCellule == cle) return;
    _derniereCellule = cle;
    _pose(_porte!, colonne, rangee);
  }

  void _lache() {
    if (_porte == null) return;
    final cle = _porte!;
    final bouge = _derniereCellule != null;
    setState(() {
      _porte = null;
      _doigt = null;
    });
    // Un appui sans déplacement sélectionne : c'est ainsi qu'on ouvre le
    // panneau de réglage.
    if (!bouge) setState(() => _choisie = _choisie == cle ? null : cle);
  }

  // -------------------------------------------------------------- la barre

  Widget _barre() {
    final cle = _choisie;
    return SafeArea(
      top: false,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 160),
        alignment: Alignment.topCenter,
        child: Container(
          decoration: BoxDecoration(
            color: Palette.fond,
            border: Border(top: BorderSide(color: Palette.bordureTrouvee)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (cle != null) _reglages(cle) else _aide(),
            const SizedBox(height: 10),
            Row(children: [
              TextButton.icon(
                onPressed: _ajouteVide,
                icon: const Icon(Icons.crop_square, size: 18),
                label: Text(T('Case vide')),
              ),
              const Spacer(),
              if (_sale)
                Text(T('Modifications non enregistrées'),
                    style: TextStyle(fontSize: 11.5, color: Palette.alerte)),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _aide() => Row(children: [
        Icon(Icons.touch_app_outlined, size: 18, color: Palette.texteDoux),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
              T('Fais glisser une vignette pour la déplacer, touche-la pour la régler.'),
              style: TextStyle(fontSize: 12.5, color: Palette.texteDoux)),
        ),
      ]);

  /// Le panneau de réglage.
  ///
  /// Chaque réglage montre ce qu'il produit plutôt que de le nommer : une
  /// grille de gabarits qu'on désigne du doigt au lieu de boutons qui
  /// incrémentent, des formes dessinées au lieu de mots. On ne lit plus, on
  /// reconnaît.
  Widget _reglages(Object cle) {
    final p = _placeDe(cle);
    if (p == null) return const SizedBox.shrink();
    final vide = _estVide(cle);
    final max = Disposition.instance.tailleMax;
    final c = vide ? null : widget.trouvees.where((x) => x.id == cle).firstOrNull;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text(vide ? 'Case vide' : (c?.nom ?? 'Vignette'),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        Text('${p.largeur} × ${p.hauteur}',
            style: TextStyle(fontSize: 12, color: Palette.texteDoux)),
        IconButton(
          onPressed: () => setState(() => _choisie = null),
          icon: const Icon(Icons.close, size: 18),
          visualDensity: VisualDensity.compact,
        ),
      ]),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (var h = 1; h <= max; h++)
            for (var l = 1; l <= max; l++)
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: _gabarit(l, h, p.largeur == l && p.hauteur == h,
                    () => _taille(cle, l, h)),
              ),
          const SizedBox(width: 10),
          if (!vide) ...[
            _pastilleForme(cle, null, p.forme == null),
            for (final f in Disposition.formes.keys)
              _pastilleForme(cle, f, p.forme == f),
            const SizedBox(width: 6),
            IconButton(
              tooltip: p.masque ? 'Réafficher' : 'Masquer',
              onPressed: () => _basculeMasque(cle as int),
              icon: Icon(p.masque ? Icons.visibility : Icons.visibility_off,
                  size: 20),
            ),
          ] else
            IconButton(
              tooltip: T('Retirer'),
              onPressed: () => _retireVide(_rangVide(cle)),
              icon: Icon(Icons.delete_outline, size: 20, color: Palette.alerte),
            ),
        ]),
      ),
    ]);
  }

  Widget _gabarit(int l, int h, bool actif, VoidCallback quand) => InkWell(
        onTap: quand,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
                color: actif ? Palette.accent : Palette.bordureTrouvee),
            color: actif ? Palette.fondSecondaire : null,
          ),
          child: Center(
            child: Container(
              width: l * 7, height: h * 7,
              decoration: BoxDecoration(
                color: actif ? Palette.accent : Palette.texteDoux,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      );

  Widget _pastilleForme(Object cle, String? forme, bool actif) => Padding(
        padding: const EdgeInsets.only(right: 5),
        child: InkWell(
          onTap: () => _changeForme(cle, forme),
          borderRadius: BorderRadius.circular(9),
          child: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                  color: actif ? Palette.accent : Palette.bordureTrouvee),
              color: actif ? Palette.fondSecondaire : null,
            ),
            child: Center(
              child: forme == null
                  // « D'origine » : un carré hachuré, pour dire qu'aucune forme
                  // n'est imposée.
                  ? Icon(Icons.block, size: 16,
                      color: actif ? Palette.accent : Palette.texteDoux)
                  : ClipPath(
                      clipper: DecoupeForme(forme),
                      child: Container(
                        width: 16, height: 16,
                        color: actif ? Palette.accent : Palette.texteDoux,
                      ),
                    ),
            ),
          ),
        ),
      );
}

/// Le découpage d'une forme. Les mêmes six que sur le site, aux mêmes
/// proportions : une vignette réglée en hexagone doit se retrouver en hexagone
/// d'un appareil à l'autre.
class DecoupeForme extends CustomClipper<Path> {
  DecoupeForme(this.forme);
  final String forme;

  @override
  Path getClip(Size t) {
    final p = Path();
    switch (forme) {
      case 'rond':
        p.addOval(Rect.fromLTWH(0, 0, t.width, t.height));
      case 'carre':
        p.addRRect(RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, t.width, t.height), const Radius.circular(3)));
      case 'goutte':
        p.addRRect(RRect.fromRectAndCorners(
            Rect.fromLTWH(0, 0, t.width, t.height),
            topLeft: Radius.circular(t.width / 2),
            topRight: Radius.circular(t.width / 2),
            bottomRight: Radius.circular(t.width / 2),
            bottomLeft: const Radius.circular(6)));
      case 'losange':
        p.moveTo(t.width / 2, 0);
        p.lineTo(t.width, t.height / 2);
        p.lineTo(t.width / 2, t.height);
        p.lineTo(0, t.height / 2);
        p.close();
      case 'hexagone':
        p.moveTo(t.width * .25, t.height * .05);
        p.lineTo(t.width * .75, t.height * .05);
        p.lineTo(t.width, t.height * .5);
        p.lineTo(t.width * .75, t.height * .95);
        p.lineTo(t.width * .25, t.height * .95);
        p.lineTo(0, t.height * .5);
        p.close();
      default:
        p.addRRect(RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, t.width, t.height), const Radius.circular(16)));
    }
    return p;
  }

  @override
  bool shouldReclip(DecoupeForme vieux) => vieux.forme != forme;
}
