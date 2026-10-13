import 'package:flutter/material.dart';
import '../i18n.dart';

import '../reglages.dart';
import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import '../widgets/badge_palier.dart';
import '../widgets/case_dex.dart';
import '../widgets/reactions.dart';
import 'detail_case.dart';
import '../widgets/chargement.dart';
import 'vitrine.dart';

/// Le classement du cercle d'amis, et le palmarès des belles prises.
///
/// Une case rapporte ses points une seule fois, à la découverte : photographier
/// dix fois le même pigeon ne fait pas monter. Ce qui fait monter, c'est de
/// trouver des espèces qu'on ne croise pas tous les jours.
class EcranClassement extends StatefulWidget {
  const EcranClassement({super.key});

  @override
  State<EcranClassement> createState() => _EcranClassementState();
}

class _EcranClassementState extends State<EcranClassement>
    with SingleTickerProviderStateMixin {
  late final TabController _onglets = TabController(length: 2, vsync: this);

  List<LigneClassement> _joueurs = [];
  List<Trouvaille> _trouvailles = [];
  MesPoints? _miens;
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
      final r = await Future.wait([
        Api.instance.get('/classement'),
        Api.instance.get('/classement/trouvailles'),
        Api.instance.get('/classement/moi'),
      ]);
      if (!mounted) return;
      setState(() {
        _joueurs = (r[0]['joueurs'] as List)
            .map((j) => LigneClassement.depuisJson(j))
            .toList();
        _trouvailles = (r[1]['trouvailles'] as List)
            .map((t) => Trouvaille.depuisJson(t))
            .toList();
        _miens = MesPoints.depuisJson(r[2]);
      });
    } catch (_) {
      // Écran de consultation : sans réseau, il reste vide.
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(T('Classement')),
        bottom: TabBar(
          controller: _onglets,
          labelColor: Palette.accent,
          indicatorColor: Palette.accent,
          tabs: [
            Tab(text: T('Joueurs')),
            Tab(text: T('Belles prises')),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _rafraichit,
        child: TabBarView(
          controller: _onglets,
          children: [_ongletJoueurs(), _ongletTrouvailles()],
        ),
      ),
    );
  }

  Widget _ongletJoueurs() {
    if (_charge && _joueurs.isEmpty) {
      return const Chargement();
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        if (_miens != null) _monBilan(_miens!),
        const SizedBox(height: 20),
        Text(T('Entre amis'),
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        for (final j in _joueurs) _ligneJoueur(j),
        if (_joueurs.length <= 1)
          Padding(
            padding: EdgeInsets.only(top: 20),
            child: Text(
              T('Ajoutez des amis pour vous mesurer à eux.'),
              style: TextStyle(color: Palette.texteDoux),
            ),
          ),
      ],
    );
  }

  Widget _monBilan(MesPoints m) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Palette.accent.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${m.total}',
                style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w800,
                    height: 1,
                    color: Palette.accentSombre)),
            const SizedBox(width: 8),
            Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('points', style: TextStyle(color: Palette.texteDoux)),
            ),
            const Spacer(),
            if (m.sur > 1)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Palette.fond,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(T('{0}ᵉ sur {1}', [m.rang, m.sur]),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
          ]),
          const SizedBox(height: 16),
          if (m.parQualite.isEmpty)
            Text(T('Aucune espèce trouvée pour l\'instant.'),
                style: TextStyle(color: Palette.texteDoux, fontSize: 13))
          else
            for (final q in m.parQualite)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  PastilleRarete(rarete: q.qualite, dense: true),
                  const SizedBox(width: 10),
                  Text(T('{0} espèce{1}', [q.cases, q.cases > 1 ? 's' : '']),
                      style: const TextStyle(fontSize: 13)),
                  const Spacer(),
                  Text(T('{0} pts', [q.points]),
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Palette.texteDoux)),
                ]),
              ),
        ],
      ),
    );
  }

  Widget _ligneJoueur(LigneClassement j) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => EcranFicheJoueur(joueurId: j.id))),
      child: _corpsLigne(j),
    );
  }

  Widget _corpsLigne(LigneClassement j) {
    // Les trois premiers portent une couleur de médaille ; au-delà, le rang
    // suffit.
    final medaille = switch (j.rang) {
      1 => const Color(0xFFE8A317),
      2 => const Color(0xFFA8AEB8),
      3 => const Color(0xFFCD7F32),
      _ => Palette.texteDoux,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: j.moi ? Palette.accent.withValues(alpha: .07) : Palette.fondSecondaire,
        borderRadius: BorderRadius.circular(14),
        border: j.moi
            ? Border.all(color: Palette.accent.withValues(alpha: .4))
            : null,
      ),
      child: Row(children: [
        SizedBox(
          width: 28,
          child: j.rang <= 3
              ? Icon(Icons.emoji_events, color: medaille, size: 22)
              : Text('${j.rang}',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: Palette.texteDoux)),
        ),
        Avatar(pseudo: j.pseudo, chemin: j.avatar, taille: 34),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(j.moi ? '${j.pseudo} (vous)' : j.pseudo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                // Le rang plutôt qu'un simple total : on se compare mieux à
                // « Fouineur » qu'à « 340 points ».
                if (j.palier.numero > 0) ...[
                  const SizedBox(width: 7),
                  BadgePalier(chemin: j.palier.badge, taille: 20),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(j.palier.nom,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Palette.texteDoux)),
                  ),
                ],
              ]),
              const SizedBox(height: 2),
              Text(
                T('{0} espèce{1}{2}{3}', [j.cases, j.cases > 1 ? 's' : '', j.belles > 0 ? ' · ${j.belles} belle${j.belles > 1 ? 's' : ''} prise${j.belles > 1 ? 's' : ''}' : '', j.pointsReactions > 0 ? ' · ${j.pointsReactions} pts d\'applaudissements' : '']),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 11.5, color: Palette.texteDoux),
              ),
            ],
          ),
        ),
        if (j.legendaires > 0)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Row(children: [
              Icon(Icons.auto_awesome,
                  size: 14, color: Palette.qualite(5)),
              const SizedBox(width: 3),
              Text('${j.legendaires}',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Palette.qualite(5))),
            ]),
          ),
        Text('${j.points}',
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(width: 2),
        Text('pts',
            style: TextStyle(fontSize: 11, color: Palette.texteDoux)),
        // La vitrine d'un joueur, depuis le classement.
        //
        // C'est ici qu'on se compare, donc ici qu'on a envie d'aller voir ce
        // que l'autre a rapporté. Pas de garde-fou sur l'amitié : ce classement
        // ne contient que soi et ses amis, et le serveur revérifie de toute
        // façon avant de servir la vitrine de quelqu'un.
        IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: j.moi ? 'Mes succès' : 'Succès de ${j.pseudo}',
            icon: const Icon(Icons.diamond_outlined,
                size: 18, color: Color(0xFF9B6BDF)),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => EcranVitrine(
                joueur: j.moi ? null : j.id,
                pseudo: j.moi ? null : j.pseudo,
              ),
            )),
          ),
      ]),
    );
  }

  Widget _ongletTrouvailles() {
    if (_charge && _trouvailles.isEmpty) {
      return const Chargement();
    }
    if (_trouvailles.isEmpty) {
      return ListView(children: [
        SizedBox(height: 90),
        Icon(Icons.workspace_premium_outlined,
            size: 46, color: Palette.silhouette),
        SizedBox(height: 14),
        Center(
          child: Text(T('Aucune trouvaille pour l\'instant.'),
              style: TextStyle(color: Palette.texteDoux)),
        ),
      ]);
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _trouvailles.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final t = _trouvailles[i];
        final couleur = Palette.qualite(t.qualite);
        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => EcranDetailCase(caseId: t.caseId))),
          child: Row(children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: Palette.caseVide,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: couleur, width: 2),
              ),
              clipBehavior: Clip.antiAlias,
              child: t.decoupe != null && !Reglages.instance.casesEntieres
                  ? Padding(
                      padding: const EdgeInsets.all(5),
                      child: ImageServeur(
                          chemin: t.decoupe!,
                          fit: BoxFit.contain,
                          taille: 160),
                    )
                  : ((t.vignette ?? t.decoupe) != null
                      ? ImageServeur(chemin: (t.vignette ?? t.decoupe)!, taille: 160)
                      : const SizedBox.shrink()),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.nom,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  PastilleRarete(
                      rarete: t.qualite, points: t.points, dense: true),
                  const SizedBox(height: 3),
                  Text(
                    '${t.moi ? 'Vous' : t.pseudo} · ${t.trouveLe.split(' ').first}',
                    style: TextStyle(
                        fontSize: 11, color: Palette.texteDoux),
                  ),
                ],
              ),
            ),
          ]),
        );
      },
    );
  }
}

