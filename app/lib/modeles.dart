/// Les objets renvoyés par le backend, transcrits en Dart.
///
/// Rien de plus que de la lecture de JSON : la logique reste au serveur, qui
/// est seul à savoir ce qui remplit une case.
library;

// `Color` seul, depuis `dart:ui` : ce fichier ne décrit que des données et
// n'a aucune raison de tirer Material avec lui.
import 'dart:ui' show Color;

import 'i18n.dart';

class CaseDex {
  CaseDex.depuisJson(Map<String, dynamic> j)
      : id = j['id'],
        latin = j['latin'] ?? '',
        nomFr = j['nom_fr'],
        regne = j['regne'] ?? 'animal',
        toxique = j['toxique'] ?? false,
        cadrage = j['cadrage'] ?? 'auto',
        nom = j['nom'] ?? j['latin'] ?? '',
        famille = j['famille'] ?? '',
        classe = j['classe'] ?? '',
        rarete = j['rarete'] ?? 3,
        points = j['points'] ?? 0,
        obs = j['obs'] ?? 0,
        visuel = j['visuel'],
        vignette = j['vignette'],
        decoupe = j['decoupe'],
        decouvert = j['decouvert'] ?? false,
        trouveLe = j['trouve_le'],
        nbCaptures = j['nb_captures'] ?? 0,
        ajoutePar = j['ajoute_par'],
        ajouteParPseudo = j['ajoute_par_pseudo'];

  final int id;
  final String latin;
  final String? nomFr;

  /// animal | plante | champignon. Le dex les mélange, mais chaque règne a son
  /// moteur, ses seuils et ses silhouettes.
  final String regne;

  /// Signalée toxique — champignons seulement, et jamais l'inverse.
  final bool toxique;

  /// Ce que montre la case : « auto » suit le réglage général de
  /// l'application, « entier » force la photo telle qu'elle a été prise,
  /// « decoupe » force l'animal détouré.
  final String cadrage;
  final String nom;
  final String famille;
  final String classe;
  /// Qualité de 1 (commun) à 5 (légendaire).
  final int rarete;

  /// Points rapportés par la découverte de cette case.
  final int points;
  final int obs;

  /// Chemin de la silhouette du groupe, servie par le backend.
  final String? visuel;

  /// Chemin de la vignette de la photo mise en avant, s'il y en a une.
  final String? vignette;

  /// L'animal détouré sur fond transparent, quand le serveur a su l'extraire.
  /// C'est lui qu'on pose dans la case, comme un autocollant.
  final String? decoupe;

  final bool decouvert;
  final String? trouveLe;
  final int nbCaptures;

  /// Non nul quand un joueur a créé cette case lui-même : elle n'existe pas au
  /// backbone GBIF, et aucune analyse ne la proposera jamais. L'écran le dit,
  /// parce que la fiabilité n'est pas la même qu'une espèce référencée.
  final int? ajoutePar;
  final String? ajouteParPseudo;

  /// L'image à poser dans la case, et comment la poser.
  ///
  /// Le serveur envoie désormais les deux cadrages et laisse le client
  /// trancher : c'est ce qui permet au réglage général de s'appliquer sans
  /// aller-retour réseau. Le choix fait sur une case précise l'emporte
  /// toujours sur le réglage général — sinon ce ne serait pas un choix.
  ({String? chemin, bool detouree}) imageDeCase({required bool entieresParDefaut}) {
    final veutEntier = switch (cadrage) {
      'entier' => true,
      'decoupe' => false,
      _ => entieresParDefaut,
    };
    if (!veutEntier && decoupe != null) return (chemin: decoupe, detouree: true);
    // Le repli n'est pas symétrique : sans découpe on montre la photo entière,
    // alors que sans photo entière il n'y a rien à montrer du tout.
    return (chemin: vignette ?? decoupe, detouree: vignette == null && decoupe != null);
  }
}

class DetailCase extends CaseDex {
  DetailCase.depuisJson(super.j)
      : alias = List<String>.from(j['alias'] ?? const []),
        captures = (j['captures'] as List? ?? const [])
            .map((c) => Capture.depuisJson(c))
            .toList(),
        chezLesAmis = (j['chez_les_amis'] as List? ?? const [])
            .map((c) => PhotoAmi.depuisJson(c))
            .toList(),
        super.depuisJson();

  /// Tous les noms latins qui retombent sur cette case : sous-espèces et
  /// synonymes. C'est ce qui explique qu'un zébu et une vache partagent la case.
  final List<String> alias;
  final List<Capture> captures;

  /// Les photos que des amis ont prises de la même espèce.
  final List<PhotoAmi> chezLesAmis;
}

class Capture {
  Capture.depuisJson(Map<String, dynamic> j)
      : id = j['id'],
        etat = j['etat'] ?? 'attente',
        verdict = j['verdict'] ?? '',
        latin = j['latin'] ?? '',
        niveau = j['niveau'] ?? '',
        confiance = (j['confiance'] ?? 0).toDouble(),
        note = j['note'] ?? '',
        duree = (j['duree'] ?? 0).toDouble(),
        caseId = j['case_id'],
        creeLe = j['cree_le'] ?? '',
        photo = j['photo'] ?? '',
        vignette = j['vignette'] ?? '',
        decoupe = j['decoupe'],
        titre = j['titre'] ?? '',
        corrigee = j['corrigee'] ?? false,
        lat = (j['lat'] as num?)?.toDouble(),
        lon = (j['lon'] as num?)?.toDouble(),
        priseLe = j['prise_le'],
        lieu = j['lieu'] ?? '',
        sourcePosition = j['source_position'] ?? '',
        sourceHeure = j['source_heure'] ?? '',
        regne = j['regne'] ?? 'animal',
        moteur = j['moteur'] ?? '',
        participants = (j['participants'] as List? ?? const [])
            .map((x) => Personne.depuisJson(x))
            .toList(),
        top = (j['top'] as List? ?? const [])
            .map((t) => Proposition.depuisJson(t))
            .toList();

  final int id;

  /// attente, analyse, ok, doute, rejet ou erreur.
  final String etat;
  final String verdict;
  final String latin;
  final String niveau;
  final double confiance;
  final String note;
  final double duree;
  final int? caseId;
  final String creeLe;
  final String photo;
  final String vignette;
  final String? decoupe;

