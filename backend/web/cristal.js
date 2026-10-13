/*
 * Le cristal des succès, et sa rupture — version navigateur.
 *
 * Le même effet que dans l'application, rendu par le même shader : il n'en
 * existe qu'un, dans `app/assets/shaders/cristal.frag`, et `outils/shader_web.py`
 * en tire la copie que ce fichier charge. Écrire deux fois le même lancer de
 * rayon aurait garanti qu'ils divergent.
 *
 * **La chorégraphie**, identique à celle de Flutter, et sa durée relative fait
 * tout :
 *
 *   0 → 1,5 s    les fissures gagnent du cœur vers les pointes. C'est la partie
 *                longue, celle qu'on regarde. Précipitée, on ne voit rien.
 *   1,5 → 2,3 s  l'éclatement, puis la dissipation des fragments.
 *
 * Au repos le cristal respire seul et tourne sur lui-même : sans ce mouvement,
 * les facettes ne s'allument jamais l'une après l'autre et l'objet reste une
 * image.
 *
 * **Pourquoi WebGL et pas une suite d'images.** Les fissures doivent partir du
 * point qu'on a touché et suivre la forme en tournant. Une animation pré-rendue
 * ne le peut pas : il faudrait une planche par orientation. Ici c'est calculé
 * par pixel, à la volée.
 */
