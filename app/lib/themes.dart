import 'package:flutter/material.dart';

/// Un jeu de couleurs complet : tout ce que [Palette] lit, plus ce qui fait
/// le caractère du thème — la police, et le fond animé derrière les écrans.
///
/// Les mêmes dix-sept thèmes que le site, aux mêmes couleurs : un joueur qui
/// passe de l'un à l'autre doit retrouver la même ambiance. Les valeurs sont
/// recopiées de `web/style.css` ; les deux ne se lisent pas l'un l'autre, il
/// faut les tenir à la main.
class JeuDeCouleurs {
  const JeuDeCouleurs({
    required this.cle,
    required this.nom,
    required this.detail,
    required this.sombre,
    required this.fond,
    required this.fondSecondaire,
    required this.caseVide,
    required this.silhouette,
    required this.bordure,
    required this.texte,
    required this.texteDoux,
    required this.accent,
    required this.accentSombre,
    required this.alerte,
    required this.surAccent,
    this.fondAnime,
    this.police,
    this.barre,
  });

  final String cle;
  final String nom;
  final String detail;

  /// Vrai quand le thème part du sombre : commande la luminosité Material et
  /// le voile posé sur les images venues de Wikipédia.
  final bool sombre;

  final Color fond;
  final Color fondSecondaire;
  final Color caseVide;
  final Color silhouette;
  final Color bordure;
  final Color texte;
  final Color texteDoux;
  final Color accent;
  final Color accentSombre;
  final Color alerte;

  /// Ce qu'on écrit **sur** l'accent.
  final Color surAccent;

  /// Le décor animé derrière les écrans, par son nom dans `FondAnime`, ou
  /// rien. Quand il y en a un, les écrans deviennent transparents pour le
  /// laisser voir ; chaque surface garde son fond opaque.
  final String? fondAnime;

  /// Une police générique — `monospace`, `serif` — ou celle du système.
  final String? police;

  /// La couleur de fond du canevas, derrière le décor, avant qu'il soit peint.
  final Color? barre;
}

const _blanc = Color(0xFFFFFFFF);