  /// Nom libre donné par le joueur : l'espèce dit ce qu'on a vu, le titre dit
  /// ce qu'on a vécu.
  String titre;

  /// Vrai si le joueur a lui-même désigné l'espèce, le moteur s'étant trompé.
  final bool corrigee;

  final double? lat;
  final double? lon;

  /// L'heure de prise de vue lue dans l'EXIF, si la photo en portait une.
  final String? priseLe;
  final String lieu;

  /// D'où viennent l'heure et la position : « exif », « appareil », « manuel »,
  /// ou vide quand on n'en sait rien. C'est ce qui distingue une date réelle
  /// d'une date par défaut.
  final String sourcePosition;
  final String sourceHeure;

  /// Ce que le joueur a déclaré photographier, et qui a tranché.
  final String regne;
  final String moteur;

  bool get situee => lat != null && lon != null;

  /// Vrai quand la date ou le lieu ne sont qu'une supposition.
  ///
  /// Quatre origines possibles : `exif` (écrite par l'appareil), `manuel` (le
  /// joueur l'a posée), `appareil` (photo prise à l'instant, donc « ici » et
  /// « maintenant » sont justes) et `defaut` (photo tirée de la galerie à
  /// laquelle on a collé le contexte de l'envoi — le seul cas douteux, avec
  /// l'absence pure et simple).
  bool get metadonneesIncertaines =>
      const {'', 'defaut'}.contains(sourceHeure) ||
      const {'', 'defaut'}.contains(sourcePosition);

  /// Les amis identifiés sur la photo, en plus de son auteur.
  ///
  /// La case et les points leur reviennent comme s'ils l'avaient prise :
  /// deux personnes qui marchent ensemble voient le même renard, et rien ne
  /// justifiait qu'elles le photographient chacune de son côté.
  final List<Personne> participants;

  final List<Proposition> top;

  bool get enCours => etat == 'attente' || etat == 'analyse';
  bool get reussie => etat == 'ok';
}

/// Une sortie : les photos qu'un groupe de gens a partagées le même jour.
///
/// Le fil listait les photos une par une. Avec cent amis à trois photos par
/// jour, il fallait faire défiler trois cents cartes pour arriver à celle de
/// la veille. Le regroupement ne change rien au comptage — chaque photo garde
/// ses réactions — il rend seulement l'écran parcourable.
class SortieFil {
  SortieFil.depuisJson(Map<String, dynamic> j)
      : cle = j['cle'] ?? '',
        jour = j['jour'] ?? '',
        quand = j['quand'] ?? '',
        gens = (j['gens'] as List? ?? const [])
            .map((g) => SignataireFil.depuisJson(g))
            .toList(),
        inconnus = j['inconnus'] ?? 0,
        nbPhotos = j['nb_photos'] ?? 0,
        rarete = j['rarete'] ?? 0,
        reactions = j['reactions'] ?? 0,
        especes = List<String>.from(j['especes'] ?? const []),
        photos = (j['photos'] as List? ?? const [])
            .map((p) => PhotoFil.depuisJson(p))
            .toList();

  /// Identifiant stable du groupe : la journée et les signataires. Sert à
  /// retrouver une carte dépliée après un rafraîchissement.
  final String cle;
  final String jour;
  final String quand;

  /// Les signataires que je connais — mes amis, et moi. Les autres sont
  /// comptés dans `inconnus` sans être nommés.
  final List<SignataireFil> gens;
  final int inconnus;

  final int nbPhotos;
  final int rarete;

  /// Le total des réactions de la sortie, pour donner une idée sans déplier.
  final int reactions;

  /// Les espèces distinctes, dans l'ordre où elles apparaissent.
  final List<String> especes;
  final List<PhotoFil> photos;

  /// Qui a partagé, en toutes lettres.
  ///
  /// « Paul et toi », « Paul avec 3 autres personnes ». On ne nomme que ceux
  /// qu'on connaît : livrer le pseudo d'un inconnu parce qu'il figure sur la
  /// photo d'un ami serait une indiscrétion.
  String get titre {
    final noms = [for (final g in gens) g.moi ? 'toi' : g.pseudo];
    final buf = StringBuffer();
    if (noms.isEmpty) {
      buf.write('$inconnus personne${inconnus > 1 ? 's' : ''}');
    } else if (noms.length == 1) {
      buf.write(noms.first);
    } else {
      buf..write(noms.sublist(0, noms.length - 1).join(', '))
         ..write(' et ')
         ..write(noms.last);
    }
    if (noms.isNotEmpty && inconnus > 0) {
      buf.write(' avec $inconnus autre${inconnus > 1 ? 's' : ''}');
    }
    return buf.toString();
  }

  /// Ce qu'on a vu, en une ligne : deux noms puis un compte.
  String get resume {
    if (especes.isEmpty) return '';
    if (especes.length <= 2) return especes.join(', ');
    final reste = especes.length - 2;
    return T('{0} et {1} autre{2}', [especes.take(2).join(', '), reste, reste > 1 ? 's' : '']);
  }
}

class SignataireFil {
  SignataireFil.depuisJson(Map<String, dynamic> j)
      : id = j['id'] ?? 0,
        pseudo = j['pseudo'] ?? '',
        avatar = j['avatar'],
        auteur = j['auteur'] ?? false,
        moi = j['moi'] ?? false;

  final int id;
  final String pseudo;
  final String? avatar;

  /// Vrai pour celui qui a pris la photo — les autres y ont été identifiés.
  final bool auteur;

  /// Vrai quand c'est le joueur qui regarde : on écrit « toi », pas son pseudo.
  final bool moi;
}

class PhotoFil {
  PhotoFil.depuisJson(Map<String, dynamic> j)
      : captureId = j['capture_id'],
        utilisateur = j['utilisateur'] ?? 0,
        pseudo = j['pseudo'] ?? '',
        caseId = j['case_id'],
        nom = j['nom'] ?? '',
        latin = j['latin'] ?? '',
        rarete = j['rarete'] ?? 0,
        titre = j['titre'] ?? '',
        lieu = j['lieu'] ?? '',
        quand = j['quand'] ?? '',
        vignette = j['vignette'] ?? '',
        decoupe = j['decoupe'],
        reactions = ResumeReactions.depuisJson(j['reactions'] ?? const {});

