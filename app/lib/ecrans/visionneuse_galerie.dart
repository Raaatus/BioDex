import 'package:flutter/material.dart';
import '../i18n.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;

import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import '../widgets/detourage.dart';
import '../widgets/identifier_amis.dart';
import '../widgets/reactions.dart';
import 'detail_case.dart';
import 'situer.dart';
import '../widgets/case_dex.dart';

/// La visionneuse de la galerie.
///
/// On y fait tout ce qu'on peut faire d'une photo : la regarder en grand, la
/// mettre en favori, y réagir si elle est d'un ami, l'enregistrer sur le
/// téléphone, corriger sa date ou son lieu, et la supprimer si elle est à soi.
class VisionneuseGalerie extends StatefulWidget {
  const VisionneuseGalerie({
    super.key,
    required this.photos,
    this.depart = 0,
    this.surChangement,
    this.surSuppression,
  });

  final List<PhotoGalerie> photos;
  final int depart;
  final VoidCallback? surChangement;
  final void Function(int captureId)? surSuppression;

  @override
  State<VisionneuseGalerie> createState() => _VisionneuseGalerieState();
}

class _VisionneuseGalerieState extends State<VisionneuseGalerie> {
  late final PageController _pages = PageController(initialPage: widget.depart);
  late int _index = widget.depart;
  bool _travaille = false;