/// Les thèmes, dans l'ordre où le sélecteur les montre.
const List<JeuDeCouleurs> themes = [
  JeuDeCouleurs(
    cle: 'clair', nom: 'Clair', detail: 'Blanc, sobre', sombre: false,
    fond: _blanc, fondSecondaire: Color(0xFFF6F7F8), caseVide: Color(0xFFF1F1F2),
    silhouette: Color(0xFFD2D3D6), bordure: Color(0xFFB9BABD),
    texte: Color(0xFF1B1D21), texteDoux: Color(0xFF6B7079),
    accent: Color(0xFF0EA5A4), accentSombre: Color(0xFF0B7F7E), alerte: Color(0xFFE05252),
    surAccent: _blanc,
  ),
  JeuDeCouleurs(
    cle: 'sombre', nom: 'Sombre', detail: 'Gris anthracite', sombre: true,
    fond: Color(0xFF121316), fondSecondaire: Color(0xFF1C1E22), caseVide: Color(0xFF24272C),
    silhouette: Color(0xFF44484F), bordure: Color(0xFF5A5F66),
    texte: Color(0xFFE9EAEC), texteDoux: Color(0xFF9AA0A8),
    accent: Color(0xFF2BC4C2), accentSombre: Color(0xFF7FE3E1), alerte: Color(0xFFFF7676),
    surAccent: Color(0xFF07231F),
  ),
  JeuDeCouleurs(
    cle: 'hacker', nom: 'Hacker', detail: 'Pluie de signes', sombre: true,
    fond: Color(0xFF050905), fondSecondaire: Color(0xFF0B140C), caseVide: Color(0xFF0E1A0F),
    silhouette: Color(0xFF1F4A24), bordure: Color(0xFF1D5A26),
    texte: Color(0xFF9DFFB0), texteDoux: Color(0xFF4FCF6A),
    accent: Color(0xFF22FF5E), accentSombre: Color(0xFF12B542), alerte: Color(0xFFFF5C5C),
    surAccent: Color(0xFF002211), fondAnime: 'matrice', police: 'monospace', barre: Color(0xFF000000),
  ),
  JeuDeCouleurs(
    cle: 'nuit', nom: 'Nuit étoilée', detail: 'Étoiles et filantes', sombre: true,
    fond: Color(0xFF0A0F24), fondSecondaire: Color(0xFF121A38), caseVide: Color(0xFF182250),
    silhouette: Color(0xFF2C3A73), bordure: Color(0xFF2F3D78),
    texte: Color(0xFFE6EBFF), texteDoux: Color(0xFF9AA8E0),
    accent: Color(0xFFFFD166), accentSombre: Color(0xFFD9A93F), alerte: Color(0xFFFF6B6B),
    surAccent: Color(0xFF1A1400), fondAnime: 'etoiles', barre: Color(0xFF05081A),
  ),
  JeuDeCouleurs(
    cle: 'abysses', nom: 'Abysses', detail: 'Bulles et rais de lumière', sombre: true,
    fond: Color(0xFF03101F), fondSecondaire: Color(0xFF072038), caseVide: Color(0xFF0A2A47),
    silhouette: Color(0xFF1C4A6E), bordure: Color(0xFF164A6C),
    texte: Color(0xFFD8F1FF), texteDoux: Color(0xFF7FB6D6),
    accent: Color(0xFF2EE6D6), accentSombre: Color(0xFF15A99C), alerte: Color(0xFFFF6B6B),
    surAccent: Color(0xFF03201E), fondAnime: 'bulles', barre: Color(0xFF06223A),
  ),
  JeuDeCouleurs(
    cle: 'neon', nom: 'Néon', detail: 'Grille synthwave', sombre: true,
    fond: Color(0xFF120A1F), fondSecondaire: Color(0xFF1B1030), caseVide: Color(0xFF241540),
    silhouette: Color(0xFF3D2766), bordure: Color(0xFF4A2C7A),
    texte: Color(0xFFF6E9FF), texteDoux: Color(0xFFB89AD8),
    accent: Color(0xFFFF3FA4), accentSombre: Color(0xFFC21F7A), alerte: Color(0xFFFF5C5C),
    surAccent: _blanc, fondAnime: 'grille', barre: Color(0xFF1E0D3A),
  ),
  JeuDeCouleurs(
    cle: 'foret', nom: 'Forêt', detail: 'Feuilles d\'automne', sombre: true,
    fond: Color(0xFF14201A), fondSecondaire: Color(0xFF1C2C22), caseVide: Color(0xFF243A2C),
    silhouette: Color(0xFF3F6A4C), bordure: Color(0xFF3A5A44),
    texte: Color(0xFFE9F3E6), texteDoux: Color(0xFF9DBF9A),
    accent: Color(0xFFD9A441), accentSombre: Color(0xFFA77A24), alerte: Color(0xFFE0623F),
    surAccent: Color(0xFF1D1400), fondAnime: 'feuilles', barre: Color(0xFF101A14),
  ),
  JeuDeCouleurs(
    cle: 'sakura', nom: 'Sakura', detail: 'Pétales au vent', sombre: false,
    fond: Color(0xFFFFF7F9), fondSecondaire: Color(0xFFFFEEF3), caseVide: Color(0xFFFDE4EC),
    silhouette: Color(0xFFE8B9C8), bordure: Color(0xFFE3A8BC),
    texte: Color(0xFF3A2530), texteDoux: Color(0xFF8A5F70),
    accent: Color(0xFFE8538A), accentSombre: Color(0xFFB93466), alerte: Color(0xFFD94040),
    surAccent: _blanc, fondAnime: 'sakura', barre: Color(0xFFFFF4F8),
  ),
  JeuDeCouleurs(
    cle: 'hiver', nom: 'Hiver', detail: 'Neige', sombre: false,
    fond: Color(0xFFF3F7FB), fondSecondaire: Color(0xFFE8EFF7), caseVide: Color(0xFFDDE7F2),
    silhouette: Color(0xFFB7C6D8), bordure: Color(0xFFA9BBD0),
    texte: Color(0xFF182636), texteDoux: Color(0xFF5C7190),
    accent: Color(0xFF2F7FD6), accentSombre: Color(0xFF1F5EA3), alerte: Color(0xFFD9534F),
    surAccent: _blanc, fondAnime: 'neige', barre: Color(0xFFEEF3F9),
  ),
  JeuDeCouleurs(
    cle: 'aurore', nom: 'Aurore boréale', detail: 'Voiles verts et violets', sombre: true,
    fond: Color(0xFF07101F), fondSecondaire: Color(0xFF0F1B30), caseVide: Color(0xFF152640),
    silhouette: Color(0xFF2A4466), bordure: Color(0xFF27456A),
    texte: Color(0xFFE4F4FF), texteDoux: Color(0xFF93B4D0),
    accent: Color(0xFF5DF2A6), accentSombre: Color(0xFF2FBF7A), alerte: Color(0xFFFF6B6B),
    surAccent: Color(0xFF06281A), fondAnime: 'aurore', barre: Color(0xFF050B16),
  ),
  JeuDeCouleurs(
    cle: 'lucioles', nom: 'Nuit d\'été', detail: 'Lucioles', sombre: true,
    fond: Color(0xFF0A1A16), fondSecondaire: Color(0xFF11261F), caseVide: Color(0xFF17332A),
    silhouette: Color(0xFF2F5A48), bordure: Color(0xFF2A5443),
    texte: Color(0xFFEEFAF2), texteDoux: Color(0xFF9AC4AD),
    accent: Color(0xFFFFE37A), accentSombre: Color(0xFFD9B93C), alerte: Color(0xFFFF7A6B),
    surAccent: Color(0xFF2A2200), fondAnime: 'lucioles', barre: Color(0xFF06130F),
  ),
  JeuDeCouleurs(
    cle: 'savane', nom: 'Savane', detail: 'Soleil couchant, oiseaux', sombre: true,
    fond: Color(0xFF2A1612), fondSecondaire: Color(0xFF3A211B), caseVide: Color(0xFF4A2B22),
    silhouette: Color(0xFF7A4A3A), bordure: Color(0xFF6A3F32),
    texte: Color(0xFFFFE9D6), texteDoux: Color(0xFFD9A98D),
    accent: Color(0xFFFF8C42), accentSombre: Color(0xFFD4651F), alerte: Color(0xFFFF5C5C),
    surAccent: Color(0xFF2A1200), fondAnime: 'savane', barre: Color(0xFF2A1612),
  ),
  JeuDeCouleurs(
    cle: 'aquarelle', nom: 'Aquarelle', detail: 'Taches de couleur', sombre: false,
    fond: Color(0xFFFFFDF8), fondSecondaire: Color(0xFFF7F3EA), caseVide: Color(0xFFEFE8DC),
    silhouette: Color(0xFFC9C0B2), bordure: Color(0xFFC2B8A8),
    texte: Color(0xFF2E2A26), texteDoux: Color(0xFF6F6860),
    accent: Color(0xFF4F8FCF), accentSombre: Color(0xFF356CA3), alerte: Color(0xFFD9534F),
    surAccent: _blanc, fondAnime: 'aquarelle', barre: Color(0xFFFFFDF8),
  ),
  JeuDeCouleurs(
    cle: 'lagon', nom: 'Lagon', detail: 'Reflets d\'eau', sombre: false,
    fond: Color(0xFFF0FBFB), fondSecondaire: Color(0xFFE3F6F6), caseVide: Color(0xFFD4F0F0),
    silhouette: Color(0xFF9FD3D3), bordure: Color(0xFF8FC9C9),
    texte: Color(0xFF0F3A3D), texteDoux: Color(0xFF3F7A7D),
    accent: Color(0xFF0AB3A6), accentSombre: Color(0xFF078A80), alerte: Color(0xFFE0623F),
    surAccent: Color(0xFF032E2B), fondAnime: 'lagon', barre: Color(0xFFDFF6F6),
  ),
  JeuDeCouleurs(
    cle: 'nebuleuse', nom: 'Nébuleuse', detail: 'Poussière d\'étoiles', sombre: true,
    fond: Color(0xFF0D0A1F), fondSecondaire: Color(0xFF17122F), caseVide: Color(0xFF211A40),
    silhouette: Color(0xFF3D3270), bordure: Color(0xFF3A2F6E),
    texte: Color(0xFFEFE9FF), texteDoux: Color(0xFFA99BD6),
    accent: Color(0xFFC77DFF), accentSombre: Color(0xFF9A4FE0), alerte: Color(0xFFFF6B8A),
    surAccent: Color(0xFF1A0A2E), fondAnime: 'nebuleuse', barre: Color(0xFF0D0A1F),
  ),
  JeuDeCouleurs(
    cle: 'carnet', nom: 'Carnet', detail: 'Papier et encre sépia', sombre: false,
    fond: Color(0xFFF6F0E1), fondSecondaire: Color(0xFFEFE6D2), caseVide: Color(0xFFE9DFC8),
    silhouette: Color(0xFFC9BB9C), bordure: Color(0xFFB8A888),
    texte: Color(0xFF2D2418), texteDoux: Color(0xFF6E5F48),
    accent: Color(0xFF8A5A2B), accentSombre: Color(0xFF5F3D1A), alerte: Color(0xFFB9412F),
    surAccent: _blanc, police: 'serif',
  ),
  JeuDeCouleurs(
    cle: 'gameboy', nom: 'Game Boy', detail: 'Quatre verts, pixels', sombre: false,
    fond: Color(0xFFCADC9F), fondSecondaire: Color(0xFFBDD08F), caseVide: Color(0xFFA9BF7D),
    silhouette: Color(0xFF6B8F45), bordure: Color(0xFF4E7A3A),
    texte: Color(0xFF0F380F), texteDoux: Color(0xFF306230),
    accent: Color(0xFF306230), accentSombre: Color(0xFF0F380F), alerte: Color(0xFF8B2F2F),
    surAccent: Color(0xFFCADC9F), police: 'monospace',
  ),
];

/// Un thème par sa clé ; `clair` à défaut, jamais une erreur sur une clé
/// venue d'une ancienne version.
JeuDeCouleurs themeParCle(String cle) =>
    themes.firstWhere((t) => t.cle == cle, orElse: () => themes.first);
