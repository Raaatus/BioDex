#!/usr/bin/env python3
"""
Enveloppe les textes de l'application Flutter dans T(…).

Les chaînes Dart à guillemets simples ou doubles qui ont l'air d'un texte
humain deviennent T('…') ; celles qui interpolent ($x, ${expr}) deviennent
T('… {0} …', [x, expr]). Les `const` que ça invalide sont retirés après coup
par le correcteur, à partir des messages de l'analyseur.

Usage : i18n_dart.py lib/ [--cles cles.json]
"""
import json
import pathlib
import re
import sys

CLES = []
EXCLUS = {"Bearer", "Authorization", "Content-Type", "Accept", "Accept-Language", "GET", "POST", "PUT", "DELETE",
          "PATCH", "Biodex", "Pl@ntNet", "OpenStreetMap", "Esri", "Material", "Roboto", "monospace", "serif"}
# Après quoi une chaîne est du code, pas du texte.
CONTEXTE_CODE = re.compile(
    r"(get|post|put|delete|patch|supprime|image|Uri\.parse|parse|getString|getBool|getInt|setString|setBool|setInt|"
    r"remove|containsKey|RegExp|case|import|export|part|fontFamily:|fontFamily =|family:|package:|asset:|"
    r"AssetImage|Image\.asset|rootBundle\.load\w*|switch|headers|\.contains|\.startsWith|\.endsWith|\.split|"
    r"\.replaceAll|\.replaceFirst|\.indexOf|\[|key:|name:|album:|tag:|value:|route:|\?\s*|:\s*|==\s*|!=\s*|"
    r"\{\s*|,\s*|\(\s*)$")


def texte_humain(s):
    nu = re.sub(r"\{\d+\}", "", s)
    if not re.search(r"[A-Za-zÀ-ÿ]{2}", nu):
        return False
    if s in EXCLUS:
        return False
    if re.match(r"^(/|#|\.|--|http|data:|\d|assets/|lib/|package:)", s):
        return False
    if "<" in s or ("/" in s and " " not in s):
        return False
    if re.match(r"^[a-z0-9_\-:./,%+*]+$", nu):
        return False
    if re.match(r"^[A-Z_0-9]+$", nu):
        return False
    if re.match(r"^[A-Za-z]*[a-z][A-Z][A-Za-z]*$", nu):
        return False
    if re.search(r"[A-Za-z\]}]=[\"'\w{;]", s):
        return False
    if re.match(r"^[\w.]+\(.*\)$", s):
        return False
    return bool(" " in nu or re.search(r"[À-ÿ…?!.:·,’()]", nu)
                or re.match(r"^[A-Z][a-zà-ÿ]{2,}$", nu) or len(nu) >= 6)


def cle_pour(k):
    if k not in CLES:
        CLES.append(k)
    return k


def dart_chaine(k):
    return "'" + k.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$").replace("\n", "\\n") + "'"


def fusionne_adjacentes(src):
    """Dart concatène les chaînes adjacentes : `'a ' 'b'` vaut `'a b'`. On les
    fusionne avant d'extraire, sinon chaque bout devient une clé à part et la
    phrase n'est plus traduisible d'un bloc."""
    motif = re.compile(r"'((?:[^'\\\n]|\\.)*)'[ \t]*\n[ \t]*'((?:[^'\\\n]|\\.)*)'")
    while True:
        nouveau = motif.sub(lambda m: "'" + m.group(1) + m.group(2) + "'", src)
        if nouveau == src:
            return src
        src = nouveau


