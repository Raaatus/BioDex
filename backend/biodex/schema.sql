-- Schéma Biodex.
--
-- SQLite en mode WAL : largement suffisant pour la centaine de comptes visée,
-- et surtout un seul fichier à sauvegarder ou à emporter dans le zip.
--
-- Vocabulaire :
--   « case »       une case du dex, c'est-à-dire une espèce canonique. Toutes
--                  les sous-espèces et tous les synonymes d'une même espèce
--                  retombent sur la même case (les 400 vaches → une Vache).
--   « capture »    une photo envoyée par un joueur, et son verdict.
--   « découverte » la première fois qu'un joueur remplit une case donnée.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ------------------------------------------------------------------ comptes

CREATE TABLE IF NOT EXISTS utilisateurs (
    id              INTEGER PRIMARY KEY,
    -- pseudo_norm sert à l'unicité et à la recherche (minuscules, sans accent),
    -- pseudo garde la casse choisie à l'inscription et c'est lui qu'on affiche.
    pseudo_norm     TEXT    NOT NULL UNIQUE,
    pseudo          TEXT    NOT NULL,
    mdp             TEXT    NOT NULL,          -- scrypt, format « scrypt$n$r$p$sel$empreinte »
    cree_le         TEXT    NOT NULL DEFAULT (datetime('now')),
    vu_le           TEXT,
    -- capture choisie comme photo de profil (facultatif)
    avatar_capture  INTEGER REFERENCES captures(id) ON DELETE SET NULL,
    -- Clé Pl@ntNet du joueur. Le quota gratuit est de 500 identifications par
    -- jour et par clé : la partager entre tous les joueurs l'épuiserait en une
    -- après-midi. Sans clé, les plantes passent directement par BioCLIP.
    cle_plantnet    TEXT    NOT NULL DEFAULT '',
    bio             TEXT    NOT NULL DEFAULT '',
    -- Ce que le joueur accepte d'être notifié, en JSON : {"type": true|false}.
    --
    -- Vide = les valeurs par défaut, qui sont volontairement avares. On ne
    -- prévient que de ce qui s'adresse à quelqu'un personnellement — une
    -- réaction sur sa photo, une identification, une demande d'ami — et de ce
    -- qui va lui coûter quelque chose s'il ne fait rien : ses photos sur le
    -- point d'être effacées.
    --
    -- L'activité des amis est éteinte par défaut. C'est elle qui transforme
    -- une application en distributeur de badges : cent amis à trois photos par
    -- jour, ce sont trois cents notifications qu'on finit par couper toutes.
    reglages_notifs TEXT    NOT NULL DEFAULT '',
    -- photo de profil, dans donnees/avatars/ ; sert à savoir d'un coup d'œil
    -- à qui appartient une photo sur la carte
    avatar          TEXT,
    actif           INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS sessions (
    -- on ne stocke jamais le jeton en clair : s'il fuit, la base ne suffit pas
    -- à se connecter. Empreinte = sha256(sel_serveur || jeton).
    empreinte       TEXT    PRIMARY KEY,
    utilisateur     INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    cree_le         TEXT    NOT NULL DEFAULT (datetime('now')),
    expire_le       TEXT    NOT NULL,
    vu_le           TEXT,
    appareil        TEXT    NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_sessions_utilisateur ON sessions(utilisateur);
CREATE INDEX IF NOT EXISTS idx_sessions_expire      ON sessions(expire_le);

-- --------------------------------------------------------------------- dex

-- Un visuel = un PNG détouré sur fond transparent. Le même sert aux deux états
-- de la case : tel quel une fois découvert, rempli en gris via son canal alpha
-- tant que la case est vide. Un visuel peut couvrir un rang entier : faute de
-- PNG pour l'espèce précise, on retombe sur celui de sa famille, puis de son
-- ordre, puis de sa classe (« un poisson » générique pour tous les poissons).
CREATE TABLE IF NOT EXISTS visuels (
    id              INTEGER PRIMARY KEY,
    -- Pas d'unicité sur le fichier : une même silhouette couvre souvent
    -- plusieurs taxons — PhyloPic donne le même dessin à une classe et à l'un
    -- de ses ordres. L'unicité porte donc sur le trio (fichier, rang, taxon).
    fichier         TEXT    NOT NULL,          -- nom de fichier dans donnees/silhouettes/
    rang            TEXT    NOT NULL,          -- espece | genre | famille | ordre | classe | embranchement | regne
    cle_gbif        INTEGER,                   -- clé GBIF du taxon couvert
    etiquette       TEXT    NOT NULL DEFAULT '',
    source          TEXT    NOT NULL DEFAULT '',
    licence         TEXT    NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_visuels_rang ON visuels(rang, cle_gbif);
CREATE UNIQUE INDEX IF NOT EXISTS idx_visuels_unique
    ON visuels(fichier, rang, cle_gbif);

CREATE TABLE IF NOT EXISTS cases (
    id              INTEGER PRIMARY KEY,
    -- speciesKey GBIF : l'identité de la case. Les espèces ajoutées par les
    -- joueurs n'en ont pas ; on leur attribue une clé négative très basse, hors
    -- de portée des orphelins du backbone, qui ne descendent qu'au million.
    cle_gbif        INTEGER NOT NULL UNIQUE,
    -- animal | plante | champignon. Le dex les mélange à l'affichage, mais
    -- chaque règne a son propre moteur et son propre catalogue : une photo de
    -- plante ne doit jamais pouvoir atterrir dans une case animale.
    regne           TEXT    NOT NULL DEFAULT 'animal',
    latin           TEXT    NOT NULL,          -- binôme accepté, ex. « Bos taurus »
    -- Non nul quand un joueur a créé la case lui-même : un cultivar, une race,
    -- une variété que le backbone GBIF ignore. Ces cases ne sont jamais
    -- proposées par le moteur — il n'a pas appris à les reconnaître — mais tout
    -- le monde les voit au dex et peut s'y ranger à la main.
    ajoute_par      INTEGER REFERENCES utilisateurs(id) ON DELETE SET NULL,
    -- 0 quand son auteur la retire. On désactive plutôt qu'on ne supprime :
    -- des captures y sont peut-être déjà rangées, et les faire disparaître
    -- avec la case serait une punition pour ceux qui ont fait confiance.
    actif           INTEGER NOT NULL DEFAULT 1,
    nom_fr          TEXT,                      -- nom vernaculaire français, si connu
    -- hiérarchie, dupliquée ici pour pouvoir filtrer et grouper sans jointure
    genre           TEXT    NOT NULL DEFAULT '',
    famille         TEXT    NOT NULL DEFAULT '',
    ordre           TEXT    NOT NULL DEFAULT '',
    classe          TEXT    NOT NULL DEFAULT '',
    embranchement   TEXT    NOT NULL DEFAULT '',
    cle_genre       INTEGER,
    cle_famille     INTEGER,
    cle_ordre       INTEGER,
    cle_classe      INTEGER,
    -- nombre d'observations GBIF : sert à trier le dex du plus commun au plus
    -- rare, et à en déduire une rareté façon pokédex.
    obs             INTEGER NOT NULL DEFAULT 0,
    -- Qualité de 1 (commun) à 5 (légendaire), calculée par outils/qualites.py.
    rarete          INTEGER NOT NULL DEFAULT 3,
    -- Points rapportés par la découverte, dérivés de la qualité.
    points          INTEGER NOT NULL DEFAULT 25,
    -- 1 si l'espèce est signalée toxique. Ne vaut que pour les champignons, et
    -- seulement dans un sens : l'absence de marque ne dit rien, beaucoup
    -- d'espèces mortelles ne sont pas listées. C'est une alerte, jamais un feu
    -- vert — l'asymétrie est délibérée.
    toxique         INTEGER NOT NULL DEFAULT 0,
    visuel          INTEGER REFERENCES visuels(id) ON DELETE SET NULL,
    -- nombre de noms latins qui retombent sur cette case (sous-espèces, synonymes)
    nb_alias        INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_cases_obs      ON cases(obs DESC);
CREATE INDEX IF NOT EXISTS idx_cases_classe   ON cases(classe, obs DESC);
CREATE INDEX IF NOT EXISTS idx_cases_famille  ON cases(famille);
-- Navigation arborescente : on regroupe par ordre dans une classe, puis par
-- famille dans un ordre. Sans ces index, chaque dépliage relit les 376 000 cases.
CREATE INDEX IF NOT EXISTS idx_cases_ordre    ON cases(classe, ordre);
CREATE INDEX IF NOT EXISTS idx_cases_ordre_fam ON cases(ordre, famille);
CREATE INDEX IF NOT EXISTS idx_cases_latin    ON cases(latin);
CREATE INDEX IF NOT EXISTS idx_cases_nom_fr   ON cases(nom_fr);

-- Tous les noms latins connus (ceux du catalogue CLIP, les sous-espèces, les
-- synonymes) et la case sur laquelle ils retombent. C'est la table que le
-- moteur interroge après avoir classé une photo.
CREATE TABLE IF NOT EXISTS alias (
    latin           TEXT    NOT NULL,
    -- Le même binôme peut désigner une plante et un animal : les codes de
    -- nomenclature botanique et zoologique sont indépendants, et le catalogue
    -- en compte une quarantaine. L'unicité porte donc sur le couple.
    regne           TEXT    NOT NULL DEFAULT 'animal',
    case_id         INTEGER NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    -- 1 si ce nom est le nom accepté de la case, 0 si c'est un synonyme
    accepte         INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (latin, regne)
);

CREATE INDEX IF NOT EXISTS idx_alias_case ON alias(case_id);

-- ---------------------------------------------------------------- captures

CREATE TABLE IF NOT EXISTS captures (
    -- AUTOINCREMENT n'est pas décoratif ici : sans lui, SQLite réattribue les
    -- identifiants libérés, et une nouvelle photo hérite de l'URL d'une photo
    -- effacée. Les téléphones qui gardaient l'ancienne image en cache la
    -- resservent alors à sa place. Les identifiants doivent être définitifs.
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    utilisateur     INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    -- attente : en file  |  analyse : chez le moteur  |  ok / doute / rejet / erreur
    etat            TEXT    NOT NULL DEFAULT 'attente',
    -- Le règne déclaré par le joueur au moment de l'envoi. C'est lui qui décide
    -- du moteur : Pl@ntNet pour une plante, FungiTastic pour un champignon,
    -- MegaDetector pour un animal. Le deviner à partir de l'image seule
    -- reviendrait à faire tourner les trois moteurs pour rien.
    regne           TEXT    NOT NULL DEFAULT 'animal',
    -- Quel moteur a produit le verdict : bioclip | plantnet | fungitastic.
    moteur          TEXT    NOT NULL DEFAULT '',
    case_id         INTEGER REFERENCES cases(id) ON DELETE SET NULL,
    fichier         TEXT    NOT NULL,          -- dans donnees/photos/
    -- L'image réellement soumise au moteur, quand elle diffère de l'originale.
    --
    -- Le joueur peut retoucher avant d'envoyer : éclaircir, entourer la bête au
    -- doigt. C'est cette version-là qu'on donne à analyser, parce qu'elle
    -- répond à la question posée. Mais c'est **l'originale** qu'on garde : elle
    -- seule est le témoignage de ce qui a été vu, et un recadrage regretté
    -- serait irréparable.
    --
    -- Effacée dès l'analyse terminée : elle n'a plus d'usage, et une deuxième
    -- copie de chaque photo doublerait la place occupée sur le serveur.
    fichier_analyse TEXT,
    vignette        TEXT,                      -- dans donnees/vignettes/
    -- l'animal détouré sur fond transparent, dans donnees/decoupes/
    decoupe         TEXT,
    -- boîte de MegaDetector, « x,y,l,h » en fractions de l'image
    bbox            TEXT,
    -- 1 si le joueur a lui-même désigné l'espèce, le moteur s'étant trompé
    corrigee        INTEGER NOT NULL DEFAULT 0,
    -- verdict rendu à l'app : nom affichable, latin, et à quel rang on a tranché
    verdict         TEXT    NOT NULL DEFAULT '',
    latin           TEXT    NOT NULL DEFAULT '',
    niveau          TEXT    NOT NULL DEFAULT '',   -- espece | genre | ''
    confiance       REAL    NOT NULL DEFAULT 0,
    note            TEXT    NOT NULL DEFAULT '',
    duree           REAL    NOT NULL DEFAULT 0,    -- secondes d'analyse
    -- géolocalisation facultative
    lat             REAL,
    lon             REAL,
    prise_le        TEXT,
    -- D'où viennent ces deux informations : exif (écrite par l'appareil photo,
    -- la plus fiable), appareil (position du téléphone à l'envoi), manuel
    -- (le joueur a placé le point ou corrigé l'heure lui-même). Vide si on ne
    -- sait pas. C'est ce qui permet de proposer de situer les photos orphelines.
    source_position TEXT    NOT NULL DEFAULT '',
    source_heure    TEXT    NOT NULL DEFAULT '',
    -- adresse approximative, retrouvée au moment où le joueur situe la photo
    lieu            TEXT    NOT NULL DEFAULT '',
    -- Titre libre donné par le joueur. Une photo n'est pas qu'un spécimen :
    -- « Le chat du voisin sur le muret » vaut mieux que « Chat #12 ».
    titre           TEXT    NOT NULL DEFAULT '',
    cree_le         TEXT    NOT NULL DEFAULT (datetime('now')),
    fini_le         TEXT,
    -- 1 = visible par les amis dans le fil d'activité
    partage         INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_captures_utilisateur ON captures(utilisateur, cree_le DESC);
CREATE INDEX IF NOT EXISTS idx_captures_case        ON captures(case_id, cree_le DESC);
CREATE INDEX IF NOT EXISTS idx_captures_etat        ON captures(etat) WHERE etat IN ('attente', 'analyse');

-- Le top-5 du classificateur, gardé pour l'écran de détail et pour pouvoir
-- rejuger une capture plus tard sans relancer le modèle.
CREATE TABLE IF NOT EXISTS captures_top (
    capture         INTEGER NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
    rang            INTEGER NOT NULL,
    latin           TEXT    NOT NULL,
    nom_fr          TEXT,
    proba           REAL    NOT NULL,
    case_id         INTEGER REFERENCES cases(id),
    PRIMARY KEY (capture, rang)
) WITHOUT ROWID;

-- ------------------------------------------------------------- découvertes

CREATE TABLE IF NOT EXISTS decouvertes (
    utilisateur     INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    case_id         INTEGER NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    premiere        INTEGER NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
    -- Capture mise en avant sur la case (par défaut la première).
    --
    -- Elle n'appartient pas forcément au joueur : on peut mettre en avant la
    -- photo d'un ami, qui a souvent mieux réussi la sienne. D'où le repli sur
    -- `premiere` partout où on la lit — une brouille ou un compte fermé rend
    -- la photo d'un tiers invisible, et la case ne doit pas devenir grise.
    vedette         INTEGER REFERENCES captures(id) ON DELETE SET NULL,
    -- Ce que montre la case. « auto » suit le réglage général du téléphone,
    -- « entier » force la photo telle qu'elle a été prise, « decoupe » force
    -- l'animal détouré. MegaDetector recadre parfois de travers, et le joueur
    -- doit pouvoir passer outre, case par case.
    cadrage         TEXT    NOT NULL DEFAULT 'auto',
    trouve_le       TEXT    NOT NULL DEFAULT (datetime('now')),
    nb_captures     INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (utilisateur, case_id)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_decouvertes_date ON decouvertes(utilisateur, trouve_le DESC);
CREATE INDEX IF NOT EXISTS idx_decouvertes_case ON decouvertes(case_id);

-- -------------------------------------------------------------------- amis

CREATE TABLE IF NOT EXISTS amities (
    id              INTEGER PRIMARY KEY,
    demandeur       INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    destinataire    INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    etat            TEXT    NOT NULL DEFAULT 'attente',  -- attente | acceptee | bloquee
    cree_le         TEXT    NOT NULL DEFAULT (datetime('now')),
    repondu_le      TEXT,
    CHECK (demandeur <> destinataire)
);

-- Une seule relation par paire, quel que soit le sens de la demande : sans ça,
-- A→B en attente et B→A en attente créeraient deux liens concurrents.
CREATE UNIQUE INDEX IF NOT EXISTS idx_amities_paire ON amities(
    MIN(demandeur, destinataire), MAX(demandeur, destinataire)
);
CREATE INDEX IF NOT EXISTS idx_amities_demandeur    ON amities(demandeur, etat);
CREATE INDEX IF NOT EXISTS idx_amities_destinataire ON amities(destinataire, etat);

-- ---------------------------------------------------------------- réactions

-- Ce que les amis pensent d'une photo. Une seule réaction par personne et par
-- photo, modifiable : on peut changer d'avis, pas voter deux fois.
-- Les points vont au propriétaire de la photo.
CREATE TABLE IF NOT EXISTS reactions (
    capture         INTEGER NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
    auteur          INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    -- 0 bof, 1 sympa, 2 beau, 3 superbe, 4 incroyable
    valeur          INTEGER NOT NULL,
    cree_le         TEXT    NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (capture, auteur)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_reactions_capture ON reactions(capture);
CREATE INDEX IF NOT EXISTS idx_reactions_auteur  ON reactions(auteur);

-- ------------------------------------------------------------------ fiches

-- Résumé encyclopédique d'une espèce, récupéré une fois auprès de Wikipédia
-- puis gardé : inutile d'interroger leur API à chaque ouverture d'une case, et
-- ça marche même quand le téléphone n'a pas d'accès direct.
CREATE TABLE IF NOT EXISTS fiches (
    case_id         INTEGER PRIMARY KEY REFERENCES cases(id) ON DELETE CASCADE,
    titre           TEXT    NOT NULL DEFAULT '',
    resume          TEXT    NOT NULL DEFAULT '',
    url             TEXT    NOT NULL DEFAULT '',
    image           TEXT    NOT NULL DEFAULT '',
    langue          TEXT    NOT NULL DEFAULT 'fr',
    -- Vide quand l'article porte bien sur l'espèce ; « genre » quand on a dû
    -- se rabattre sur le taxon supérieur. L'application le signale, pour ne
    -- pas faire passer la fiche du genre pour celle de l'espèce.
    approximation   TEXT    NOT NULL DEFAULT '',
    -- 1 si Wikipédia n'a rien pour cette espèce : on ne réinterroge pas en
    -- boucle une espèce sans article.
    vide            INTEGER NOT NULL DEFAULT 0,
    maj_le          TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- ----------------------------------------------------------------- favoris

-- Photos mises de côté : les siennes comme celles des amis. Contrairement à la
-- vedette d'une case, qui est publique, un favori ne regarde que son auteur.
CREATE TABLE IF NOT EXISTS favoris (
    utilisateur     INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    capture         INTEGER NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
    cree_le         TEXT    NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (utilisateur, capture)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_favoris_date ON favoris(utilisateur, cree_le DESC);

-- ------------------------------------------------------------- participants

-- Les amis présents au moment de la photo.
--
-- Deux personnes qui marchent ensemble voient le même renard. Jusqu'ici il
-- fallait le photographier chacun de son côté pour que chacun le compte, ce
-- qui produisait deux fichiers quasi identiques sur le serveur et deux photos
-- redondantes dans le fil des amis. Une capture peut désormais être signée par
-- plusieurs personnes : **un seul fichier, N comptes**.
--
-- L'auteur n'est pas dans cette table. Il reste `captures.utilisateur` : c'est
-- lui qui possède le fichier, peut le supprimer, et à qui il revient si tous
-- les participants s'en retirent. Les mélanger aurait laissé croire qu'on peut
-- se retirer de sa propre photo.
--
-- Chaque participant reçoit sa ligne dans `decouvertes`, donc sa case et ses
-- points, exactement comme s'il avait pris la photo. Le partage est le sujet,
-- pas une consolation.
CREATE TABLE IF NOT EXISTS participants (
    capture         INTEGER NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
    utilisateur     INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    -- Qui a identifié qui. Sert à dire « Un ami t'a identifié sur sa photo »
    -- plutôt qu'un « tu as été identifié » sans auteur.
    par             INTEGER REFERENCES utilisateurs(id) ON DELETE SET NULL,
    cree_le         TEXT    NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (capture, utilisateur)
) WITHOUT ROWID;

-- « Sur quelles photos suis-je identifié ? » est la question posée à chaque
-- ouverture de la galerie, de la carte et du dex : elle mérite son index.
CREATE INDEX IF NOT EXISTS idx_participants_utilisateur
    ON participants(utilisateur, cree_le DESC);

-- La galerie trie et filtre par date de prise de vue, à défaut par date d'envoi.
CREATE INDEX IF NOT EXISTS idx_captures_quand
    ON captures(COALESCE(prise_le, cree_le) DESC);
CREATE INDEX IF NOT EXISTS idx_captures_position ON captures(lat, lon);

-- ----------------------------------------------------------- notifications

-- Ce qui mérite qu'on prévienne quelqu'un. Pour l'instant les réactions à ses
-- photos ; la table est faite pour en accueillir d'autres.
CREATE TABLE IF NOT EXISTS notifications (
    id              INTEGER PRIMARY KEY,
    -- à qui elle s'adresse
    destinataire    INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    -- qui l'a provoquée
    auteur          INTEGER REFERENCES utilisateurs(id) ON DELETE CASCADE,
    type            TEXT    NOT NULL,   -- reaction | ami | identifie
    capture         INTEGER REFERENCES captures(id) ON DELETE CASCADE,
    -- Une photo représentative, pour les types groupés comme `ami_actif` où
    -- `capture` reste NULL exprès (c'est cette colonne-là qui porte la clé
    -- d'unicité, une seule ligne par ami tant qu'elle n'est pas lue). Sans
    -- `apercu`, ces notifications n'avaient aucune image, juste un badge.
    -- `ON DELETE SET NULL` et non CASCADE : la photo qui disparaît ne doit pas
    -- effacer la notification qui annonçait « 5 nouvelles trouvailles ».
    apercu          INTEGER REFERENCES captures(id) ON DELETE SET NULL,
    -- valeur de la réaction, pour afficher le bon emoji sans rejointure
    valeur          INTEGER,
    lu              INTEGER NOT NULL DEFAULT 0,
    cree_le         TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_notifications_dest
    ON notifications(destinataire, lu, cree_le DESC);
-- Une personne qui change trois fois d'avis sur la même photo ne doit produire
-- qu'une seule notification : on remplace la précédente.
CREATE UNIQUE INDEX IF NOT EXISTS idx_notifications_reaction
    ON notifications(destinataire, auteur, capture, type);


-- ═══════════════════════════════════════════════════════════════════ succès
--
-- Deux tables, et la distinction compte.
--
-- `succes_especes` dit quelles espèces répondent à quel thème. Elle est
-- **précalculée** par outils/succes_especes.py : décider en direct que « Rosa
-- gallica » évoque le jardin demanderait une expression régulière sur 977 415
-- lignes à chaque photo. Elle est aussi relisible, donc corrigeable quand un
-- faux positif se montre.
--
-- `succes_obtenus` dit qui a débloqué quoi, et quand. Un succès ne s'obtient
-- **qu'une fois** : la clé primaire l'impose, et retrouver la même espèce
-- ensuite ne produit rien.
CREATE TABLE IF NOT EXISTS succes_especes (
    succes          TEXT    NOT NULL,   -- « feu », « couleur:rouge »…
    case_id         INTEGER NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    PRIMARY KEY (succes, case_id)
);
CREATE INDEX IF NOT EXISTS idx_succes_especes_case ON succes_especes(case_id);

CREATE TABLE IF NOT EXISTS succes_obtenus (
    utilisateur     INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    cle             TEXT    NOT NULL,
    -- 1 quand le succès est réellement décroché. Une ligne peut exister sans
    -- l'être : révéler la condition en pose une. C'est ce drapeau, et non la
    -- présence de la ligne, qui fait foi.
    obtenu          INTEGER NOT NULL DEFAULT 0,
    obtenu_le       TEXT,
    -- 1 quand le joueur a demandé à voir la condition. On le retient pour
    -- marquer discrètement ce qu'il s'est spoilé — et pour ne pas le lui
    -- recacher au rendu suivant.
    revele          INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (utilisateur, cle)
);

-- La vitrine d'un profil : les photos qu'on choisit de montrer.
--
-- Le classement montre ce qu'on a trouvé de plus rare, la galerie tout ce
-- qu'on a pris. Ni l'un ni l'autre ne dit ce dont on est fier : la photo
-- réussie d'un moineau ne vaut aucun point et vaut pourtant qu'on la montre.
-- C'est une sélection à la main, dans l'ordre qu'on veut.
--
-- `rang` porte cet ordre. Il n'est pas déduit de la date : on réarrange sa
-- vitrine sans pour autant reprendre les photos.
CREATE TABLE IF NOT EXISTS profil_vitrine (
    utilisateur INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    capture     INTEGER NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
    rang        INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (utilisateur, capture)
);
CREATE INDEX IF NOT EXISTS idx_profil_vitrine ON profil_vitrine(utilisateur, rang);

-- La disposition libre du dex : où le joueur a posé ses trouvailles.
--
-- Comme des icônes sur un bureau. On ne stocke **que les exceptions** : une
-- case absente d'ici suit la disposition automatique. Quelqu'un qui n'arrange
-- rien ne coûte pas une ligne, et quelqu'un qui arrange vingt espèces en coûte
-- vingt — pas 977 416.
--
-- Les coordonnées sont en **cellules**, jamais en pixels. Un arrangement fait
-- sur un téléphone doit se retrouver identique sur une tablette ; des pixels
-- donneraient une bouillie dès qu'on change d'écran. La grille logique fait
-- toujours COLONNES_LIBRES colonnes de large, et c'est la taille des cellules
-- qui s'adapte.
CREATE TABLE IF NOT EXISTS dex_disposition (
    utilisateur INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    case_id     INTEGER NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    colonne     INTEGER NOT NULL DEFAULT 0,
    rangee      INTEGER NOT NULL DEFAULT 0,
    largeur     INTEGER NOT NULL DEFAULT 1,
    hauteur     INTEGER NOT NULL DEFAULT 1,
    -- Carré arrondi, rond, hexagone… La forme appartient au joueur autant que
    -- la position : c'est ce qui fait qu'un dex ressemble à quelqu'un.
    forme       TEXT NOT NULL DEFAULT 'arrondi',
    -- Masquée : la case reste au dex et compte toujours, mais n'apparaît plus
    -- dans la grille. C'est de la mise en forme, pas un retrait.
    masque      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (utilisateur, case_id)
);
CREATE INDEX IF NOT EXISTS idx_dex_disposition
    ON dex_disposition(utilisateur, rangee, colonne);

-- Les cases vides du dex : des trous que le joueur pose lui-même.
--
-- Elles n'affichent rien — ni silhouette, ni cadre. Elles servent à aérer, à
-- caler une ligne, à séparer deux groupes. Table à part parce qu'elles n'ont
-- pas d'espèce : `dex_disposition` exige une case existante.
CREATE TABLE IF NOT EXISTS dex_vides (
    utilisateur INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    rang        INTEGER NOT NULL,
    colonne     INTEGER NOT NULL DEFAULT 0,
    rangee      INTEGER NOT NULL DEFAULT 0,
    largeur     INTEGER NOT NULL DEFAULT 1,
    hauteur     INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (utilisateur, rang)
);

-- ----------------------------------------------------------- photos vues
--
-- Ce qu'un joueur a déjà regardé chez ses amis. C'est ce qui permet à la carte
-- de mettre en avant ce qu'on n'a pas encore vu : « Nouveautés » par défaut,
-- « Tout voir » d'un appui.
--
-- Une ligne par (joueur, photo), posée la première fois qu'il ouvre la photo —
-- pas quand elle passe dans une liste. Ses propres photos n'y entrent jamais :
-- il les a prises, il les a vues.
CREATE TABLE IF NOT EXISTS photos_vues (
    utilisateur     INTEGER NOT NULL REFERENCES utilisateurs(id) ON DELETE CASCADE,
    capture         INTEGER NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
    vu_le           TEXT    NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (utilisateur, capture)
);
CREATE INDEX IF NOT EXISTS idx_photos_vues_capture ON photos_vues(capture);