const Cristal = (() => {
  'use strict';

  // Le carré qui couvre l'écran. Deux triangles, quatre sommets : la
  // géométrie ne sert qu'à faire tourner le fragment shader sur chaque pixel.
  const SOMMETS = `#version 300 es
  in vec2 position;
  void main() { gl_Position = vec4(position, 0.0, 1.0); }`;

  let sourceFragment = null;

  async function chargeShader() {
    if (sourceFragment) return sourceFragment;
    const r = await fetch('media/cristal.frag');
    if (!r.ok) throw new Error('shader introuvable');
    sourceFragment = await r.text();
    return sourceFragment;
  }

  function compile(gl, type, source) {
    const s = gl.createShader(type);
    gl.shaderSource(s, source);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
      // On remonte le journal du pilote tel quel : c'est la seule chose qui
      // dise quelle ligne pose problème, et elle n'apparaît nulle part
      // ailleurs.
      const journal = gl.getShaderInfoLog(s);
      gl.deleteShader(s);
      throw new Error(`shader refusé : ${journal}`);
    }
    return s;
  }

  /* Une gemme qui tourne dans un canevas. Rend un objet qu'on pilote :
   * `.brise()` déclenche la rupture, `.arrete()` rend le contexte WebGL.
   *
   * `surFin` est appelé quand les fragments ont fini de se dissiper — c'est le
   * moment où le modèle 3D prend la place. */
  /* Un seul contexte WebGL, réutilisé.
   *
   * Un navigateur n'en accorde qu'une poignée — huit à seize selon les
   * appareils — et en réclamer un neuf à chaque ouverture finit par échouer :
   * `getContext` rend `null`, la gemme n'apparaît plus et on tombe droit sur le
   * repli, c'est-à-dire le modèle en grand sans animation. Le symptôme est
   * traître, puisque les premières fois marchent.
   *
   * On garde donc une toile hors document, on y dessine toujours, et on recopie
   * le résultat dans la toile visible du moment. Une copie de 420 px carrés par
   * trame ne coûte rien face au lancer de rayon lui-même.
   */
  let atelier = null;

  function contexte() {
    if (atelier) return atelier;
    const toile = document.createElement('canvas');
    const gl = toile.getContext('webgl2', {
      alpha: true, antialias: false, premultipliedAlpha: true,
      // Le tampon doit survivre à la trame : c'est lui qu'on recopie.
      preserveDrawingBuffer: true,
    });
    if (!gl) throw new Error('WebGL 2 indisponible');
    atelier = { toile, gl, prog: null };
    return atelier;
  }

  async function pose(toile, {
    teinte = [0.50, 0.83, 1.0],   // la matière : le corps de la grenouille
    lueur = [1.0, 0.82, 0.50],    // les fissures : sa couleur d'accent
    surFin = null,
  } = {}) {
    const atelier = contexte();
    const gl = atelier.gl;
    const vue = toile.getContext('2d');

    // Le programme est compilé une fois pour toutes : le shader ne change pas
    // d'une gemme à l'autre, seules ses couleurs changent.
    if (!atelier.prog) {
      const prog = gl.createProgram();
      gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, SOMMETS));
      gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, await chargeShader()));
      gl.linkProgram(prog);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
        throw new Error(`édition de liens : ${gl.getProgramInfoLog(prog)}`);
      }
      gl.useProgram(prog);

      const tampon = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, tampon);
      gl.bufferData(gl.ARRAY_BUFFER,
                    new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
      const pos = gl.getAttribLocation(prog, 'position');
      gl.enableVertexAttribArray(pos);
      gl.vertexAttribPointer(pos, 2, gl.FLOAT, false, 0, 0);

      // Le shader rend des couleurs déjà multipliées par l'alpha : sans ce
      // mélange-là, les bords de la gemme s'entourent d'un halo noir.
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      atelier.prog = prog;
    }
    const prog = atelier.prog;

    const u = {
      taille: gl.getUniformLocation(prog, 'uTaille'),
      temps: gl.getUniformLocation(prog, 'uTemps'),
      fissure: gl.getUniformLocation(prog, 'uFissure'),
      eclat: gl.getUniformLocation(prog, 'uEclat'),
      teinte: gl.getUniformLocation(prog, 'uTeinte'),
      lueur: gl.getUniformLocation(prog, 'uLueur'),
    };

    // La densité de l'écran est bornée à 2. Au-delà, un lancer de rayon à
    // soixante-quatre pas par pixel fait chauffer le téléphone sans rien
    // ajouter de visible.
    const densite = Math.min(devicePixelRatio || 1, 2);

    let debut = performance.now();
    let rupture = null;
    let vivant = true;
    let finAnnoncee = false;

    function dimensionne() {
      const c = Math.round(toile.clientWidth * densite);
      const h = Math.round(toile.clientHeight * densite);
      if (toile.width !== c || toile.height !== h) {
        toile.width = c;
        toile.height = h;
      }
      if (atelier.toile.width !== c || atelier.toile.height !== h) {
        atelier.toile.width = c;
        atelier.toile.height = h;
        gl.viewport(0, 0, c, h);
      }
    }

    function trame(maintenant) {
      // Le canevas retiré du document ne se redessine plus. C'est ce qui
      // arrête la boucle quand `dessine()` remplace la page sous nos pieds —
      // sans ça elle tournerait indéfiniment, invisible.
      if (!vivant || !toile.isConnected) { rend(); return; }

      dimensionne();
      const t = (maintenant - debut) / 1000;

      let fissure = 0;
      let eclat = 0;
      if (rupture !== null) {
        const depuis = (maintenant - rupture) / 1000;
        // Les fissures d'abord, seules : c'est le suspense. L'éclatement ne
        // commence qu'une fois la fracture arrivée au bord.
        fissure = Math.min(depuis / 1.5, 1);
        eclat = Math.min(Math.max((depuis - 1.5) / 0.8, 0), 1);
        if (depuis >= 2.3 && !finAnnoncee) { finAnnoncee = true; surFin?.(); }
      }

      gl.uniform2f(u.taille, toile.width, toile.height);
      gl.uniform1f(u.temps, t);
      gl.uniform1f(u.fissure, fissure);
      gl.uniform1f(u.eclat, eclat);
      gl.uniform3f(u.teinte, teinte[0], teinte[1], teinte[2]);
      gl.uniform3f(u.lueur, lueur[0], lueur[1], lueur[2]);

      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

      // On recopie l'atelier dans la toile visible.
      vue.clearRect(0, 0, toile.width, toile.height);
      vue.drawImage(atelier.toile, 0, 0);
      requestAnimationFrame(trame);
    }

    function rend() {
      // Le contexte, lui, n'est pas rendu : il est partagé et resservira à la
      // prochaine gemme. On arrête seulement la boucle.
      vivant = false;
    }

    requestAnimationFrame(trame);

    return {
      brise() { if (rupture === null) rupture = performance.now(); },
      brisee() { return rupture !== null; },
      arrete: rend,
    };
  }

  return { pose, chargeShader };
})();
