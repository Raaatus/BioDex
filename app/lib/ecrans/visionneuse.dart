import 'package:flutter/material.dart';
import '../i18n.dart';

import '../api.dart';
import '../modeles.dart';
import '../theme.dart';
import '../widgets/detourage.dart';
import '../widgets/identifier_amis.dart';
import '../widgets/chargement.dart';
import '../widgets/case_dex.dart';

/// Une photo en grand, sur fond noir.
///
/// Balayage horizontal pour passer d'une photo à l'autre de la même case,
/// pincement pour zoomer, et de quoi mettre en avant ou supprimer.
class Visionneuse extends StatefulWidget {
  const Visionneuse({
    super.key,
    required this.captures,
    this.depart = 0,
    this.titre = '',
    this.surVedette,
    this.surCadrage,
    this.cadrage = 'auto',
    this.surSuppression,
  });

  final List<Capture> captures;
  final int depart;
  final String titre;

  /// Absents quand on regarde la collection de quelqu'un d'autre : on ne
  /// touche pas aux photos des autres.
  final Future<void> Function(int captureId)? surVedette;

  /// Bascule entre l'animal détouré et la photo entière pour l'image de la
  /// case. Le détourage automatique rate parfois son cadrage.
  final Future<void> Function(String mode)? surCadrage;

  /// Le cadrage actuellement retenu : « auto » ou « entier ».
  final String cadrage;
  final Future<void> Function(int captureId)? surSuppression;

  @override
  State<Visionneuse> createState() => _VisionneuseState();
}