/// La fiche détaillée d'un joueur : d'où viennent ses points, et ce qu'il a
/// trouvé de plus beau.
class EcranFicheJoueur extends StatefulWidget {
  const EcranFicheJoueur({super.key, required this.joueurId});
  final int joueurId;

  @override
  State<EcranFicheJoueur> createState() => _EcranFicheJoueurState();
}

class _EcranFicheJoueurState extends State<EcranFicheJoueur> {
  DetailJoueur? _j;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _charge();
  }

  Future<void> _charge() async {
    try {
      final d = await Api.instance.get('/classement/joueur/${widget.joueurId}');
      if (mounted) setState(() => _j = DetailJoueur.depuisJson(d));
    } on ErreurApi catch (e) {
      if (mounted) setState(() => _erreur = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final j = _j;
    return Scaffold(
      appBar: AppBar(title: Text(j?.pseudo ?? '')),
      body: _erreur != null
          ? Center(child: Text(_erreur!))
          : j == null
              ? const Chargement()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  children: [
                    _entete(j),
                    const SizedBox(height: 24),
                    Text(T('Ses prises par qualité'),
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    _repartition(j),
                    if (j.meilleures.isNotEmpty) ...[
                      const SizedBox(height: 26),
                      Text(T('Ses plus belles trouvailles'),
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 12),
                      _meilleures(j),
                    ],
                  ],
                ),
    );
  }

  Widget _entete(DetailJoueur j) {
    return Row(children: [
      Avatar(pseudo: j.pseudo, chemin: j.avatar, taille: 64),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(T('{0} points', [j.total]),
                style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Palette.accentSombre)),
            const SizedBox(height: 4),
            Text(T('{0} espèce{1} · {2} photo{3}', [j.cases, j.cases > 1 ? 's' : '', j.photos, j.photos > 1 ? 's' : '']),
                style: TextStyle(
                    color: Palette.texteDoux, fontSize: 13)),
            if (j.pointsReactions > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  T('{0} pts d\'espèces + {1} pts d\'applaudissements', [j.pointsEspeces, j.pointsReactions]),
                  style: TextStyle(
                      color: Palette.texteDoux, fontSize: 11.5),
                ),
              ),
          ],
        ),
      ),
    ]);
  }

  /// Une barre par qualité, proportionnelle au nombre de prises : on voit d'un
  /// coup si quelqu'un accumule du commun ou chasse le rare.
  Widget _repartition(DetailJoueur j) {
    final maximum = j.parQualite.fold<int>(1, (m, q) => q.cases > m ? q.cases : m);
    return Column(
      children: [
        for (final q in j.parQualite)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              SizedBox(
                  width: 96,
                  child: PastilleRarete(rarete: q.qualite, dense: true)),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: q.cases / maximum,
                    minHeight: 8,
                    backgroundColor: Palette.caseVide,
                    valueColor:
                        AlwaysStoppedAnimation(Palette.qualite(q.qualite)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 62,
                child: Text(T('{0} · {1} pts', [q.cases, q.points]),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: 11, color: Palette.texteDoux)),
              ),
            ]),
          ),
      ],
    );
  }

  Widget _meilleures(DetailJoueur j) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 8,
        mainAxisSpacing: 10,
        childAspectRatio: .78,
      ),
      itemCount: j.meilleures.length,
      itemBuilder: (context, i) {
        final t = j.meilleures[i];
        final couleur = Palette.qualite(t.qualite);
        return GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => EcranDetailCase(caseId: t.caseId))),
          child: Column(children: [
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: Palette.caseVide,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: couleur, width: 2),
                ),
                clipBehavior: Clip.antiAlias,
                child: t.decoupe != null && !Reglages.instance.casesEntieres
                    ? Padding(
                        padding: const EdgeInsets.all(5),
                        child: ImageServeur(
                            chemin: t.decoupe!,
                            fit: BoxFit.contain,
                            taille: 160),
                      )
                    : ((t.vignette ?? t.decoupe) != null
                        ? ImageServeur(chemin: (t.vignette ?? t.decoupe)!, taille: 160)
                        : const SizedBox.shrink()),
              ),
            ),
            const SizedBox(height: 4),
            Text(t.nom,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, height: 1.2)),
          ]),
        );
      },
    );
  }
}
