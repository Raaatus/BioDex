import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets/chargement.dart';
import '../widgets/regnes.dart';

/// Ajouter au dex une espèce que le moteur ne connaîtra jamais.
///
/// Le cas qui a motivé cet écran : une roseraie. Le moteur rend « Rosa
/// gallica » pour tous les cultivars, parce qu'un cultivar n'est pas un taxon
/// et n'existe dans aucun catalogue. « Sophie Vartan » ne sera jamais reconnue
/// par une analyse — mais elle peut exister au dex, et on peut y ranger ses
/// photos à la main.
///
/// Deux chemins, et le second ne marche pas toujours :
///
///   à la main       un titre, une description. C'est le chemin des cultivars,
///                   des races, des variétés — tout ce que GBIF ignore ;
///   par un lien     coller une adresse Wikipédia remplit le reste. Quand
///                   l'article a une entité Wikidata, on récupère le binôme, la
///                   clé GBIF et le résumé. Un cultivar n'en a pas : on récupère
///                   alors le titre et le résumé, et rien de plus.
class EcranNouvelleEspece extends StatefulWidget {
  const EcranNouvelleEspece({
    super.key,
    this.regne = 'plante',
    this.parente,
    this.existante,
  });

  final String regne;

  /// La case dont la nouvelle est une variante, quand on vient d'une
  /// correction : elle donne le genre et la famille, faute de backbone.
  final int? parente;

  /// Non nul pour modifier une espèce déjà indexée plutôt qu'en créer une.
  final Map<String, dynamic>? existante;

  @override
  State<EcranNouvelleEspece> createState() => _EcranNouvelleEspeceState();
}

class _EcranNouvelleEspeceState extends State<EcranNouvelleEspece> {
  late final _nom =
      TextEditingController(text: widget.existante?['nom'] as String? ?? '');
  late final _latin =
      TextEditingController(text: widget.existante?['latin'] as String? ?? '');
  late final _description =
      TextEditingController(text: widget.existante?['resume'] as String? ?? '');
  late final _lien = TextEditingController(
      text: widget.existante?['wikipedia'] as String? ?? '');

  late String _regne = widget.existante?['regne'] as String? ?? widget.regne;
  bool _envoie = false;
  bool _cherche = false;
  String? _erreur;
  String? _trouve;

  bool get _modification => widget.existante != null;

  @override
  void dispose() {
    for (final c in [_nom, _latin, _description, _lien]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Regarder ce que le lien donne, sans rien créer.
  ///
  /// On montre le résultat avant d'enregistrer : coller une adresse ne doit
  /// jamais fabriquer une case que personne n'a relue.
  Future<void> _essaieLeLien() async {
    final lien = _lien.text.trim();
    if (lien.isEmpty) return;
    setState(() {
      _cherche = true;
      _erreur = null;
      _trouve = null;
    });
    try {
      final d = await Api.instance
          .get('/especes/apercu?lien=${Uri.encodeQueryComponent(lien)}');
      if (!mounted) return;
      setState(() {
        if (_nom.text.trim().isEmpty) {
          _nom.text = (d['nom_fr'] ?? d['titre'] ?? '') as String;
        }
        if (_latin.text.trim().isEmpty && d['latin'] != null) {
          _latin.text = d['latin'] as String;
        }
        if (_description.text.trim().isEmpty && d['resume'] != null) {
          _description.text = d['resume'] as String;
        }
        _trouve = d['latin'] != null
            ? 'Taxon reconnu : ${d['latin']}'
            // Le cas du cultivar, dit franchement : l'article existe, mais il
            // ne décrit pas un taxon. On a pris le titre et le résumé, la
            // taxonomie reste à la charge du joueur.
            : 'Article trouvé, mais ce n\'est pas un taxon référencé. Le titre et le résumé ont été repris.';
      });
    } on ErreurApi catch (e) {
      if (mounted) setState(() => _erreur = e.message);
    } finally {
      if (mounted) setState(() => _cherche = false);
    }
  }

  Future<void> _valide() async {
    final nom = _nom.text.trim();
    if (nom.length < 2) {
      setState(() => _erreur = T('Il faut au moins un nom.'));
      return;
    }
    setState(() {
      _envoie = true;
      _erreur = null;
    });
    try {
      final corps = {
        'nom': nom,
        'description': _description.text.trim(),
        'wikipedia': _lien.text.trim(),
      };
      final Map<String, dynamic> d;
      if (_modification) {
        d = await Api.instance
            .patch('/especes/${widget.existante!['id']}', corps);
      } else {
        d = await Api.instance.post('/especes', {
          ...corps,
          'regne': _regne,
          'latin': _latin.text.trim(),
          if (widget.parente != null) 'parente': widget.parente,
        });
      }
      if (mounted) Navigator.of(context).pop(d);
    } on ErreurApi catch (e) {
      if (mounted) {
        setState(() {
          _erreur = e.message;
          _envoie = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_modification ? 'Modifier l\'espèce' : 'Nouvelle espèce')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            T('Cette espèce entrera au dex et tout le monde la verra. Elle ne sera jamais proposée par une analyse : le moteur n\'a pas appris à la reconnaître, et ne l\'apprendra pas. On l\'y range à la main.'),
            style: TextStyle(
                fontSize: 12.5, color: Palette.texteDoux, height: 1.4),
          ),
          const SizedBox(height: 18),
          if (!_modification) ...[
            Text(T('RÈGNE'),
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .5,
                    color: Palette.texteDoux)),
            const SizedBox(height: 8),
            ChoixRegne(
                choisi: _regne, surChoix: (r) => setState(() => _regne = r.cle)),
            const SizedBox(height: 18),
          ],
          TextField(
            controller: _nom,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: T('Nom *'),
              hintText: T('Rosier Sophie Vartan'),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (!_modification) ...[
            TextField(
              controller: _latin,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: T('Nom latin'),
                hintText: T('Laissé vide, le nom sert de référence'),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _lien,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: T('Article Wikipédia'),
              hintText: 'https://fr.wikipedia.org/wiki/…',
              border: const OutlineInputBorder(),
              suffixIcon: _cherche
                  ? const Padding(
                      padding: EdgeInsets.all(12), child: PetitChargement())
                  : IconButton(
                      tooltip: T('Remplir depuis l\'article'),
                      icon: const Icon(Icons.download_outlined),
                      onPressed: _essaieLeLien,
                    ),
            ),
          ),
          if (_trouve != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.info_outline, size: 15, color: Palette.texteDoux),
              const SizedBox(width: 6),
              Expanded(
                child: Text(_trouve!,
                    style: TextStyle(fontSize: 12, color: Palette.texteDoux)),
              ),
            ]),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            minLines: 4,
            maxLines: 10,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: T('Description'),
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          if (_erreur != null) ...[
            const SizedBox(height: 14),
            Text(_erreur!,
                style: TextStyle(color: Palette.alerte, fontSize: 13)),
          ],
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: _envoie ? null : _valide,
            icon: _envoie
                ? const PetitChargement(taille: 16, couleur: Colors.white)
                : const Icon(Icons.check),
            label: Text(_modification ? 'Enregistrer' : 'Ajouter au dex'),
          ),
          const SizedBox(height: 10),
          Text(
            T('Vous pourrez la retirer si elle s\'avère fausse. Tant que personne n\'y a rangé de photo, elle disparaîtra complètement ; ensuite elle sera seulement désactivée, pour ne pas emporter le travail des autres.'),
            style: TextStyle(
                fontSize: 11.5, color: Palette.texteDoux, height: 1.35),
          ),
        ],
      ),
    );
  }
}
