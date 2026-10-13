#!/usr/bin/env python3
"""
Génère la page de documentation du site (docs/docs.html) à partir du README.

Le README est la source : cette page n'est qu'une mise en forme, avec un
sommaire collant à gauche, les captures en place et les liens vers les
fichiers du dépôt qui pointent sur GitHub. À relancer après chaque
modification du README :

    python3 docs/genere.py

Il faut le paquet `markdown` (dans le venv du serveur : backend/.venv).
"""
import html
import pathlib
import re
import sys

import markdown

RACINE = pathlib.Path(__file__).resolve().parent.parent
DEPOT = "https://github.com/Raaatus/BioDex"


def main() -> None:
    src = (RACINE / "README.md").read_text(encoding="utf-8")
    # Les captures vivent à côté de cette page, pas sous docs/.
    src = src.replace("docs/captures/", "captures/")
    # Les liens vers des fichiers du dépôt mènent à GitHub.
    src = re.sub(r"\]\(((?:backend|app|i18n|docs)/[^)]+|LICENSE|CONTRIBUTING\.md)\)",
                 lambda m: f"]({DEPOT}/blob/main/{m.group(1)})", src)

    md = markdown.Markdown(extensions=["tables", "fenced_code", "toc", "sane_lists", "md_in_html"],
                           extension_configs={"toc": {"anchorlink": False, "toc_depth": "2-3", "slugify": slug}})
    corps = md.convert(src)
    sommaire = []
    for t in md.toc_tokens:
        sommaire.append(f'<a href="#{t["id"]}">{html.escape(t["name"])}</a>')
        for s in t.get("children", []):
            sommaire.append(f'<a class="h3" href="#{s["id"]}">{html.escape(s["name"])}</a>')

    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Biodex — documentation</title>
<meta name="description" content="Biodex documentation: how it works, hosting your own server, the Android app, the web client on iPhone, configuration, upgrading, languages, data.">
<link rel="icon" href="icone.png">
<link rel="stylesheet" href="style.css">
</head>
<body>
<div class="page">
  <header class="barre">
    <div class="dedans">
      <a class="marque" href="./"><img src="icone.png" alt="">Biodex</a>
      <nav aria-label="Sections">
        <a href="./#fonctions">Features</a>
        <a href="./#captures">Screenshots</a>
        <a href="./#themes">Themes</a>
        <a href="./#telecharger">Download</a>
        <a class="actif" href="docs.html">Docs</a>
      </nav>
      <div class="actions">
        <button class="menu" aria-label="Menu" aria-expanded="false">☰</button>
        <a href="{DEPOT}" aria-label="GitHub"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>GitHub</a>
        <a class="cta" href="{DEPOT}/releases/latest">Get Biodex</a>
      </div>
      <div class="tiroir">
        <a href="./">Home</a>
        <a href="./#captures">Screenshots</a>
        <a href="./#telecharger">Download</a>
        <a class="actif" href="docs.html">Documentation</a>
        <a href="{DEPOT}">GitHub</a>
      </div>
    </div>
  </header>
  <div class="doc">
    <aside>
      <input type="search" placeholder="Filter sections…" aria-label="Filter sections">
      {''.join(sommaire)}
      <a href="{DEPOT}/edit/main/README.md" style="margin-top:14px;color:var(--accent)">✎ Edit this page on GitHub</a>
    </aside>
    <article class="prose">
{corps}
    </article>
  </div>
</div>
<footer><div class="bas">Generated from <a href="{DEPOT}/blob/main/README.md">README.md</a> by <code>docs/genere.py</code>. Biodex is released under the MIT licence.</div></footer>
<script src="fond.js"></script>
<script src="site.js"></script>
</body>
</html>
"""
    (RACINE / "docs" / "docs.html").write_text(page, encoding="utf-8")
    print(f"docs/docs.html : {len(sommaire)} entrées de sommaire, {len(page) // 1024} Ko")


def slug(valeur: str, separateur: str) -> str:
    """Les mêmes ancres que GitHub, pour que les liens du README tiennent."""
    v = valeur.strip().lower()
    v = re.sub(r"[^\w\s-]", "", v)
    return re.sub(r"\s+", "-", v)


if __name__ == "__main__":
    sys.exit(main())
