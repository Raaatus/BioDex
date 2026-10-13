"""
Qui a le droit de voir quelle photo, et à qui une photo appartient.

Ces deux questions se posaient dans quatre fichiers, avec quatre copies de la
même condition SQL. Tant qu'une photo n'avait qu'un propriétaire, les copies
restaient identiques par chance. Les photos co-signées ont changé ça : une
capture compte désormais pour son auteur **et** pour les amis qu'il a
identifiés dessus, et une copie oubliée aurait rendu la photo invisible dans un
écran sur quatre, sans erreur ni message.

Les fragments prennent leur alias en argument plutôt que de figer « c. » : une
même requête joint parfois deux tables de captures, et réécrire le SQL par
substitution de texte se corromprait le jour où une colonne s'appellera
`calc.`.

Le paramètre nommé, lui, est toujours `:u` — sauf mention contraire — et
désigne **celui qui regarde**.
"""


# Quand une photo a été prise.
#
# L'heure de prise de vue quand on la connaît, sinon celle de l'envoi. La
# définition vivait dans `galerie.py` ; elle est remontée ici parce que trois
# écrans en dépendent désormais, et que deux définitions divergentes de « quand »
# feraient dire à la carte et aux succès des choses différentes de la même photo.
QUAND = "COALESCE(c.prise_le, c.cree_le)"


def sienne(alias: str = "c", qui: str = "u") -> str:
    """La photo compte-t-elle pour ce joueur ?

    Vrai s'il l'a prise, ou si quelqu'un l'a identifié dessus. C'est la
    définition qui vaut pour le dex, les points et « mes photos » : les deux
    personnes qui ont vu le même renard le comptent chacune une fois.
    """
    return f"""({alias}.utilisateur = :{qui}
                OR EXISTS (SELECT 1 FROM participants pa
                            WHERE pa.capture = {alias}.id
                              AND pa.utilisateur = :{qui}))"""


def amis(alias: str = "c", qui: str = "u") -> str:
    """`alias.utilisateur` est-il un ami accepté de `:qui` ?"""
    return f"""EXISTS (SELECT 1 FROM amities a
                        WHERE a.etat = 'acceptee'
                          AND ((a.demandeur = :{qui} AND a.destinataire = {alias}.utilisateur)
                            OR (a.destinataire = :{qui} AND a.demandeur = {alias}.utilisateur)))"""


def visible(alias: str = "c", qui: str = "u") -> str:
    """Ai-je le droit de voir cette photo ?

    Trois portes : elle est à moi, je suis identifié dessus, ou un ami l'a
    partagée. La deuxième est indispensable — sans elle, une photo sur laquelle
    un ami m'identifie m'ouvrirait une case du dex que je ne pourrais pas
    regarder.

    Le partage d'un ami ne se juge que sur l'auteur, pas sur les participants :
    c'est l'auteur qui possède le fichier et décide s'il sort de chez lui.
    """
    return f"""({sienne(alias, qui)}
                OR ({alias}.partage = 1 AND {amis(alias, qui)}))"""
