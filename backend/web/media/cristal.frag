#version 300 es
// ─────────────────────────────────────────────────────────────────────────
// COPIE MÉCANIQUE de app/assets/shaders/cristal.frag — ne pas modifier ici.
//
// Le corps est rigoureusement identique : la gemme lancée au rayon, ses
// fissures de Voronoï, ses éclats. Seul l'en-tête diffère, Flutter et WebGL ne
// nommant pas les mêmes choses.
//
// Pour la régénérer après une retouche du shader Flutter :
//     python -m outils.shader_web
// ─────────────────────────────────────────────────────────────────────────

// Le cristal du succès : un vrai volume, ses facettes, ses fissures.
//
// **Pourquoi un lancer de rayon.** La première version dessinait un hexagone
// plat avec un ombrage simulé à partir du champ de distance 2D. Ça se voyait :
// pas de profondeur, pas d'arête franche, une gemme en carton. Ici on marche
// réellement dans un volume — un prisme hexagonal recoupé par une bipyramide,
// la taille d'une pierre précieuse. Les facettes viennent de la géométrie, pas
// d'un dégradé, et c'est ce qui fait la différence.
//
// Le volume tourne lentement sur lui-même. Sans cela, les facettes ne
// s'allument jamais l'une après l'autre et l'objet reste une image.
//
// **Ce qui est gardé de la version d'avant** : tout le système de fissures.
// La partition de Voronoï, la propagation depuis le cœur, la lumière qui
// blanchit en sortant, les éclats qui partent chacun avec son retard. C'est
// désormais projeté sur la surface du volume au lieu d'un plan.

precision highp float;

out vec4 fragColor;

uniform vec2  uTaille;
uniform float uTemps;
uniform float uFissure;    // 0 → intact, 1 → parcouru de fractures
uniform float uEclat;      // 0 → assemblé, 1 → fragments dispersés
uniform vec3  uTeinte;
// La couleur de la lumière qui sort des fissures.
//
// Déclarée en dernier, et ce n'est pas un détail : côté Dart les uniformes
// n'ont pas de nom, seulement un index dans l'ordre de déclaration. L'insérer
// au milieu décalerait tout ce qui suit, sans erreur et sans bruit.
//
// Elle vient de la grenouille enfermée dans la gemme — sa couleur d'accent,
// le chapeau, l'écharpe — quand `uTeinte` vient de son corps. Voir
// `outils/couleurs_succes.py`.
uniform vec3  uLueur;

const float PI = 3.14159265;

// ── bruit ───────────────────────────────────────────────────────────────────

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 hash2(vec2 p) {
    return fract(sin(vec2(dot(p, vec2(127.1, 311.7)),
                          dot(p, vec2(269.5, 183.3)))) * 43758.5453);
}

float bruit(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    vec2 uv = i.xy + vec2(37.0, 17.0) * i.z + f.xy;
    return mix(hash(uv), hash(uv + vec2(37.0, 17.0)), f.z);
}

// ── la gemme ────────────────────────────────────────────────────────────────

// Un prisme hexagonal. Six plans verticaux : ce sont eux qui donnent les
// grandes facettes de côté, celles qui accrochent la lumière quand ça tourne.
float prismeHexa(vec3 p, vec2 h) {
    const vec3 k = vec3(-0.8660254, 0.5, 0.57735);
    p = abs(p);
    p.xy -= 2.0 * min(dot(k.xy, p.xy), 0.0) * k.xy;
    vec2 d = vec2(
        length(p.xy - vec2(clamp(p.x, -k.z * h.x, k.z * h.x), h.x))
            * sign(p.y - h.x),
        p.z - h.y);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

// Une bipyramide. C'est elle qui taille les pointes en haut et en bas, et qui
// fait qu'on lit « cristal » plutôt que « écrou ».
float octaedre(vec3 p, float s) {
    p = abs(p);
    return (p.x + p.y + p.z - s) * 0.57735027;
}

// La pierre : l'intersection des deux. `max` d'un SDF, c'est l'intersection —
// on garde ce qui est à l'intérieur des deux formes.
float gemme(vec3 p) {
    // Allongée sur la verticale : une gemme aussi large que haute paraît
    // tassée.
    vec3 q = p;
    q.y *= 0.72;
    float prisme = prismeHexa(q.xzy, vec2(0.46, 0.95));
    float pointes = octaedre(p, 1.28);
    return max(prisme, pointes);
}

// La normale, prise sur quatre échantillons plutôt que six : deux fois moins
// d'évaluations pour une différence invisible sur des faces planes.
vec3 normale(vec3 p) {
    const vec2 k = vec2(1.0, -1.0);
    const float e = 0.0015;
    return normalize(k.xyy * gemme(p + k.xyy * e) +
                     k.yyx * gemme(p + k.yyx * e) +
                     k.yxy * gemme(p + k.yxy * e) +
                     k.xxx * gemme(p + k.xxx * e));
}

// ── les fragments ───────────────────────────────────────────────────────────

// Inchangé dans son principe : une partition de Voronoï donne à la fois les
// lignes de fissure et les morceaux. Elle est maintenant lue sur la surface du
// volume, pas sur un plan.
vec3 cellules(vec2 p, float densite) {
    vec2 grille = p * densite;
    vec2 base = floor(grille);
    vec2 f = fract(grille);

    vec2 meilleur = vec2(0.0);
    float d1 = 8.0;
    float d2 = 8.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 voisin = vec2(float(x), float(y));
            vec2 centre = voisin + hash2(base + voisin);
            float d = length(centre - f);
            if (d < d1) {
                d2 = d1;
                d1 = d;
                meilleur = base + voisin;
            } else if (d < d2) {
                d2 = d;
            }
        }
    }
    return vec3(d2 - d1, meilleur);
}

