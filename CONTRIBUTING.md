# Contribuer à Biodex

Merci d'y penser. Quelques repères pour que ça se passe bien.

## Avant de coder

- Ouvrez une issue pour tout changement de comportement visible : c'est là
  qu'on se met d'accord sur le *quoi* avant le *comment*.
- Une correction de bug peut arriver directement en pull request, avec de
  quoi la reproduire.

## Le code

- **Serveur** : Python 3.12, FastAPI, SQLite. Tests avec `pytest` dans
  `backend/tests/`. Lancer `cd backend && .venv/bin/python -m pytest -q tests`.
- **Site** : JavaScript sans framework ni étape de compilation, dans
  `backend/web/`. Vérifier la syntaxe avec `node --check backend/web/*.js`.
- **Application** : Flutter. `flutter analyze` doit être vide, `flutter test`
  vert.
- Les commentaires expliquent le *pourquoi* — ce qui a été essayé, ce qui a
  cassé, pourquoi ce choix. Le *quoi* se lit dans le code.
- Les noms sont en français, comme le reste du projet. Les textes d'interface
  sont enveloppés pour la traduction : voir `i18n/README.md`.

## Les données

Ni base, ni photos, ni poids de modèles dans le dépôt — `.gitignore` les
refuse. Les catalogues se téléchargent depuis les releases ou se
reconstruisent avec les outils de `backend/outils/`.

## Une pull request

- Une intention par PR. Deux sujets, deux PR.
- Décrivez ce que ça change pour la personne qui utilise Biodex, pas
  seulement ce que ça change dans le code.
- Si ça touche le schéma SQLite, passez par une migration dans
  `backend/biodex/db.py` et faites monter `VERSION_SCHEMA`.