  final int captureId;
  final int utilisateur;
  final String pseudo;
  final int? caseId;
  final String nom;
  final String latin;
  final int rarete;
  final String titre;
  final String lieu;
  final String quand;
  final String vignette;
  final String? decoupe;

  /// Les réactions restent attachées à la photo, pas à la sortie : c'est ce
  /// qui permet d'applaudir LA belle photo plutôt que le lot.
  ResumeReactions reactions;
}

/// Un joueur, réduit à ce qu'il faut pour l'afficher dans une liste.
///
/// Le serveur renvoie ce même triplet sous une dizaine de formes — auteur
/// d'une photo, ami, participant, membre d'un classement. Les modéliser
/// séparément revenait à écrire dix fois le même `depuisJson`.
class Personne {
  Personne.depuisJson(Map<String, dynamic> j)
      : id = j['id'] ?? 0,
        pseudo = j['pseudo'] ?? '',
        avatar = j['avatar'];

  final int id;
  final String pseudo;
  final String? avatar;
}

class Proposition {
  Proposition.depuisJson(Map<String, dynamic> j)
      : latin = j['latin'] ?? '',
        nomFr = j['nom_fr'],
        proba = (j['proba'] ?? 0).toDouble(),
        caseId = j['case_id'],
        visuel = j['visuel'],
        image = j['image'],
        rarete = j['rarete'] ?? 0,
        points = j['points'] ?? 0,
        regne = j['regne'] ?? 'animal',
        toxique = j['toxique'] ?? false,
        resume = j['resume'] ?? '';

  final String latin;
  final String? nomFr;
  final double proba;

  /// La case correspondante : une piste se choisit d'un appui, sans repasser
  /// par la recherche.
  final int? caseId;

  /// La silhouette de la case, servie par le serveur.
  final String? visuel;

  /// L'illustration Wikipédia, en URL directe.
  final String? image;

  final int rarete;
  final int points;
  final String regne;

  /// Signalée toxique. Ne vaut que dans un sens : l'absence de marque ne dit
  /// rien, beaucoup d'espèces mortelles ne sont pas listées.
  final bool toxique;

  /// Le début de l'article Wikipédia, quand le serveur l'a en cache.
  final String resume;

  String get nom => nomFr ?? latin;
}

class Joueur {
  Joueur.depuisJson(Map<String, dynamic> j)
      : id = j['id'],
        pseudo = j['pseudo'] ?? '',
        avatar = j['avatar'],
        bio = j['bio'] ?? '',
        cases = j['cases'] ?? 0,
        captures = j['captures'] ?? 0,
        amis = j['amis'] ?? 0,
        demandes = j['demandes'] ?? 0,
        relation = j['relation'] ?? '',
        demandeId = j['demande_id'],
        plantnetActive = (j['plantnet'] ?? const {})['active'] ?? false,
        plantnetApercu = (j['plantnet'] ?? const {})['apercu'] ?? '';

  final int id;
  final String pseudo;
  final String? avatar;
  final String bio;
  final int cases;
  final int captures;
  final int amis;
  final int demandes;

  /// aucune, envoyee, recue, amis, bloquee ou moi.
  final String relation;
  final int? demandeId;

  /// La clé Pl@ntNet ne redescend jamais en clair : le serveur dit seulement
  /// s'il en a une et en montre les quatre derniers caractères, de quoi
  /// reconnaître celle qu'on a saisie.
  final bool plantnetActive;
  final String plantnetApercu;
}

class ResumeDex {
  ResumeDex.depuisJson(Map<String, dynamic> j)
      : total = j['total'] ?? 0,
        trouve = j['trouve'] ?? 0,
        points = j['points'] ?? 0,
        pointsDecouvertes = j['points_decouvertes'] ?? 0,
        pointsReactions = j['points_reactions'] ?? 0,
        palier = Palier.depuisJson(j['palier'] ?? const {}),
        regnes = (j['regnes'] as List? ?? const [])
            .map((c) => GroupeDex.depuisJson(c))
            .toList(),
        classes = (j['classes'] as List? ?? const [])
            .map((c) => GroupeDex.depuisJson(c))
            .toList();

  final int total;
  final int trouve;
  /// Le total, découvertes et applaudissements confondus.
  final int points;

  /// Ce que rapportent les espèces trouvées.
  final int pointsDecouvertes;

  /// Ce que rapportent les réactions des amis sur ses photos. Ces points-là
  /// ne font pas monter en rang : le rang se gagne en espèces.
  final int pointsReactions;

  /// Le rang atteint, qui remplace le rapport au total : personne ne remplira
  /// 977 000 cases, et l'afficher ne fait que décourager.
  final Palier palier;

  /// La progression par règne, pour les trois entrées du dex.
  final List<GroupeDex> regnes;
  final List<GroupeDex> classes;
}

/// Un jalon de collection : le rang courant et celui qu'on vise.
class Palier {
  Palier.depuisJson(Map<String, dynamic> j)
      : numero = j['numero'] ?? 0,
        nom = j['nom'] ?? 'Sans rang',
        depuis = j['depuis'] ?? 0,
        badge = j['badge'] ?? '/badges/00.svg',
        badgeSuivant = j['badge_suivant'],
        total = j['total_paliers'] ?? 50,
        suivant = j['suivant'],
        objectif = j['objectif'],
        reste = j['reste'];

  /// De 1 à 50. Zéro tant qu'aucune espèce n'a été trouvée.
  final int numero;
  final String nom;
  final int depuis;

  /// L'écusson du rang, servi par le serveur.
  final String badge;
  final String? badgeSuivant;
  final int total;

  /// Null quand le dernier palier est atteint.
  final String? suivant;
  final int? objectif;
  final int? reste;

  /// Part parcourue entre le palier courant et le suivant.
  double part(int trouve) {
    final cible = objectif;
    if (cible == null || cible <= depuis) return 1;
    return ((trouve - depuis) / (cible - depuis)).clamp(0.0, 1.0);
  }
}

