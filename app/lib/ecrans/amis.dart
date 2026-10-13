import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import '../widgets/case_dex.dart';
import '../widgets/reactions.dart';
import 'classement.dart';
import 'detail_case.dart';
import 'sortie.dart';
import '../widgets/chargement.dart';
import 'profil_joueur.dart';

/// Amis : le fil de leurs trouvailles, la liste, les demandes, la recherche.
class EcranAmis extends StatefulWidget {
  const EcranAmis({super.key});

  @override
  State<EcranAmis> createState() => _EcranAmisState();
}

class _EcranAmisState extends State<EcranAmis> with SingleTickerProviderStateMixin {
  late final TabController _onglets = TabController(length: 2, vsync: this);

  List<SortieFil> _fil = [];
  List<Joueur> _amis = [];
  List<Joueur> _recues = [];
  bool _charge = true;

  @override
  void initState() {
    super.initState();
    _rafraichit();
  }

  @override
  void dispose() {
    _onglets.dispose();
    super.dispose();
  }

  Future<void> _rafraichit() async {
    setState(() => _charge = true);
    try {
      final resultats = await Future.wait([
        Api.instance.get('/fil'),
        Api.instance.get('/amis'),
        Api.instance.get('/amis/demandes'),
        Api.instance.get('/notifications'),
      ]);
      if (!mounted) return;
      setState(() {
        _fil = (resultats[0]['groupes'] as List)
            .map((e) => SortieFil.depuisJson(e))
            .toList();
        _amis = (resultats[1]['amis'] as List)
            .map((e) => Joueur.depuisJson(e))
            .toList();
        _recues = (resultats[2]['recues'] as List)
            .map((e) => Joueur.depuisJson(e))
            .toList();
      });
    } catch (_) {
      // Le message d'erreur du réseau est déjà porté par les autres écrans ;
      // ici on laisse simplement les listes vides.
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  Future<void> _repond(int demandeId, String reponse) async {
    await Api.instance.post('/amis/demandes/$demandeId/$reponse');
    _rafraichit();
  }

  Future<void> _ajoute() async {
    final pseudo = await showDialog<String>(
      context: context,
      builder: (_) => const _DialogueAjout(),
    );
    if (pseudo == null || pseudo.isEmpty) return;
    try {
      final d = await Api.instance.post('/amis/demandes', {'pseudo': pseudo});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(d['etat'] == 'acceptee'
            ? 'Vous êtes maintenant amis !'
            : 'Demande envoyée à $pseudo.'),
      ));
      _rafraichit();
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(T('Amis')),
        actions: [
          IconButton(
            tooltip: T('Classement'),
            icon: const Icon(Icons.emoji_events_outlined),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const EcranClassement())),
          ),
          IconButton(
              tooltip: T('Ajouter un ami'),
              onPressed: _ajoute,
              icon: const Icon(Icons.person_add_alt)),
        ],
        bottom: TabBar(
          controller: _onglets,
          labelColor: Palette.accent,
          indicatorColor: Palette.accent,
          tabs: [
            Tab(text: T('Activité')),
            Tab(text: _recues.isEmpty ? 'Mes amis' : 'Mes amis (${_recues.length})'),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _rafraichit,
        child: TabBarView(
          controller: _onglets,
          children: [_ongletFil(), _ongletAmis()],
        ),
      ),
    );
  }

  Widget _ongletFil() {
    if (_charge && _fil.isEmpty) {
      return const Chargement();
    }
    if (_fil.isEmpty) {
      return _vide(Icons.rss_feed,
          'Rien pour l\'instant', 'Les trouvailles de tes amis apparaîtront ici.');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      itemCount: _fil.length,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (context, i) => _carteSortie(_fil[i]),
    );
  }

  /// Une sortie, en une carte.
  ///
  /// Elle dit qui, quand, et ce qui a été vu ; les vignettes donnent envie
  /// d'entrer. Le détail — chaque photo, chaque réaction — vit derrière, dans
  /// l'écran de sortie. Tout mettre à plat ici ramènerait le fil à ce qu'il
  /// était : une colonne interminable où l'on ne trouve plus rien.
  Widget _carteSortie(SortieFil g) {
    final couleur = Palette.qualite(g.rarete == 0 ? 2 : g.rarete);
    return Container(
      decoration: BoxDecoration(
        color: Palette.fondSecondaire,
        borderRadius: BorderRadius.circular(18),
        // Un liseré de la plus belle prise de la sortie : on repère de loin
        // celle qui vaut le détour.
        border: Border.all(
            color: g.rarete >= 4 ? couleur : Colors.transparent, width: 1.4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(children: [
            // Les avatars empilés : le groupe se lit avant même le texte.
            SizedBox(
              width: 34.0 + (g.gens.length - 1).clamp(0, 3) * 18,
              height: 34,
              child: Stack(children: [
                for (final (k, gene) in g.gens.take(4).indexed)
                  Positioned(
                    left: k * 18.0,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.fromBorderSide(
                            BorderSide(color: Palette.fondSecondaire, width: 2)),
                      ),
                      child: Avatar(
                          pseudo: gene.pseudo,
                          chemin: gene.avatar,
                          taille: 30),
                    ),
                  ),
              ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(g.titre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                  Text(
                    T('{0} photo{1}{2}', [g.nbPhotos, g.nbPhotos > 1 ? 's' : '', g.resume.isEmpty ? '' : ' · ${g.resume}']),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: Palette.texteDoux),
                  ),
                ],
              ),
            ),
            Text(g.jour,
                style: TextStyle(
                    fontSize: 11, color: Palette.texteDoux)),
          ]),
        ),
        // Les vignettes, en bande horizontale : elles tiennent quel que soit
        // le nombre de photos, là où une grille imposerait une hauteur qui
        // varie d'une carte à l'autre.
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            itemCount: g.photos.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, k) {
              final p = g.photos[k];
              return GestureDetector(
                onTap: () => _ouvreSortie(g, k),
                child: Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 86,
                      height: 86,
                      child: ImageServeur(chemin: p.vignette, taille: 256),
                    ),
                  ),
                  if (p.reactions.total > 0)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('${p.reactions.total} 👏',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10)),
                      ),
                    ),
                ]),
              );
            },
          ),
        ),
        // L'entrée franche dans la sortie : un rappel que le détail existe, et
        // où l'on réagit photo par photo.
        InkWell(
          onTap: () => _ouvreSortie(g, 0),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                  top: BorderSide(color: Palette.caseVide, width: 1)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(
                g.reactions > 0
                    ? 'Voir et réagir · ${g.reactions} réaction${g.reactions > 1 ? 's' : ''}'
                    : 'Voir et réagir',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Palette.accent),
              ),
              Icon(Icons.chevron_right, size: 18, color: Palette.accent),
            ]),
          ),
        ),
      ]),
    );
  }

  /// Ouvre la sortie, puis se redessine : les réactions posées dans l'écran
  /// de détail doivent se retrouver sur les vignettes en revenant.
  Future<void> _ouvreSortie(SortieFil g, int debut) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EcranSortie(sortie: g, debut: debut),
    ));
    if (mounted) setState(() {});
  }

  Widget _ongletAmis() {
    if (_charge && _amis.isEmpty && _recues.isEmpty) {
      return const Chargement();
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_recues.isNotEmpty) ...[
          Text(T('Demandes reçues'),
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final j in _recues)
            Card(
              elevation: 0,
              color: Palette.fondSecondaire,
              child: ListTile(
                title: Text(j.pseudo),
                subtitle: Text(T('{0} espèces', [j.cases])),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: Icon(Icons.check, color: Palette.accent),
                    onPressed: () => _repond(j.demandeId!, 'accepter'),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: Palette.texteDoux),
                    onPressed: () => _repond(j.demandeId!, 'refuser'),
                  ),
                ]),
              ),
            ),
          const SizedBox(height: 20),
        ],
        Text(T('Mes amis'), style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (_amis.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(T('Personne pour l\'instant. Ajoute quelqu\'un avec le bouton en haut à droite.'),
                style: TextStyle(color: Palette.texteDoux)),
          ),
        for (final j in _amis)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: Palette.caseVide,
              child: Text(j.pseudo.characters.first.toUpperCase(),
                  style: TextStyle(
                      color: Palette.texte, fontWeight: FontWeight.w700)),
            ),
            title: Text(j.pseudo),
            subtitle: Text(T('{0} espèces trouvées', [j.cases])),
            trailing: Icon(Icons.chevron_right, color: Palette.texteDoux),
            // Le profil d'abord, son dex ensuite. Ouvrir directement une
            // grille de silhouettes ne disait rien de qui on regardait ; le
            // profil porte sa vitrine, ses succès et ses trouvailles, et rend
            // le dex à un bouton.
            onTap: () => _ouvreProfil(j),
          ),
      ],
    );
  }

  /// Ouvre le profil, et enchaîne sur le dex si c'est ce qu'on y demande.
  ///
  /// Le profil rend « dex » en se fermant plutôt que d'empiler l'écran
  /// lui-même : sans ça, revenir du dex repasserait par le profil, puis par la
  /// liste — deux retours pour un aller.
  Future<void> _ouvreProfil(Joueur j) async {
    final suite = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => EcranProfilJoueur(joueurId: j.id, pseudo: j.pseudo),
    ));
    if (suite == 'dex' && mounted) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _EcranDexAmi(joueur: j),
      ));
    }
  }

  Widget _vide(IconData icone, String titre, String detail) => ListView(
        children: [
          const SizedBox(height: 90),
          Icon(icone, size: 46, color: Palette.silhouette),
          const SizedBox(height: 14),
          Text(titre,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(detail,
                textAlign: TextAlign.center,
                style: TextStyle(color: Palette.texteDoux, height: 1.4)),
          ),
        ],
      );
}

