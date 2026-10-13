"""
Tests d'intégration de l'API, moteur débranché.

Chaque exécution part d'une base neuve dans un dossier temporaire : les tests ne
touchent jamais aux données de développement. Le dex y est réduit à quelques
cases fabriquées à la main, ce qui suffit à vérifier les parcours.
"""
import io
import os
import pathlib
import sys
import tempfile

import pytest

_tmp = tempfile.mkdtemp(prefix="biodex-tests-")
os.environ["BIODEX_DONNEES"] = _tmp
os.environ["BIODEX_SANS_MOTEUR"] = "1"

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from fastapi.testclient import TestClient  # noqa: E402

from biodex import db  # noqa: E402
from biodex.main import app  # noqa: E402


def _photo(couleur=(120, 160, 90), taille=(640, 480)) -> bytes:
    from PIL import Image
    tampon = io.BytesIO()
    Image.new("RGB", taille, couleur).save(tampon, "JPEG")
    return tampon.getvalue()


def _photo_heic(taille=(640, 480)) -> bytes | None:
    """Une photo au format des iPhone. None si l'encodeur manque."""
    from PIL import Image
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()
    except Exception:
        return None
    tampon = io.BytesIO()
    try:
        Image.new("RGB", taille, (120, 160, 90)).save(tampon, "HEIF")
    except Exception:
        return None
    return tampon.getvalue()


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        # Un dex minuscule mais réaliste : deux cases, dont une qui regroupe
        # plusieurs noms latins comme le fait le vrai regroupement.
        with db.transaction() as cx:
            cx.execute(
                """INSERT INTO cases (cle_gbif, latin, nom_fr, genre, famille, classe,
                                      obs, rarete, nb_alias)
                   VALUES (2441022, 'Bos taurus', 'Vache', 'Bos', 'Bovidae', 'Mammalia',
                           49553, 3, 3)""")
            cx.execute(
                """INSERT INTO cases (cle_gbif, latin, nom_fr, genre, famille, classe,
                                      obs, rarete, nb_alias)
                   VALUES (2492575, 'Cyanistes caeruleus', 'Mésange bleue', 'Cyanistes',
                           'Paridae', 'Aves', 11140558, 1, 2)""")
            cx.executemany(
                "INSERT INTO alias (latin, case_id, accepte) SELECT ?, id, ? FROM cases WHERE cle_gbif = ?",
                [("Bos taurus", 1, 2441022), ("Bos indicus", 0, 2441022),
                 ("Bos primigenius", 0, 2441022),
                 ("Cyanistes caeruleus", 1, 2492575), ("Parus caeruleus", 0, 2492575)])
        yield c


def entete(jeton: str) -> dict:
    return {"Authorization": f"Bearer {jeton}"}


# ------------------------------------------------------------------- comptes

def test_inscription_puis_moi(client):
    r = client.post("/inscription", json={"pseudo": "Loutre", "mdp": "motdepasse1"})
    assert r.status_code == 201, r.text
    d = r.json()
    assert d["pseudo"] == "Loutre" and d["jeton"]
    assert d["cases"] == 0 and d["captures"] == 0

    r = client.get("/moi", headers=entete(d["jeton"]))
    assert r.status_code == 200 and r.json()["pseudo"] == "Loutre"


def test_pseudo_deja_pris_meme_a_la_casse_pres(client):
    client.post("/inscription", json={"pseudo": "Doublon", "mdp": "motdepasse1"})
    r = client.post("/inscription", json={"pseudo": "doublon", "mdp": "autrepasse2"})
    assert r.status_code == 409


def test_connexion_refuse_le_mauvais_mot_de_passe(client):
    client.post("/inscription", json={"pseudo": "Bidule", "mdp": "motdepasse1"})
    assert client.post("/connexion", json={"pseudo": "Bidule", "mdp": "faux"}).status_code == 401
    r = client.post("/connexion", json={"pseudo": "bidule", "mdp": "motdepasse1"})
    assert r.status_code == 200 and r.json()["jeton"]


def test_pseudo_inexistant_repond_comme_un_mauvais_mot_de_passe(client):
    """Sinon on saurait quels pseudos existent en lisant le code de retour."""
    r = client.post("/connexion", json={"pseudo": "PersonneIci", "mdp": "motdepasse1"})
    assert r.status_code == 401


def test_sans_jeton_c_est_401(client):
    assert client.get("/moi").status_code == 401
    assert client.get("/moi", headers=entete("nimportequoi")).status_code == 401


def test_changement_de_mdp_invalide_les_sessions(client):
    j = client.post("/inscription", json={"pseudo": "Tournant", "mdp": "motdepasse1"}).json()["jeton"]
    r = client.post("/moi/mot-de-passe", headers=entete(j),
                    json={"ancien": "motdepasse1", "nouveau": "nouveaupasse2"})
    assert r.status_code == 204
    assert client.get("/moi", headers=entete(j)).status_code == 401
    assert client.post("/connexion",
                       json={"pseudo": "Tournant", "mdp": "nouveaupasse2"}).status_code == 200


# ----------------------------------------------------------------------- dex

def test_grille_triee_du_plus_commun_au_plus_rare(client):
    j = client.post("/inscription", json={"pseudo": "Grille", "mdp": "motdepasse1"}).json()["jeton"]
    d = client.get("/dex", headers=entete(j)).json()
    noms = [c["nom"] for c in d["cases"]]
    assert noms == ["Mésange bleue", "Vache"]      # 11 M d'observations avant 49 k
    assert all(c["decouvert"] is False for c in d["cases"])


def test_recherche_par_synonyme(client):
    """« zebu » n'est pas un nom de case, mais un alias : il doit ramener Vache."""
    j = client.post("/inscription", json={"pseudo": "Chercheur", "mdp": "motdepasse1"}).json()["jeton"]
    d = client.get("/dex", params={"q": "Bos indicus"}, headers=entete(j)).json()
    assert [c["nom"] for c in d["cases"]] == ["Vache"]


def test_filtres_et_resume(client):
    j = client.post("/inscription", json={"pseudo": "Filtre", "mdp": "motdepasse1"}).json()["jeton"]
    d = client.get("/dex", params={"classe": "Aves"}, headers=entete(j)).json()
    assert [c["nom"] for c in d["cases"]] == ["Mésange bleue"]

    d = client.get("/dex", params={"etat": "manquant"}, headers=entete(j)).json()
    assert len(d["cases"]) == 2

    r = client.get("/dex/resume", headers=entete(j)).json()
    assert r["total"] == 2 and r["trouve"] == 0
    assert {g["classe"] for g in r["classes"]} == {"Aves", "Mammalia"}


def test_detail_de_case_liste_les_alias(client):
    j = client.post("/inscription", json={"pseudo": "Detail", "mdp": "motdepasse1"}).json()["jeton"]
    d = client.get("/dex/1", headers=entete(j)).json()
    assert d["nom"] == "Vache"
    assert set(d["alias"]) == {"Bos taurus", "Bos indicus", "Bos primigenius"}
    assert d["captures"] == []


# ------------------------------------------------------------------ captures

def test_depot_photo_met_en_file(client):
    j = client.post("/inscription", json={"pseudo": "Photographe", "mdp": "motdepasse1"}).json()["jeton"]
    r = client.post("/captures", headers=entete(j),
                    files={"photo": ("test.jpg", _photo(), "image/jpeg")},
                    data={"lat": "48.85", "lon": "2.35"})
    assert r.status_code == 202, r.text
    d = r.json()
    assert d["etat"] == "attente" and d["lat"] == 48.85

    # La photo et sa vignette sont servies, et l'orientation a été appliquée.
    assert client.get(f"/captures/{d['id']}/photo", headers=entete(j)).status_code == 200
    assert client.get(f"/captures/{d['id']}/vignette", headers=entete(j)).status_code == 200


def test_fichier_non_image_refuse(client):
    j = client.post("/inscription", json={"pseudo": "Malin", "mdp": "motdepasse1"}).json()["jeton"]
    r = client.post("/captures", headers=entete(j),
                    files={"photo": ("faux.jpg", b"ceci n'est pas une image", "image/jpeg")})
    assert r.status_code == 400


def test_photo_heic_iphone_acceptee(client):
    """Le format que produit l'appareil photo des iPhone depuis iOS 11.

    Safari convertit en JPEG quand la photo passe par le sélecteur de photos,
    mais pas quand elle vient de Fichiers, d'un album partagé ou d'AirDrop : le
    HEIC arrive alors tel quel. Sans le décodeur, il repartait en 400.
    """
    blob = _photo_heic()
    if blob is None:
        pytest.skip("pillow-heif absent : pas d'encodeur HEIC pour le test")

    j = client.post("/inscription",
                    json={"pseudo": "Pomme", "mdp": "motdepasse1"}).json()["jeton"]
    r = client.post("/captures", headers=entete(j),
                    files={"photo": ("IMG_0042.HEIC", blob, "image/heic")})
    assert r.status_code == 202, r.text

    # Et elle est rangée en JPEG, comme n'importe quelle autre photo : rien en
    # aval n'a besoin de savoir d'où elle vient.
    from PIL import Image
    from biodex import config
    d = client.get(f"/captures/{r.json()['id']}", headers=entete(j)).json()
    assert d["vignette"]
    with Image.open(next(config.VIGNETTES.glob("*.jpg"))) as im:
        assert im.format == "JPEG"


def test_capture_d_un_autre_est_inaccessible(client):
    a = client.post("/inscription", json={"pseudo": "Alice", "mdp": "motdepasse1"}).json()["jeton"]
    b = client.post("/inscription", json={"pseudo": "Bob", "mdp": "motdepasse1"}).json()["jeton"]
    cid = client.post("/captures", headers=entete(a),
                      files={"photo": ("a.jpg", _photo(), "image/jpeg")}).json()["id"]
    assert client.get(f"/captures/{cid}", headers=entete(b)).status_code == 403
    assert client.get(f"/captures/{cid}/photo", headers=entete(b)).status_code == 403


def test_decouverte_apres_analyse(client):
    """On simule le verdict du moteur pour vérifier que la case se remplit."""
    from biodex.moteur import Resultat, file as file_moteur

    j = client.post("/inscription", json={"pseudo": "Veinard", "mdp": "motdepasse1"}).json()["jeton"]
    uid = client.get("/moi", headers=entete(j)).json()["id"]
    cid = client.post("/captures", headers=entete(j),
                      files={"photo": ("vache.jpg", _photo(), "image/jpeg")}).json()["id"]

    file_moteur._enregistre(cid, uid, Resultat(
        etat="ok", verdict="Vache", latin="Bos taurus", niveau="espece",
        confiance=0.93, case_id=1, duree=15.7,
        # Les pistes sont au niveau case : (case_id, latin, proba).
        top=[(1, "Bos taurus", 0.71), (2, "Bos indicus", 0.19)]))

    d = client.get(f"/captures/{cid}", headers=entete(j)).json()
    assert d["etat"] == "ok" and d["verdict"] == "Vache"
    assert [t["latin"] for t in d["top"]] == ["Bos taurus", "Bos indicus"]
    # Chaque piste porte sa case : c'est ce qui la rend choisissable d'un appui.
    assert [t["case_id"] for t in d["top"]] == [1, 2]

    case = client.get("/dex/1", headers=entete(j)).json()
    assert case["decouvert"] is True and case["nb_captures"] == 1
    assert len(case["captures"]) == 1

    assert client.get("/dex/resume", headers=entete(j)).json()["trouve"] == 1

    # Une deuxième vache va dans la même case, sans créer de doublon.
    cid2 = client.post("/captures", headers=entete(j),
                       files={"photo": ("zebu.jpg", _photo((80, 80, 80)), "image/jpeg")}).json()["id"]
    file_moteur._enregistre(cid2, uid, Resultat(
        etat="ok", verdict="Vache", latin="Bos taurus", niveau="espece",
        confiance=0.88, case_id=1, duree=14.2))
    case = client.get("/dex/1", headers=entete(j)).json()
    assert case["nb_captures"] == 2 and len(case["captures"]) == 2
    assert client.get("/dex/resume", headers=entete(j)).json()["trouve"] == 1