class GroupeDex {
  GroupeDex.depuisJson(Map<String, dynamic> j)
      : classe = j['classe'] ?? '',
        total = j['total'] ?? 0,
        trouve = j['trouve'] ?? 0;

  final String classe;
  final int total;
  final int trouve;
}

/// Les cinq réactions possibles sur une photo, et ce qu'elles rapportent.
class Reaction {
  const Reaction(this.valeur, this.emoji, this.nom, this.points);
  final int valeur;
  final String emoji;
  final String nom;
  final int points;
}

/// Fixé côté application autant que côté serveur : l'app doit pouvoir dessiner
/// la barre de réactions sans attendre une requête.
const reactionsPossibles = <Reaction>[
  Reaction(0, '😐', 'Bof', 0),
  Reaction(1, '🙂', 'Sympa', 3),
  Reaction(2, '😮', 'Beau', 6),
  Reaction(3, '🤩', 'Superbe', 9),
  Reaction(4, '🏆', 'Incroyable', 12),
];

/// Ce que les amis ont mis sur une photo.
class ResumeReactions {
  ResumeReactions.depuisJson(Map<String, dynamic> j)
      : total = j['total'] ?? 0,
        points = j['points'] ?? 0,
        maReaction = j['ma_reaction'],
        // Les clés arrivent en texte depuis le JSON : « {"4": 2} ».
        compte = ((j['compte'] ?? const {}) as Map).map(
            (k, v) => MapEntry(int.tryParse(k.toString()) ?? 0, v as int));

  final int total;
  final int points;

  /// La réaction que j'ai posée, ou null si je n'ai pas réagi.
  final int? maReaction;
  final Map<int, int> compte;

  /// Les emojis les plus posés, pour tenir dans une pastille de vignette.
  String emojisEnTete(int combien) {
    final tries = compte.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return tries
        .take(combien)
        .map((e) => reactionsPossibles
            .firstWhere((r) => r.valeur == e.key,
                orElse: () => reactionsPossibles.first)
            .emoji)
        .join();
  }

  /// Le chemin inverse, pour retraduire une photo d'un modèle vers l'autre.
  Map<String, dynamic> versJson() => {
        'total': total,
        'points': points,
        'ma_reaction': maReaction,
        'compte': compte.map((k, v) => MapEntry(k.toString(), v)),
      };
}

/// Résumé encyclopédique d'une espèce.
class FicheEspece {
  FicheEspece.depuisJson(Map<String, dynamic> j)
      : trouvee = j['trouvee'] ?? false,
        titre = j['titre'] ?? '',
        resume = j['resume'] ?? '',
        url = j['url'] ?? '',
        image = j['image'] ?? '',
        langue = j['langue'] ?? 'fr',
        approximation = j['approximation'] ?? '';

  final bool trouvee;

  /// Vide quand l'article porte sur l'espèce ; « genre » quand on a dû se
  /// rabattre sur le taxon supérieur, faute d'article dédié.
  final String approximation;
  final String titre;
  final String resume;
  final String url;
  final String image;
  final String langue;
}

/// Une capture posée sur la carte.
class PointCarte {
  PointCarte.depuisJson(Map<String, dynamic> j)
      : captureId = j['capture_id'],
        lat = (j['lat'] ?? 0).toDouble(),
        lon = (j['lon'] ?? 0).toDouble(),
        utilisateur = j['utilisateur'] ?? 0,
        pseudo = j['pseudo'] ?? '',
        avatar = j['avatar'],
        moi = j['moi'] ?? false,
        caseId = j['case_id'],
        nom = j['nom'] ?? '',
        latin = j['latin'] ?? '',
        rarete = j['rarete'] ?? 3,
        quand = j['quand'] ?? '',
        heureSure = j['heure_sure'] ?? false,
        lieu = j['lieu'] ?? '',
        positionManuelle = j['position_manuelle'] ?? false,
        titre = j['titre'] ?? '',
        vignette = j['vignette'] ?? '',
        decoupe = j['decoupe'];

  final int captureId;
  final double lat;
  final double lon;
  final int utilisateur;
  final String pseudo;

  /// Photo de profil de l'auteur, pour le médaillon du marqueur.
  final String? avatar;

  /// Vrai si c'est une de mes photos : la carte les distingue de celles des amis.
  final bool moi;
  final int? caseId;
  final String nom;
  final String latin;
  final int rarete;

  /// Heure de prise de vue si on la connaît, sinon celle de l'envoi.
  final String quand;
  final bool heureSure;
  final String lieu;
  final bool positionManuelle;

  /// Nom libre donné par le joueur.
  final String titre;
  final String vignette;
  final String? decoupe;
}

/// Une de mes captures qu'on ne peut pas situer : sans coordonnées, ou sans
/// heure fiable.
class CaptureOrpheline {
  CaptureOrpheline.depuisJson(Map<String, dynamic> j)
      : captureId = j['capture_id'],
        nom = j['nom'] ?? '',
        creeLe = j['cree_le'] ?? '',
        priseLe = j['prise_le'],
        lat = (j['lat'] as num?)?.toDouble(),
        lon = (j['lon'] as num?)?.toDouble(),
        sansPosition = j['sans_position'] ?? false,
        sansHeure = j['sans_heure'] ?? false,
        vignette = j['vignette'] ?? '',
        decoupe = j['decoupe'];

  final int captureId;
  final String nom;
  final String creeLe;
  final String? priseLe;
  final double? lat;
  final double? lon;
  final bool sansPosition;
  final bool sansHeure;
  final String vignette;
  final String? decoupe;
}

/// Un lieu proposé par la recherche d'adresse.
class LieuTrouve {
  LieuTrouve.depuisJson(Map<String, dynamic> j)
      : nom = j['nom'] ?? '',
        lat = (j['lat'] ?? 0).toDouble(),
        lon = (j['lon'] ?? 0).toDouble();

  final String nom;
  final double lat;
  final double lon;
}