  PhotoGalerie get _photo => widget.photos[_index];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _basculeFavori() async {
    final p = _photo;
    setState(() => p.favori = !p.favori);
    try {
      if (p.favori) {
        await Api.instance.put('/captures/${p.captureId}/favori');
      } else {
        await Api.instance.supprime('/captures/${p.captureId}/favori');
      }
      widget.surChangement?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => p.favori = !p.favori);      // on revient en arrière
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Enregistre la photo dans la pellicule du téléphone.
  Future<void> _telecharge() async {
    setState(() => _travaille = true);
    try {
      final url = Api.instance.image(_photo.photo).toString();
      final r = await http.get(Uri.parse(url), headers: Api.instance.entetes);
      if (r.statusCode >= 400) throw ErreurApi('Téléchargement refusé.', r.statusCode);
      await Gal.putImageBytes(r.bodyBytes, album: 'Biodex');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(T('Photo enregistrée dans la pellicule.'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(T('Enregistrement impossible : {0}', [e]))),
      );
    } finally {
      if (mounted) setState(() => _travaille = false);
    }
  }

  /// Donner un nom à la photo. L'espèce dit ce qu'on a vu, le titre dit ce
  /// qu'on a vécu.
  Future<void> _renomme() async {
    final champ = TextEditingController(text: _photo.titre);
    final titre = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(T('Titre de la photo')),
        content: TextField(
          controller: champ,
          autofocus: true,
          maxLength: 120,
          decoration: InputDecoration(
            hintText: T('Le héron du canal…'),
          ),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: Text(T('Annuler'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, champ.text),
              child: Text(T('Enregistrer'))),
        ],
      ),
    );
    champ.dispose();
    if (titre == null) return;
    try {
      final d = await Api.instance
          .patch('/captures/${_photo.captureId}/titre', {'titre': titre});
      if (!mounted) return;
      setState(() => _photo.titre = d['titre'] ?? '');
      widget.surChangement?.call();
    } on ErreurApi catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _modifie() async {
    final p = _photo;
    // On réutilise l'écran qui sert déjà à situer les photos orphelines : c'est
    // exactement le même travail, sur une photo qui a déjà des valeurs.
    final fait = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => EcranSituerUne(
        capture: CaptureOrpheline.depuisJson({
          'capture_id': p.captureId,
          'nom': p.nom,
          'cree_le': p.quand,
          'prise_le': p.heureSure ? p.quand : null,
          'lat': p.lat,
          'lon': p.lon,
          'sans_position': !p.situee,
          'sans_heure': !p.heureSure,
          'vignette': p.vignette,
        }),
      ),
    ));
    if (fait == true) {
      widget.surChangement?.call();
      if (mounted) Navigator.pop(context);
    }
  }

  /// Redessiner la vignette au doigt.
  ///
  /// On repart de la photo entière, pas de la découpe existante : retracer
  /// par-dessus un détourage raté ne permettrait pas de récupérer ce qu'il
  /// avait jeté.
  Future<void> _retraceVignette() async {
    final p = _photo;
    try {
      final octets = await Api.instance.octets(p.photo);
      if (!mounted) return;
      final resultat = await Navigator.of(context).push<PhotoRetouchee>(
        MaterialPageRoute(
          builder: (_) => EcranDetourage(
              image: octets, titre: T('Détourer la vignette'), traceSeul: true),
        ),
      );
      final trace = resultat?.decoupe;
      if (trace == null) {
        if (resultat != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(T('Aucun tracé : la vignette est inchangée.'))));
        }
        return;
      }
      await Api.instance.redecoupe(p.captureId, trace);
      if (!mounted) return;
      widget.surChangement?.call();
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(T('Vignette redessinée.'))));
    } on ErreurApi catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  /// Identifier des amis sur une photo déjà envoyée.
  ///
  /// On relit les participants avant d'ouvrir : la liste a pu changer depuis
  /// que la galerie a été chargée, et partir d'un état périmé ferait retirer
  /// quelqu'un qu'on n'a jamais décoché.
  Future<void> _identifie() async {
    final p = _photo;
    try {
      final d = await Api.instance.get('/captures/${p.captureId}/participants');
      if (!mounted) return;
      final change = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => IdentifierAmis(
          captureId: p.captureId,
          dejaLa: (d['participants'] as List)
              .map((x) => Personne.depuisJson(x))
              .toList(),
        ),
      ));
      if (change == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(T('Photo partagée.'))));
      }
    } on ErreurApi catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _supprime() async {
    final confirme = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(T('Supprimer cette photo ?')),
        content: Text(
            T('Si c\'est la seule de la case, l\'espèce redeviendra à trouver.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(T('Annuler'))),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(backgroundColor: Palette.alerte),
            child: Text(T('Supprimer')),
          ),
        ],
      ),
    );
    if (confirme != true) return;
    final id = _photo.captureId;
    try {
      await Api.instance.supprime('/captures/$id');
      widget.surSuppression?.call(id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _photo;
    return Scaffold(
      backgroundColor: Colors.black,
      // La barre flotte au-dessus de la photo : sur un ciel blanc ou une aile
      // claire, des icônes blanches sur fond translucide disparaissaient. Un
      // fond franc les détache quelle que soit l'image dessous.
      extendBodyBehindAppBar: false,
      appBar: AppBar(
        backgroundColor: const Color(0xFF101114),
        surfaceTintColor: const Color(0xFF101114),
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white, size: 22),
        actionsIconTheme: const IconThemeData(color: Colors.white, size: 22),
        titleTextStyle: const TextStyle(
            color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(p.titre.isEmpty ? p.nom : p.titre),
            if (p.titre.isNotEmpty)
              Text(p.nom,
                  style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white54,
                      fontWeight: FontWeight.w400)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: p.favori ? 'Retirer des favoris' : 'Mettre en favori',
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: .12),
            ),
            icon: Icon(p.favori ? Icons.star : Icons.star_border,
                color: p.favori ? const Color(0xFFF0B429) : Colors.white),
            onPressed: _basculeFavori,
          ),
          const SizedBox(width: 6),
          IconButton(
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: .12),
            ),
            tooltip: T('Enregistrer sur le téléphone'),
            icon: _travaille
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.download_outlined),
            onPressed: _travaille ? null : _telecharge,
          ),
          if (p.moi)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              // Le menu reste clair : un fond sombre y rendrait les libellés
              // illisibles, ils héritent du thème général.
              iconColor: Colors.white,
              onSelected: (v) => switch (v) {
                'titre' => _renomme(),
                'modifier' => _modifie(),
                'amis' => _identifie(),
                'vignette' => _retraceVignette(),
                _ => _supprime(),
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'titre',
                    child: ListTile(
                        dense: true,
                        leading: Icon(Icons.title),
                        title: Text(T('Donner un titre')))),
                PopupMenuItem(
                    value: 'modifier',
                    child: ListTile(
                        dense: true,
                        leading: Icon(Icons.edit_location_alt_outlined),
                        title: Text(T('Corriger date et lieu')))),
                // On se rappelle rarement sur le moment qu'on était à deux :
                // l'identification doit rester ouverte longtemps après, au
                // même endroit que la date et le lieu.
                PopupMenuItem(
                    value: 'vignette',
                    child: ListTile(
                        dense: true,
                        leading: Icon(Icons.gesture),
                        title: Text(T('Détourer au doigt')),
                        subtitle: Text(T('Ne change que la vignette'),
                            style: TextStyle(fontSize: 11)))),
                PopupMenuItem(
                    value: 'amis',
                    child: ListTile(
                        dense: true,
                        leading: Icon(Icons.group_add_outlined),
                        title: Text(T('Qui était avec moi')))),
                PopupMenuItem(
                    value: 'supprimer',
                    child: ListTile(
                        dense: true,
                        leading: Icon(Icons.delete_outline, color: Palette.alerte),
                        title: Text(T('Supprimer')))),
              ],
            ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: PageView.builder(
            controller: _pages,
            itemCount: widget.photos.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => _GlisserPourFermer(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                // `ImageServeur` et non `Image.network` : la seconde ne garde
                // rien sur le disque, et rouvrir la même photo la
                // retéléchargeait en entier.
                child: Center(
                  child: ImageServeur(
                    chemin: widget.photos[i].photo,
                    fit: BoxFit.contain,
                    attente: const Center(
                        child: CircularProgressIndicator(color: Colors.white)),
                    repli: const Icon(Icons.broken_image_outlined,
                        color: Colors.white38, size: 48),
                  ),
                ),
              ),
            ),
          ),
        ),
        _pied(p),
      ]),
    );
  }

  Widget _pied(PhotoGalerie p) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
      color: Colors.black,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Avatar(pseudo: p.pseudo, chemin: p.avatar, taille: 26),
          const SizedBox(width: 8),
          Text(p.moi ? 'Moi' : p.pseudo,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (p.caseId != null)
            TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => EcranDetailCase(caseId: p.caseId!))),
              child: Text(T('Voir la case')),
            ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          const Icon(Icons.schedule, size: 13, color: Colors.white38),
          const SizedBox(width: 5),
          Text(
            p.heureSure
                ? p.quand.replaceFirst(' ', ' à ').substring(0, 16)
                : '${p.quand.split(' ').first} (heure approximative)',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ]),
        if (p.lieu.isNotEmpty || p.situee)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(children: [
              const Icon(Icons.place_outlined, size: 13, color: Colors.white38),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  p.lieu.isNotEmpty
                      ? p.lieu
                      : '${p.lat!.toStringAsFixed(4)}, ${p.lon!.toStringAsFixed(4)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ]),
          ),
        // On ne réagit qu'aux photos des autres : le serveur le refuserait de
        // toute façon, autant ne pas montrer la barre.
        if (!p.moi) ...[
          const SizedBox(height: 10),
          Theme(
            data: Theme.of(context).copyWith(
              textTheme: Theme.of(context)
                  .textTheme
                  .apply(bodyColor: Colors.white70),
            ),
            child: BarreReactions(
              captureId: p.captureId,
              resume: p.reactions,
              surChangement: (r) {
                setState(() => p.reactions = r);
                widget.surChangement?.call();
              },
            ),
          ),
        ],
      ]),
    );
  }
}


