import 'dart:async';
import '../i18n.dart';

import 'package:flutter/material.dart';

import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import '../widgets/case_dex.dart';
import '../widgets/badge_palier.dart';
import '../widgets/regnes.dart';
import 'carte.dart';
import 'notifications.dart';
import 'detail_case.dart';
import 'paliers.dart';
import '../widgets/chargement.dart';
import 'vitrine.dart';
import '../widgets/bandeau_vitrine.dart';
import '../reglages.dart';
import '../disposition.dart';
import 'ranger_dex.dart';

/// Le dex.
///
/// Il y a 376 000 cases, et les dérouler toutes n'a aucun intérêt : on ne
/// remonte pas des dizaines de milliers de silhouettes identiques. La règle est
/// donc : on montre ce qu'on a trouvé, puis un échantillon de ce qu'on a une
/// chance de trouver — les espèces les plus observées de la branche courante.
///
/// Trois façons de parcourir tout ça :
///   collection  ce qu'on a, suivi de cent cases à remplir
///   arbre       la descente classe → ordre → famille, avec l'avancement
///   récent      les dernières trouvailles, dans l'ordre où elles sont arrivées
enum ModeDex { collection, arbre, recent }

/// Les tris du dex, tels que le serveur les comprend.
enum TriDex {
  // Le panachage d'abord : trier par observations donnait douze oiseaux
  // d'affilée, l'ornithologie amateur écrasant tout sur GBIF. Ici chaque
  // classe place son représentant à tour de rôle.
  varie('varie', 'Un peu de tout'),
  communes('communes', 'Les plus communes'),
  rares('rares', 'Les plus rares'),
  nom('nom', 'Alphabétique');

  const TriDex(this.cle, this.etiquette);
  final String cle;
  final String etiquette;
}

/// Nombre de cases vides proposées en complément. Assez pour donner envie de
/// chercher, assez peu pour rester parcourable.
const _casesVides = 100;

class EcranDex extends StatefulWidget {
  const EcranDex({super.key});

  @override
  State<EcranDex> createState() => _EcranDexState();
}

class _EcranDexState extends State<EcranDex> {
  final _recherche = TextEditingController();
  Timer? _attenteFrappe;

  ModeDex _mode = ModeDex.collection;
  ResumeDex? _resume;

  /// La vitrine, chargée seulement si on la demande.
  ///
  /// Elle n'est pas dans le chargement initial du dex : la plupart des
  /// ouvertures ne la regardent pas, et c'est une requête de plus sur un écran
  /// qui en fait déjà plusieurs.
  Vitrine? _vitrine;
  // Repris du dernier lancement : quelqu'un qui vit sur sa vitrine ne veut pas
  // la rechoisir à chaque ouverture.
  bool _vitrineAffichee = Reglages.instance.bandeauVitrine;

  /// Au démarrage : si la bannière retenue est la vitrine, on la charge tout
  /// de suite, sinon l'écran s'ouvrirait sur le rang du dex avant de basculer
  /// sous les yeux du joueur.
  void _reprendLaVitrine() {
    if (_vitrineAffichee && _vitrine == null) _chargeVitrine();
  }

  Future<void> _chargeVitrine() async {
    try {
      final d = await Api.instance.get('/vitrine');
      if (mounted) setState(() => _vitrine = Vitrine.depuisJson(d));
    } catch (_) {
      // Sans vitrine, la bannière du rang reste affichée : c'est un bonus, pas
      // une information dont l'écran dépend.
      if (mounted) setState(() => _vitrineAffichee = false);
    }
  }

  /// Filtres du dex. La qualité vaut filtre par couleur : c'est elle qui donne
  /// sa teinte à la bordure des cases.
  int? _qualite;
  TriDex _tri = TriDex.communes;

  List<CaseDex> _trouvees = [];
  List<CaseDex> _aTrouver = [];
  String _texte = '';

  // Position dans l'arbre : null, null = les grands groupes.
  String? _classe;

  /// Le règne affiché, ou null pour les trois mélangés. Un dex du vivant se
  /// parcourt d'un bloc ; les onglets ne servent qu'à s'y retrouver.
  String? _regne;
  String? _ordre;
  String? _famille;

