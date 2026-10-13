import 'dart:async';
import '../i18n.dart';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../reglages.dart';
import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import '../widgets/apercu_espece.dart';
import '../widgets/regnes.dart';
import 'nouvelle_espece.dart';

/// Chercher une espèce dans le dex et la désigner soi-même.
///
/// Sert quand le moteur s'est trompé, ou n'a rien reconnu du tout. La recherche
/// porte aussi sur les synonymes : taper « Bos indicus » ramène la case Vache,
/// puisque c'est là que le zébu atterrit.
class EcranChoixEspece extends StatefulWidget {
  const EcranChoixEspece({super.key, this.pisteInitiale});

  /// Pré-remplit la recherche avec ce que le moteur avait proposé.
  final String? pisteInitiale;

  @override
  State<EcranChoixEspece> createState() => _EcranChoixEspeceState();
}

class _EcranChoixEspeceState extends State<EcranChoixEspece> {
  final _champ = TextEditingController();
  Timer? _attente;

  List<CaseDex> _resultats = [];
  bool _charge = false;
  String? _erreur;

  /// Les illustrations Wikipédia, par identifiant de case.
  ///
  /// Devant « Pica pica » et « Corvus corone », une photo tranche là où deux
  /// binômes latins laissent perplexe. Elles arrivent après la liste : le
  /// serveur doit parfois aller les chercher, et la recherche ne doit pas
  /// attendre pour autant.
  final _apercus = <int, String>{};

  @override
  void initState() {
    super.initState();
    if (widget.pisteInitiale != null && widget.pisteInitiale!.isNotEmpty) {
      _champ.text = widget.pisteInitiale!;
      _cherche(_champ.text);
    } else {
      // Sans recherche, on propose les espèces les plus communes : c'est le
      // meilleur point de départ quand on ne sait pas quoi taper.
      _cherche('');
    }
  }

  @override
  void dispose() {
    _attente?.cancel();
    _champ.dispose();
    super.dispose();
  }

  /// Recherche différée : on attend que la frappe se calme avant d'interroger
  /// le serveur, sinon chaque lettre déclenche une requête.
  void _differe(String texte) {
    _attente?.cancel();
    _attente = Timer(const Duration(milliseconds: 350), () => _cherche(texte));
  }