/// Fermer la photo en la faisant glisser vers le bas.
///
/// Le geste attendu partout ailleurs : on pousse l'image hors de l'écran et
/// elle se referme. La photo suit le doigt et s'efface à mesure, de sorte que
/// le geste s'annule de lui-même si on remonte.
class _GlisserPourFermer extends StatefulWidget {
  const _GlisserPourFermer({required this.child});
  final Widget child;

  @override
  State<_GlisserPourFermer> createState() => _GlisserPourFermerState();
}

class _GlisserPourFermerState extends State<_GlisserPourFermer> {
  double _decalage = 0;

  @override
  Widget build(BuildContext context) {
    final hauteur = MediaQuery.of(context).size.height;
    return GestureDetector(
      // Vertical seulement : le balayage horizontal appartient au feuilletage
      // d'une photo à l'autre.
      onVerticalDragUpdate: (d) =>
          setState(() => _decalage = (_decalage + d.delta.dy).clamp(0.0, hauteur)),
      onVerticalDragEnd: (d) {
        // Un geste franc suffit, même court : c'est la vitesse qui dit
        // l'intention, pas la distance parcourue.
        if (_decalage > hauteur * .18 || d.velocity.pixelsPerSecond.dy > 700) {
          Navigator.of(context).maybePop();
        } else {
          setState(() => _decalage = 0);
        }
      },
      child: Transform.translate(
        offset: Offset(0, _decalage),
        child: Opacity(
          opacity: (1 - _decalage / (hauteur * .6)).clamp(0.0, 1.0),
          child: widget.child,
        ),
      ),
    );
  }
}