/// Une ligne du classement entre amis.
class LigneClassement {
  LigneClassement.depuisJson(Map<String, dynamic> j)
      : rang = j['rang'] ?? 0,
        id = j['id'] ?? 0,
        pointsReactions = j['points_reactions'] ?? 0,
        pseudo = j['pseudo'] ?? '',
        avatar = j['avatar'],
        moi = j['moi'] ?? false,
        points = j['points'] ?? 0,
        cases = j['cases'] ?? 0,
        belles = j['belles'] ?? 0,
        legendaires = j['legendaires'] ?? 0,
        palier = Palier.depuisJson(j['palier'] ?? const {});

  final int rang;

  /// Le rang de collection du joueur : « Fouineur » se compare mieux qu'un
  /// total de points.
  final Palier palier;
  final int id;
  final String pseudo;
  final String? avatar;
  final bool moi;
  final int points;

  /// Part des points venue des réactions des amis sur ses photos.
  final int pointsReactions;
  final int cases;

  /// Cases de qualité rare ou légendaire.
  final int belles;
  final int legendaires;
}

/// Une belle prise du cercle d'amis.
class Trouvaille {
  Trouvaille.depuisJson(Map<String, dynamic> j)
      : caseId = j['case_id'] ?? 0,
        nom = j['nom'] ?? '',
        latin = j['latin'] ?? '',
        qualite = j['qualite'] ?? 3,
        points = j['points'] ?? 0,
        pseudo = j['pseudo'] ?? '',
        moi = j['moi'] ?? false,
        trouveLe = j['trouve_le'] ?? '',
        vignette = j['vignette'],
        decoupe = j['decoupe'];

  final int caseId;
  final String nom;
  final String latin;
  final int qualite;
  final int points;
  final String pseudo;
  final bool moi;
  final String trouveLe;
  final String? vignette;
  final String? decoupe;
}

/// Mon total de points et sa décomposition par qualité.
class MesPoints {
  MesPoints.depuisJson(Map<String, dynamic> j)
      : total = j['total'] ?? 0,
        cases = j['cases'] ?? 0,
        pointsReactions = j['points_reactions'] ?? 0,
        rang = j['rang'] ?? 1,
        sur = j['sur'] ?? 1,
        parQualite = (j['par_qualite'] as List? ?? const [])
            .map((q) => LigneQualite.depuisJson(q))
            .toList();

  final int total;
  final int cases;
  final int rang;
  final int sur;
  final int pointsReactions;
  final List<LigneQualite> parQualite;
}

class LigneQualite {
  LigneQualite.depuisJson(Map<String, dynamic> j)
      : qualite = j['qualite'] ?? 3,
        nom = j['nom'] ?? '',
        cases = j['cases'] ?? 0,
        points = j['points'] ?? 0;

  final int qualite;
  final String nom;
  final int cases;
  final int points;
}

/// Une photo dans la galerie.
class PhotoGalerie {
  PhotoGalerie.depuisJson(Map<String, dynamic> j)
      : captureId = j['capture_id'],
        utilisateur = j['utilisateur'] ?? 0,
        pseudo = j['pseudo'] ?? '',
        avatar = j['avatar'],
        moi = j['moi'] ?? false,
        etat = j['etat'] ?? '',
        caseId = j['case_id'],
        nom = j['nom'] ?? '',
        latin = j['latin'] ?? '',
        qualite = j['qualite'] ?? 0,
        quand = j['quand'] ?? '',
        heureSure = j['heure_sure'] ?? false,
        sansPosition = j['sans_position'] ?? false,
        sansHeure = j['sans_heure'] ?? false,
        lat = (j['lat'] as num?)?.toDouble(),
        lon = (j['lon'] as num?)?.toDouble(),
        lieu = j['lieu'] ?? '',
        corrigee = j['corrigee'] ?? false,
        titre = j['titre'] ?? '',
        favori = j['favori'] ?? false,
        photo = j['photo'] ?? '',
        vignette = j['vignette'] ?? '',
        decoupe = j['decoupe'],
        reactions = ResumeReactions.depuisJson(j['reactions'] ?? const {});

  final int captureId;
  final int utilisateur;
  final String pseudo;
  final String? avatar;
  final bool moi;
  final String etat;
  final int? caseId;
  final String nom;
  final String latin;
  final int qualite;
  final String quand;
  final bool heureSure;

  /// La photo n'a pas de position, ou n'en a qu'une posée par défaut.
  ///
  /// Le second cas est le plus traître : elle **a** des coordonnées, donc elle
  /// s'affiche sur la carte — au mauvais endroit. Le serveur tranche pour nous,
  /// avec la même règle que la carte : impossible qu'un écran en signale
  /// dix-huit et l'autre cinq.
  final bool sansPosition;

  /// Idem pour la date : absente, ou devinée au moment de l'envoi.
  final bool sansHeure;

  /// Vrai dès que l'une des deux manque.
  bool get aSituer => sansPosition || sansHeure;

  final double? lat;
  final double? lon;
  final String lieu;
  final bool corrigee;

  /// Nom libre donné par le joueur.
  String titre;
  bool favori;
  final String photo;
  final String vignette;
  final String? decoupe;
  ResumeReactions reactions;

  bool get situee => lat != null && lon != null;
}

/// De quoi remplir les menus de filtres de la galerie.
class ReperesGalerie {
  ReperesGalerie.depuisJson(Map<String, dynamic> j)
      : auteurs = (j['auteurs'] as List? ?? const [])
            .map((a) => AuteurGalerie.depuisJson(a))
            .toList(),
        lieux = (j['lieux'] as List? ?? const [])
            .map((l) => (l['lieu'] ?? '').toString())
            .toList(),
        especes = (j['especes'] as List? ?? const [])
            .map((e) => EspeceGalerie.depuisJson(e))
            .toList(),
        debut = j['debut'],
        fin = j['fin'],
        total = j['total'] ?? 0,
        situees = j['situees'] ?? 0,
        favoris = j['favoris'] ?? 0;

  final List<AuteurGalerie> auteurs;
  final List<String> lieux;
  final List<EspeceGalerie> especes;
  final String? debut;
  final String? fin;
  final int total;
  final int situees;
  final int favoris;
}

class AuteurGalerie {
  AuteurGalerie.depuisJson(Map<String, dynamic> j)
      : id = j['id'] ?? 0,
        pseudo = j['pseudo'] ?? '',
        avatar = j['avatar'],
        photos = j['photos'] ?? 0,
        moi = j['moi'] ?? false;