def test_suppression_derniere_capture_vide_la_case(client):
    from biodex.moteur import Resultat, file as file_moteur

    j = client.post("/inscription", json={"pseudo": "Repentant", "mdp": "motdepasse1"}).json()["jeton"]
    uid = client.get("/moi", headers=entete(j)).json()["id"]
    cid = client.post("/captures", headers=entete(j),
                      files={"photo": ("m.jpg", _photo(), "image/jpeg")}).json()["id"]
    file_moteur._enregistre(cid, uid, Resultat(etat="ok", verdict="Mésange bleue",
                                               case_id=2, niveau="espece", confiance=0.9))
    assert client.get("/dex/2", headers=entete(j)).json()["decouvert"] is True

    assert client.delete(f"/captures/{cid}", headers=entete(j)).status_code == 204
    assert client.get("/dex/2", headers=entete(j)).json()["decouvert"] is False


# ---------------------------------------------------------------------- amis

def test_parcours_d_amitie_complet(client):
    a = client.post("/inscription", json={"pseudo": "Amie", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Copain", "mdp": "motdepasse1"}).json()

    r = client.post("/amis/demandes", headers=entete(a["jeton"]), json={"pseudo": "Copain"})
    assert r.status_code == 201 and r.json()["etat"] == "attente"

    # Redemander ne crée pas un second lien.
    assert client.post("/amis/demandes", headers=entete(a["jeton"]),
                       json={"pseudo": "Copain"}).status_code == 409

    recues = client.get("/amis/demandes", headers=entete(b["jeton"])).json()["recues"]
    assert [x["pseudo"] for x in recues] == ["Amie"]

    did = recues[0]["demande_id"]
    assert client.post(f"/amis/demandes/{did}/accepter",
                       headers=entete(b["jeton"])).status_code == 200
    assert [x["pseudo"] for x in client.get("/amis", headers=entete(a["jeton"])).json()["amis"]] \
        == ["Copain"]
    assert client.get("/utilisateurs/" + str(b["id"]),
                      headers=entete(a["jeton"])).json()["relation"] == "amis"

    assert client.delete(f"/amis/{b['id']}", headers=entete(a["jeton"])).status_code == 204
    assert client.get("/amis", headers=entete(a["jeton"])).json()["amis"] == []


def test_demande_croisee_vaut_acceptation(client):
    a = client.post("/inscription", json={"pseudo": "Croix", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Croisee", "mdp": "motdepasse1"}).json()
    client.post("/amis/demandes", headers=entete(a["jeton"]), json={"pseudo": "Croisee"})
    r = client.post("/amis/demandes", headers=entete(b["jeton"]), json={"pseudo": "Croix"})
    assert r.status_code == 201 and r.json()["etat"] == "acceptee"


def test_on_ne_voit_pas_le_dex_d_un_inconnu(client):
    a = client.post("/inscription", json={"pseudo": "LotCurieux", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Discret", "mdp": "motdepasse1"}).json()
    r = client.get("/dex", params={"joueur": b["id"]}, headers=entete(a["jeton"]))
    assert r.status_code == 403


def test_correction_manuelle_deplace_la_decouverte(client):
    """Le moteur s'est trompé de case : le joueur tranche, l'ancienne case se
    vide et la nouvelle se remplit."""
    from biodex.moteur import Resultat, file as file_moteur

    j = client.post("/inscription", json={"pseudo": "Corrigeur", "mdp": "motdepasse1"}).json()["jeton"]
    uid = client.get("/moi", headers=entete(j)).json()["id"]
    cid = client.post("/captures", headers=entete(j),
                      files={"photo": ("x.jpg", _photo(), "image/jpeg")}).json()["id"]
    # Le moteur croit voir une vache.
    file_moteur._enregistre(cid, uid, Resultat(etat="ok", verdict="Vache", case_id=1,
                                               niveau="espece", confiance=0.7))
    assert client.get("/dex/1", headers=entete(j)).json()["decouvert"] is True

    r = client.post(f"/captures/{cid}/espece", headers=entete(j), json={"case_id": 2})
    assert r.status_code == 200, r.text
    d = r.json()
    assert d["etat"] == "ok" and d["niveau"] == "manuel" and d["corrigee"] is True
    assert d["verdict"] == "Mésange bleue"

    assert client.get("/dex/1", headers=entete(j)).json()["decouvert"] is False
    assert client.get("/dex/2", headers=entete(j)).json()["decouvert"] is True
    assert client.get("/dex/resume", headers=entete(j)).json()["trouve"] == 1


def test_correction_sur_une_capture_rejetee(client):
    """Une photo que le moteur n'a pas su lire peut quand même remplir une case."""
    from biodex.moteur import Resultat, file as file_moteur

    j = client.post("/inscription", json={"pseudo": "Obstine", "mdp": "motdepasse1"}).json()["jeton"]
    uid = client.get("/moi", headers=entete(j)).json()["id"]
    cid = client.post("/captures", headers=entete(j),
                      files={"photo": ("flou.jpg", _photo(), "image/jpeg")}).json()["id"]
    file_moteur._enregistre(cid, uid, Resultat(etat="doute", verdict="Indéterminé"))

    d = client.post(f"/captures/{cid}/espece", headers=entete(j),
                    json={"case_id": 1}).json()
    assert d["etat"] == "ok" and d["case_id"] == 1
    assert client.get("/dex/1", headers=entete(j)).json()["nb_captures"] == 1


def test_retrait_de_l_espece(client):
    from biodex.moteur import Resultat, file as file_moteur

    j = client.post("/inscription", json={"pseudo": "Repenti", "mdp": "motdepasse1"}).json()["jeton"]
    uid = client.get("/moi", headers=entete(j)).json()["id"]
    cid = client.post("/captures", headers=entete(j),
                      files={"photo": ("y.jpg", _photo(), "image/jpeg")}).json()["id"]
    file_moteur._enregistre(cid, uid, Resultat(etat="ok", verdict="Vache", case_id=1,
                                               niveau="espece", confiance=0.9))
    d = client.post(f"/captures/{cid}/espece", headers=entete(j),
                    json={"case_id": None}).json()
    assert d["case_id"] is None and d["etat"] == "doute"
    assert client.get("/dex/1", headers=entete(j)).json()["decouvert"] is False


def test_correction_vers_une_case_inexistante(client):
    j = client.post("/inscription", json={"pseudo": "Etourdi", "mdp": "motdepasse1"}).json()["jeton"]
    cid = client.post("/captures", headers=entete(j),
                      files={"photo": ("z.jpg", _photo(), "image/jpeg")}).json()["id"]
    assert client.post(f"/captures/{cid}/espece", headers=entete(j),
                       json={"case_id": 999999}).status_code == 404


def test_deuxieme_photo_conserve_la_decouverte_apres_suppression(client):
    """Supprimer une photo sur deux ne doit pas faire perdre l'espèce."""
    from biodex.moteur import Resultat, file as file_moteur

    j = client.post("/inscription", json={"pseudo": "Prudent", "mdp": "motdepasse1"}).json()["jeton"]
    uid = client.get("/moi", headers=entete(j)).json()["id"]
    ids = []
    for n in range(2):
        cid = client.post("/captures", headers=entete(j),
                          files={"photo": (f"{n}.jpg", _photo(), "image/jpeg")}).json()["id"]
        file_moteur._enregistre(cid, uid, Resultat(etat="ok", verdict="Vache", case_id=1,
                                                   niveau="espece", confiance=0.9))
        ids.append(cid)

    assert client.delete(f"/captures/{ids[0]}", headers=entete(j)).status_code == 204
    case = client.get("/dex/1", headers=entete(j)).json()
    assert case["decouvert"] is True and case["nb_captures"] == 1
    # La capture restante reprend le rôle de « première » de la case.
    assert [c["id"] for c in case["captures"]] == [ids[1]]


def test_arbre_taxonomique(client):
    j = client.post("/inscription", json={"pseudo": "Arboriste", "mdp": "motdepasse1"}).json()["jeton"]

    racine = client.get("/dex/arbre", headers=entete(j)).json()
    assert racine["niveau"] == "classe" and racine["enfant"] == "ordre"
    assert {n["nom"] for n in racine["noeuds"]} == {"Mammalia", "Aves"}

    # Les cases de test n'ont pas d'ordre renseigné : la branche est vide, ce
    # qui doit rester une réponse valide et non une erreur.
    sous = client.get("/dex/arbre", params={"classe": "Mammalia"}, headers=entete(j)).json()
    assert sous["niveau"] == "ordre" and sous["classe"] == "Mammalia"
    assert sous["noeuds"] == []


def test_filtre_par_ordre(client):
    j = client.post("/inscription", json={"pseudo": "Ordonne", "mdp": "motdepasse1"}).json()["jeton"]
    d = client.get("/dex", params={"ordre": "Carnivora"}, headers=entete(j)).json()
    assert d["cases"] == []


def test_classement_entre_amis(client):
    """Les points viennent de la qualité des cases, une fois par espèce."""
    from biodex import db as base
    from biodex.moteur import Resultat, file as file_moteur

    # La vache vaut 5 points (commune), la mésange 150 (on la dit légendaire
    # pour ce test, afin de vérifier que la qualité pèse bien sur le total).
    base.ecrit("UPDATE cases SET rarete = 1, points = 5 WHERE id = 1")
    base.ecrit("UPDATE cases SET rarete = 5, points = 150 WHERE id = 2")

    a = client.post("/inscription", json={"pseudo": "Chasseur", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Rival", "mdp": "motdepasse1"}).json()
    client.post("/amis/demandes", headers=entete(a["jeton"]), json={"pseudo": "Rival"})
    did = client.get("/amis/demandes",
                     headers=entete(b["jeton"])).json()["recues"][0]["demande_id"]
    client.post(f"/amis/demandes/{did}/accepter", headers=entete(b["jeton"]))

    def trouve(joueur, case_id):
        cid = client.post("/captures", headers=entete(joueur["jeton"]),
                          files={"photo": ("p.jpg", _photo(), "image/jpeg")}).json()["id"]
        file_moteur._enregistre(cid, joueur["id"],
                                Resultat(etat="ok", verdict="x", case_id=case_id,
                                         niveau="espece", confiance=0.9))

    trouve(a, 1)          # 5 points
    trouve(b, 2)          # 150 points
    trouve(b, 1)          # + 5

    tableau = client.get("/classement", headers=entete(a["jeton"])).json()["joueurs"]
    assert [j["pseudo"] for j in tableau[:2]] == ["Rival", "Chasseur"]
    assert tableau[0]["points"] == 155 and tableau[1]["points"] == 5
    assert tableau[0]["legendaires"] == 1
    assert any(j["moi"] for j in tableau)

    # Une deuxième photo de la même espèce ne rapporte rien de plus.
    trouve(a, 1)
    mien = client.get("/classement/moi", headers=entete(a["jeton"])).json()
    assert mien["total"] == 5 and mien["cases"] == 1
    assert mien["rang"] == 2 and mien["sur"] == 2

    palmares = client.get("/classement/trouvailles",
                          headers=entete(a["jeton"])).json()["trouvailles"]
    assert palmares[0]["qualite"] == 5 and palmares[0]["pseudo"] == "Rival"


def test_reactions_rapportent_des_points_au_photographe(client):
    from biodex.moteur import Resultat, file as file_moteur

    a = client.post("/inscription", json={"pseudo": "Artiste", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Public", "mdp": "motdepasse1"}).json()
    client.post("/amis/demandes", headers=entete(a["jeton"]), json={"pseudo": "Public"})
    did = client.get("/amis/demandes",
                     headers=entete(b["jeton"])).json()["recues"][0]["demande_id"]
    client.post(f"/amis/demandes/{did}/accepter", headers=entete(b["jeton"]))

    cid = client.post("/captures", headers=entete(a["jeton"]),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")}).json()["id"]
    file_moteur._enregistre(cid, a["id"], Resultat(etat="ok", verdict="Vache",
                                                   case_id=1, niveau="espece",
                                                   confiance=0.9))
    avant = client.get("/classement/moi", headers=entete(a["jeton"])).json()["total"]

    r = client.put(f"/captures/{cid}/reaction", headers=entete(b["jeton"]),
                   json={"valeur": 4})
    assert r.status_code == 200 and r.json()["points"] == 12

    apres = client.get("/classement/moi", headers=entete(a["jeton"])).json()
    assert apres["total"] == avant + 12
    assert apres["points_reactions"] == 12

    # Changer d'avis remplace la réaction, il n'y en a jamais deux.
    client.put(f"/captures/{cid}/reaction", headers=entete(b["jeton"]),
               json={"valeur": 1})
    apres = client.get("/classement/moi", headers=entete(a["jeton"])).json()
    assert apres["points_reactions"] == 3

    # « Bof » ne rapporte rien.
    client.put(f"/captures/{cid}/reaction", headers=entete(b["jeton"]),
               json={"valeur": 0})
    assert client.get("/classement/moi",
                      headers=entete(a["jeton"])).json()["points_reactions"] == 0

    d = client.get(f"/captures/{cid}/reactions", headers=entete(a["jeton"])).json()
    assert d["ma_reaction"] is None            # l'auteur n'a pas réagi
    assert [x["pseudo"] for x in d["detail"]] == ["Public"]

    client.delete(f"/captures/{cid}/reaction", headers=entete(b["jeton"]))
    assert client.get(f"/captures/{cid}/reactions",
                      headers=entete(a["jeton"])).json()["total"] == 0


def test_notifications_de_reaction(client):
    from biodex.moteur import Resultat, file as file_moteur

    a = client.post("/inscription", json={"pseudo": "Notifie", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Reacteur", "mdp": "motdepasse1"}).json()
    client.post("/amis/demandes", headers=entete(a["jeton"]), json={"pseudo": "Reacteur"})
    did = client.get("/amis/demandes",
                     headers=entete(b["jeton"])).json()["recues"][0]["demande_id"]
    client.post(f"/amis/demandes/{did}/accepter", headers=entete(b["jeton"]))

    cid = client.post("/captures", headers=entete(a["jeton"]),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")}).json()["id"]
    file_moteur._enregistre(cid, a["id"], Resultat(etat="ok", verdict="Vache",
                                                   case_id=1, niveau="espece"))

    assert client.get("/notifications",
                      headers=entete(a["jeton"])).json()["non_lues"] == 0

    client.put(f"/captures/{cid}/reaction", headers=entete(b["jeton"]),
               json={"valeur": 4})
    d = client.get("/notifications", headers=entete(a["jeton"])).json()
    assert d["non_lues"] == 1
    n = d["notifications"][0]
    assert n["pseudo"] == "Reacteur" and n["emoji"] == "🏆" and n["points"] == 12
    assert n["capture_id"] == cid

    # Changer d'avis remplace la notification au lieu d'en empiler une seconde.
    client.put(f"/captures/{cid}/reaction", headers=entete(b["jeton"]),
               json={"valeur": 1})
    d = client.get("/notifications", headers=entete(a["jeton"])).json()
    assert d["non_lues"] == 1 and len(d["notifications"]) == 1
    assert d["notifications"][0]["emoji"] == "🙂"

    client.post("/notifications/lues", headers=entete(a["jeton"]))
    assert client.get("/notifications",
                      headers=entete(a["jeton"])).json()["non_lues"] == 0

    # Retirer sa réaction retire la notification : pas de badge orphelin.
    client.delete(f"/captures/{cid}/reaction", headers=entete(b["jeton"]))
    assert client.get("/notifications",
                      headers=entete(a["jeton"])).json()["notifications"] == []

    # On ne se notifie pas soi-même.
    assert client.get("/notifications",
                      headers=entete(b["jeton"])).json()["notifications"] == []


def test_titre_de_photo(client):
    j = client.post("/inscription", json={"pseudo": "Poete", "mdp": "motdepasse1"}).json()["jeton"]
    cid = client.post("/captures", headers=entete(j),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")}).json()["id"]

    assert client.get(f"/captures/{cid}", headers=entete(j)).json()["titre"] == ""
    d = client.patch(f"/captures/{cid}/titre", headers=entete(j),
                     json={"titre": "  Le héron du canal  "}).json()
    assert d["titre"] == "Le héron du canal"          # espaces rognés
    assert client.get(f"/captures/{cid}",
                      headers=entete(j)).json()["titre"] == "Le héron du canal"

    # On peut l'effacer.
    assert client.patch(f"/captures/{cid}/titre", headers=entete(j),
                        json={"titre": ""}).json()["titre"] == ""


def test_photos_des_amis_sur_la_meme_case(client):
    from biodex.moteur import Resultat, file as file_moteur

    a = client.post("/inscription", json={"pseudo": "Duo1", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Duo2", "mdp": "motdepasse1"}).json()
    c = client.post("/inscription", json={"pseudo": "Tiers", "mdp": "motdepasse1"}).json()
    client.post("/amis/demandes", headers=entete(a["jeton"]), json={"pseudo": "Duo2"})
    did = client.get("/amis/demandes",
                     headers=entete(b["jeton"])).json()["recues"][0]["demande_id"]
    client.post(f"/amis/demandes/{did}/accepter", headers=entete(b["jeton"]))

    def trouve(joueur, partage=True):
        cid = client.post("/captures", headers=entete(joueur["jeton"]),
                          files={"photo": ("p.jpg", _photo(), "image/jpeg")},
                          data={"partage": str(partage).lower()}).json()["id"]
        file_moteur._enregistre(cid, joueur["id"],
                                Resultat(etat="ok", verdict="Vache", case_id=1,
                                         niveau="espece", confiance=0.9))
        return cid

    mienne = trouve(a)
    amie = trouve(b)
    inconnue = trouve(c)
    privee = trouve(b, partage=False)

    d = client.get("/dex/1", headers=entete(a["jeton"])).json()
    assert [x["id"] for x in d["captures"]] == [mienne]
    chez_amis = {x["id"] for x in d["chez_les_amis"]}
    assert amie in chez_amis
    assert inconnue not in chez_amis and privee not in chez_amis
    assert d["chez_les_amis"][0]["pseudo"] == "Duo2"

    # Et on peut réagir depuis là, comme dans le fil.
    r = client.put(f"/captures/{amie}/reaction", headers=entete(a["jeton"]),
                   json={"valeur": 3})
    assert r.status_code == 200
    d = client.get("/dex/1", headers=entete(a["jeton"])).json()
    assert d["chez_les_amis"][0]["reactions"]["ma_reaction"] == 3


def test_on_ne_reagit_pas_a_ses_propres_photos_ni_a_celles_des_inconnus(client):
    a = client.post("/inscription", json={"pseudo": "Seul", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Passant", "mdp": "motdepasse1"}).json()
    cid = client.post("/captures", headers=entete(a["jeton"]),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")}).json()["id"]
    assert client.put(f"/captures/{cid}/reaction", headers=entete(a["jeton"]),
                      json={"valeur": 4}).status_code == 400
    assert client.put(f"/captures/{cid}/reaction", headers=entete(b["jeton"]),
                      json={"valeur": 4}).status_code == 403
    assert client.put(f"/captures/{cid}/reaction", headers=entete(b["jeton"]),
                      json={"valeur": 9}).status_code == 422


def test_avatar(client):
    j = client.post("/inscription", json={"pseudo": "Coquet", "mdp": "motdepasse1"}).json()
    assert client.get("/moi", headers=entete(j["jeton"])).json()["avatar"] is None

    r = client.post("/moi/avatar", headers=entete(j["jeton"]),
                    files={"photo": ("moi.jpg", _photo(taille=(800, 400)), "image/jpeg")})
    assert r.status_code == 200
    assert client.get("/moi", headers=entete(j["jeton"])).json()["avatar"] is not None
    assert client.get(f"/utilisateurs/{j['id']}/avatar",
                      headers=entete(j["jeton"])).status_code == 200

    assert client.delete("/moi/avatar", headers=entete(j["jeton"])).status_code == 204
    assert client.get(f"/utilisateurs/{j['id']}/avatar",
                      headers=entete(j["jeton"])).status_code == 404


def test_galerie_filtres_et_pagination(client):
    from biodex.moteur import Resultat, file as file_moteur

    a = client.post("/inscription", json={"pseudo": "Collectionneur", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Compagnon", "mdp": "motdepasse1"}).json()
    c = client.post("/inscription", json={"pseudo": "Lointain", "mdp": "motdepasse1"}).json()
    client.post("/amis/demandes", headers=entete(a["jeton"]), json={"pseudo": "Compagnon"})
    did = client.get("/amis/demandes",
                     headers=entete(b["jeton"])).json()["recues"][0]["demande_id"]
    client.post(f"/amis/demandes/{did}/accepter", headers=entete(b["jeton"]))

    def photo(joueur, case_id, lat=None, lon=None, quand=None, partage=True):
        data = {"partage": str(partage).lower()}
        if lat is not None:
            data |= {"lat": str(lat), "lon": str(lon)}
        cid = client.post("/captures", headers=entete(joueur["jeton"]),
                          files={"photo": ("p.jpg", _photo(), "image/jpeg")},
                          data=data).json()["id"]
        file_moteur._enregistre(cid, joueur["id"],
                                Resultat(etat="ok", verdict="x", case_id=case_id,
                                         niveau="espece", confiance=0.9))
        if quand:
            client.patch(f"/captures/{cid}/lieu", headers=entete(joueur["jeton"]),
                         json={"prise_le": quand})
        return cid

    mienne = photo(a, 1, 48.85, 2.35, "2026-01-15 10:00:00")
    ancienne = photo(a, 2, 45.76, 4.83, "2025-06-01 09:00:00")
    amie = photo(b, 1, 48.86, 2.36, "2026-02-20 14:00:00")
    privee = photo(b, 2, partage=False)
    inconnue = photo(c, 1)

    vues = {p["capture_id"] for p in
            client.get("/galerie", headers=entete(a["jeton"])).json()["photos"]}
    assert {mienne, ancienne, amie} <= vues
    assert privee not in vues and inconnue not in vues

    # Filtre par auteur
    d = client.get("/galerie", params={"qui": "moi"}, headers=entete(a["jeton"])).json()
    assert all(p["moi"] for p in d["photos"])
    d = client.get("/galerie", params={"qui": "amis"}, headers=entete(a["jeton"])).json()
    assert {p["pseudo"] for p in d["photos"]} == {"Compagnon"}
    d = client.get("/galerie", params={"qui": str(b["id"])},
                   headers=entete(a["jeton"])).json()
    assert {p["capture_id"] for p in d["photos"]} == {amie}

    # Filtre par période, combiné avec l'auteur
    d = client.get("/galerie", params={"qui": "moi", "depuis": "2026-01-01"},
                   headers=entete(a["jeton"])).json()
    assert {p["capture_id"] for p in d["photos"]} == {mienne}

    # Filtre par zone géographique
    d = client.get("/galerie",
                   params={"lat_min": 48, "lat_max": 49, "lon_min": 2, "lon_max": 3},
                   headers=entete(a["jeton"])).json()
    assert {p["capture_id"] for p in d["photos"]} == {mienne, amie}

    # Filtre par espèce
    d = client.get("/galerie", params={"espece": 2},
                   headers=entete(a["jeton"])).json()
    assert {p["capture_id"] for p in d["photos"]} == {ancienne}

    # Pagination : deux pages d'une photo, puis la fin
    p1 = client.get("/galerie", params={"limite": 1},
                    headers=entete(a["jeton"])).json()
    p2 = client.get("/galerie", params={"limite": 1, "decalage": 1},
                    headers=entete(a["jeton"])).json()
    assert p1["fin"] is False
    assert p1["photos"][0]["capture_id"] != p2["photos"][0]["capture_id"]

    # Tri du plus ancien au plus récent
    d = client.get("/galerie", params={"tri": "ancien", "qui": "moi"},
                   headers=entete(a["jeton"])).json()
    assert [p["capture_id"] for p in d["photos"]] == [ancienne, mienne]


def test_favoris(client):
    from biodex.moteur import Resultat, file as file_moteur

    j = client.post("/inscription", json={"pseudo": "Amateur", "mdp": "motdepasse1"}).json()
    cid = client.post("/captures", headers=entete(j["jeton"]),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")}).json()["id"]
    file_moteur._enregistre(cid, j["id"], Resultat(etat="ok", verdict="x", case_id=1,
                                                   niveau="espece", confiance=0.9))

    assert client.get("/galerie", params={"favoris": True},
                      headers=entete(j["jeton"])).json()["photos"] == []
    assert client.put(f"/captures/{cid}/favori",
                      headers=entete(j["jeton"])).status_code == 204
    # Deux fois de suite : pas de doublon, pas d'erreur.
    client.put(f"/captures/{cid}/favori", headers=entete(j["jeton"]))

    d = client.get("/galerie", params={"favoris": True},
                   headers=entete(j["jeton"])).json()["photos"]
    assert [p["capture_id"] for p in d] == [cid] and d[0]["favori"] is True

    assert client.delete(f"/captures/{cid}/favori",
                         headers=entete(j["jeton"])).status_code == 204
    assert client.get("/galerie", params={"favoris": True},
                      headers=entete(j["jeton"])).json()["photos"] == []


def test_reperes_de_galerie(client):
    j = client.post("/connexion", json={"pseudo": "Collectionneur", "mdp": "motdepasse1"}).json()
    d = client.get("/galerie/reperes", headers=entete(j["jeton"])).json()
    assert {a["pseudo"] for a in d["auteurs"]} == {"Collectionneur", "Compagnon"}
    assert d["total"] >= 3 and d["situees"] >= 3
    assert any(e["nom"] for e in d["especes"])


def test_detail_d_un_joueur(client):
    a = client.post("/connexion", json={"pseudo": "Collectionneur", "mdp": "motdepasse1"}).json()
    b = client.post("/connexion", json={"pseudo": "Compagnon", "mdp": "motdepasse1"}).json()
    etranger = client.post("/connexion", json={"pseudo": "Lointain", "mdp": "motdepasse1"}).json()

    d = client.get(f"/classement/joueur/{b['id']}", headers=entete(a["jeton"])).json()
    assert d["pseudo"] == "Compagnon"
    assert len(d["par_qualite"]) == 5          # les cinq paliers, même à zéro
    assert d["photos"] >= 1

    assert client.get(f"/classement/joueur/{etranger['id']}",
                      headers=entete(a["jeton"])).status_code == 403


def test_vedette_produit_la_decoupe(client, monkeypatch):
    """Choisir une photo comme image de la case la détoure si besoin, sans
    relancer d'analyse."""
    from biodex import images
    from biodex.moteur import Resultat, file as file_moteur

    j = client.post("/inscription", json={"pseudo": "Esthete", "mdp": "motdepasse1"}).json()
    cid = client.post("/captures", headers=entete(j["jeton"]),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")}).json()["id"]
    file_moteur._enregistre(cid, j["id"], Resultat(etat="ok", verdict="x", case_id=1,
                                                   niveau="espece", confiance=0.9))

    # Le vrai détourage demande un modèle de 176 Mo : on simule sa sortie.
    appels = []

    def faux_decoupe(fichier, bbox):
        appels.append(fichier)
        return "decoupe-simulee.png"

    monkeypatch.setattr(images, "decoupe", faux_decoupe)
    r = client.post(f"/dex/1/vedette/{cid}", headers=entete(j["jeton"]))
    assert r.status_code == 200
    assert r.json()["decoupe"] == f"/captures/{cid}/decoupe"
    assert len(appels) == 1

    # Deuxième appel : la découpe existe déjà, on ne la refait pas.
    client.post(f"/dex/1/vedette/{cid}", headers=entete(j["jeton"]))
    assert len(appels) == 1


def test_classement_ignore_les_inconnus(client):
    c = client.post("/inscription", json={"pseudo": "Etranger", "mdp": "motdepasse1"}).json()
    a = client.post("/connexion", json={"pseudo": "Chasseur", "mdp": "motdepasse1"}).json()
    tableau = client.get("/classement", headers=entete(a["jeton"])).json()["joueurs"]
    assert c["pseudo"] not in {j["pseudo"] for j in tableau}


def test_carte_montre_mes_points_et_ceux_des_amis(client):
    from biodex.moteur import Resultat, file as file_moteur

    a = client.post("/inscription", json={"pseudo": "Marcheur", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Randonneur", "mdp": "motdepasse1"}).json()
    c = client.post("/inscription", json={"pseudo": "Inconnu", "mdp": "motdepasse1"}).json()

    def pose(jeton, uid, lat, lon, partage=True):
        cid = client.post("/captures", headers=entete(jeton),
                          files={"photo": ("p.jpg", _photo(), "image/jpeg")},
                          data={"lat": str(lat), "lon": str(lon),
                                "partage": str(partage).lower()}).json()["id"]
        file_moteur._enregistre(cid, uid, Resultat(etat="ok", verdict="Vache",
                                                   case_id=1, niveau="espece",
                                                   confiance=0.9))
        return cid

    pose(a["jeton"], a["id"], 48.85, 2.35)
    pose(b["jeton"], b["id"], 45.76, 4.83)
    pose(c["jeton"], c["id"], 43.60, 1.44)          # pas un ami
    prive = pose(b["jeton"], b["id"], 44.84, -0.58, partage=False)

    # a et b deviennent amis
    client.post("/amis/demandes", headers=entete(a["jeton"]), json={"pseudo": "Randonneur"})
    did = client.get("/amis/demandes",
                     headers=entete(b["jeton"])).json()["recues"][0]["demande_id"]
    client.post(f"/amis/demandes/{did}/accepter", headers=entete(b["jeton"]))

    points = client.get("/carte", headers=entete(a["jeton"])).json()["points"]
    pseudos = {p["pseudo"] for p in points}
    assert "Marcheur" in pseudos and "Randonneur" in pseudos
    assert "Inconnu" not in pseudos                  # pas ami : invisible
    assert prive not in {p["capture_id"] for p in points}   # non partagée

    miens = client.get("/carte", params={"qui": "moi"},
                       headers=entete(a["jeton"])).json()["points"]
    assert {p["pseudo"] for p in miens} == {"Marcheur"}
    assert all(p["moi"] for p in miens)


def test_photo_sans_espece_n_apparait_nulle_part(client):
    """Une photo que le moteur n'a pas su lire ne doit polluer ni la carte ni la
    galerie : ce serait un point qui ne dit rien."""
    j = client.post("/inscription", json={"pseudo": "Rate", "mdp": "motdepasse1"}).json()
    cid = client.post("/captures", headers=entete(j["jeton"]),
                      files={"photo": ("flou.jpg", _photo(), "image/jpeg")},
                      data={"lat": "48.85", "lon": "2.35"}).json()["id"]
    from biodex.moteur import Resultat, file as file_moteur
    file_moteur._enregistre(cid, j["id"],
                            Resultat(etat="rejet", verdict="Pas d'animal"))

    assert cid not in {p["capture_id"]
                       for p in client.get("/carte", headers=entete(j["jeton"])).json()["points"]}
    assert cid not in {p["capture_id"]
                       for p in client.get("/galerie",
                                           headers=entete(j["jeton"])).json()["photos"]}

    # Elle reste signalée au joueur, pour qu'il puisse la ranger ou la jeter.
    d = client.get("/captures/non-identifiees", headers=entete(j["jeton"])).json()
    assert cid in {x["capture_id"] for x in d["captures"]}

    # Une fois rangée dans une case, elle rejoint carte et galerie.
    client.post(f"/captures/{cid}/espece", headers=entete(j["jeton"]),
                json={"case_id": 1})
    assert cid in {p["capture_id"]
                   for p in client.get("/carte", headers=entete(j["jeton"])).json()["points"]}
    assert cid in {p["capture_id"]
                   for p in client.get("/galerie",
                                       headers=entete(j["jeton"])).json()["photos"]}
    assert client.get("/captures/non-identifiees",
                      headers=entete(j["jeton"])).json()["captures"] == []


def test_suppression_groupee_des_non_identifiees(client):
    from biodex.moteur import Resultat, file as file_moteur

    j = client.post("/inscription", json={"pseudo": "Menage", "mdp": "motdepasse1"}).json()
    ids = []
    for n in range(3):
        cid = client.post("/captures", headers=entete(j["jeton"]),
                          files={"photo": (f"{n}.jpg", _photo(), "image/jpeg")}).json()["id"]
        file_moteur._enregistre(cid, j["id"], Resultat(etat="rejet", verdict="Pas d'animal"))
        ids.append(cid)
    # Une quatrième, rangée à la main : elle doit survivre au ménage.
    gardee = client.post("/captures", headers=entete(j["jeton"]),
                         files={"photo": ("ok.jpg", _photo(), "image/jpeg")}).json()["id"]
    file_moteur._enregistre(gardee, j["id"], Resultat(etat="ok", verdict="Vache",
                                                      case_id=1, niveau="espece"))

    d = client.request("DELETE", "/captures/non-identifiees",
                       headers=entete(j["jeton"])).json()
    assert d["supprimees"] == 3
    assert client.get(f"/captures/{gardee}", headers=entete(j["jeton"])).status_code == 200
    assert client.get(f"/captures/{ids[0]}", headers=entete(j["jeton"])).status_code == 404


def test_capture_sans_position_est_orpheline(client):
    from biodex.moteur import Resultat, file as file_moteur

    j = client.post("/inscription", json={"pseudo": "Perdu", "mdp": "motdepasse1"}).json()
    cid = client.post("/captures", headers=entete(j["jeton"]),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")}).json()["id"]
    # L'espèce est reconnue, mais la photo n'a ni coordonnées ni heure : c'est
    # bien la position qui manque ici, pas l'identification.
    file_moteur._enregistre(cid, j["id"], Resultat(etat="ok", verdict="Vache",
                                                   case_id=1, niveau="espece",
                                                   confiance=0.9))
    j = j["jeton"]

    d = client.get("/carte/orphelines", headers=entete(j)).json()["captures"]
    ligne = next(x for x in d if x["capture_id"] == cid)
    assert ligne["sans_position"] is True and ligne["sans_heure"] is True

    # Elle n'apparaît pas encore sur la carte…
    assert cid not in {p["capture_id"]
                       for p in client.get("/carte", headers=entete(j)).json()["points"]}

    # …puis le joueur la situe à la main.
    r = client.patch(f"/captures/{cid}/lieu", headers=entete(j),
                     json={"lat": 48.8584, "lon": 2.2945,
                           "prise_le": "2026-08-15 09:30:00",
                           "lieu": "Tour Eiffel, Paris"})
    assert r.status_code == 200, r.text
    d = r.json()
    assert d["source_position"] == "manuel" and d["source_heure"] == "manuel"
    assert d["lieu"] == "Tour Eiffel, Paris"

    points = client.get("/carte", headers=entete(j)).json()["points"]
    point = next(p for p in points if p["capture_id"] == cid)
    assert point["lat"] == 48.8584 and point["heure_sure"] is True
    assert point["position_manuelle"] is True

    # Et elle sort de la liste des orphelines.
    assert cid not in {x["capture_id"]
                       for x in client.get("/carte/orphelines",
                                           headers=entete(j)).json()["captures"]}


def test_correction_de_l_heure_seule(client):
    j = client.post("/inscription", json={"pseudo": "Horloger", "mdp": "motdepasse1"}).json()["jeton"]
    cid = client.post("/captures", headers=entete(j),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")},
                      data={"lat": "48.85", "lon": "2.35"}).json()["id"]
    d = client.patch(f"/captures/{cid}/lieu", headers=entete(j),
                     json={"prise_le": "2026-07-01T18:45:00"}).json()
    assert d["prise_le"] == "2026-07-01 18:45:00"
    assert d["lat"] == 48.85                      # la position n'a pas bougé
    assert d["source_position"] == "appareil"


def test_lieu_invalide_refuse(client):
    j = client.post("/inscription", json={"pseudo": "Farfelu", "mdp": "motdepasse1"}).json()["jeton"]
    cid = client.post("/captures", headers=entete(j),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")}).json()["id"]
    assert client.patch(f"/captures/{cid}/lieu", headers=entete(j),
                        json={"lat": 200.0, "lon": 0.0}).status_code == 400
    assert client.patch(f"/captures/{cid}/lieu", headers=entete(j),
                        json={"prise_le": "hier soir"}).status_code == 400
    assert client.patch(f"/captures/{cid}/lieu", headers=entete(j),
                        json={}).status_code == 400


def test_on_ne_situe_pas_la_photo_d_un_autre(client):
    a = client.post("/inscription", json={"pseudo": "LotProprio", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Intrus", "mdp": "motdepasse1"}).json()
    cid = client.post("/captures", headers=entete(a["jeton"]),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")}).json()["id"]
    assert client.patch(f"/captures/{cid}/lieu", headers=entete(b["jeton"]),
                        json={"lat": 0.0, "lon": 0.0}).status_code == 403


def test_fil_montre_les_trouvailles_des_amis(client):
    from biodex.moteur import Resultat, file as file_moteur

    a = client.post("/inscription", json={"pseudo": "Suiveur", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Suivi", "mdp": "motdepasse1"}).json()
    client.post("/amis/demandes", headers=entete(a["jeton"]), json={"pseudo": "Suivi"})
    did = client.get("/amis/demandes", headers=entete(b["jeton"])).json()["recues"][0]["demande_id"]
    client.post(f"/amis/demandes/{did}/accepter", headers=entete(b["jeton"]))

    cid = client.post("/captures", headers=entete(b["jeton"]),
                      files={"photo": ("x.jpg", _photo(), "image/jpeg")}).json()["id"]
    file_moteur._enregistre(cid, b["id"], Resultat(etat="ok", verdict="Vache", case_id=1,
                                                   niveau="espece", confiance=0.9))

    fil = client.get("/fil", headers=entete(a["jeton"])).json()["fil"]
    assert any(x["pseudo"] == "Suivi" and x["nom_fr"] == "Vache" for x in fil)
    # Et la vignette d'un ami est bien lisible.
    assert client.get(f"/captures/{cid}/vignette", headers=entete(a["jeton"])).status_code == 200


def test_pistes_au_dessus_du_seuil(client):
    """Le nombre de pistes suit ce que le modèle a à dire, pas un chiffre fixe.

    Une image nette ne produit qu'un candidat sérieux, une image douteuse en
    produit huit : proposer toujours cinq lignes cachait les vraies hésitations
    et en inventait là où il n'y en avait pas.
    """
    from biodex import config
    from biodex.moteur import pistes_depuis

    # Un verdict net : une seule case dépasse le seuil. Le plancher en réclame
    # trois, mais le dex de test n'en contient que deux — les identifiants
    # inconnus sont écartés plutôt que proposés à vide.
    net = pistes_depuis([(1, 0.92), (2, 0.03), (3, 0.01), (4, 0.005)])
    assert [c for c, _, _ in net] == [1, 2]
    assert net[0][1] == "Bos taurus"

    # Une image douteuse : tout ce qui dépasse le seuil est proposé, et rien
    # en dessous.
    doute = pistes_depuis([(1, 0.21), (2, 0.06), (3, 0.04)])
    assert [c for c, _, _ in doute] == [1, 2]
    assert all(p >= config.SEUIL_PISTE for _, _, p in doute)

    # Sous le seuil partout : le plancher évite l'écran vide.
    faible = pistes_depuis([(1, 0.03), (2, 0.02)])
    assert len(faible) == 2

    # Et jamais une liste à rallonge.
    beaucoup = pistes_depuis([(i, 0.5) for i in range(1, 40)])
    assert len(beaucoup) <= config.MAX_PISTES


def test_identifiants_captures_jamais_reutilises(client):
    """Une remise à zéro ne doit pas faire resservir les identifiants.

    Les URLs des images sont bâties dessus (« /captures/12/vignette »), et les
    téléphones gardent ces images en cache. Un identifiant recyclé fait
    réapparaître l'ancienne photo à la place de la nouvelle : on croit alors à
    des résidus côté serveur alors que la base est vide.
    """
    j = client.post("/inscription",
                    json={"pseudo": "Recyclage", "mdp": "motdepasse1"}).json()["jeton"]
    ids = [client.post("/captures", headers=entete(j),
                       files={"photo": (f"p{i}.jpg", _photo(), "image/jpeg")}).json()["id"]
           for i in range(3)]

    # On efface comme le ferait outils/remise_a_zero.py.
    with db.transaction() as cx:
        for t in ("reactions", "favoris", "captures_top", "decouvertes",
                  "amities", "captures", "sessions", "utilisateurs"):
            cx.execute(f"DELETE FROM {t}")

    j2 = client.post("/inscription",
                     json={"pseudo": "Apres", "mdp": "motdepasse1"}).json()["jeton"]
    neuf = client.post("/captures", headers=entete(j2),
                       files={"photo": ("neuf.jpg", _photo(), "image/jpeg")}).json()["id"]

    assert neuf not in ids, (
        f"l'identifiant {neuf} a déjà servi : son URL d'image est encore "
        f"en cache sur les téléphones")


def test_relacher_rend_la_case(client):
    """Relâcher une prise supprime la photo et rend l'espèce à trouver.

    C'est ce que promet la confirmation affichée au joueur : la case
    redevient vide et les points de la découverte sont perdus. Si la case
    porte d'autres photos, en revanche, elle survit — on n'a relâché qu'un
    cliché.
    """
    from biodex.moteur import Resultat, file as file_moteur

    j = client.post("/inscription",
                    json={"pseudo": "Relacheur", "mdp": "motdepasse1"}).json()["jeton"]
    uid = client.get("/moi", headers=entete(j)).json()["id"]

    def depose_et_analyse():
        cid = client.post("/captures", headers=entete(j),
                          files={"photo": ("v.jpg", _photo(), "image/jpeg")}).json()["id"]
        file_moteur._enregistre(cid, uid, Resultat(
            etat="ok", verdict="Vache", latin="Bos taurus", niveau="espece",
            confiance=0.9, case_id=1, duree=1.0,
            top=[(1, "Bos taurus", 0.9)]))
        return cid

    premiere = depose_et_analyse()
    avant = client.get("/dex/resume", headers=entete(j)).json()
    assert avant["trouve"] == 1 and avant["points"] > 0

    # Deux photos sur la case : relâcher la seconde ne doit rien coûter.
    seconde = depose_et_analyse()
    assert client.delete(f"/captures/{seconde}", headers=entete(j)).status_code == 204
    milieu = client.get("/dex/resume", headers=entete(j)).json()
    assert milieu["trouve"] == 1, "la case garde son autre photo"
    assert milieu["points"] == avant["points"]

    # La dernière photo : la case repart et les points avec.
    assert client.delete(f"/captures/{premiere}", headers=entete(j)).status_code == 204
    apres = client.get("/dex/resume", headers=entete(j)).json()
    assert apres["trouve"] == 0, "l'espèce doit redevenir à trouver"
    assert apres["points"] == 0, "les points de la découverte sont perdus"
    assert client.get("/dex/1", headers=entete(j)).json()["decouvert"] is False


# ----------------------------------------------------------------- aquatique
#
# « aquatique » n'est pas un règne de plus dans la table `cases` : c'est un
# aiguillage. Un poisson est un animal, sa case est une case animale, et ces
# tests existent surtout pour empêcher qu'on « corrige » un jour cette
# étrangeté apparente en créant un quatrième règne de cases — ce qui
# dédoublerait chaque poisson déjà découvert.

def _case_poisson(cx, cle=99001, latin="Amphiprion ocellaris",
                  nom="Poisson-clown", genre="Amphiprion"):
    """Une case de poisson telle que GBIF la produit : Chordata, sans classe.

    Le `classe = ''` n'est pas un oubli. GBIF laisse la classe vide pour les
    poissons à nageoires rayonnées, le rang étant disputé entre Actinopterygii
    et Actinopteri. C'est précisément ce qui interdit de filtrer sur la classe.
    """
    cx.execute(
        """INSERT INTO cases (cle_gbif, regne, latin, nom_fr, genre, famille,
                              ordre, classe, embranchement, obs, rarete, nb_alias)
           VALUES (?, 'animal', ?, ?, ?, 'Pomacentridae', 'Perciformes', '',
                   'Chordata', 4200, 3, 1)""", (cle, latin, nom, genre))
    cid = cx.execute("SELECT id FROM cases WHERE cle_gbif = ?", (cle,)).fetchone()[0]
    cx.execute("INSERT INTO alias (latin, case_id, accepte) VALUES (?, ?, 1)",
               (latin, cid))
    return cid


def test_regne_aquatique_est_accepte(client):
    j = client.post("/inscription", json={"pseudo": "Aquariophile",
                                          "mdp": "motdepasse1"}).json()["jeton"]
    r = client.post("/captures", headers=entete(j),
                    files={"photo": ("poisson.jpg", _photo(), "image/jpeg")},
                    data={"regne": "aquatique"})
    assert r.status_code == 202, r.text
    # Le règne déclaré est conservé tel quel : c'est ce qui permettra de savoir
    # par quel moteur la photo est passée, sans changer où elle atterrit.
    assert r.json()["regne"] == "aquatique"


def test_regne_inconnu_est_refuse(client):
    j = client.post("/inscription", json={"pseudo": "Farceur",
                                          "mdp": "motdepasse1"}).json()["jeton"]
    r = client.post("/captures", headers=entete(j),
                    files={"photo": ("x.jpg", _photo(), "image/jpeg")},
                    data={"regne": "poisson"})
    assert r.status_code == 400


def test_dex_filtre_aquatique_ne_montre_que_les_poissons(client):
    j = client.post("/inscription", json={"pseudo": "Filtreur",
                                          "mdp": "motdepasse1"}).json()["jeton"]
    with db.transaction() as cx:
        cid = _case_poisson(cx)
    try:
        d = client.get("/dex?regne=aquatique&limite=50", headers=entete(j)).json()
        ids = {c["id"] for c in d["cases"]}
        assert cid in ids, "le poisson doit apparaître sous le filtre aquatique"
        noms = {c["nom"] for c in d["cases"]}
        assert "Vache" not in noms and "Mésange bleue" not in noms

        # Et il reste une case animale : le filtre est une lentille, pas un
        # déménagement. Sans cela, un joueur qui a pris son poisson-clown sous
        # « animal » ne le retrouverait plus.
        a = client.get("/dex?regne=animal&limite=50", headers=entete(j)).json()
        assert cid in {c["id"] for c in a["cases"]}
    finally:
        with db.transaction() as cx:
            cx.execute("DELETE FROM alias WHERE case_id = ?", (cid,))
            cx.execute("DELETE FROM cases WHERE id = ?", (cid,))


def test_perimetre_poissons_ecarte_les_tuniciers(client):
    """Une appendiculaire est un Chordata sans classe, et n'est pas un poisson.

    Le cas est réel : 34 cases du dex de production. Sans l'exclusion de
    l'ordre Copelata, elles concourraient contre un guppy.
    """
    from biodex import poissons
    j = client.post("/inscription", json={"pseudo": "Tunicier",
                                          "mdp": "motdepasse1"}).json()["jeton"]
    with db.transaction() as cx:
        cx.execute(
            """INSERT INTO cases (cle_gbif, regne, latin, nom_fr, genre, famille,
                                  ordre, classe, embranchement, obs, rarete, nb_alias)
               VALUES (99002, 'animal', 'Oikopleura dioica', NULL, 'Oikopleura',
                       'Oikopleuridae', 'Copelata', '', 'Chordata', 12, 5, 1)""")
        tid = cx.execute("SELECT id FROM cases WHERE cle_gbif = 99002").fetchone()[0]
        pid = _case_poisson(cx, cle=99003, latin="Betta splendens",
                            nom="Combattant", genre="Betta")
    try:
        ou, params = poissons.condition()
        trouves = {r["id"] for r in
                   db.lit(f"SELECT id FROM cases WHERE {ou}", params)}
        assert pid in trouves, "le combattant est un poisson"
        assert tid not in trouves, "l'appendiculaire n'en est pas un"

        d = client.get("/dex?regne=aquatique&limite=50", headers=entete(j)).json()
        assert tid not in {c["id"] for c in d["cases"]}
    finally:
        with db.transaction() as cx:
            cx.execute("DELETE FROM alias WHERE case_id IN (?, ?)", (tid, pid))
            cx.execute("DELETE FROM cases WHERE id IN (?, ?)", (tid, pid))


# ------------------------------------------------------- photos à situer
#
# La carte et la galerie répondaient différemment à « cette photo est-elle
# située ? ». La carte comptait comme mal placée toute position issue d'un
# repli ; la galerie regardait seulement si la latitude était nulle. Sur la
# base de développement, dix-huit photos contre cinq.
#
# Les treize de l'écart sont les pires : elles ont des coordonnées, donc elles
# s'affichent sur la carte, mais à un endroit que personne n'a choisi.

def _capture_posee(cx, uid, cle, lat, source_position, source_heure):
    # `case_id` est indispensable : la galerie écarte les photos sans espèce
    # (`c.case_id IS NOT NULL`). C'est d'ailleurs pourquoi une photo
    # indéterminée *et* mal située n'était situable en lot nulle part — la
    # galerie ne la montrait pas, et l'écran de la carte ne savait pas
    # sélectionner.
    cx.execute(
        """INSERT INTO captures (utilisateur, etat, case_id, fichier, vignette,
                                 verdict, lat, lon, prise_le, cree_le,
                                 source_position, source_heure, partage, regne, titre)
           VALUES (?, 'ok', 1, ?, ?, 'x', ?, ?, '2026-08-01 10:00:00',
                   '2026-08-01 10:00:00', ?, ?, 1, 'animal', ?)""",
        (uid, f"{cle}.jpg", f"{cle}_v.jpg", lat, lat, source_position,
         source_heure, cle))
    return cx.execute("SELECT id FROM captures WHERE titre = ?", (cle,)).fetchone()[0]


def test_position_par_defaut_compte_comme_non_situee(client):
    """Une photo posée « par défaut » doit être signalée des deux côtés.

    C'est le cas qui n'était visible nulle part : la carte la montrait au
    mauvais endroit, la galerie la donnait pour située.
    """
    j = client.post("/inscription", json={"pseudo": "Situeur",
                                          "mdp": "motdepasse1"}).json()
    jeton, uid = j["jeton"], j["id"]
    with db.transaction() as cx:
        bonne = _capture_posee(cx, uid, "bonne", 48.85, "exif", "exif")
        defaut = _capture_posee(cx, uid, "defaut", 48.85, "defaut", "exif")
        nulle = _capture_posee(cx, uid, "nulle", None, "", "")
    try:
        orphelines = {c["capture_id"] for c in client.get(
            "/carte/orphelines", headers=entete(jeton)).json()["captures"]}
        assert defaut in orphelines and nulle in orphelines
        assert bonne not in orphelines

        # La galerie doit désigner exactement les mêmes.
        d = client.get("/galerie?situees=false&limite=200",
                       headers=entete(jeton)).json()
        vues = {p["capture_id"] for p in d["photos"]}
        assert defaut in vues, "la position par défaut doit compter comme non située"
        assert nulle in vues
        assert bonne not in vues

        # Et chaque photo porte son drapeau, pour qu'on puisse la marquer dans
        # la grille sans deviner.
        toutes = {p["capture_id"]: p for p in client.get(
            "/galerie?limite=200", headers=entete(jeton)).json()["photos"]}
        assert toutes[defaut]["sans_position"] is True
        assert toutes[bonne]["sans_position"] is False
        assert toutes[nulle]["sans_heure"] is True
        assert toutes[bonne]["sans_heure"] is False
    finally:
        with db.transaction() as cx:
            cx.execute("DELETE FROM captures WHERE utilisateur = ?", (uid,))


def test_filtre_sans_date(client):
    j = client.post("/inscription", json={"pseudo": "Dateur",
                                          "mdp": "motdepasse1"}).json()
    jeton, uid = j["jeton"], j["id"]
    with db.transaction() as cx:
        datee = _capture_posee(cx, uid, "datee", 48.85, "exif", "exif")
        sans = _capture_posee(cx, uid, "sansdate", 48.85, "exif", "defaut")
    try:
        vues = {p["capture_id"] for p in client.get(
            "/galerie?datees=false&limite=200",
            headers=entete(jeton)).json()["photos"]}
        assert sans in vues and datee not in vues
    finally:
        with db.transaction() as cx:
            cx.execute("DELETE FROM captures WHERE utilisateur = ?", (uid,))


# --------------------------------------------------------------- vitrine
#
# La vitrine existe pour mesurer autre chose que le rang du dex. Ces tests
# tiennent surtout à cette différence : si un jour le score se met à suivre le
# nombre de trouvailles, les deux jauges disent la même chose et l'une des deux
# ne sert plus à rien.

def _decouvre(cx, uid, cle_gbif, latin, rarete, points):
    cx.execute(
        """INSERT INTO cases (cle_gbif, regne, latin, nom_fr, genre, famille,
                              classe, obs, rarete, points, nb_alias)
           VALUES (?, 'animal', ?, ?, 'G', 'F', 'Mammalia', 10, ?, ?, 1)""",
        (cle_gbif, latin, latin, rarete, points))
    cid = cx.execute("SELECT id FROM cases WHERE cle_gbif = ?",
                     (cle_gbif,)).fetchone()[0]
    cx.execute(
        """INSERT INTO captures (utilisateur, etat, case_id, fichier, vignette,
                                 verdict, cree_le, partage, regne)
           VALUES (?, 'ok', ?, 'p.jpg', 'v.jpg', ?, '2026-08-01 10:00:00', 1,
                   'animal')""", (uid, cid, latin))
    cap = cx.execute("SELECT MAX(id) FROM captures WHERE utilisateur = ?",
                     (uid,)).fetchone()[0]
    cx.execute(
        """INSERT INTO decouvertes (utilisateur, case_id, premiere, trouve_le,
                                    nb_captures)
           VALUES (?, ?, ?, '2026-08-01 10:00:00', 1)""", (uid, cid, cap))
    return cid


def test_vitrine_recompense_la_rarete_pas_la_quantite(client):
    """Douze bonnes prises doivent battre trente banalités.

    C'est toute la raison d'être de la vitrine : le rang du dex classerait
    l'inverse.
    """
    a = client.post("/inscription", json={"pseudo": "Collectionneur",
                                          "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "Ramasseur",
                                          "mdp": "motdepasse1"}).json()
    cases = []
    with db.transaction() as cx:
        # Trois légendaires, rien d'autre.
        for i in range(3):
            cases.append(_decouvre(cx, a["id"], 90100 + i, f"Rara {i}", 5, 150))
        # Trente espèces communes.
        for i in range(30):
            cases.append(_decouvre(cx, b["id"], 90200 + i, f"Banalis {i}", 1, 5))
    try:
        va = client.get("/vitrine", headers=entete(a["jeton"])).json()
        vb = client.get("/vitrine", headers=entete(b["jeton"])).json()
        assert va["score"] == 450, va["score"]
        # Dix communes retenues sur trente : la onzième n'apporte rien.
        assert vb["score"] == 50, vb["score"]
        assert va["rang"]["numero"] > vb["rang"]["numero"]

        # Le dex, lui, classe dans l'autre sens — c'est bien deux mesures.
        ra = client.get("/dex/resume", headers=entete(a["jeton"])).json()
        rb = client.get("/dex/resume", headers=entete(b["jeton"])).json()
        assert rb["trouve"] > ra["trouve"]

        # Les pièces exposées sont les dix meilleures, dans l'ordre.
        pts = [p["points"] for p in vb["pieces"]]
        assert len(pts) == 10 and pts == sorted(pts, reverse=True)
    finally:
        with db.transaction() as cx:
            for uid in (a["id"], b["id"]):
                cx.execute("DELETE FROM decouvertes WHERE utilisateur = ?", (uid,))
                cx.execute("DELETE FROM captures WHERE utilisateur = ?", (uid,))
            cx.executemany("DELETE FROM cases WHERE id = ?", [(c,) for c in cases])


def test_vitrine_d_un_ami_visible_et_d_un_inconnu_refusee(client):
    moi = client.post("/inscription", json={"pseudo": "CarteCurieux",
                                            "mdp": "motdepasse1"}).json()
    autre = client.post("/inscription", json={"pseudo": "Inconnu",
                                              "mdp": "motdepasse1"}).json()
    r = client.get(f"/vitrine?joueur={autre['id']}", headers=entete(moi["jeton"]))
    assert r.status_code == 403, "un inconnu ne montre pas sa vitrine"

    with db.transaction() as cx:
        cx.execute(
            """INSERT INTO amities (demandeur, destinataire, etat, cree_le)
               VALUES (?, ?, 'acceptee', '2026-08-01 10:00:00')""",
            (moi["id"], autre["id"]))
    try:
        r = client.get(f"/vitrine?joueur={autre['id']}",
                       headers=entete(moi["jeton"]))
        assert r.status_code == 200, r.text
        assert r.json()["joueur"] == autre["id"]
    finally:
        with db.transaction() as cx:
            cx.execute("DELETE FROM amities WHERE demandeur = ?", (moi["id"],))


# ----------------------------------------------- espèces ajoutées par les joueurs
#
# Le moteur rend « Rosa gallica » pour tous les cultivars d'une roseraie : ces
# plantes ne sont pas des taxons, elles n'existent nulle part dans le backbone
# et n'y existeront jamais. Ces routes laissent les joueurs les ajouter au dex.
#
# La règle que ces tests protègent : **on ajoute à la base, pas au modèle**.
# Une case créée à la main ne doit jamais devenir une réponse possible d'une
# analyse — le moteur n'a pas appris à la reconnaître, et la proposer serait
# mentir.

def test_espece_ajoutee_apparait_au_dex_avec_son_auteur(client):
    j = client.post("/inscription", json={"pseudo": "Rosieriste",
                                          "mdp": "motdepasse1"}).json()
    r = client.post("/especes", headers=entete(j["jeton"]), json={
        "nom": "Rosier Sophie Vartan",
        "regne": "plante",
        "description": "Cultivar de rosier à grandes fleurs, rouge vif.",
    })
    assert r.status_code == 201, r.text
    e = r.json()
    assert e["ajoute_par"] == j["id"]
    assert e["ajoute_par_pseudo"] == "Rosieriste"
    assert e["actif"] is True

    # Elle est bien au dex, et son résumé a suivi.
    d = client.get(f"/dex/{e['id']}", headers=entete(j["jeton"]))
    assert d.status_code == 200, d.text

    mienne = client.get("/especes/miennes",
                        headers=entete(j["jeton"])).json()["especes"]
    assert [x["id"] for x in mienne] == [e["id"]]
    assert "rouge vif" in mienne[0]["resume"]


def test_une_espece_ajoutee_n_est_jamais_proposee_par_le_moteur(client):
    """La distinction qui tient tout le reste.

    Une case sans clé GBIF positive n'est dans aucun catalogue : le moteur ne
    peut pas la sortir. Ce test vérifie qu'on ne l'a pas glissée dans les
    alias d'un règne au point de la rendre atteignable par une analyse.
    """
    j = client.post("/inscription", json={"pseudo": "Prudent",
                                          "mdp": "motdepasse1"}).json()
    e = client.post("/especes", headers=entete(j["jeton"]), json={
        "nom": "Rosier de Test", "regne": "plante"}).json()

    ligne = db.lit_un("SELECT cle_gbif, obs FROM cases WHERE id = ?", (e["id"],))
    assert ligne["cle_gbif"] <= -100_000_000, \
        "la clé doit être hors de portée du backbone et des orphelins"
    assert ligne["obs"] == 0, "aucune observation GBIF ne peut exister"


def test_retrait_supprime_si_inutilisee_desactive_sinon(client):
    j = client.post("/inscription", json={"pseudo": "Repentant",
                                          "mdp": "motdepasse1"}).json()
    jeton = j["jeton"]

    # Sans photo : la case part pour de bon.
    vide = client.post("/especes", headers=entete(jeton),
                       json={"nom": "Erreur totale", "regne": "plante"}).json()
    r = client.delete(f"/especes/{vide['id']}", headers=entete(jeton)).json()
    assert r["supprimee"] is True
    assert db.lit_un("SELECT 1 FROM cases WHERE id = ?", (vide["id"],)) is None

    # Avec une photo : on désactive, la photo reste.
    tenue = client.post("/especes", headers=entete(jeton),
                        json={"nom": "Erreur habitée", "regne": "plante"}).json()
    with db.transaction() as cx:
        cx.execute(
            """INSERT INTO captures (utilisateur, etat, case_id, fichier, vignette,
                                     verdict, cree_le, partage, regne)
               VALUES (?, 'ok', ?, 'p.jpg', 'v.jpg', 'x', '2026-08-01 10:00:00',
                       1, 'plante')""", (j["id"], tenue["id"]))
    r = client.delete(f"/especes/{tenue['id']}", headers=entete(jeton)).json()
    assert r["desactivee"] is True and r["captures"] == 1
    assert db.lit_un("SELECT actif FROM cases WHERE id = ?",
                     (tenue["id"],))["actif"] == 0

    # Désactivée, elle sort du parcours du dex…
    vues = {c["id"] for c in client.get("/dex?limite=200",
                                        headers=entete(jeton)).json()["cases"]}
    assert tenue["id"] not in vues
    # …mais son auteur la retrouve pour la remettre en service.
    miennes = {x["id"]: x for x in client.get(
        "/especes/miennes", headers=entete(jeton)).json()["especes"]}
    assert miennes[tenue["id"]]["actif"] is False
    assert client.post(f"/especes/{tenue['id']}/reactive",
                       headers=entete(jeton)).json()["actif"] is True

    with db.transaction() as cx:
        cx.execute("DELETE FROM captures WHERE case_id = ?", (tenue["id"],))
        cx.execute("DELETE FROM alias WHERE case_id = ?", (tenue["id"],))
        cx.execute("DELETE FROM cases WHERE id = ?", (tenue["id"],))


def test_on_ne_touche_pas_a_l_espece_d_un_autre(client):
    a = client.post("/inscription", json={"pseudo": "AuteurEspece",
                                          "mdp": "motdepasse1"}).json()
    b = client.post("/inscription", json={"pseudo": "IntrusEspece",
                                          "mdp": "motdepasse1"}).json()
    e = client.post("/especes", headers=entete(a["jeton"]),
                    json={"nom": "Chasse gardée", "regne": "plante"}).json()
    try:
        assert client.patch(f"/especes/{e['id']}", headers=entete(b["jeton"]),
                            json={"nom": "Volée"}).status_code == 403
        assert client.delete(f"/especes/{e['id']}",
                             headers=entete(b["jeton"])).status_code == 403
        # Et une case venue de GBIF n'appartient à personne.
        assert client.delete("/especes/1",
                             headers=entete(a["jeton"])).status_code == 403
    finally:
        client.delete(f"/especes/{e['id']}", headers=entete(a["jeton"]))


# ------------------------------------------------------------------- cache
#
# Le serveur posait un ETag mais ne le relisait jamais : un client discipliné,
# qui gardait l'image et demandait poliment si elle avait changé, recevait
# quand même les 42 Ko. Sur une grille qui défile, c'est des mégaoctets pour
# rien — poussés par un serveur sans GPU.

def test_une_image_deja_connue_n_est_pas_renvoyee(client):
    j = client.post("/inscription", json={"pseudo": "Econome",
                                          "mdp": "motdepasse1"}).json()
    jeton = j["jeton"]
    cid = client.post("/captures", headers=entete(jeton),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")}).json()["id"]

    for chemin in (f"/captures/{cid}/photo", f"/captures/{cid}/vignette"):
        premiere = client.get(chemin, headers=entete(jeton))
        assert premiere.status_code == 200, chemin
        marque = premiere.headers.get("etag")
        assert marque, f"{chemin} doit porter un ETag"
        assert "max-age" in premiere.headers.get("cache-control", ""), \
            f"{chemin} doit dire combien de temps le garder"

        seconde = client.get(chemin, headers={**entete(jeton),
                                              "If-None-Match": marque})
        assert seconde.status_code == 304, f"{chemin} devait répondre 304"
        assert not seconde.content, "un 304 ne porte pas de corps"


def test_un_fichier_modifie_change_d_empreinte(client):
    """Recadrer sa photo doit se voir tout de suite.

    L'empreinte vient de la date de modification et de la taille : un fichier
    réécrit en change, donc le client retélécharge. Sans cela, un joueur qui
    reprend son tracé au doigt verrait l'ancien pendant un mois.
    """
    import pathlib
    import tempfile
    import time

    from biodex import cache as cache_mod

    f = pathlib.Path(tempfile.gettempdir()) / "essai-empreinte.bin"
    f.write_bytes(b"avant")
    try:
        avant = cache_mod.empreinte(f)
        time.sleep(0.01)
        f.write_bytes(b"apres, plus long")
        assert cache_mod.empreinte(f) != avant
    finally:
        f.unlink(missing_ok=True)


# --------------------------------------------------------------- le fil SSE

def test_le_fil_libere_ses_abonnes_a_la_deconnexion():
    """Une connexion fermée ne doit rien laisser derrière elle.

    C'est la seule fuite possible du mécanisme : le dictionnaire d'abonnés
    grossirait à chaque onglet ouvert puis fermé, sur un serveur qui tourne des
    mois sans redémarrer. La libération se fait dans un `finally`, et ce test
    est là pour qu'elle y reste.

    On pilote le générateur à la main plutôt que par `TestClient` : celui-ci
    n'a aucune notion de connexion qui dure, et attend la fin d'une réponse qui
    par construction n'en a pas.
    """
    import asyncio

    from biodex import flux
    from biodex.routes.notifications import fil

    class RequeteFactice:
        async def is_disconnected(self):
            return False

    async def scenario():
        depart = flux.combien()
        reponse = await fil(RequeteFactice(), u={"id": 4242})
        morceaux = reponse.body_iterator

        # Le premier message part tout de suite : c'est lui qui confirme au
        # client que la connexion tient.
        assert await morceaux.__anext__() == b"event: ouvert\ndata: 1\n\n"
        assert flux.combien() == depart + 1

        # Un événement déposé ailleurs ressort ici.
        flux.signale(4242)
        assert await morceaux.__anext__() == b"event: notifications\ndata: 1\n\n"

        # Le client s'en va.
        await morceaux.aclose()
        assert flux.combien() == depart

    asyncio.run(scenario())


def test_signaler_quelquun_qui_n_ecoute_pas_ne_casse_rien():
    """Prévenir est un bonus : rater un réveil ne doit jamais faire échouer
    l'action qui l'a provoqué. Ici, personne n'écoute."""
    from biodex import flux
    flux.signale(999999)


def test_le_fil_ne_repond_pas_sans_jeton(client):
    """Un flux ouvert sans session laisserait fuiter l'activité de n'importe
    qui à quiconque devine l'URL."""
    assert client.get("/notifications/flux").status_code == 401


def test_un_ami_identifie_decroche_le_succes_de_l_heure(client):
    """« On était là tous les deux » vaut aussi pour les succès.

    Les cases et les points comptaient déjà pour la personne identifiée sur une
    photo ; les succès mesurés sur les photos l'ignoraient. Deux amis sortis à
    l'aube, une seule photo, un seul « Lève-tôt » : c'est ce qu'on corrige.

    « Bon oeil » reste personnel, lui : il récompense un acte — corriger une
    identification — et non le fait d'avoir été là.
    """
    from biodex.moteur import Resultat, file as file_moteur

    a = client.post("/inscription",
                    json={"pseudo": "Matinal", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription",
                    json={"pseudo": "SonAmi", "mdp": "motdepasse1"}).json()
    client.post("/amis/demandes", headers=entete(a["jeton"]),
                json={"pseudo": "SonAmi"})
    did = client.get("/amis/demandes",
                     headers=entete(b["jeton"])).json()["recues"][0]["demande_id"]
    client.post(f"/amis/demandes/{did}/accepter", headers=entete(b["jeton"]))

    def avancement(joueur, cle):
        d = client.get("/succes", headers=entete(joueur["jeton"])).json()
        return next(s["avancement"] for s in d["succes"] if s["cle"] == cle)

    avant = avancement(b, "leve_tot")

    cid = client.post("/captures", headers=entete(a["jeton"]),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")},
                      data={"partage": "true"}).json()["id"]
    file_moteur._enregistre(cid, a["id"],
                            Resultat(etat="ok", verdict="x", case_id=1,
                                     niveau="espece", confiance=0.9))
    # Une heure qui tombe dans la plage du Lève-tôt, posée à la main : c'est ce
    # que le succès exige (`source_heure` doit valoir « exif » ou « manuel »).
    client.patch(f"/captures/{cid}/lieu", headers=entete(a["jeton"]),
                 json={"prise_le": "2026-05-04 05:30:00"})

    # Avant l'identification, l'ami n'a rien.
    assert avancement(b, "leve_tot") == avant

    r = client.post(f"/captures/{cid}/participants", headers=entete(a["jeton"]),
                    json={"pseudos": ["SonAmi"]})
    assert r.status_code == 200, r.text
    assert b["id"] in [x["id"] for x in r.json()["participants"]], r.text

    assert avancement(b, "leve_tot") == avant + 1, \
        "l'ami identifié doit décrocher le succès comme s'il avait pris la photo"
    # Et la personne qui a réellement pris la photo l'a aussi, évidemment.
    assert avancement(a, "leve_tot") >= 1


def test_activite_ami_ne_spamme_pas(client):
    """Une seule notification par ami, quel que soit le nombre de photos.

    Le cas réel : quelqu'un rentre de balade et vide sa pellicule. Sans
    regroupement, son ami reçoit une notification par photo. Ici la ligne
    existante grossit tant qu'elle n'a pas été lue, et une seule reparaît
    ensuite.
    """
    from biodex.moteur import Resultat, file as file_moteur

    a = client.post("/inscription",
                    json={"pseudo": "Baladeur", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription",
                    json={"pseudo": "SonVoisin", "mdp": "motdepasse1"}).json()
    ea, eb = entete(a["jeton"]), entete(b["jeton"])

    client.post("/amis/demandes", headers=ea, json={"pseudo": "SonVoisin"})
    did = client.get("/amis/demandes", headers=eb).json()["recues"][0]["demande_id"]
    assert client.post(f"/amis/demandes/{did}/accepter",
                       headers=eb).status_code == 200
    # La catégorie est éteinte par défaut : sans elle on ne mesurerait rien.
    assert client.put("/notifications/reglages", headers=eb,
                  json={"reglages": {"ami_actif": True}}).status_code == 200

    def publie(n):
        for _ in range(n):
            cid = client.post("/captures", headers=ea,
                              files={"photo": ("p.jpg", _photo(), "image/jpeg")}
                              ).json()["id"]
            file_moteur._enregistre(cid, a["id"],
                                    Resultat(etat="ok", verdict="Vache",
                                             case_id=1, niveau="espece",
                                             confiance=0.9))

    publie(5)
    recues = [n for n in client.get("/notifications", headers=eb).json()["notifications"]
              if n["type"] == "ami_actif"]
    assert len(recues) == 1, f"cinq photos ont fait {len(recues)} notifications"
    assert recues[0]["nb_trouvailles"] == 5

    # Une fois lue, la publication suivante a de nouveau le droit de prévenir.
    client.post("/notifications/lues", headers=eb)
    publie(1)
    recues = [n for n in client.get("/notifications", headers=eb).json()["notifications"]
              if n["type"] == "ami_actif" and not n["lu"]]
    assert len(recues) == 1 and recues[0]["nb_trouvailles"] == 1


def test_activite_ami_porte_une_photo_representative(client):
    """La notification groupée a désormais une image, et la bonne.

    `ami_actif` garde `capture` à NULL — c'est ce qui porte la clé d'unicité
    du regroupement — donc `vignette` était toujours vide avant `apercu` :
    un badge, jamais une photo. Ici on vérifie qu'elle existe, et qu'elle
    suit la dernière trouvaille plutôt que de rester figée sur la première.
    """
    from biodex.moteur import Resultat, file as file_moteur

    a = client.post("/inscription",
                    json={"pseudo": "Sourcier", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription",
                    json={"pseudo": "SaSuivante", "mdp": "motdepasse1"}).json()
    ea, eb = entete(a["jeton"]), entete(b["jeton"])

    client.post("/amis/demandes", headers=ea, json={"pseudo": "SaSuivante"})
    did = client.get("/amis/demandes", headers=eb).json()["recues"][0]["demande_id"]
    client.post(f"/amis/demandes/{did}/accepter", headers=eb)
    client.put("/notifications/reglages", headers=eb,
              json={"reglages": {"ami_actif": True}})

    def publie():
        cid = client.post("/captures", headers=ea,
                          files={"photo": ("p.jpg", _photo(), "image/jpeg")}
                          ).json()["id"]
        file_moteur._enregistre(cid, a["id"],
                                Resultat(etat="ok", verdict="Vache",
                                         case_id=1, niveau="espece",
                                         confiance=0.9))
        return cid

    premiere = publie()
    n = next(n for n in client.get("/notifications", headers=eb).json()["notifications"]
             if n["type"] == "ami_actif")
    assert n["vignette"] == f"/captures/{premiere}/vignette"

    derniere = publie()
    n = next(n for n in client.get("/notifications", headers=eb).json()["notifications"]
             if n["type"] == "ami_actif")
    assert n["vignette"] == f"/captures/{derniere}/vignette", \
        "l'aperçu doit suivre la dernière photo, pas rester sur la première"
    assert n["capture_id"] is None, \
        "aucune photo précise : c'est un ami qui est actif, pas une trouvaille"


def test_espece_ajoutee_porte_le_bon_case_id(client):
    """Le clic sur « espèce indexée » mène quelque part.

    `previens()` reçoit le `case_id` dans `valeur` pour ce type — il n'y a pas
    de capture à joindre. Sans repli explicite dans la sérialisation, `case_id`
    ressortait toujours NULL : la notification existait, mais ne menait nulle
    part, sur le site comme dans l'application.
    """
    from biodex.routes.notifications import previens

    a = client.post("/inscription",
                    json={"pseudo": "Indexeur", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription",
                    json={"pseudo": "Curieuse2", "mdp": "motdepasse1"}).json()
    ea, eb = entete(a["jeton"]), entete(b["jeton"])

    client.post("/amis/demandes", headers=ea, json={"pseudo": "Curieuse2"})
    did = client.get("/amis/demandes", headers=eb).json()["recues"][0]["demande_id"]
    client.post(f"/amis/demandes/{did}/accepter", headers=eb)

    previens(b["id"], a["id"], "espece_ajoutee", valeur=1)
    n = next(n for n in client.get("/notifications", headers=eb).json()["notifications"]
             if n["type"] == "espece_ajoutee")
    assert n["case_id"] == 1


def test_suppression_en_lot_epargne_les_captures_rangees(client):
    """Le tri des indéterminées ne peut pas emporter une découverte.

    Le filtre est dans le SQL et non côté client, précisément pour que ça
    reste vrai même avec une liste d'identifiants fabriquée à la main. On
    envoie donc les deux ensemble et on vérifie que seule la photo sans espèce
    s'en va.
    """
    from biodex.moteur import Resultat, file as file_moteur

    j = client.post("/inscription",
                    json={"pseudo": "LotTrieuse", "mdp": "motdepasse1"}).json()
    e = entete(j["jeton"])

    def depose():
        return client.post("/captures", headers=e,
                           files={"photo": ("p.jpg", _photo(), "image/jpeg")}
                           ).json()["id"]

    rangee, perdue = depose(), depose()
    file_moteur._enregistre(rangee, j["id"],
                            Resultat(etat="ok", verdict="Vache", case_id=1,
                                     niveau="espece", confiance=0.9))
    file_moteur._enregistre(perdue, j["id"],
                            Resultat(etat="doute", verdict="Non identifiée",
                                     case_id=None, confiance=0.0))

    attente = client.get("/captures/non-identifiees", headers=e).json()["captures"]
    assert {c["capture_id"] for c in attente} == {perdue}

    r = client.post("/captures/non-identifiees/suppression", headers=e,
                    json={"ids": [rangee, perdue]})
    assert r.status_code == 200, r.text
    assert r.json()["supprimees"] == 1, "la capture rangée devait être épargnée"

    assert client.get(f"/captures/{rangee}", headers=e).status_code == 200
    assert client.get(f"/captures/{perdue}", headers=e).status_code == 404
    assert client.get("/captures/non-identifiees", headers=e).json()["captures"] == []


def test_suppression_en_lot_ne_touche_pas_les_photos_d_autrui(client):
    """Un identifiant volé ne suffit pas : la requête filtre aussi sur le compte."""
    from biodex.moteur import Resultat, file as file_moteur

    a = client.post("/inscription",
                    json={"pseudo": "LotProprio", "mdp": "motdepasse1"}).json()
    b = client.post("/inscription",
                    json={"pseudo": "LotCurieux", "mdp": "motdepasse1"}).json()

    cid = client.post("/captures", headers=entete(a["jeton"]),
                      files={"photo": ("p.jpg", _photo(), "image/jpeg")}
                      ).json()["id"]
    file_moteur._enregistre(cid, a["id"],
                            Resultat(etat="doute", verdict="Non identifiée",
                                     case_id=None, confiance=0.0))

    r = client.post("/captures/non-identifiees/suppression",
                    headers=entete(b["jeton"]), json={"ids": [cid]})
    assert r.status_code == 200 and r.json()["supprimees"] == 0
    assert client.get(f"/captures/{cid}", headers=entete(a["jeton"])).status_code == 200


def test_carte_distingue_les_photos_d_amis_jamais_vues(client):
    """La carte met en avant ce qu'on n'a pas encore regardé chez ses amis :
    ouvrir la photo la marque vue, et « nouvelles » ne la rend plus."""
    from biodex.moteur import Resultat, file as file_moteur

    ra = client.post("/inscription", json={"pseudo": "RegardeurA", "mdp": "motdepasse1"})
    assert ra.status_code == 201, ra.text
    a = ra.json()
    b = client.post("/inscription", json={"pseudo": "RegardeurB", "mdp": "motdepasse1"}).json()

    def pose(jeton, uid, lat, lon):
        cid = client.post("/captures", headers=entete(jeton),
                          files={"photo": ("p.jpg", _photo(), "image/jpeg")},
                          data={"lat": str(lat), "lon": str(lon), "partage": "true"}).json()["id"]
        file_moteur._enregistre(cid, uid, Resultat(etat="ok", verdict="Vache",
                                                   case_id=1, niveau="espece",
                                                   confiance=0.9))
        return cid

    mienne = pose(a["jeton"], a["id"], 48.85, 2.35)
    une = pose(b["jeton"], b["id"], 45.76, 4.83)
    deux = pose(b["jeton"], b["id"], 45.77, 4.84)

    client.post("/amis/demandes", headers=entete(a["jeton"]), json={"pseudo": "RegardeurB"})
    did = client.get("/amis/demandes",
                     headers=entete(b["jeton"])).json()["recues"][0]["demande_id"]
    client.post(f"/amis/demandes/{did}/accepter", headers=entete(b["jeton"]))

    vues = {p["capture_id"]: p["vue"]
            for p in client.get("/carte", headers=entete(a["jeton"])).json()["points"]}
    assert vues[mienne] is True            # la mienne : je l'ai prise, je l'ai vue
    assert vues[une] is False and vues[deux] is False
    assert all("regne" in p for p in client.get("/carte", headers=entete(a["jeton"])).json()["points"])

    # Ouvrir la photo la marque vue.
    client.get(f"/captures/{une}", headers=entete(a["jeton"]))
    nouvelles = {p["capture_id"] for p in client.get(
        "/carte", params={"nouvelles": "true"},
        headers=entete(a["jeton"])).json()["points"]}
    assert nouvelles == {deux}

    # L'auteur qui ouvre sa propre photo ne la marque pas « vue » pour autant
    # chez les autres : chacun son regard.
    client.get(f"/captures/{deux}", headers=entete(b["jeton"]))
    assert deux in {p["capture_id"] for p in client.get(
        "/carte", params={"nouvelles": "true"}, headers=entete(a["jeton"])).json()["points"]}

    # « Tout marquer comme vu ».
    r = client.post("/captures/vues", headers=entete(a["jeton"]), json={"ids": [deux, mienne]})
    assert r.status_code == 200 and r.json()["vues"] == 1   # la mienne est ignorée
    assert client.get("/carte", params={"nouvelles": "true"},
                      headers=entete(a["jeton"])).json()["points"] == []


def test_les_donnees_servies_suivent_accept_language(client):
    """Les noms de rangs et de succès sont traduits à la sortie, dans la
    langue annoncée par le client ; sans en-tête, ou pour une langue inconnue,
    le français reste."""
    j = client.post("/inscription", json={"pseudo": "Polyglotte", "mdp": "motdepasse1"}).json()
    en = client.get("/paliers", headers={**entete(j["jeton"]), "Accept-Language": "en-GB,en;q=0.9"}).json()
    fr = client.get("/paliers", headers=entete(j["jeton"])).json()
    xx = client.get("/paliers", headers={**entete(j["jeton"]), "Accept-Language": "xx"}).json()
    assert en["paliers"][0]["nom"] == "Larva"
    assert fr["paliers"][0]["nom"] == "Larve" and xx["paliers"][0]["nom"] == "Larve"
    s = client.get("/succes", headers={**entete(j["jeton"]), "Accept-Language": "en"}).json()
    noms = {x["nom"] for x in s.get("succes", s if isinstance(s, list) else [])}
    assert "First step" in noms