  bool _charge = true;
  String? _erreur;

  /// Le compte de notifications non lues, pour la pastille de la cloche.
  ///
  /// Elle vit dans le dex et non dans l'onglet Amis : le dex est l'écran qu'on
  /// ouvre en premier, et une pastille qu'il faut aller chercher ne prévient
  /// de rien.
  int _nonLues = 0;

  @override
  void initState() {
    super.initState();
    _rafraichit();
    _compteNonLues();
    _reprendLaVitrine();
    _chargeLaDisposition();
  }

  /// L'arrangement du dex. Il vient du serveur — c'est ce qui le fait suivre
  /// entre l'application et le site — avec un cache local pour dessiner tout de
  /// suite, sans attendre l'aller-retour.
  Future<void> _chargeLaDisposition() async {
    await Disposition.instance.charge();
    if (mounted) setState(() {});
  }

  Future<void> _compteNonLues() async {
    try {
      final d = await Api.instance.get('/notifications');
      if (mounted) setState(() => _nonLues = d['non_lues'] ?? 0);
    } catch (_) {
      // Une pastille absente vaut mieux qu'un écran en erreur.
    }
  }

  @override
  void dispose() {
    _attenteFrappe?.cancel();
    _recherche.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _filtres => {
        if (_regne != null) 'regne': _regne,
        if (_classe != null) 'classe': _classe,
        if (_ordre != null) 'ordre': _ordre,
        if (_famille != null) 'famille': _famille,
        if (_qualite != null) 'rarete': _qualite,
      };

  int get _nbFiltres => [_classe != null, _qualite != null].where((x) => x).length;

  Future<void> _rafraichit() async {
    setState(() {
      _charge = true;
      _erreur = null;
    });
    try {
      if (_texte.isNotEmpty) {
        // En recherche, on montre tout ce qui correspond, trouvé ou non :
        // c'est le seul cas où l'on veut fouiller le catalogue entier.
        final d = await Api.instance.get(
            '/dex', {'q': _texte, 'limite': 120, 'tri': _tri.cle, ..._filtres});
        _trouvees = (d['cases'] as List).map((c) => CaseDex.depuisJson(c)).toList();
        _aTrouver = [];
      } else {
        final resultats = await Future.wait([
          Api.instance.get('/dex', {
            'etat': 'decouvert',
            'limite': 300,
            // Les trouvailles se rangent par date d'ajout par défaut ; les
            // autres tris s'appliquent aux deux listes de la même façon.
            'tri': _tri == TriDex.communes ? 'recentes' : _tri.cle,
            ..._filtres,
          }),
          Api.instance.get('/dex',
              // Les cases à trouver se panachent par défaut : c'est la
              // vitrine du dex, elle doit donner envie d'aller voir ailleurs
              // que dans les buissons à moineaux.
              {'etat': 'manquant', 'limite': _casesVides,
               'tri': _tri == TriDex.communes ? 'varie' : _tri.cle,
               ..._filtres}),
          Api.instance.get('/dex/resume'),
        ]);
        _trouvees =
            (resultats[0]['cases'] as List).map((c) => CaseDex.depuisJson(c)).toList();
        _aTrouver =
            (resultats[1]['cases'] as List).map((c) => CaseDex.depuisJson(c)).toList();
        _resume = ResumeDex.depuisJson(resultats[2]);
      }
      if (mounted) setState(() {});
    } on ErreurApi catch (e) {
      if (mounted) setState(() => _erreur = e.message);
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  void _differe(String texte) {
    _attenteFrappe?.cancel();
    _attenteFrappe = Timer(const Duration(milliseconds: 350), () {
      setState(() => _texte = texte.trim());
      _rafraichit();
    });
  }

  Future<void> _ouvreFiltres() async {
    final retour = await showModalBottomSheet<(int?, TriDex, String?)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _PanneauFiltresDex(
        qualite: _qualite,
        tri: _tri,
        classe: _classe,
        groupes: _resume?.classes ?? const [],
      ),
    );
    if (retour == null) return;
    setState(() {
      _qualite = retour.$1;
      _tri = retour.$2;
      if (retour.$3 != _classe) {
        _classe = retour.$3;
        _ordre = null;
        _famille = null;
      }
    });
    _rafraichit();
  }

  void _descend({String? classe, String? ordre, String? famille}) {
    setState(() {
      if (classe != null) {
        _classe = classe;
        _ordre = null;
        _famille = null;
      } else if (ordre != null) {
        _ordre = ordre;
        _famille = null;
      } else if (famille != null) {
        _famille = famille;
        // Arrivé à la famille, on bascule sur les cases elles-mêmes.
        _mode = ModeDex.collection;
      }
    });
    _rafraichit();
  }

  void _remonte(int niveau) {
    setState(() {
      if (niveau == 0) {
        _classe = _ordre = _famille = null;
      } else if (niveau == 1) {
        _ordre = _famille = null;
      } else {
        _famille = null;
      }
      if (_mode == ModeDex.collection && _famille == null) _mode = ModeDex.arbre;
    });
    _rafraichit();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        // Le rang, les règnes et le mode d'affichage s'escamotent quand on
        // descend dans la grille et reviennent au premier geste vers le haut :
        // ils prenaient un tiers de l'écran en permanence pour une information
        // qu'on ne consulte qu'en arrivant.
        child: NestedScrollView(
          floatHeaderSlivers: true,
          headerSliverBuilder: (context, _) => [
            SliverAppBar(
              floating: true,
              snap: true,
              backgroundColor: Palette.barre,
              surfaceTintColor: Palette.barre,
              elevation: 0,
              automaticallyImplyLeading: false,
              toolbarHeight: _hauteurEntete,
              flexibleSpace: SingleChildScrollView(
                // Le bandeau se replie image par image : sans cette souplesse,
                // la reconstruction pendant l'escamotage déborde de quelques
                // pixels et Flutter s'en plaint.
                physics: const NeverScrollableScrollPhysics(),
                child: Builder(builder: (context) {
                  WidgetsBinding.instance
                      .addPostFrameCallback((_) => _mesureEntete());
                  return Column(
                    key: _cleEntete,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _entete(),
                      _progression(),
                      _onglets(),
                      _selecteurMode(),
                      if (_classe != null) _filAriane(),
                      // Une respiration sous le bandeau : sans elle, la grille
                      // vient coller au sélecteur de mode.
                      const SizedBox(height: 8),
                    ],
                  );
                }),
              ),
            ),
          ],
          body: Stack(children: [
            RefreshIndicator(
              onRefresh: _rafraichit,
              child: switch (_mode) {
                ModeDex.arbre => _VueArbre(
                    classe: _classe,
                    ordre: _ordre,
                    surDescente: _descend,
                  ),
                ModeDex.recent => _vueRecent(),
                ModeDex.collection => _vueCollection(),
              },
            ),
            // L'attente pendant un rechargement, quand la liste n'est pas vide.
            //
            // Sans elle, rien ne bougeait au rafraîchissement ni au changement
            // de filtre : les anciennes données restaient à l'écran, immobiles,
            // et on ne savait pas si l'application travaillait ou si elle avait
            // ignoré l'appui. Le grand format est réservé à l'écran vide, où il
            // a la place ; ici c'est une pastille posée en haut.
            if (_charge && (_trouvees.isNotEmpty || _aTrouver.isNotEmpty))
              Positioned(
                top: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: Material(
                    color: Palette.fond,
                    shape: const CircleBorder(),
                    elevation: 3,
                    child: const Padding(
                      padding: EdgeInsets.all(5),
                      child: Pastille(taille: 34),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  /// La hauteur du bandeau escamotable, mesurée après le premier rendu.
  ///
  /// Elle était estimée composant par composant, et l'estimation tombait
  /// toujours un peu court : le sélecteur « Cases / Groupes / Récentes » se
  /// retrouvait rogné par la grille. On laisse le contenu se dessiner, on
  /// relève sa hauteur réelle, et le bandeau s'y ajuste.
  final _cleEntete = GlobalKey();
  double _hauteurEntete = 300;

  void _mesureEntete() {
    final boite = _cleEntete.currentContext?.findRenderObject() as RenderBox?;
    if (boite == null || !boite.hasSize) return;
    final h = boite.size.height;
    if ((h - _hauteurEntete).abs() > 1) {
      // Après la frame en cours : on ne redimensionne pas pendant qu'elle se
      // dessine.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _hauteurEntete = h);
      });
    }
  }

  Widget _entete() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(T('Mon dex'),
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                // Le rang plutôt que le rapport au total : « 3 sur 977 415 »
                // n'est pas un score, c'est un rappel qu'on n'y arrivera
                // jamais. Ce qui compte est ce qu'on a trouvé et le prochain
                // jalon, qui lui est à portée.

              ],
            ),
          ),
          IconButton(
            tooltip: T('Carte de mes trouvailles'),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const EcranCarte())),
            icon: const Icon(Icons.public_outlined),
          ),
          IconButton(
            tooltip: T('Filtrer et trier'),
            onPressed: _ouvreFiltres,
            icon: Badge.count(
              count: _nbFiltres,
              isLabelVisible: _nbFiltres > 0,
              child: Icon(Icons.tune,
                  color: _nbFiltres > 0 ? Palette.accent : Palette.texte),
            ),
          ),
          SizedBox(
            width: 150,
            child: TextField(
              controller: _recherche,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 13),
              onChanged: _differe,
              decoration: InputDecoration(
                isDense: true,
                hintText: T('Chercher…'),
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _texte.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          _recherche.clear();
                          setState(() => _texte = '');
                          _rafraichit();
                        },
                      ),
              ),
            ),
          ),
          IconButton(
            tooltip: T('Notifications'),
            icon: Badge.count(
              count: _nonLues,
              isLabelVisible: _nonLues > 0,
              child: Icon(
                  _nonLues > 0
                      ? Icons.notifications
                      : Icons.notifications_none,
                  color: _nonLues > 0 ? Palette.accent : Palette.texte),
            ),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const EcranNotifications()));
              _compteNonLues();
            },
          ),
        ],
      ),
    );
  }

  /// Les trois règnes, plus « Tout ». Changer de règne remet la navigation
  /// taxonomique à zéro : une classe d'oiseaux n'a aucun sens sous les plantes.
  /// Le rang, en écusson, avec la marche suivante.
  Widget _progression() {
    final r = _resume;
    if (r == null) return const SizedBox.shrink();
    // La bascule vit sur l'écusson lui-même, en surimpression : elle ne prend
    // aucune place dans un en-tête déjà chargé, et elle est là où l'œil se
    // pose. Une seule bannière à la fois — les empiler mangerait la moitié de
    // l'écran avant la première case.
    void bascule() {
      setState(() => _vitrineAffichee = !_vitrineAffichee);
      Reglages.instance.retiensBandeauVitrine(_vitrineAffichee);
      if (_vitrineAffichee && _vitrine == null) _chargeVitrine();
    }

    if (_vitrineAffichee) {
      final v = _vitrine;
      // Tant que la vitrine n'est pas arrivée, on garde la bannière du rang
      // plutôt qu'un trou : la bascule doit se sentir instantanée, et les deux
      // bannières ont exactement la même hauteur.
      if (v != null) {
        return BandeauVitrine(
          vitrine: v,
          surBascule: bascule,
          surAppui: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EcranVitrine())),
        );
      }
    }
    return BandeauPalier(
      resume: r,
      surBascule: bascule,
      surAppui: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const EcranPaliers())),
    );
  }

  Widget _onglets() {
    Widget puce(String? cle, String texte, String emoji, Color couleur) {
      final actif = _regne == cle;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            if (_regne == cle) return;
            setState(() {
              _regne = cle;
              _classe = null;
              _ordre = null;
              _famille = null;
            });
            _rafraichit();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            decoration: BoxDecoration(
              color: actif ? couleur.withValues(alpha: .14) : Palette.fondSecondaire,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: actif ? couleur : Colors.transparent, width: 1.4),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (emoji.isNotEmpty) ...[
                Text(emoji, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 5),
              ],
              Text(texte,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: actif ? couleur : Palette.texteDoux)),
            ]),
          ),
        ),
      );
    }

    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          puce(null, 'Tout', '', Palette.accent),
          for (final r in Regne.tous) puce(r.cle, r.nom, r.emoji, r.couleur),
        ],
      ),
    );
  }

  Widget _selecteurMode() {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: SegmentedButton<ModeDex>(
        segments: [
          ButtonSegment(
              value: ModeDex.collection,
              icon: Icon(Icons.grid_view, size: 17),
              label: Text(T('Cases'))),
          ButtonSegment(
              value: ModeDex.arbre,
              icon: Icon(Icons.account_tree_outlined, size: 17),
              label: Text(T('Groupes'))),
          ButtonSegment(
              value: ModeDex.recent,
              icon: Icon(Icons.schedule, size: 17),
              label: Text(T('Récent'))),
        ],
        selected: {_mode},
        showSelectedIcon: false,
        style: ButtonStyle(
          textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
          visualDensity: VisualDensity.compact,
        ),
        onSelectionChanged: (s) {
          setState(() => _mode = s.first);
          if (_mode != ModeDex.arbre) _rafraichit();
        },
      ),
    );
  }

  Widget _filAriane() {
    final etapes = <(String, int)>[
      (nomDeTaxon(_classe!), 0),
      if (_ordre != null) (nomDeTaxon(_ordre!), 1),
      if (_famille != null) (nomDeTaxon(_famille!), 2),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          InkWell(
            onTap: () => _remonte(0),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Icon(Icons.home_outlined, size: 16, color: Palette.accent),
            ),
          ),
          for (final (nom, niveau) in etapes) ...[
            Icon(Icons.chevron_right, size: 15, color: Palette.texteDoux),
            InkWell(
              onTap: () => _remonte(niveau),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Text(nom,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: niveau == etapes.length - 1
                          ? FontWeight.w700
                          : FontWeight.w400,
                      color: niveau == etapes.length - 1
                          ? Palette.texte
                          : Palette.accent,
                    )),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------- vue « cases »

  Widget _vueCollection() {
    if (_charge && _trouvees.isEmpty && _aTrouver.isEmpty) {
      return const Chargement();
    }
    if (_erreur != null) {
      return _Message(
        icone: Icons.cloud_off,
        titre: T('Serveur injoignable'),
        detail: _erreur!,
        action: TextButton(onPressed: _rafraichit, child: Text(T('Réessayer'))),
      );
    }
    if (_trouvees.isEmpty && _aTrouver.isEmpty) {
      return _Message(
        icone: Icons.search_off,
        titre: T('Rien ici'),
        detail: T('Aucune espèce ne correspond.'),
      );
    }

    return CustomScrollView(
      slivers: [
        if (_texte.isNotEmpty)
          _titre(T('{0} résultat{1}', [_trouvees.length, _trouvees.length > 1 ? 's' : ''])),
        if (_texte.isEmpty && _trouvees.isNotEmpty)
          _titre(T('Trouvées ({0})', [_trouvees.length]), action: _rangeLeDex),
        // La grille libre n'est utilisée que hors recherche : en recherche,
        // `_trouvees` contient tout le catalogue, découvert ou non, et un
        // arrangement n'a aucun sens sur des espèces qu'on n'a pas.
        if (_texte.isEmpty) _grilleLibre(_trouvees) else _grille(_trouvees),
        if (_aTrouver.isNotEmpty) ...[
          _titre(T('À découvrir'),
              detail: T('Les plus fréquentes que vous n\'avez pas encore.')),
          _grille(_aTrouver),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 28)),
      ],
    );
  }

  Widget _titre(String texte, {String? detail, VoidCallback? action}) =>
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(18, 14, action == null ? 18 : 8, 8),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(texte,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                  if (detail != null)
                    Text(detail,
                        style: TextStyle(
                            color: Palette.texteDoux, fontSize: 11.5)),
                ],
              ),
            ),
            // Un bouton explicite en plus de l'appui long : le geste seul ne
            // se devine pas, et personne ne trouverait le mode sans lui.
            if (action != null)
              TextButton.icon(
                onPressed: action,
                icon: const Icon(Icons.dashboard_customize_outlined, size: 17),
                label: Text(T('Ranger')),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontSize: 12.5)),
              ),
          ]),
        ),
      );

  /// La grille des trouvailles, disposées comme le joueur les a rangées.
  ///
  /// Les positions viennent du serveur — c'est ce qui les fait suivre d'un
  /// appareil à l'autre — et les cases sans position se posent à la suite. Un
  /// dex jamais arrangé est donc identique à ce qu'il était : mêmes cinq
  /// colonnes, mêmes gouttières, mêmes vignettes.
  Widget _grilleLibre(List<CaseDex> cases) {
    final d = Disposition.instance;
    if (d.places.isEmpty && d.vides.isEmpty) return _grille(cases);

    // On refait le placement d'office pour les cases sans position, exactement
    // comme l'écran de rangement.
    final occupe = <String>{};
    void marque(Place p) {
      for (var y = p.rangee; y < p.rangee + p.hauteur; y++) {
        for (var x = p.colonne; x < p.colonne + p.largeur; x++) {
          occupe.add('$x,$y');
        }
      }
    }

    final posees = <(CaseDex, Place)>[];
    final libres = <CaseDex>[];
    for (final c in cases) {
      final p = d.places[c.id];
      if (p == null) {
        libres.add(c);
      } else if (!p.masque) {
        // Masquée : elle reste au dex et compte toujours, elle n'occupe
        // simplement plus de place dans la grille.
        posees.add((c, p));
        marque(p);
      } else {
        marque(Place(colonne: p.colonne, rangee: p.rangee, largeur: 0, hauteur: 0));
      }
    }
    for (final v in d.vides) {
      marque(v);
    }

    var col = 0;
    var rang = 0;
    for (final c in libres) {
      while (occupe.contains('$col,$rang')) {
        col += 1;
        if (col >= d.colonnes) {
          col = 0;
          rang += 1;
        }
      }
      final p = Place(colonne: col, rangee: rang);
      posees.add((c, p));
      marque(p);
    }

    var rangs = 1;
    for (final (_, p) in posees) {
      if (p.rangee + p.hauteur > rangs) rangs = p.rangee + p.hauteur;
    }

    return SliverToBoxAdapter(
      child: LayoutBuilder(builder: (context, ct) {
        const gouttiere = 8.0;
        const espace = 10.0;
        const nom = 20.0;
        final cote = (ct.maxWidth - 32 - (d.colonnes - 1) * gouttiere) / d.colonnes;
        final hauteur = cote + nom;
        return SizedBox(
          height: rangs * (hauteur + espace),
          child: Stack(children: [
            for (final (c, p) in posees)
              Positioned(
                left: 16 + p.colonne * (cote + gouttiere),
                top: p.rangee * (hauteur + espace),
                width: p.largeur * cote + (p.largeur - 1) * gouttiere,
                height: p.hauteur * hauteur + (p.hauteur - 1) * espace,
                child: GestureDetector(
                  onTap: () => _ouvre(c),
                  onLongPress: _rangeLeDex,
                  child: p.forme == null
                      ? CaseDexVignette(item: c)
                      : ClipPath(
                          clipper: DecoupeForme(p.forme!),
                          child: CaseDexVignette(item: c)),
                ),
              ),
          ]),
        );
      }),
    );
  }

  /// Ouvre l'écran de rangement, et recharge si quelque chose a changé.
  Future<void> _rangeLeDex() async {
    if (_trouvees.isEmpty) return;
    final fait = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => EcranRangerDex(
        trouvees: _trouvees,
        // Le dex ne charge que ses trois cents premières trouvailles :
        // enregistrer en remplaçant tout effacerait la position de celles qui
        // n'étaient pas à l'écran.
        partiel: _trouvees.length >= 300,
      ),
    ));
    if (fait == true && mounted) setState(() {});
  }

  Widget _grille(List<CaseDex> cases) => SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 5,
            crossAxisSpacing: 8,
            mainAxisSpacing: 10,
            childAspectRatio: .75,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => CaseDexVignette(
              item: cases[i],
              onTap: () => _ouvre(cases[i]),
            ),
            childCount: cases.length,
          ),
        ),
      );

  Future<void> _ouvre(CaseDex c) async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => EcranDetailCase(caseId: c.id)));
    _rafraichit();
  }

  // ------------------------------------------------------------ vue « récent »

  Widget _vueRecent() {
    if (_charge && _trouvees.isEmpty) {
      return const Chargement();
    }
    if (_trouvees.isEmpty) {
      return _Message(
        icone: Icons.schedule,
        titre: T('Aucune trouvaille'),
        detail: T('Photographiez un animal pour commencer votre collection.'),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _trouvees.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final c = _trouvees[i];
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _ouvre(c),
          child: Row(children: [
            SizedBox(
              width: 58,
              height: 58,
              child: CaseDexVignette(item: c, compacte: true),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.nom,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(c.latin,
                      style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: Palette.texteDoux,
                          fontSize: 12)),
                  if (c.trouveLe != null)
                    Text(c.trouveLe!.split(' ').first,
                        style: TextStyle(
                            color: Palette.texteDoux, fontSize: 11)),
                ],
              ),
            ),
            if (c.nbCaptures > 1)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Palette.fondSecondaire,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(T('{0} photos', [c.nbCaptures]),
                    style: TextStyle(
                        fontSize: 11, color: Palette.texteDoux)),
              ),
            Icon(Icons.chevron_right, color: Palette.texteDoux),
          ]),
        );
      },
    );
  }

}

