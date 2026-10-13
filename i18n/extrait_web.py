#!/usr/bin/env python3
"""
Extrait et enveloppe les textes du site dans t(…).

Un analyseur à la main, caractère par caractère, qui distingue le code, les
chaînes, les gabarits (avec leurs ${…} imbriqués), les commentaires et les
regex. Dans un gabarit HTML, les « runs » de texte — entre > et <, et dans
title/placeholder/aria-label/alt — deviennent ${t('…', [expr…])}, les
expressions prenant la place de {0}, {1}… Les chaînes JS ordinaires qui ont
l'air d'un texte humain deviennent t('…').

Usage : i18n_web.py fichier.js [--cles cles.txt] [--sortie fichier]
"""
import json
import re
import sys

ATTRS = ("title", "placeholder", "aria-label", "alt", "label")
EXCLUS = {"Bearer", "Authorization", "Content-Type", "Accept", "Accept-Language", "GET", "POST", "PUT",
          "DELETE", "PATCH", "HEAD", "Escape", "Enter", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
          "Leaflet", "OpenStreetMap", "Esri", "Satellite", "Pl@ntNet"}
CONTEXTES_CODE = re.compile(
    r"(appel|getItem|setItem|removeItem|querySelector|querySelectorAll|getElementById|closest|matches|"
    r"addEventListener|removeEventListener|createElement|matchMedia|getPropertyValue|setProperty|"
    r"URLSearchParams|append|get|set|has|delete|includes|startsWith|endsWith|split|join|replace|"
    r"indexOf|classList\.(add|remove|toggle|contains)|dataset\.\w+\s*=|fetch|open|localStorage|"
    r"sessionStorage|new Date|getContext|setAttribute|getAttribute|hasAttribute|style\.\w+\s*=|"
    r"Intl\.\w+|toLocale\w+|RegExp|require|import|from|case|typeof|instanceof|history\.\w+|"
    r"location\.\w+\s*=|cssText\s*=|font\s*=|textContent\s*=|className\s*=|id\s*=|type\s*=|"
    r"name\s*=|method:|headers|key:|cle:|vue:|couche:|mode:|regne:|qui:|tri:|etat:|role:|"
    r"data-[\w-]+=|=\s*|\|\|\s*|\?\?\s*)\s*\(?\s*$")
CLES = []


def texte_humain(s, strict=True):
    if not re.search(r"[A-Za-zÀ-ÿ]{2}", s):
        return False
    if not strict:
        return True
    if s in EXCLUS:
        return False
    if re.match(r"^(/|#|\.|--|http|data:|rgba?\(|hsl|url\(|\d)", s):
        return False
    if re.match(r"^[a-z0-9_\-:./,%+*]+$", s):          # identifiant, clé, unité
        return False
    if re.match(r"^[A-Z_0-9]+$", s):                    # CONSTANTE
        return False
    if re.match(r"^[A-Za-z]*[a-z][A-Z][A-Za-z]*$", s):  # camelCase
        return False
    if re.match(r"^[a-z]+[A-Za-z]*\.[a-z]+$", s):       # a.b
        return False
    if re.search(r"[A-Za-z\]}]=[\"'\w{;]", s):                  # style="…", min="{0}", cookies
        return False
    if re.match(r"^[\w.]+\(.*\)$", s) or re.match(r"^&\w+;$", s): # un appel, une entité
        return False
    if re.match(r"^[?/#&]", s) or s.startswith("{0}api") or s.startswith("Bearer"):
        return False
    if "<" in s or ("/" in s and " " not in s):                   # du HTML nu, une adresse
        return False
    if re.match(r"^(belle q|flux )", s):                            # une classe CSS, un journal
        return False
    # Un texte : des mots séparés, des accents, de la ponctuation de phrase, un
    # mot capitalisé, ou un mot assez long pour n'être pas une clé.
    return bool(" " in s or re.search(r"[À-ÿ…?!.:·,’()]", s)
                or re.match(r"^[A-Z][a-zà-ÿ]{2,}$", s) or len(s) >= 6)


