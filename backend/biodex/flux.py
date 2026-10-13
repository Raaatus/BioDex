"""
Le fil temps réel : prévenir au moment où ça arrive.

**Pourquoi pas du sondage.** Un badge de notifications rafraîchi toutes les
dix secondes, c'est six requêtes par minute et par onglet ouvert, dont la
quasi-totalité ne rapporte rien. À cinq personnes qui laissent l'onglet ouvert
la journée, ça fait quarante mille requêtes pour une poignée d'événements
réels. Ici la connexion reste ouverte et ne coûte rien tant que rien ne se
passe : c'est exactement l'inverse.

**Ce qui circule.** Pas le contenu des notifications — seulement le fait qu'il
y a du neuf. Le client rappelle alors `/notifications` normalement. C'est une
requête de plus, et ça évite de dupliquer ici toute la mise en forme des
notifications, qui dériverait de son original à la première évolution.

**La contrainte technique.** Les routes qui écrivent sont synchrones : FastAPI
les exécute dans un fil d'exécution séparé, pas dans la boucle asyncio. On ne
peut donc pas toucher une file asyncio directement depuis `previens()` —
`call_soon_threadsafe` est là pour ça, et c'est la seule façon correcte de
franchir cette frontière.
"""
import asyncio
import threading

# Un abonné = la boucle qui l'anime, et la file où déposer ses réveils. Une
# personne peut en avoir plusieurs : deux onglets, ou le téléphone et le
# portable. Tous doivent être prévenus.
_verrou = threading.Lock()
_abonnes: dict[int, set[tuple[asyncio.AbstractEventLoop, asyncio.Queue]]] = {}


def abonne(uid: int) -> asyncio.Queue:
    """Ouvre une file de réveils pour cette personne. À rendre avec `oublie`."""
    file: asyncio.Queue = asyncio.Queue(maxsize=32)
    with _verrou:
        _abonnes.setdefault(uid, set()).add((asyncio.get_running_loop(), file))
    return file


def oublie(uid: int, file: asyncio.Queue) -> None:
    """Ferme un abonnement.

    Ne rien laisser derrière : un abonné oublié fait grossir le dictionnaire
    indéfiniment sur un serveur qui tourne des mois.
    """
    with _verrou:
        restants = _abonnes.get(uid)
        if not restants:
            return
        parti = next((a for a in restants if a[1] is file), None)
        if parti is not None:
            restants.discard(parti)
        if not restants:
            _abonnes.pop(uid, None)


def signale(uid: int, quoi: str = "notifications") -> None:
    """Réveille les connexions de cette personne, s'il y en a.

    Appelable depuis n'importe quel fil. Ne lève jamais : prévenir est un
    bonus, et rater un réveil ne doit surtout pas faire échouer l'action qui
    l'a provoqué — la notification est déjà en base, elle sera vue au prochain
    chargement.
    """
    with _verrou:
        cibles = list(_abonnes.get(uid, ()))
    for boucle, file in cibles:
        try:
            boucle.call_soon_threadsafe(_depose, file, quoi)
        except RuntimeError:
            # Boucle fermée : l'abonné est parti sans se désinscrire.
            pass


def _depose(file: asyncio.Queue, quoi: str) -> None:
    try:
        file.put_nowait(quoi)
    except asyncio.QueueFull:
        # Une file pleine, c'est un client qui ne lit plus. On laisse tomber le
        # réveil : il en recevra un autre, et `/notifications` lui donnera de
        # toute façon l'état complet.
        pass


def combien() -> int:
    """Le nombre de connexions ouvertes, pour la supervision."""
    with _verrou:
        return sum(len(s) for s in _abonnes.values())