class _DialogueAjout extends StatefulWidget {
  const _DialogueAjout();

  @override
  State<_DialogueAjout> createState() => _DialogueAjoutState();
}

class _DialogueAjoutState extends State<_DialogueAjout> {
  final _champ = TextEditingController();

  @override
  void dispose() {
    _champ.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(T('Ajouter un ami')),
      content: TextField(
        controller: _champ,
        autofocus: true,
        autocorrect: false,
        decoration: InputDecoration(hintText: T('Pseudo')),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(T('Annuler'))),
        FilledButton(
          onPressed: () => Navigator.pop(context, _champ.text.trim()),
          child: Text(T('Envoyer')),
        ),
      ],
    );
  }
}

/// Le dex d'un ami, en lecture seule.
class _EcranDexAmi extends StatefulWidget {
  const _EcranDexAmi({required this.joueur});
  final Joueur joueur;

  @override
  State<_EcranDexAmi> createState() => _EcranDexAmiState();
}

class _EcranDexAmiState extends State<_EcranDexAmi> {
  List<CaseDex> _cases = [];
  bool _charge = true;

  @override
  void initState() {
    super.initState();
    _charge2();
  }

  Future<void> _charge2() async {
    try {
      final d = await Api.instance.get('/dex', {
        'joueur': widget.joueur.id,
        'etat': 'decouvert',
        'limite': 120,
        'tri': 'recentes',
      });
      if (mounted) {
        setState(() =>
            _cases = (d['cases'] as List).map((c) => CaseDex.depuisJson(c)).toList());
      }
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(T('Dex de {0}', [widget.joueur.pseudo]))),
      body: _charge
          ? const Chargement()
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                crossAxisSpacing: 8,
                mainAxisSpacing: 10,
                childAspectRatio: .75,
              ),
              itemCount: _cases.length,
              itemBuilder: (context, i) => GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => EcranDetailCase(
                      caseId: _cases[i].id, joueur: widget.joueur.id),
                )),
                child: _VignetteAmi(item: _cases[i]),
              ),
            ),
    );
  }
}

class _VignetteAmi extends StatelessWidget {
  const _VignetteAmi({required this.item});
  final CaseDex item;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            color: Palette.caseVide,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Palette.bordureTrouvee, width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: item.vignette == null
              ? const SizedBox.shrink()
              : Image.network(Api.instance.image(item.vignette!).toString(),
                  headers: Api.instance.entetes, fit: BoxFit.cover),
        ),
      ),
      const SizedBox(height: 4),
      SizedBox(
        height: 26,
        child: Text(item.nom,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10, height: 1.2)),
      ),
    ]);
  }
}