def cle_pour(texte):
    """Normalise les blancs d'un run HTML ; enregistre la clé."""
    k = re.sub(r"\s+", " ", texte).strip()
    if k not in CLES:
        CLES.append(k)
    return k


def js_chaine(k):
    return "'" + k.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n") + "'"


class Lecteur:
    def __init__(self, src):
        self.s = src
        self.i = 0

    def fin(self):
        return self.i >= len(self.s)


def process_code(src, arret=None):
    """Transforme du code JS jusqu'à `arret` ('}' fermant une expression de
    gabarit, compté par profondeur) ; rend (nouveau code, position)."""
    out = []
    i = 0
    n = len(src)
    prof = 0
    while i < n:
        c = src[i]
        # commentaires
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(src[i:j]); i = j; continue
        if src.startswith("/*", i):
            j = src.find("*/", i)
            j = n if j < 0 else j + 2
            out.append(src[i:j]); i = j; continue
        if c in "'\"":
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == "\\":
                    j += 1
                if src[j] == "\n":
                    break
                j += 1
            contenu = src[i + 1:j]
            avant = "".join(out)[-80:]
            apres = src[j + 1:j + 3]
            if "<" in contenu and ">" in contenu and re.search(r"[A-Za-zÀ-ÿ]{2}", re.sub(r"<[^>]*>", "", contenu)):
                brut = contenu.replace("\\'", "'").replace("\\\"", '"')
                out.append("`" + reecrit_gabarit([("t", brut.replace("`", "\\`"))]) + "`")
                i = j + 1
                continue
            if (texte_humain(contenu.replace("\\'", "'"), strict=True)
                    and not CONTEXTES_CODE.search(avant)
                    and not re.match(r"\s*:", apres)
                    and not re.search(r"\[\s*['\"]?[\w$]*$", avant.rstrip())
                    and not avant.rstrip().endswith("[")):
                k = cle_pour(contenu.replace("\\'", "'").replace("\\\"", '"'))
                out.append("t(" + js_chaine(k) + ")")
            else:
                out.append(src[i:j + 1])
            i = j + 1
            continue
        if c == "`":
            avant = "".join(out)[-80:]
            nouveau, j = process_template(src, i + 1, code_autour=bool(CONTEXTES_CODE.search(avant)))
            out.append(nouveau)
            i = j
            continue
        if c == "/" and re.search(r"[(,=:;!&|?{}\[]\s*$|return\s*$|^\s*$", "".join(out)[-20:]):
            # une regex : on la recopie telle quelle
            j = i + 1
            while j < n and src[j] != "/":
                if src[j] == "\\":
                    j += 1
                if src[j] == "[":
                    k2 = src.find("]", j)
                    j = k2 if k2 > 0 else j
                j += 1
            j += 1
            while j < n and src[j].isalpha():
                j += 1
            out.append(src[i:j]); i = j; continue
        if arret is not None:
            if c == "{":
                prof += 1
            elif c == "}":
                if prof == 0:
                    return "".join(out), i
                prof -= 1
        out.append(c)
        i += 1
    return "".join(out), i


def process_template(src, i, code_autour=False):
    """Depuis le caractère après le backtick ouvrant ; rend (code, position
    après le backtick fermant). Le gabarit est réécrit avec t(…)."""
    segments = []   # ('t', texte) | ('e', code)
    n = len(src)
    buf = []
    while i < n:
        c = src[i]
        if c == "\\":
            buf.append(src[i:i + 2]); i += 2; continue
        if c == "`":
            segments.append(("t", "".join(buf)))
            i += 1
            break
        if src.startswith("${", i):
            segments.append(("t", "".join(buf))); buf = []
            code, j = process_code(src[i + 2:], arret="}")
            segments.append(("e", code))
            i = i + 2 + j + 1
            continue
        buf.append(c); i += 1
    return "`" + reecrit_gabarit(segments, code_autour) + "`", i