/// La descente dans l'arbre du vivant : mammifères, puis ongulés, puis cervidés.
class _VueArbre extends StatefulWidget {
  const _VueArbre(
      {required this.classe, required this.ordre, required this.surDescente});

  final String? classe;
  final String? ordre;
  final void Function({String? classe, String? ordre, String? famille}) surDescente;

  @override
  State<_VueArbre> createState() => _VueArbreState();
}

class _VueArbreState extends State<_VueArbre> {
  NiveauArbre? _niveau;
  bool _charge = true;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _charge2();
  }

  @override
  void didUpdateWidget(_VueArbre ancien) {
    super.didUpdateWidget(ancien);
    if (ancien.classe != widget.classe || ancien.ordre != widget.ordre) {
      _charge2();
    }
  }

  Future<void> _charge2() async {
    setState(() {
      _charge = true;
      _erreur = null;
    });
    try {
      final d = await Api.instance.get('/dex/arbre', {
        if (widget.classe != null) 'classe': widget.classe,
        if (widget.ordre != null) 'ordre': widget.ordre,
      });
      if (mounted) setState(() => _niveau = NiveauArbre.depuisJson(d));
    } on ErreurApi catch (e) {
      if (mounted) setState(() => _erreur = e.message);
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_charge && _niveau == null) {
      return const Chargement();
    }
    if (_erreur != null) {
      return _Message(
          icone: Icons.cloud_off, titre: T('Serveur injoignable'), detail: _erreur!);
    }
    final n = _niveau;
    if (n == null || n.noeuds.isEmpty) {
      return _Message(
        icone: Icons.account_tree_outlined,
        titre: T('Pas de sous-groupe'),
        detail: T('Cette branche n\'est pas détaillée. Passez à l\'onglet Cases pour voir les espèces directement.'),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: n.noeuds.length,
      separatorBuilder: (_, _) => const SizedBox(height: 2),
      itemBuilder: (context, i) {
        final noeud = n.noeuds[i];
        final part = noeud.total == 0 ? 0.0 : noeud.trouve / noeud.total;
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => switch (n.niveau) {
            'classe' => widget.surDescente(classe: noeud.nom),
            'ordre' => widget.surDescente(ordre: noeud.nom),
            _ => widget.surDescente(famille: noeud.nom),
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(nomDeTaxon(noeud.nom),
                              style: TextStyle(
                                fontWeight: noeud.trouve > 0
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              )),
                        ),
                        Text('${noeud.trouve} / ${noeud.total}',
                            style: TextStyle(
                              fontSize: 12,
                              color: noeud.trouve > 0
                                  ? Palette.accent
                                  : Palette.texteDoux,
                              fontWeight: noeud.trouve > 0
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                            )),
                      ]),
                      if (nomDeTaxon(noeud.nom) != noeud.nom)
                        Text(noeud.nom,
                            style: TextStyle(
                                fontSize: 11,
                                fontStyle: FontStyle.italic,
                                color: Palette.texteDoux)),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: part.clamp(0.0, 1.0),
                          minHeight: 5,
                          backgroundColor: Palette.caseVide,
                          valueColor:
                              AlwaysStoppedAnimation(Palette.accent),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right,
                    color: Palette.texteDoux, size: 20),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(
      {required this.icone,
      required this.titre,
      required this.detail,
      this.action});

  final IconData icone;
  final String titre;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 80),
        Icon(icone, size: 48, color: Palette.silhouette),
        const SizedBox(height: 16),
        Text(titre,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(detail,
              textAlign: TextAlign.center,
              style: TextStyle(color: Palette.texteDoux, height: 1.4)),
        ),
        if (action != null) Center(child: action!),
      ],
    );
  }
}

