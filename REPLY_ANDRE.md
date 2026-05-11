# Reply — André Freyssinet
# Suite au retour sur le rapport

---

**Subject:** Re: Rapport intermédiaire — corrections appliquées

---

André,

Merci pour la relecture détaillée. J'ai appliqué toutes les corrections.

Voici ce qui a changé :

- La description des softirqs en §2.2 est corrigée : ils s'exécutent en contexte d'interruption et basculent vers `ksoftirqd` sous charge, pas systématiquement dans des threads dédiés.
- La formulation wireguard-go en §4 intègre maintenant la nuance : l'écart mesuré est une borne inférieure sur l'overhead workqueue, puisque wireguard-go a ses propres coûts (frontière user/kernel, TUN, appels système).
- Quelques corrections mineures : cohérence du pourcentage (19.2% partout), "a prerequisite" au lieu de "the prerequisite", "attribute the overhead", virgule parasite en §3 transformée en phrase propre.

Je vous joins le PDF mis à jour.

Pour la suite : je ne suis plus en stage jusqu'au début du temps plein. On se voit mercredi 13 mai pour lancer la phase de reproduction.

Cordialement,
Anas