  final int id;
  final String pseudo;
  final String? avatar;
  final int photos;
  final bool moi;
}

class EspeceGalerie {
  EspeceGalerie.depuisJson(Map<String, dynamic> j)
      : caseId = j['case_id'] ?? 0,
        nom = j['nom'] ?? '',
        qualite = j['qualite'] ?? 0,
        photos = j['photos'] ?? 0;

  final int caseId;
  final String nom;
  final int qualite;
  final int photos;
}

/// La fiche détaillée d'un joueur, dans le classement.
class DetailJoueur {
  DetailJoueur.depuisJson(Map<String, dynamic> j)
      : id = j['id'] ?? 0,
        pseudo = j['pseudo'] ?? '',
        pointsReactions = j['points_reactions'] ?? 0,
        avatar = j['avatar'],
        moi = j['moi'] ?? false,
        depuis = j['depuis'] ?? '',
        photos = j['photos'] ?? 0,
        total = j['total'] ?? 0,
        cases = j['cases'] ?? 0,
        pointsEspeces = j['points_especes'] ?? 0,
        parQualite = (j['par_qualite'] as List? ?? const [])
            .map((q) => LigneQualite.depuisJson(q))
            .toList(),
        meilleures = (j['meilleures'] as List? ?? const [])
            .map((t) => Trouvaille.depuisJson(t))
            .toList();

  final int id;
  final String pseudo;
  final String? avatar;
  final bool moi;
  final String depuis;
  final int photos;
  final int total;
  final int cases;
  final int pointsEspeces;
  final int pointsReactions;
  final List<LigneQualite> parQualite;
  final List<Trouvaille> meilleures;
}

/// Une notification reçue. Le nom porte « Recue » parce que Flutter a déjà
/// une classe `Notification`, qui n'a rien à voir.
class NotificationRecue {
  NotificationRecue.depuisJson(Map<String, dynamic> j)
      : id = j['id'] ?? 0,
        type = j['type'] ?? '',
        joursRestants = j['jours_restants'],
        // Le nombre de trouvailles réunies sous une seule notification : le
        // serveur ne crée pas une ligne par photo, il fait grossir celle-ci
        // tant qu'elle n'est pas lue.
        nbTrouvailles = j['nb_trouvailles'] ?? 1,
        lu = j['lu'] ?? false,
        creeLe = j['cree_le'] ?? '',
        // Absente pour beaucoup de types — une demande d'ami n'a pas de date
        // de prise de vue — d'où le fait de la garder distincte de `creeLe`
        // plutôt que d'y replier ici : c'est à l'affichage de choisir.
        prisePle = j['prise_le'],
        auteur = j['auteur'] ?? 0,
        pseudo = j['pseudo'] ?? '',
        avatar = j['avatar'],
        captureId = j['capture_id'],
        caseId = j['case_id'],
        titre = j['titre'] ?? '',
        espece = j['espece'] ?? '',
        qualite = j['qualite'] ?? 0,
        emoji = j['emoji'] ?? '',
        reaction = j['reaction'] ?? '',
        points = j['points'] ?? 0,
        vignette = j['vignette'],
        decoupe = j['decoupe'];

  final int id;
  final String type;
  final int nbTrouvailles;

  /// Pour une alerte de purge : le nombre de jours avant l'effacement, ou -1
  /// quand les photos concernées n'ont pas toutes le même délai. Nul pour les
  /// autres types.
  final int? joursRestants;
  final bool lu;
  final String creeLe;
  final String? prisePle;
  final int auteur;
  final String pseudo;
  final String? avatar;
  final int? captureId;
  final int? caseId;
  final String titre;
  final String espece;
  final int qualite;
  final String emoji;
  final String reaction;
  final int points;
  final String? vignette;
  final String? decoupe;
}

/// Une photo d'ami sur la même espèce que soi.
class PhotoAmi {
  PhotoAmi.depuisJson(Map<String, dynamic> j)
      : id = j['id'],
        creeLe = j['cree_le'] ?? '',
        titre = j['titre'] ?? '',
        utilisateur = j['utilisateur'] ?? 0,
        pseudo = j['pseudo'] ?? '',
        avatar = j['avatar'],
        vignette = j['vignette'] ?? '',
        photo = j['photo'] ?? '',
        decoupe = j['decoupe'],
        quand = j['quand'] ?? j['cree_le'] ?? '',
        heureSure = j['heure_sure'] ?? false,
        lat = (j['lat'] as num?)?.toDouble(),
        lon = (j['lon'] as num?)?.toDouble(),
        lieu = j['lieu'] ?? '',
        favori = j['favori'] ?? false,
        reactions = ResumeReactions.depuisJson(j['reactions'] ?? const {});

  final int id;
  final String creeLe;
  final String titre;
  final int utilisateur;
  final String pseudo;
  final String? avatar;
  final String vignette;
  final String photo;
  final String? decoupe;
  final String quand;
  final bool heureSure;
  final double? lat;
  final double? lon;
  final String lieu;
  final bool favori;
  ResumeReactions reactions;

  /// La même photo, vue par la visionneuse plein écran.
  ///
  /// Celle-ci sait déjà tout faire — zoomer, réagir, mettre en favori — et n'a
  /// pas à savoir d'où vient la photo. Plutôt que d'en écrire une deuxième pour
  /// les photos d'amis, on traduit.
  PhotoGalerie versGalerie({required String espece, int? caseId, int qualite = 0}) {
    return PhotoGalerie.depuisJson({
      'capture_id': id, 'utilisateur': utilisateur, 'pseudo': pseudo,
      'avatar': avatar, 'moi': false, 'etat': 'identifiee',
      'case_id': caseId, 'nom': espece, 'qualite': qualite,
      'quand': quand, 'heure_sure': heureSure,
      'lat': lat, 'lon': lon, 'lieu': lieu,
      'titre': titre, 'favori': favori,
      'photo': photo, 'vignette': vignette, 'decoupe': decoupe,
      'reactions': reactions.versJson(),
    });
  }
}