def reecrit_gabarit(segments, code_autour=False):
    # Une seule chaîne avec des sentinelles pour les expressions.
    exprs = []
    parts = []
    for genre, v in segments:
        if genre == "t":
            parts.append(v)
        else:
            parts.append(f"\x00{len(exprs)}\x00")
            exprs.append(v)
    s = "".join(parts)
    html = "<" in s and ">" in s
    sortie = []
    if html:
        # Parcours : on repère les runs entre > et <, et les attributs texte.
        i = 0
        while i < len(s):
            if s[i] == "<":
                # dans une balise : jusqu'au > correspondant (hors sentinelles)
                j = i + 1
                while j < len(s) and s[j] != ">":
                    j += 1
                balise = s[i:j + 1]
                sortie.append(reecrit_attributs(balise, exprs))
                i = j + 1
            else:
                j = s.find("<", i)
                j = len(s) if j < 0 else j
                sortie.append(reecrit_run(s[i:j], exprs))
                i = j
    else:
        # Un gabarit sans HTML : seulement s'il a l'air d'un texte, et pas d'une
        # adresse, d'une clé ou d'un bout de code.
        nu = re.sub("\x00\\d+\x00", "{0}", s)
        if code_autour or not texte_humain(nu, strict=True):
            sortie.append(s)
        else:
            sortie.append(reecrit_run(s, exprs))
    res = "".join(sortie)
    # Remettre les expressions non consommées.
    def remet(m):
        return "${" + exprs[int(m.group(1))] + "}"
    return re.sub("\x00(\\d+)\x00", remet, res)


def reecrit_attributs(balise, exprs):
    def rempl(m):
        nom, val = m.group(1), m.group(2)
        return f'{nom}="{reecrit_run(val, exprs, attribut=True)}"'
    return re.sub(r'\b(' + "|".join(ATTRS) + r')="([^"]*)"', rempl, balise)


def reecrit_run(run, exprs, attribut=False):
    # Le texte, sans les sentinelles, doit avoir des lettres.
    texte_seul = re.sub("\x00\\d+\x00", "", run)
    if not re.search(r"[A-Za-zÀ-ÿ]{2}", texte_seul):
        return run
    if "&nbsp;" in run and not re.search(r"[A-Za-zÀ-ÿ]{2}", texte_seul.replace("&nbsp;", "")):
        return run
    # Les blancs de bord restent dehors.
    m = re.match(r"^(\s*)(.*?)(\s*)$", run, re.S)
    gauche, coeur, droite = m.group(1), m.group(2), m.group(3)
    if attribut:
        gauche, droite = "", ""
        coeur = run
    # Les sentinelles deviennent {k}, dans l'ordre d'apparition.
    utilisees = []
    def sent(mm):
        idx = int(mm.group(1))
        if idx not in utilisees:
            utilisees.append(idx)
        return "{" + str(utilisees.index(idx)) + "}"
    cle = re.sub("\x00(\\d+)\x00", sent, coeur)
    cle = cle_pour(cle)
    args = ""
    if utilisees:
        args = ", [" + ", ".join(exprs[k] for k in utilisees) + "]"
    return f"{gauche}${{t({js_chaine(cle)}{args})}}{droite}"


def main():
    chemin = sys.argv[1]
    src = open(chemin, encoding="utf-8").read()
    nouveau, _ = process_code(src)
    sortie = chemin
    if "--sortie" in sys.argv:
        sortie = sys.argv[sys.argv.index("--sortie") + 1]
    open(sortie, "w", encoding="utf-8").write(nouveau)
    if "--cles" in sys.argv:
        open(sys.argv[sys.argv.index("--cles") + 1], "w", encoding="utf-8").write(
            json.dumps(CLES, ensure_ascii=False, indent=0))
    print(f"{len(CLES)} clés")


if __name__ == "__main__":
    main()