class _VisionneuseState extends State<Visionneuse> {
  late final PageController _pages = PageController(initialPage: widget.depart);
  late int _courante = widget.depart;
  // Copie modifiable : on retire les photos supprimées sans toucher à la liste
  // que l'écran appelant nous a passée.
  late final List<Capture> _captures = List.of(widget.captures);

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _supprime() async {
    final capture = _captures[_courante];
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

    await widget.surSuppression!(capture.id);
    if (!mounted) return;
    if (_captures.length <= 1) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _captures.removeAt(_courante);
      if (_courante >= _captures.length) _courante = _captures.length - 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Une liste vide fait planter l'indexation qui suit. Le cas ne se produit
    // pas aujourd'hui — la carte ne renvoie que des photos rangées — mais un
    // appelant y est déjà exposé, et un écran vide vaut mieux qu'un plantage.
    if (_captures.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(widget.titre),
        ),
        body: Center(
          child: Text(T('Aucune photo à montrer.'),
              style: TextStyle(color: Colors.white70)),
        ),
      );
    }
    final capture = _captures[_courante];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        titleTextStyle: const TextStyle(
            color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
        title: Text(widget.titre.isEmpty ? capture.verdict : widget.titre),
        actions: [
          if (widget.surVedette != null || widget.surSuppression != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) async {
                switch (v) {
                  case 'vedette':
                    await widget.surVedette!(capture.id);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(T('Cette photo représente la case.'))));
                  case 'auto':
                  case 'decoupe':
                  case 'entier':
                    await widget.surCadrage!(v);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(switch (v) {
                      'entier' => T('La case montre la photo entière.'),
                      'decoupe' => T('La case montre l\'animal détouré.'),
                      _ => T('La case suit votre réglage général.'),
                    })));
                  case 'amis':
                    _identifie(capture);
                  case 'vignette':
                    _retraceVignette(capture);
                  case 'supprimer':
                    _supprime();
                }
              },
              itemBuilder: (_) => [
                if (widget.surVedette != null)
                  PopupMenuItem(
                    value: 'vedette',
                    child: ListTile(
                        dense: true,
                        leading: Icon(Icons.push_pin_outlined),
                        title: Text(T('Photo de la case')),
                        subtitle: Text(T('Celle qu\'on voit sur la grille'),
                            style: TextStyle(fontSize: 11))),
                  ),
                // Le détourage rate parfois son cadrage : on doit pouvoir
                // reprendre la photo telle qu'elle a été prise.
                //
                // Trois entrées et non plus une bascule : depuis qu'un réglage
                // général existe, « détouré » et « suivre le réglage » ne sont
                // plus la même chose, et une bascule à deux états ne saurait
                // pas dire lequel des deux on demande.
                if (widget.surCadrage != null) ...[
                  _cadrage('auto', Icons.auto_awesome_outlined,
                      'Suivre mon réglage', widget.cadrage),
                  _cadrage('decoupe', Icons.crop,
                      'Toujours l\'animal détouré', widget.cadrage),
                  _cadrage('entier', Icons.crop_free,
                      'Toujours la photo entière', widget.cadrage),
                ],
                // Le détourage automatique garde la branche, coupe une patte,
                // ou n'attrape rien sur une plante. Le joueur, lui, sait ce
                // qu'il a photographié.
                PopupMenuItem(
                  value: 'vignette',
                  child: ListTile(
                      dense: true,
                      leading: Icon(Icons.gesture),
                      title: Text(T('Détourer au doigt')),
                      subtitle: Text(T('Ne change que la vignette'),
                          style: TextStyle(fontSize: 11))),
                ),
                // On se rappelle rarement sur le moment qu'on était à deux :
                // l'identification reste ouverte longtemps après.
                PopupMenuItem(
                  value: 'amis',
                  child: ListTile(
                      dense: true,
                      leading: Icon(Icons.group_add_outlined),
                      title: Text(T('Qui était avec moi')),
                      subtitle: Text(T('La photo comptera aussi pour eux'),
                          style: TextStyle(fontSize: 11))),
                ),
                if (widget.surSuppression != null)
                  PopupMenuItem(
                    value: 'supprimer',
                    child: ListTile(
                        dense: true,
                        leading: Icon(Icons.delete_outline, color: Palette.alerte),
                        title: Text(T('Supprimer'))),
                  ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pages,
              itemCount: _captures.length,
              onPageChanged: (i) => setState(() => _courante = i),
              itemBuilder: (context, i) => InteractiveViewer(
                // Zoom au pincement, avec assez de marge pour aller chercher un
                // détail — la plume, l'antenne — sans sortir de l'écran.
                minScale: 1,
                maxScale: 5,
                child: Center(
                  // `ImageServeur` et non `Image.network` : la seconde ne
                  // garde rien sur le disque, et rouvrir la même photo la
                  // retéléchargeait en entier. C'est le plus gros fichier de
                  // l'application, et celui qu'on regarde le plus souvent.
                  child: ImageServeur(
                    chemin: _captures[i].photo,
                    fit: BoxFit.contain,
                    attente: const Chargement(),
                    repli: const Icon(Icons.broken_image_outlined,
                        color: Colors.white38, size: 48),
                  ),
                ),
              ),
            ),
          ),
          _pied(capture),
        ],
      ),
    );
  }

  /// Redessiner la vignette d'une photo, au doigt.
  ///
  /// On repart de la photo entière, pas de la découpe existante : retracer
  /// par-dessus un détourage raté ne permettrait pas de récupérer ce qu'il
  /// avait jeté.
  Future<void> _retraceVignette(Capture c) async {
    try {
      final octets = await Api.instance.octets(c.photo);
      if (!mounted) return;
      final resultat = await Navigator.of(context).push<PhotoRetouchee>(
        MaterialPageRoute(
          builder: (_) => EcranDetourage(
              image: octets, titre: T('Détourer la vignette'), traceSeul: true),
        ),
      );
      final trace = resultat?.decoupe;
      if (trace == null || !mounted) {
        if (resultat != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(T('Aucun tracé : la vignette est inchangée.'))));
        }
        return;
      }
      await Api.instance.redecoupe(c.id, trace);
      if (!mounted) return;
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
  /// que l'écran a été chargé, et partir d'un état périmé ferait retirer
  /// quelqu'un qu'on n'a jamais décoché.
  Future<void> _identifie(Capture c) async {
    try {
      final d = await Api.instance.get('/captures/${c.id}/participants');
      if (!mounted) return;
      final change = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => IdentifierAmis(
          captureId: c.id,
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

  Widget _pied(Capture c) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 26),
      color: Colors.black,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_captures.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _captures.length; i++)
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _courante ? Colors.white : Colors.white24,
                      ),
                    ),
                ],
              ),
            ),
          Text(c.creeLe.replaceFirst(' ', ' à '),
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          if (c.corrigee)
            Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(T('Espèce choisie à la main'),
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
            ),
        ],
      ),
    );
  }
}