/// Un niveau de l'arbre du vivant : un groupe et l'avancement dedans.
class NoeudArbre {
  NoeudArbre.depuisJson(Map<String, dynamic> j)
      : nom = j['nom'] ?? '',
        total = j['total'] ?? 0,
        trouve = j['trouve'] ?? 0;

  final String nom;
  final int total;
  final int trouve;
}

class NiveauArbre {
  NiveauArbre.depuisJson(Map<String, dynamic> j)
      : niveau = j['niveau'] ?? 'classe',
        enfant = j['enfant'],
        classe = j['classe'],
        ordre = j['ordre'],
        noeuds = (j['noeuds'] as List? ?? const [])
            .map((n) => NoeudArbre.depuisJson(n))
            .toList();

  /// classe, ordre ou famille.
  final String niveau;

  /// Le niveau qu'on ouvrira en tapant sur un nœud ; null si on est au bout.
  final String? enfant;
  final String? classe;
  final String? ordre;
  final List<NoeudArbre> noeuds;
}

/// Noms français des grands groupes, pour la navigation. Ceux qui manquent
/// s'affichent avec leur nom latin, qui reste juste, seulement moins parlant.
const nomsClasses = <String, String>{
  'Insecta': 'Insectes',
  'Aves': 'Oiseaux',
  'Mammalia': 'Mammifères',
  'Amphibia': 'Amphibiens',
  'Squamata': 'Lézards et serpents',
  'Actinopterygii': 'Poissons',
  'Actinopteri': 'Poissons',
  'Chondrichthyes': 'Requins et raies',
  'Arachnida': 'Araignées',
  'Gastropoda': 'Escargots',
  'Bivalvia': 'Coquillages',
  'Malacostraca': 'Crustacés',
  'Chilopoda': 'Mille-pattes',
  'Diplopoda': 'Mille-pattes',
  'Clitellata': 'Vers',
  'Polychaeta': 'Vers marins',
  'Anthozoa': 'Coraux et anémones',
  'Scyphozoa': 'Méduses',
  'Hydrozoa': 'Hydres',
  'Asteroidea': 'Étoiles de mer',
  'Echinoidea': 'Oursins',
  'Testudines': 'Tortues',
  'Reptilia': 'Reptiles',
  'Collembola': 'Collemboles',
  'Ostracoda': 'Ostracodes',
  'Maxillopoda': 'Copépodes',
  'Branchiopoda': 'Branchiopodes',
};

/// Ordres et familles courants. La liste n'a pas vocation à être exhaustive —
/// il y a des milliers de familles — mais à couvrir ce qu'on croise vraiment.
/// Le nom latin s'affiche pour le reste.
const nomsTaxons = <String, String>{
  // ordres de mammifères
  'Artiodactyla': 'Ongulés',
  'Carnivora': 'Carnivores',
  'Rodentia': 'Rongeurs',
  'Chiroptera': 'Chauves-souris',
  'Primates': 'Primates',
  'Lagomorpha': 'Lapins et lièvres',
  'Cetacea': 'Baleines et dauphins',
  'Soricomorpha': 'Musaraignes',
  'Eulipotyphla': 'Insectivores',
  'Perissodactyla': 'Chevaux et rhinocéros',
  'Diprotodontia': 'Marsupiaux',
  'Proboscidea': 'Éléphants',
  // ordres d'oiseaux
  'Passeriformes': 'Passereaux',
  'Anseriformes': 'Canards et oies',
  'Accipitriformes': 'Rapaces',
  'Falconiformes': 'Faucons',
  'Strigiformes': 'Chouettes et hiboux',
  'Charadriiformes': 'Limicoles et mouettes',
  'Pelecaniformes': 'Hérons et pélicans',
  'Columbiformes': 'Pigeons',
  'Galliformes': 'Gallinacés',
  'Piciformes': 'Pics',
  'Apodiformes': 'Martinets et colibris',
  'Ciconiiformes': 'Cigognes',
  'Gruiformes': 'Grues et râles',
  // ordres d'insectes et autres
  'Lepidoptera': 'Papillons',
  'Coleoptera': 'Coléoptères',
  'Hymenoptera': 'Abeilles, guêpes et fourmis',
  'Diptera': 'Mouches et moustiques',
  'Odonata': 'Libellules',
  'Orthoptera': 'Sauterelles et criquets',
  'Hemiptera': 'Punaises',
  'Araneae': 'Araignées',
  'Decapoda': 'Crabes et crevettes',
  // ordres d'amphibiens et reptiles
  'Anura': 'Grenouilles et crapauds',
  'Caudata': 'Tritons et salamandres',
  'Testudines': 'Tortues',
  'Serpentes': 'Serpents',
  'Crocodylia': 'Crocodiles',
  // familles fréquentes
  'Cervidae': 'Cervidés',
  'Bovidae': 'Bovidés',
  'Felidae': 'Félins',
  'Canidae': 'Canidés',
  'Ursidae': 'Ours',
  'Mustelidae': 'Mustélidés',
  'Sciuridae': 'Écureuils',
  'Muridae': 'Souris et rats',
  'Suidae': 'Sangliers et porcs',
  'Equidae': 'Chevaux',
  'Leporidae': 'Lapins et lièvres',
  'Paridae': 'Mésanges',
  'Corvidae': 'Corvidés',
  'Anatidae': 'Canards',
  'Turdidae': 'Grives et merles',
  'Fringillidae': 'Fringilles',
  'Laridae': 'Mouettes et goélands',
  'Ardeidae': 'Hérons',
  'Accipitridae': 'Aigles et buses',
  'Strigidae': 'Chouettes',
  'Picidae': 'Pics',
  'Hirundinidae': 'Hirondelles',
  'Lacertidae': 'Lézards',
  'Colubridae': 'Couleuvres',
  'Viperidae': 'Vipères',
  'Ranidae': 'Grenouilles vraies',
  'Bufonidae': 'Crapauds',
  'Salamandridae': 'Salamandres et tritons',
  'Coccinellidae': 'Coccinelles',
  'Apidae': 'Abeilles',
  'Formicidae': 'Fourmis',
  'Nymphalidae': 'Papillons nymphalidés',
  'Pieridae': 'Piérides',
  'Papilionidae': 'Machaons',
  'Carabidae': 'Carabes',
  'Libellulidae': 'Libellules',
  'Helicidae': 'Escargots',
};