def transforme(src):
    src = fusionne_adjacentes(src)
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i); j = n if j < 0 else j
            out.append(src[i:j]); i = j; continue
        if src.startswith("/*", i):
            j = src.find("*/", i); j = n if j < 0 else j + 2
            out.append(src[i:j]); i = j; continue
        # chaîne brute r'…' : jamais du texte
        if c == "r" and i + 1 < n and src[i + 1] in "'\"" and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] == "_")):
            q = src[i + 1]
            j = i + 2
            while j < n and src[j] != q:
                j += 1
            out.append(src[i:j + 1]); i = j + 1; continue
        if c in "'\"":
            if src.startswith(c * 3, i):
                # chaîne triple : recopiée telle quelle
                j = src.find(c * 3, i + 3); j = n if j < 0 else j + 3
                out.append(src[i:j]); i = j; continue
            # lire la chaîne, en notant les interpolations
            j = i + 1
            morceaux = []   # ('t', texte) | ('e', code)
            buf = []
            while j < n and src[j] != c:
                if src[j] == "\\":
                    buf.append(src[j:j + 2]); j += 2; continue
                if src[j] == "$":
                    if j + 1 < n and src[j + 1] == "{":
                        morceaux.append(("t", "".join(buf))); buf = []
                        prof = 1; k = j + 2
                        while k < n and prof:
                            if src[k] == "{": prof += 1
                            elif src[k] == "}": prof -= 1
                            elif src[k] in "'\"":
                                # chaîne imbriquée dans l'expression
                                q = src[k]; k += 1
                                while k < n and src[k] != q:
                                    if src[k] == "\\": k += 1
                                    k += 1
                            k += 1
                        morceaux.append(("e", src[j + 2:k - 1])); j = k; continue
                    m = re.match(r"\$([A-Za-z_]\w*)", src[j:])
                    if m:
                        morceaux.append(("t", "".join(buf))); buf = []
                        morceaux.append(("e", m.group(1))); j += m.end(); continue
                if src[j] == "\n":
                    break
                buf.append(src[j]); j += 1
            morceaux.append(("t", "".join(buf)))
            brut = src[i:j + 1]
            avant = "".join(out)[-60:]
            # Une chaîne qui suit directement une autre (adjacente) : on la
            # traite séparément, c'est le cas des longs textes coupés.
            exprs = []
            parts = []
            for g, v in morceaux:
                if g == "t":
                    parts.append(v.replace("\\'", "'").replace('\\"', '"').replace("\\$", "$"))
                else:
                    parts.append("{" + str(len(exprs)) + "}"); exprs.append(v)
            cle = "".join(parts)
            code_autour = bool(CONTEXTE_CODE.search(avant.rstrip())) and not re.search(r"(Text|TextSpan|SnackBar|Tooltip|Tab|title|label|hint|helper|content|message|texte|titre|detail|nom|child)\s*(:|\()\s*(const\s+)?(Text\()?\s*$", avant.rstrip())
            # `:` en fin de contexte : valeur d'un paramètre nommé (texte probable)
            # ou clé/valeur de map. On tranche sur le nom du paramètre.
            if re.search(r"\b(title|label|labelText|hintText|helperText|tooltip|semanticsLabel|content|text|message|subtitle|detail|nom|texte|titre|prefixText|suffixText|errorText|counterText|value|album)\s*:\s*(const\s+)?(Text\(|TextSpan\(text:\s*)?$", avant.rstrip()):
                code_autour = False
            # Un `case 'x':` ou une clé de map `'x':` : du code.
            apres = src[j + 1:j + 3]
            if re.match(r"\s*:", apres) and not re.search(r"\?[^:]*$", avant):
                code_autour = True
            if texte_humain(cle) and not code_autour and "\n" not in cle:
                cle_pour(cle)
                if exprs:
                    out.append("T(" + dart_chaine(cle) + ", [" + ", ".join(exprs) + "])")
                else:
                    out.append("T(" + dart_chaine(cle) + ")")
            else:
                out.append(brut)
            i = j + 1
            continue
        out.append(c); i += 1
    return "".join(out)


def main():
    racine = pathlib.Path(sys.argv[1])
    for f in sorted(racine.rglob("*.dart")):
        if f.name in ("i18n.dart",):
            continue
        src = f.read_text(encoding="utf-8")
        nouveau = transforme(src)
        if nouveau != src:
            if "import '" in nouveau and "i18n.dart" not in nouveau:
                rel = "../" * (len(f.relative_to(racine).parts) - 1) + "i18n.dart"
                nouveau = re.sub(r"^(import '[^']*';\n)", lambda m: m.group(1) + f"import '{rel}';\n", nouveau, count=1, flags=re.M)
            f.write_text(nouveau, encoding="utf-8")
    if "--cles" in sys.argv:
        open(sys.argv[sys.argv.index("--cles") + 1], "w", encoding="utf-8").write(json.dumps(CLES, ensure_ascii=False, indent=0))
    print(f"{len(CLES)} clés")


if __name__ == "__main__":
    main()