/// Le panneau de filtres du dex : la couleur de qualité, le tri, le groupe.
class _PanneauFiltresDex extends StatefulWidget {
  const _PanneauFiltresDex({
    required this.qualite,
    required this.tri,
    required this.classe,
    required this.groupes,
  });

  final int? qualite;
  final TriDex tri;
  final String? classe;
  final List<GroupeDex> groupes;

  @override
  State<_PanneauFiltresDex> createState() => _PanneauFiltresDexState();
}

class _PanneauFiltresDexState extends State<_PanneauFiltresDex> {
  late int? _qualite = widget.qualite;
  late TriDex _tri = widget.tri;
  late String? _classe = widget.classe;

  @override
  Widget build(BuildContext context) {
    // On ne propose que les groupes qui contiennent vraiment quelque chose,
    // triés du plus fourni au moins.
    final groupes = widget.groupes.where((g) => g.total > 0).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .68,
      maxChildSize: .92,
      builder: (context, defilement) => ListView(
        controller: defilement,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        children: [
          Text(T('Filtrer le dex'),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 20),

          Text(T('Qualité'),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(
              label: Text(T('Toutes'), style: TextStyle(fontSize: 12)),
              selected: _qualite == null,
              onSelected: (_) => setState(() => _qualite = null),
            ),
            // De la plus prestigieuse à la plus banale : c'est l'or qu'on vient
            // chercher en ouvrant ce panneau.
            for (var q = 5; q >= 1; q--)
              ChoiceChip(
                avatar: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Palette.qualite(q),
                    shape: BoxShape.circle,
                  ),
                ),
                label: Text(Palette.nomQualite(q),
                    style: const TextStyle(fontSize: 12)),
                selected: _qualite == q,
                selectedColor: Palette.qualite(q).withValues(alpha: .2),
                onSelected: (_) =>
                    setState(() => _qualite = _qualite == q ? null : q),
              ),
          ]),
          const SizedBox(height: 22),

          Text(T('Trier par'),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final t in TriDex.values)
              ChoiceChip(
                label: Text(t.etiquette, style: const TextStyle(fontSize: 12)),
                selected: _tri == t,
                onSelected: (_) => setState(() => _tri = t),
              ),
          ]),
          const SizedBox(height: 22),

          if (groupes.isNotEmpty) ...[
            Text(T('Groupe'),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ChoiceChip(
                label: Text(T('Tous'), style: TextStyle(fontSize: 12)),
                selected: _classe == null,
                onSelected: (_) => setState(() => _classe = null),
              ),
              for (final g in groupes.take(24))
                ChoiceChip(
                  label: Text(
                      '${nomDeClasse(g.classe)}${g.trouve > 0 ? ' · ${g.trouve}' : ''}',
                      style: const TextStyle(fontSize: 12)),
                  selected: _classe == g.classe,
                  onSelected: (_) => setState(
                      () => _classe = _classe == g.classe ? null : g.classe),
                ),
            ]),
            const SizedBox(height: 26),
          ],

          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(
                    context, (null, TriDex.communes, null)),
                child: Text(T('Effacer')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: () =>
                    Navigator.pop(context, (_qualite, _tri, _classe)),
                child: Text(T('Appliquer')),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