// Les coordonnées de surface qui portent les fissures. On projette en
// cylindrique : l'angle autour de l'axe et la hauteur. Sur une gemme dressée,
// c'est la projection qui déforme le moins les cellules.
vec2 surface(vec3 p) {
    return vec2(atan(p.z, p.x) / PI, p.y * 0.9);
}

mat2 rotation(float a) {
    float c = cos(a);
    float s = sin(a);
    return mat2(c, -s, s, c);
}

void main() {
    vec2 px = gl_FragCoord.xy;
    vec2 uv = (px - uTaille * 0.5) / min(uTaille.x, uTaille.y) * 2.0;
    float t = uTemps;

    // La caméra, reculée et légèrement au-dessus : on regarde la pierre
    // posée, pas de face comme un logo.
    vec3 oeil = vec3(0.0, 0.30, -3.2);
    vec3 rayon = normalize(vec3(uv.x, uv.y - 0.06, 1.9));

    // Le volume tourne. C'est ce mouvement qui allume les facettes l'une après
    // l'autre — sans lui, la gemme reste une image, quelle que soit la qualité
    // du rendu.
    float angle = t * 0.55;
    float berceau = 0.12 * sin(t * 0.9);   // un léger roulis, pour la vie

    // ── marche ─────────────────────────────────────────────────────────────
    float distance = 0.0;
    float touche = -1.0;
    vec3 point = vec3(0.0);
    for (int i = 0; i < 64; i++) {
        point = oeil + rayon * distance;
        vec3 q = point;
        q.xz *= rotation(angle);
        q.yz *= rotation(berceau);
        float d = gemme(q);
        if (d < 0.0015) { touche = distance; break; }
        if (distance > 7.0) break;
        distance += d * 0.85;   // pas prudent : les arêtes vives débordent
    }

    vec3 couleur = vec3(0.0);
    float alpha = 0.0;

    if (touche > 0.0) {
        vec3 q = point;
        q.xz *= rotation(angle);
        q.yz *= rotation(berceau);
        vec3 n = normale(q);

        // ── éclairage ──────────────────────────────────────────────────────
        vec3 versOeil = normalize(oeil - point);
        vec3 cle = normalize(vec3(-0.5, 0.85, -0.7));    // la lumière principale
        vec3 contre = normalize(vec3(0.7, -0.2, 0.6));   // un contre-jour froid

        // Les faces sont planes : le diffus est constant par facette, ce qui
        // donne des arêtes franches. C'est exactement ce qu'on veut — un
        // dégradé continu ferait « bulle de savon ».
        float diffus = max(dot(n, cle), 0.0);
        float appoint = max(dot(n, contre), 0.0);

        // Fresnel : les bords s'allument quand on les voit de biais. C'est le
        // signal le plus fort de « ça, c'est du verre ».
        float fresnel = pow(1.0 - max(dot(n, versOeil), 0.0), 3.5);

        // Un éclat spéculaire dur, comme sur une arête polie.
        vec3 reflet = reflect(-cle, n);
        float speculaire = pow(max(dot(reflet, versOeil), 0.0), 48.0);

        // ── l'intérieur ────────────────────────────────────────────────────
        // On ne calcule pas de vraie réfraction : on relance un rayon dévié
        // dans la matière et on échantillonne un bruit le long. C'est faux
        // physiquement, et c'est ce qui donne les voiles et les inclusions
        // qu'on voit dans une pierre naturelle.
        vec3 dedans = refract(-versOeil, n, 0.72);
        float voiles = 0.0;
        for (int i = 1; i <= 5; i++) {
            voiles += bruit(q + dedans * float(i) * 0.22 + vec3(0.0, t * 0.15, 0.0));
        }
        voiles /= 5.0;
        float inclusions = smoothstep(0.42, 0.78, voiles);

        // ── les fissures, projetées sur la surface ─────────────────────────
        vec2 s = surface(q);
        vec3 cel = cellules(s, 3.1);
        float rayonCoeur = length(q);
        // `uFissure` est un rayon de propagation, pas une opacité : la
        // fracture part du cœur et gagne les pointes. On la voit avancer.
        float front = smoothstep(uFissure * 1.5, uFissure * 1.5 - 0.4, rayonCoeur);
        float ligne = 1.0 - smoothstep(0.0, 0.045, cel.x);
        float fissure = ligne * front;

        float pulsation = 0.6 + 0.4 * sin(t * (6.0 + uFissure * 14.0));
        float halo = (1.0 - smoothstep(0.0, 0.15, cel.x)) * front;
        float fuite = fissure * (0.55 + 0.45 * pulsation) + halo * 0.30 * uFissure;

        // ── composition ────────────────────────────────────────────────────
        couleur = uTeinte * (0.10 + 0.50 * diffus);
        couleur += uTeinte * 0.55 * appoint * 0.35;
        couleur += uTeinte * inclusions * 0.30;
        couleur += mix(uTeinte, vec3(1.0), 0.6) * fresnel * 0.85;
        couleur += vec3(1.0) * speculaire * 1.4;

        // Le cœur s'échauffe avant de céder — de la couleur de ce qu'il
        // contient, puisque c'est cette lumière-là qui va sortir.
        float coeur = smoothstep(1.1, 0.0, rayonCoeur) * uFissure;
        couleur += mix(uLueur, vec3(1.0), 0.6) * coeur * 0.9;

        // La lumière des fissures tire vers le blanc sans y aller tout à fait.
        // Une fracture qui reste franchement colorée a l'air peinte ; une qui
        // blanchit complètement a l'air d'une source, mais perd la couleur
        // qu'on tenait à montrer. À 55 % la teinte survit au cœur du trait et
        // le blanc ne prend que sur les bords surexposés.
        couleur += mix(uLueur * 1.7, vec3(1.7, 1.6, 1.45), 0.55) * fuite;

        alpha = 1.0;

        // ── éclatement ─────────────────────────────────────────────────────
        // Chaque cellule part avec son propre retard, sur une courbe qui
        // accélère puis freine : le mouvement d'un éclat projeté.
        float retard = hash(cel.yz);
        float depart = clamp((uEclat - retard * 0.4) / 0.6, 0.0, 1.0);
        float course = depart * depart * (3.0 - 2.0 * depart);
        // On ne déplace pas la géométrie — on efface le fragment en le
        // faisant fondre. Déplacer un volume raymarché par cellule
        // demanderait de marcher autant de fois qu'il y a de morceaux.
        couleur += vec3(1.0) * course * 0.6;
        alpha *= 1.0 - course;
    }

    // ── l'aura ─────────────────────────────────────────────────────────────
    // Une lueur derrière la pierre, qui enfle avec la fissuration. Elle vit
    // hors du volume : c'est elle qui fait que la lumière semble déborder de
    // l'objet.
    float distanceCentre = length(uv);
    float aura = exp(-distanceCentre * 2.6) * (0.10 + 0.55 * uFissure);
    float flash = smoothstep(0.0, 0.2, uEclat) * (1.0 - smoothstep(0.2, 0.75, uEclat));
    aura += exp(-distanceCentre * 1.4) * flash * 0.9;
    aura *= 1.0 - smoothstep(0.6, 1.0, uEclat);

    // L'aura passe de la couleur du corps à celle de la lueur à mesure que la
    // fracture avance : ce qui déborde de l'objet, c'est ce qui va en sortir.
    couleur += mix(mix(uTeinte, uLueur, uFissure), vec3(1.0), 0.35) * aura;
    alpha = clamp(alpha + aura, 0.0, 1.0);

    fragColor = vec4(couleur * alpha, alpha);
}
