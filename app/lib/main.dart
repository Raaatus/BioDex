import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'reglages.dart';
import 'ecrans/amis.dart';
import 'ecrans/capture.dart';
import 'ecrans/connexion.dart';
import 'ecrans/dex.dart';
import 'ecrans/galerie.dart';
import 'ecrans/profil.dart';
import 'theme.dart';
import 'widgets/fond_anime.dart';
import 'widgets/sphere.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Le jeton et l'adresse du serveur sont relus avant le premier écran : sans
  // ça, l'application repasserait par la connexion à chaque lancement.
  await Api.instance.charge();
  await Reglages.instance.charge();
  runApp(const Biodex());
}

class Biodex extends StatefulWidget {
  const Biodex({super.key});

  @override
  State<Biodex> createState() => _BiodexState();
}

class _BiodexState extends State<Biodex> {
  @override
  Widget build(BuildContext context) {
    // L'application se redessine quand les réglages changent : c'est ce qui
    // fait basculer le thème sans redémarrer.
    return ListenableBuilder(
      listenable: Reglages.instance,
      builder: (context, _) {
        final r = Reglages.instance;
        // « Système » suit le téléphone entre clair et sombre ; tout autre
        // thème s'impose tel quel.
        final systeme =
            MediaQuery.platformBrightnessOf(context) == Brightness.dark;
        final jeu = r.theme == 'systeme'
            ? themeParCle(systeme ? 'sombre' : 'clair')
            : themeParCle(r.theme);
        final td = theme(jeu);
        return MaterialApp(
          title: 'Biodex',
          debugShowCheckedModeBanner: false,
          theme: td,
          darkTheme: td,
          themeMode: ThemeMode.light,
          // Le décor animé du thème, sous tous les écrans : il ne passe devant
          // rien, il remplit ce que les écrans laissent transparent.
          builder: (context, enfant) => jeu.fondAnime == null
              ? enfant!
              : Stack(children: [
                  Positioned.fill(
                      child: FondAnime(
                          key: ValueKey(jeu.fondAnime),
                          effet: jeu.fondAnime!,
                          anime: r.decorAnime)),
                  enfant!,
                ]),
          home: Api.instance.connecte
              ? EcranPrincipal(surDeconnexion: () => setState(() {}))
              : EcranConnexion(surConnexion: () => setState(() {})),
        );
      },
    );
  }
}

class EcranPrincipal extends StatefulWidget {
  const EcranPrincipal({super.key, required this.surDeconnexion});
  final VoidCallback surDeconnexion;

  @override
  State<EcranPrincipal> createState() => _EcranPrincipalState();
}

class _EcranPrincipalState extends State<EcranPrincipal> {
  int _onglet = 0;
  int _demandes = 0;
  int _notifications = 0;
  Timer? _veille;

  @override
  void initState() {
    super.initState();
    _compteDemandes();
    // Une demande d'ami qui reste invisible ne sert à rien. On relève le
    // compteur de temps en temps, sans en faire un abonnement permanent.
    _veille = Timer.periodic(const Duration(minutes: 2), (_) => _compteDemandes());
  }

  @override
  void dispose() {
    _veille?.cancel();
    super.dispose();
  }

  /// Le badge de l'onglet Amis réunit ce qui réclame une attention : les
  /// demandes en attente et les réactions qu'on n'a pas encore vues.
  Future<void> _compteDemandes() async {
    try {
      final r = await Future.wait([
        Api.instance.get('/moi'),
        Api.instance.get('/notifications'),
      ]);
      if (mounted) {
        setState(() {
          _demandes = r[0]['demandes'] ?? 0;
          _notifications = r[1]['non_lues'] ?? 0;
        });
      }
    } catch (_) {
      // Sans réseau, on garde le dernier compte connu.
    }
  }

  /// Les écrans montés en permanence, dans l'ordre de l'IndexedStack.
  /// Capturer a son bouton central ; la carte s'ouvre depuis le dex, puisque
  /// c'est en regardant sa collection qu'on veut savoir où l'on a trouvé quoi.
  static const _dex = 0, _capture = 1, _amis = 2, _galerie = 3, _profil = 4;

  @override
  Widget build(BuildContext context) {
    // Tous les écrans restent montés : revenir sur le dex ne doit pas relancer
    // le chargement de la grille ni perdre la position de défilement.
    final alertes = _demandes + _notifications;
    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _onglet,
        children: [
          const EcranDex(),
          EcranCapture(visible: _onglet == _capture),
          const EcranAmis(),
          const EcranGalerie(),
          EcranProfil(surDeconnexion: widget.surDeconnexion),
        ],
      ),
      // Photographier est le geste le plus fréquent et le plus attendu : il
      // mérite mieux qu'un onglet parmi six, où il se noyait. Au centre, en
      // relief, sous le pouce.
      // La sphère plutôt qu'un appareil photo : c'est l'objet du jeu, et le
      // geste qu'on vient faire. Elle s'entrouvre et s'entoure d'un halo
      // quand on est sur l'écran de capture.
      // La sphère disparaît sur l'écran de capture : le viseur y a son propre
      // déclencheur, au même endroit, et les deux se chevauchaient.
      // La sphère disparaît sur l'écran de capture : le viseur y a son propre
      // déclencheur, au même endroit, et les deux se chevauchaient.
      floatingActionButton: _onglet == _capture
          ? null
          : SphereMenu(surAppui: () => setState(() => _onglet = _capture)),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        height: 64,
        padding: EdgeInsets.zero,
        color: Palette.barre,
        surfaceTintColor: Palette.barre,
        shadowColor: Colors.black26,
        elevation: 8,
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _bouton(_dex, Icons.grid_view_rounded, 'Dex'),
            _bouton(_amis, Icons.people_rounded, 'Amis', badge: alertes),
            const SizedBox(width: 56),          // la place du bouton central
            _bouton(_galerie, Icons.photo_library_rounded, 'Galerie'),
            _bouton(_profil, Icons.person_rounded, 'Profil'),
          ],
        ),
      ),
    );
  }

  /// Une destination de la barre. Icône seule quand elle n'est pas choisie, le
  /// nom n'apparaissant que sur l'onglet actif : quatre libellés permanents
  /// alourdissaient la barre sans rien apprendre.
  Widget _bouton(int index, IconData icone, String nom, {int badge = 0}) {
    final actif = _onglet == index;
    return Expanded(
      child: InkResponse(
        onTap: () {
          setState(() => _onglet = index);
          if (index == _amis) _compteDemandes();
        },
        radius: 34,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Badge.count(
              count: badge,
              isLabelVisible: badge > 0,
              child: Icon(icone,
                  size: 23,
                  color: actif ? Palette.accent : Palette.texteDoux),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              child: actif
                  ? Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(nom,
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: Palette.accent)),
                    )
                  : const SizedBox(height: 0, width: 0),
            ),
          ],
        ),
      ),
    );
  }
}