String nomDeClasse(String latin) => T(nomsClasses[latin] ?? latin);

/// Nom affichable d'un taxon, quel que soit son rang.
String nomDeTaxon(String latin) =>
    T(nomsClasses[latin] ?? nomsTaxons[latin] ?? latin);

/// Une pièce de la vitrine : une des dix meilleures trouvailles.
class PieceVitrine {
  PieceVitrine.depuisJson(Map<String, dynamic> j)
      : caseId = j['case_id'],
        nom = j['nom'] ?? '',
        latin = j['latin'] ?? '',
        qualite = j['qualite'] ?? 0,
        points = j['points'] ?? 0,
        regne = j['regne'] ?? 'animal',
        trouveLe = j['trouve_le'] ?? '',
        vignette = j['vignette'],
        decoupe = j['decoupe'];

  final int caseId;
  final String nom;
  final String latin;
  final int qualite;
  final int points;
  final String regne;
  final String trouveLe;

  /// La photo qui a valu la pièce. Les deux versions sont servies : c'est le
  /// réglage du téléphone qui décide laquelle montrer, pas le serveur.
  final String? vignette;
  final String? decoupe;

  /// Le chemin à afficher selon la préférence du joueur. On retombe sur la
  /// photo entière quand il n'y a pas de découpe — mieux vaut une photo large
  /// qu'un carré vide.
  String? photo({required bool entiere}) =>
      entiere ? (vignette ?? decoupe) : (decoupe ?? vignette);
}

/// La vitrine d'un joueur : un rang tiré de la rareté de ses prises.
///
/// À ne pas confondre avec le rang du dex, qui compte les espèces. Ici seules
/// les dix meilleures comptent : la onzième banalité n'ajoute rien, seule une
/// prise meilleure que la dixième fait monter le score.
class Vitrine {
  Vitrine.depuisJson(Map<String, dynamic> j)
      : joueur = j['joueur'] ?? 0,
        score = j['score'] ?? 0,
        taille = j['taille'] ?? 10,
        rang = Palier.depuisJson(j['rang'] ?? const {}),
        pieces = [
          for (final p in (j['pieces'] as List? ?? const []))
            PieceVitrine.depuisJson(p)
        ];

  final int joueur;
  final int score;

  /// Combien de pièces comptent. Renvoyé par le serveur pour que l'écran ne
  /// réinvente pas la règle de son côté.
  final int taille;

  final Palier rang;
  final List<PieceVitrine> pieces;
}

/// Un succès, et où j'en suis.
///
/// `comment` est nul tant que le succès n'est ni obtenu ni révélé : le serveur
/// ne l'envoie pas. Le cacher seulement à l'affichage laisserait le texte
/// lisible dans la réponse, ce qui n'est pas un secret gardé.
/// « #a1b2c3 » tel que l'envoie le serveur. Le repli sert quand un modèle n'a
/// pas encore été analysé : mieux vaut un cristal quelconque qu'une exception
/// au milieu d'une liste de trente.
Color _couleur(dynamic hexa, int repli) {
  if (hexa is! String) return Color(repli);
  final n = int.tryParse(hexa.replaceFirst('#', ''), radix: 16);
  return n == null ? Color(repli) : Color(0xFF000000 | n);
}

class Succes {
  Succes.depuisJson(Map<String, dynamic> j)
      : cle = j['cle'] ?? '',
        nom = j['nom'] ?? '',
        emoji = j['emoji'] ?? '',
        difficulte = j['difficulte'] ?? 'facile',
        modele = j['modele'] ?? 'grenouille',
        teinte = _couleur(j['couleurs']?['corps'], 0xFF7FD4FF),
        lueur = _couleur(j['couleurs']?['fissure'], 0xFFFFD27F),
        seuil = j['seuil'] ?? 1,
        obtenu = j['obtenu'] ?? false,
        obtenuLe = j['obtenu_le'],
        revele = j['revele'] ?? false,
        comment = j['comment'],
        avancement = j['avancement'],
        neuf = j['neuf'] ?? false;

  final String cle;
  final String nom;
  final String emoji;
  final String difficulte;

  /// Le nom du modèle 3D, sans extension. Tant qu'il n'existe pas, on retombe
  /// sur la grenouille de base — en silhouette noire si le succès n'est pas
  /// obtenu.
  final String modele;

  /// La matière de la gemme : la couleur du corps de la grenouille qu'elle
  /// enferme. Elle vient du serveur, qui l'a tirée des pixels du modèle — voir
  /// `outils/couleurs_succes.py`. Trois teintes selon la difficulté rendaient
  /// vingt-neuf gemmes interchangeables, et répétaient une information déjà
  /// écrite sur la tuile.
  final Color teinte;

  /// La lumière qui sort des fissures : la couleur d'accent du modèle — le
  /// chapeau, l'écharpe.
  final Color lueur;

  final int seuil;
  final bool obtenu;
  final String? obtenuLe;
  final bool revele;
  final String? comment;

  /// Nul chez un ami : voir qu'il est à 9/10 d'un succès qu'il ignore
  /// reviendrait à le lui souffler.
  final int? avancement;

  final bool neuf;

  double get part =>
      avancement == null ? (obtenu ? 1 : 0) : (avancement! / seuil).clamp(0, 1);
}

/// Le palmarès d'un joueur.
///
/// Pas `Succès` : Dart refuse les accents dans les identifiants. La leçon a
/// déjà été payée une fois sur `tracéSeul`.
class Palmares {
  Palmares.depuisJson(Map<String, dynamic> j)
      : joueur = j['joueur'] ?? 0,
        obtenus = j['obtenus'] ?? 0,
        total = j['total'] ?? 0,
        nouveaux = [for (final n in (j['nouveaux'] as List? ?? const [])) '$n'],
        liste = [
          for (final s in (j['succes'] as List? ?? const []))
            Succes.depuisJson(s)
        ];

  final int joueur;
  final int obtenus;
  final int total;
  final List<String> nouveaux;
  final List<Succes> liste;
}