  Future<void> _cherche(String texte) async {
    setState(() {
      _charge = true;
      _erreur = null;
    });
    try {
      final d = await Api.instance.get('/dex', {
        'limite': 50,
        if (texte.trim().isNotEmpty) 'q': texte.trim(),
      });
      if (!mounted) return;
      setState(() => _resultats =
          (d['cases'] as List).map((c) => CaseDex.depuisJson(c)).toList());
      _chargeApercus();
    } on ErreurApi catch (e) {
      if (mounted) setState(() => _erreur = e.message);
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  /// Va chercher les illustrations des premiers résultats.
  ///
  /// Seulement les premiers : ce sont ceux qu'on voit, et chaque espèce
  /// inconnue coûte un aller-retour vers Wikipédia côté serveur.
  Future<void> _chargeApercus() async {
    final aDemander = _resultats
        .map((c) => c.id)
        .where((id) => !_apercus.containsKey(id))
        .take(12)
        .toList();
    if (aDemander.isEmpty) return;
    try {
      final d = await Api.instance
          .get('/fiches', {'cases': aDemander.join(',')});
      if (!mounted) return;
      final fiches = (d['fiches'] as Map?) ?? const {};
      setState(() {
        for (final e in fiches.entries) {
          final image = (e.value as Map)['image'];
          if (image is String && image.isNotEmpty) {
            _apercus[int.parse(e.key)] = image;
          }
        }
      });
    } catch (_) {
      // Une illustration manquante ne doit pas gêner le choix : la silhouette
      // reste affichée.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(T('Choisir l\'espèce')),
        actions: [
          // Le recours quand aucune proposition ne convient parce que
          // l'espèce n'existe simplement pas au catalogue : un cultivar de
          // rosier, une race, une variété. On l'ajoute soi-même.
          IconButton(
            tooltip: T('Ajouter une espèce absente du dex'),
            icon: const Icon(Icons.add),
            onPressed: () async {
              final creee = await Navigator.of(context)
                  .push<Map<String, dynamic>>(MaterialPageRoute(
                builder: (_) => EcranNouvelleEspece(
                  regne: _resultats.isNotEmpty ? _resultats.first.regne : 'plante',
                ),
              ));
              if (creee != null && mounted) {
                // On relance la recherche sur le nom créé : le joueur retombe
                // sur sa propre espèce et la choisit, au lieu d'avoir à la
                // retrouver lui-même.
                _champ.text = creee['nom'] as String? ?? '';
                _cherche(_champ.text);
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _champ,
              autofocus: true,
              autocorrect: false,
              onChanged: _differe,
              decoration: InputDecoration(
                hintText: T('Nom français ou latin…'),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _champ.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _champ.clear();
                          _cherche('');
                        },
                      ),
              ),
            ),
          ),
          // Choisir soi-même un champignon n'écarte pas le risque : c'est même
          // le moment où l'on se persuade d'avoir reconnu l'espèce.
          if (_resultats.any((c) => c.regne == 'champignon'))
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: AvertissementChampignon(),
            ),
          if (_charge) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _liste()),
        ],
      ),
    );
  }

  /// Ce qu'on montre à gauche d'une espèce, par ordre de préférence : sa propre
  /// photo si on l'a déjà trouvée, sinon l'illustration Wikipédia, sinon la
  /// silhouette. La première dit « c'est celle-ci que tu as vue », la deuxième
  /// aide à trancher, la troisième donne au moins la forme.
  Widget _apercu(CaseDex c) {
    final photo = _apercus[c.id];
    return SizedBox(
      width: 54,
      height: 54,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: Palette.caseVide,
          child: c.decoupe != null && !Reglages.instance.casesEntieres
              ? Padding(
                  padding: const EdgeInsets.all(5),
                  child: Image.network(
                      Api.instance.image(c.decoupe!).toString(),
                      headers: Api.instance.entetes,
                      fit: BoxFit.contain),
                )
              : photo != null
                  ? Image.network(photo,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _silhouette(c))
                  : _silhouette(c),
        ),
      ),
    );
  }

  Widget _silhouette(CaseDex c) => Padding(
        padding: const EdgeInsets.all(8),
        child: c.visuel == null
            ? Icon(Icons.help_outline,
                color: Palette.silhouette, size: 18)
            : SvgPicture.network(
                Api.instance.image(c.visuel!).toString(),
                colorFilter: ColorFilter.mode(
                    Palette.silhouette, BlendMode.srcIn),
              ),
      );

  /// Ouvre la fiche d'une espèce sans la choisir.
  Future<void> _ouvreFiche(CaseDex c) async {
    final choisi = await showDialog<bool>(
      context: context,
      builder: (_) => ApercuEspece(
        caseId: c.id,
        nom: c.nom,
        latin: c.latin,
        image: _apercus[c.id],
        regne: c.regne,
        toxique: c.toxique,
        rarete: c.rarete,
        points: c.points,
      ),
    );
    if (choisi == true && mounted) Navigator.pop(context, c);
  }

  Widget _liste() {
    if (_erreur != null) {
      return Center(child: Text(_erreur!, style: TextStyle(color: Palette.alerte)));
    }
    if (_resultats.isEmpty && !_charge) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            T('Aucune espèce ne correspond.\\nEssayez le nom latin, ou un nom plus général.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Palette.texteDoux, height: 1.4),
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: _resultats.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final c = _resultats[i];
        return ListTile(
          // La photo ouvre la fiche, jamais la sélection : c'est le geste
          // qu'on fait quand on hésite entre deux espèces voisines.
          leading: GestureDetector(
            onTap: () => _ouvreFiche(c),
            child: _apercu(c),
          ),
          onLongPress: () => _ouvreFiche(c),
          title: Row(children: [
            Flexible(
              child: Text(c.nom,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (c.toxique) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Palette.alerte,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('TOXIQUE',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .4)),
              ),
            ],
          ]),
          subtitle: Text(
            c.nomFr == null
                ? nomDeClasse(c.classe)
                : '${c.latin} · ${nomDeClasse(c.classe)}',
            style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
          ),
          trailing: c.decouvert
              ? Icon(Icons.check_circle, color: Palette.accent, size: 20)
              : null,
          onTap: () => Navigator.pop(context, c),
        );
      },
    );
  }
}
