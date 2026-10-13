# Traductions · Translations

Biodex est écrit en français, et c'est le français qui sert de clé. Chaque
texte de l'interface — site, application Android, et ce que le serveur sert
comme données (succès, rangs) — est traduit à partir d'un seul fichier par
langue : `i18n/<code>.json`.

```json
{
  "Se connecter": "Sign in",
  "{0} photos situées.": "{0} photos located."
}
```

Les trous `{0}`, `{1}`… sont numérotés : une traduction peut les réordonner.
Un texte absent du dictionnaire s'affiche en français ; rien n'est jamais
remplacé par une clé technique.

## Ajouter une langue

1. Copier `en.json` en `<code>.json` (`de.json`, `es.json`…) et traduire les
   valeurs. `cles.json` liste tous les textes connus du code.
2. Déclarer la langue dans les deux sélecteurs :
   - site : `LANGUES` dans `backend/web/i18n.js` ;
   - application : `I18n.langues` dans `app/lib/i18n.dart`.
3. Lancer `python3 i18n/genere.py` : il distribue le dictionnaire au site
   (`backend/web/lang/`), au serveur (`backend/biodex/lang/`) et à
   l'application (`app/assets/lang/`).
4. `python3 i18n/genere.py --manquantes <code>` liste ce qui reste à traduire.

Le serveur n'a pas besoin de redémarrer pour un nouveau dictionnaire déjà
présent au lancement ; l'application doit être reconstruite (le dictionnaire
est embarqué).

## Ajouter un texte dans le code

Écrire le français, enveloppé :

- site : `t('Mon texte')`, ou `t('{0} photos', [n])` ;
- application : `T('Mon texte')`, ou `T('{0} photos', [n])` ;
- serveur, pour une donnée servie : `tr("Mon texte")` (`biodex/i18n.py`).

Les messages d'erreur du serveur ne passent pas par `tr` : ce sont les
clients qui les traduisent, avec le même dictionnaire.

Les scripts `extrait_web.py` et `extrait_dart.py` sont ceux qui ont enveloppé
le code existant ; ils servent à retrouver des textes oubliés, pas à relancer
sur du code déjà enveloppé.
