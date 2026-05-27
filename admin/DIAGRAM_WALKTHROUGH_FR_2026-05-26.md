# Présentation des diagrammes — Réunion 26 mai 2026
# Points de présentation détaillés — Alain Tchana + André Freyssinet

---

## Diagramme 1 — Vue d'ensemble du pipeline à trois étages

**Ce que montre ce diagramme :** la structure complète du pipeline de réception WireGuard et le point exact où se produit l'EoI.

---

**Ce qu'il faut dire :**

"Je vais commencer par le diagramme général pour qu'on ait tous la même vue d'ensemble avant d'entrer dans les détails.

Le pipeline de réception WireGuard se compose de trois étages successifs et obligatoires. Chaque paquet chiffré reçu par la machine passe par les trois étages dans cet ordre.

**Étage 1 — Le gestionnaire UDP** (`wg_packet_receive`, `receive.c`). Cet étage s'exécute dans le contexte BH (*bottom half*) — c'est-à-dire dans un contexte interruptible de haute priorité, déclenché par l'interruption matérielle de la carte réseau. Le travail de cet étage est minimal : il lit l'en-tête UDP, identifie le peer source par sa clé publique, puis place le paquet dans deux files d'attente simultanément (on verra ça en détail dans le diagramme 2). Cet étage ne déchiffre rien.

**Étage 2 — La workqueue de déchiffrement** (`packet_crypt_wq`). C'est ici que le déchiffrement ChaCha20-Poly1305 se passe. Cette workqueue est créée avec les flags `WQ_PERCPU | WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM` — ce qui signifie qu'il y a exactement un thread worker par cœur CPU en ligne. Ces workers tournent à priorité normale — `SCHED_NORMAL` dans le scheduler Linux. C'est important : priorité normale veut dire que les softirqs peuvent les préempter.

**Étage 3 — GRO** (*Generic Receive Offload*, `wg_packet_rx_poll`, `receive.c:438`). GRO réassemble les paquets déchiffrés et les livre à la pile réseau Linux — TCP/IP par exemple. GRO s'exécute comme un *softirq*, c'est-à-dire à haute priorité, en tant que `NET_RX_SOFTIRQ`. Un softirq peut s'exécuter à n'importe quel point de réactivation du BH dans le code normal.

**Le côté droit du diagramme montre l'EoI.**

Après chaque déchiffrement, le worker appelle `napi_schedule(&peer->napi)` à la ligne `queueing.h:196`. Cette fonction lève `NET_RX_SOFTIRQ` et marque l'instance NAPI du peer comme 'à exécuter'. Le softirq se déclenche au prochain `spin_unlock_bh` dans la boucle du worker lui-même — c'est-à-dire à l'itération suivante, quand le worker fait `ptr_ring_consume_bh` pour chercher le paquet suivant. GRO s'exécute. Il regarde la tête de la file du peer. Dans la majorité des cas, cette tête est encore à l'état UNCRYPTED — parce que d'autres CPUs décryptent encore les paquets précédents. GRO retourne `work_done = 0`. Rien n'est livré. Le cycle CPU est gaspillé.

Le problème fondamental est là : `napi_schedule` est appelé de façon **inconditionnelle** après **chaque paquet déchiffré**, sans vérifier si GRO peut réellement faire quelque chose."

---

## Diagramme 2 — Les deux files d'attente parallèles

**Ce que montre ce diagramme :** la séparation structurelle entre la file globale du device et la file par peer, et l'enqueuement en deux phases.

---

**Ce qu'il faut dire :**

"Ce diagramme est fondamental — c'est la structure de données qui explique pourquoi le bug existe.

Il y a deux files d'attente complètement indépendantes, avec des rôles distincts.

**La file globale du device** (`ptr_ring`, `decrypt_queue`). Il y a **une seule** file pour tout le device WireGuard — tous les peers confondus. Quand un paquet arrive de Peer A, Peer B, ou Peer C, il finit dans cette même file. Cette file détermine **quel CPU déchiffre quel paquet**. Les workers des différents CPUs consomment cette file avec `ptr_ring_consume_bh`. L'attribution des CPUs se fait par round-robin approximatif via `wg_cpumask_next_online` (`queueing.h:164`).

**La file par peer** (`prev_queue`). Il y a **une file par peer**. Cette file ne contient que les paquets d'un seul peer, dans l'ordre d'arrivée strict. Cette file détermine **l'ordre de livraison** à la pile réseau. GRO parcourt cette file depuis le paquet le plus ancien (`tail`) vers le plus récent, et s'arrête au premier paquet UNCRYPTED.

**L'enqueuement en deux phases** — c'est la clé de tout (`queueing.h:152`, `wg_queue_enqueue_per_device_and_peer`) :

Phase 1 : le paquet est inséré dans la file par peer avec état = UNCRYPTED. **L'ordre de livraison est fixé ici**, avant tout déchiffrement. Cette phase établit la garantie d'ordre.

Phase 2 : le paquet est inséré dans la file globale, et un worker est dispatché sur un CPU via `queue_work_on(cpu, wq, work)`. **L'attribution CPU se fait ici**, après que l'ordre est déjà fixé.

Ces deux rôles sont totalement séparés par conception. Il n'y a pas de verrou — la coordination se fait uniquement via le champ `state` du paquet (`UNCRYPTED` → `CRYPTED` ou `DEAD`), mis à jour atomiquement par le worker avec `atomic_set_release`.

**La conséquence directe :** un paquet peut être à la position 3 dans la file du peer (c'est-à-dire que GRO ne peut pas l'atteindre avant les positions 0, 1, 2), mais il peut être décrypté en premier par CPU 3 pendant que les positions 0, 1, 2 sont encore UNCRYPTED. Dès que CPU 3 appelle `napi_schedule`, GRO s'exécute — mais il trouve UNCRYPTED à la tête et sort sans rien faire."

---

## Diagramme 3 — Le scénario de déchiffrement concurrent et le déclenchement de l'EoI

**Ce que montre ce diagramme :** le scénario complet en quatre panneaux — distribution des paquets, timeline de déchiffrement, état de la file au moment du déclenchement GRO, et comportement du poll GRO.

---

**Ce qu'il faut dire :**

"Ce diagramme montre le scénario concret. C'est l'argument central.

**Panneau 1 — La distribution initiale.**

Quatre paquets arrivent en séquence depuis le même peer. L'étage 1 les enfile dans la file du peer dans l'ordre d'arrivée : pkt 0, pkt 1, pkt 2, pkt 3. Simultanément, ils sont assignés en round-robin : pkt 0 → CPU 0, pkt 1 → CPU 1, pkt 2 → CPU 2, pkt 3 → CPU 3. Source : `queueing.h:164`, `wg_cpumask_next_online`.

**Panneau 2 — La timeline de déchiffrement.**

CPU 0 était occupé à finir le paquet précédent d'un autre peer quand les quatre nouveaux paquets sont arrivés. Il commence donc à déchiffrer pkt 0 *après* que les CPUs 1, 2, 3 ont déjà commencé leurs paquets. C'est le **désavantage systématique du paquet en tête** : le paquet en position 0 — celui dont GRO a besoin en premier — est structurellement le dernier à commencer son déchiffrement.

CPU 3 finit en premier. Il appelle `wg_queue_enqueue_per_peer_rx` (`queueing.h:188`), qui fait deux choses : `atomic_set_release(&PACKET_CB(skb)->state, PACKET_STATE_CRYPTED)` — marque pkt 3 CRYPTED — puis `napi_schedule(&peer->napi)` — déclenche GRO.

**Panneau 3 — L'état de la file au moment du déclenchement.**

Au moment où GRO s'exécute :
- pkt 0 : UNCRYPTED (CPU 0 déchiffre encore)
- pkt 1 : UNCRYPTED (CPU 1 déchiffre encore)
- pkt 2 : UNCRYPTED (CPU 2 déchiffre encore)
- pkt 3 : CRYPTED (CPU 3 vient de finir)

La file montre `tail` pointant vers pkt 0 — le plus ancien. C'est là que GRO commence.

**Panneau 4 — Le comportement de wg_packet_rx_poll.**

`wg_packet_rx_poll` (`receive.c:451`) — la boucle while :
```c
while ((skb = wg_prev_queue_peek(&peer->rx_queue)) != NULL &&
       atomic_read_acquire(&PACKET_CB(skb)->state) != PACKET_STATE_UNCRYPTED)
```
Premier paquet : pkt 0, état = UNCRYPTED → condition fausse → la boucle ne s'exécute pas. `work_done = 0`. `napi_complete_done` est appelé car `work_done < budget` (`receive.c:487`) — ce qui efface `NAPI_STATE_SCHED` et réarme le NAPI. GRO repart.

**Le modèle probabiliste.**

La probabilité que le paquet en tête finisse en premier parmi N déchiffrements concurrents est 1/N (en supposant des durées de déchiffrement uniformes).

| N CPUs | P(succès GRO) | P(appels gaspillés) |
|---|---|---|
| 2 | 50% | 50% |
| 4 | 25% | 75% |
| 8 | 12.5% | **87.5%** |
| 16 | 6.25% | 93.75% |

Mais c'est une borne supérieure — en réalité c'est pire, à cause du désavantage systématique du paquet en tête expliqué dans le panneau 2. Et le trigger se déclenche pour **chaque paquet individuel**, pas une fois par batch. Sur un trafic soutenu de 25 Gbps avec 1000 clients, il y a des milliers de déchiffrements par milliseconde. La quasi-totalité déclenchent un `napi_schedule` inutile.

C'est ça qui explique les 94% d'utilisation CPU mesurés par Mounah et al. Le cœur ne fait pas du travail utile — il alterne entre déchiffrement et appels GRO inutiles dans une boucle serrée par paquet."

---

## Diagramme 4 — Le détail du worker de déchiffrement (le bug en boucle)

**Ce que montre ce diagramme :** le comportement exact du worker sur deux itérations consécutives — où le softirq se déclenche dans la boucle, et le cycle auto-renforcant.

---

**Ce qu'il faut dire :**

"Ce diagramme zoome sur ce qui se passe à l'intérieur d'un seul worker — CPU 0 — sur deux itérations consécutives. C'est pour montrer que le gaspillage est intégré dans la boucle du worker lui-même, pas à un niveau supérieur.

**Itération N.**

Le worker appelle `ptr_ring_consume_bh` pour récupérer un paquet depuis la file globale. Le suffixe `_bh` signifie que cette fonction **désactive le BH** pendant l'opération (elle fait `spin_lock_bh` en interne). Pendant que le BH est désactivé, aucun softirq ne peut s'exécuter sur ce CPU.

Le worker déchiffre le paquet — travail utile, ChaCha20-Poly1305.

Ensuite `wg_queue_enqueue_per_peer_rx` (`queueing.h:188`) : marque CRYPTED, appelle `napi_schedule`. Le flag `NET_RX_SOFTIRQ` est levé — le softirq est en attente.

Le worker appelle `ptr_ring_consume_bh` pour le paquet suivant. **À l'intérieur de cet appel**, quand `spin_unlock_bh` est appelé pour relâcher le verrou, le BH est réactivé. Le softirq en attente s'exécute **immédiatement à ce point** — c'est la sémantique de `spin_unlock_bh`. GRO s'exécute, trouve UNCRYPTED à la tête, retourne `work_done = 0`, `napi_complete_done` efface le flag.

Le worker reprend depuis `ptr_ring_consume_bh`. Il a perdu le temps d'exécution du softirq.

**Itération N+1.** Exactement pareil. Même déchiffrement. Même `napi_schedule`. Même softirq. Même gaspillage.

**Le cycle auto-renforcant** (côté droit du diagramme) :
1. Worker déchiffre pkt N
2. Worker appelle `napi_schedule`
3. Softirq se déclenche au prochain `spin_unlock_bh`
4. GRO trouve UNCRYPTED → `work_done = 0`
5. Worker reprend → déchiffre pkt N+1 → retour à l'étape 2

Ce cycle tourne pour **chaque paquet individuel**. Un seul cœur sature à 94% en tournant dans ce cycle. Les autres cœurs font le même travail utile mais le résultat ne peut pas être livré parce que la tête de la file est bloquée."

---

## Diagramme 5 — Le correctif : napi_schedule conditionnel

**Ce que montre ce diagramme :** le code patché, deux scénarios concrets (tête UNCRYPTED et tête CRYPTED), la limitation résiduelle, et la comparaison avant/après.

---

**Ce qu'il faut dire :**

"Ce diagramme présente le correctif que vous avez proposé lors de la réunion du 21 mai.

**L'idée centrale :** avant d'appeler `napi_schedule`, vérifier si GRO peut réellement faire quelque chose. Si la tête de la file du peer est encore UNCRYPTED, GRO va retourner `work_done = 0` peu importe ce qu'on fait — donc on n'appelle pas `napi_schedule`.

**Le nouveau code (haut gauche) — `wg_queue_enqueue_per_peer_rx` patchée :**

Après `atomic_set_release` (marquer CRYPTED), on fait :
```c
tail = READ_ONCE(peer->rx_queue.tail);
if (tail == (struct sk_buff *)&peer->rx_queue.empty ||
    atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
        napi_schedule(&peer->napi);
```

`READ_ONCE(peer->rx_queue.tail)` lit le pointeur vers le paquet le plus ancien dans la file par peer. C'est un accès `READ_ONCE` — hint atomique, sans barrière mémoire. C'est safe depuis le contexte worker parce que `queue->tail` n'est écrit **que** par le consommateur (la fonction `wg_prev_queue_dequeue`, `queueing.c:87, 92, 101`). Le worker ne fait que lire — il n'y a pas de race destructive possible.

Le cas STUB : quand `tail == (struct sk_buff *)&peer->rx_queue.empty`, la file est dans un état de frontière (sentinel). Plutôt que de traverser ce cas délicatement, on schedule conservativement. Confirmé : `queueing.c:51, 56` — `STUB(queue) = (struct sk_buff *)&queue->empty`.

Pourquoi `atomic_read` et pas `atomic_read_acquire` ? Parce que c'est un hint spéculatif, pas un point de synchronisation. On n'a pas besoin de barrière mémoire ici. Un read relaxé est correct et évite le coût de la barrière.

**Scénario A (haut droite) — tête UNCRYPTED :**

CPU 3 finit en premier. Il lit `tail` → pkt 0, état = UNCRYPTED → condition fausse → `napi_schedule` **non appelé**. `NET_RX_SOFTIRQ` n'est pas levé. GRO ne s'exécute pas. Zéro appel gaspillé. CPU 3 reprend son travail immédiatement.

**Scénario B (milieu droite) — tête CRYPTED :**

CPU 0 finit en premier (le cas rare, mais correct). Il lit `tail` → pkt 0, état = CRYPTED → condition vraie → `napi_schedule` appelé. GRO s'exécute. Il parcourt la file : pkt 0 CRYPTED → livré, pkt 1 CRYPTED → livré, pkt 2 CRYPTED → livré, pkt 3 CRYPTED → livré. `work_done = 4`. Travail utile.

GRO se déclenche **exactement quand il peut progresser**.

**Les quatre cas formels :**

| Cas | Situation | Décision | Justification source |
|---|---|---|---|
| A | Paquet N est la tête, vient d'être CRYPTED | Schedule | `tail` est non-UNCRYPTED |
| B | N n'est pas la tête ; tête déjà CRYPTED ou DEAD | Schedule | GRO trouve du travail ; les DEAD passent (`receive.c:458`) |
| C | N n'est pas la tête ; tête UNCRYPTED | Skip | GRO retourne `work_done=0` immédiatement (`receive.c:451–453`) |
| D | N n'est pas la tête ; gap avant N | Skip | Sous-cas de C — la tête est UNCRYPTED |
| STUB | File sur la frontière sentinel | Schedule | Conservatif — évite la traversée hors-consommateur |

**Sécurité du read rassis (stale read) :**

Supposons que le worker lit `UNCRYPTED` au moment précis où un autre cœur vient de basculer la tête en `CRYPTED`. Ce worker saute `napi_schedule`. Mais le cœur qui a fait la bascule lit `CRYPTED` — et **lui** appelle `napi_schedule`. Aucun paquet n'est bloqué. Aucune liveness n'est perdue. Le pire cas est un `napi_schedule` raté qui est compensé par l'appel suivant.

**La limitation résiduelle (bas gauche) :**

Supposons que GRO a livré pkt 0 et pkt 1, et s'est arrêté sur pkt 2 (UNCRYPTED). `work_done = 2 < 64`, donc `napi_complete_done` est appelé — mais il y a un court laps de temps entre GRO s'arrêtant et `napi_complete_done` effaçant `NAPI_STATE_SCHED`.

Si CPU 2 marque pkt 2 CRYPTED dans cette fenêtre : il lit `tail` → CRYPTED → appelle `napi_schedule` → mais `NAPI_STATE_SCHED` est encore levé → `napi_schedule` est un no-op (retourne immédiatement). Puis `napi_complete_done` efface le flag. Personne ne reschedule. pkt 2 et pkt 3 attendent le prochain paquet entrant.

Ce n'est **pas un problème de correction** — les paquets sont livrés éventuellement. Sur un trafic soutenu à 25 Gbps, le prochain paquet arrive en quelques nanosecondes. Sur un trafic en burst, cela peut se manifester comme un rare pic de latence de queue. C'est un effet de second ordre — le correctif élimine la source dominante des appels gaspillés.

**Comparaison avant/après (bas tableau) :**

| Métrique | Avant le correctif | Après le correctif |
|---|---|---|
| Invocations GRO | chaque milliseconde | seulement quand la tête est non-UNCRYPTED |
| Polls GRO gaspillés | ~87.5% (8 cœurs) | **éliminés dans le cas dominant** |
| Utilisation CPU | 94% (gaspillage) | réduit — les workers courent plus librement |
| Risque résiduel | aucun | fenêtre étroite, rare, non-correctif |"

---

## Diagramme 6 — Architecture NAPI par peer (diagramme de support)

**Ce que montre ce diagramme :** le binding des instances NAPI aux CPUs, la mécanique de scheduling sous déchiffrement concurrent, le cycle de vie napi_enable/napi_disable.

---

**Ce qu'il faut dire :**

"Ce diagramme répond à la question du 21 mai : le napi_struct est-il par peer ou par paquet ?

**Réponse : par peer, pour toute la durée de vie du peer.**

`peer.c:57` :
```c
netif_napi_add(wg->dev, &peer->napi, wg_packet_rx_poll);
```
Un seul appel par peer, à la création. Avec 1000 peers, il y a 1000 instances `napi_struct` indépendantes.

`peer.c:58` — `napi_enable` après initialisation complète : état = SCHED=0, NAPI_STATE_NPSVC=0 — schedulable.
`peer.c:120` — `napi_disable` au teardown du peer : bit DISABLE levé — `napi_schedule` devient no-op.

**Le mécanisme de binding CPU (important) :**

Quand un worker sur CPU 0 appelle `napi_schedule(&peer_A->napi)`, l'implémentation fait `this_cpu_ptr(&softnet_data)` — ce qui capture **le CPU courant** au moment de l'appel, pas le CPU optimal pour GRO. Elle ajoute le napi_struct à la poll list du CPU 0. Donc GRO s'exécutera sur CPU 0 — qui est peut-être le CPU qui avait le moins de progrès sur la file du peer.

Sous déchiffrement concurrent, plusieurs CPUs appellent `napi_schedule(&peer->napi)` pour le même peer. Le premier positionne `NAPI_STATE_SCHED`. Les suivants voient le flag levé et retournent immédiatement (no-op). GRO se déclenche une seule fois — sur le CPU qui a fini en premier, pas forcément le plus avancé.

**Le flag MISSED :**

Si un deuxième `napi_schedule` arrive pendant que le poll est en cours d'exécution, `NAPI_STATE_MISSED` est levé. Quand `napi_complete_done` s'exécute, il vérifie MISSED — si levé, il reschedule immédiatement. Ce mécanisme garantit qu'aucun appel n'est perdu si deux completions arrivent en rafale.

**Ce que ce diagramme clarifie pour le correctif :**

La sécurité du `NAPI_STATE_SCHED` comme guard contre les double-schedules s'applique à notre patch aussi. Si deux CPUs passent la vérification `tail != UNCRYPTED` simultanément et appellent tous les deux `napi_schedule`, le second est un no-op. Pas de double-schedule, pas de double poll. La mécanique NAPI gère ça correctement."

---

## Diagramme 7 — Flux de données complet avec toutes les files (diagramme de référence)

**Ce que montre ce diagramme :** la vue bout-en-bout complète — tous les composants, toutes les files, tous les points de scheduling, et le point exact du correctif.

---

**Ce qu'il faut dire :**

"Ce dernier diagramme est la vue complète — tout le pipeline en un seul schéma. C'est le diagramme de référence que j'utiliserai dans le rapport.

**Étage 1 — gauche :** `wg_packet_receive` en contexte BH. Un datagramme UDP arrive. L'en-tête WireGuard est parsé — type de message, identifiant du peer, compteur pour la protection anti-rejeu. Le paquet est alloué avec `GFP_ATOMIC` (allocation sans blocage, obligatoire en contexte BH). Phase 1 : insertion dans la file par peer (état = UNCRYPTED). Phase 2 : insertion dans la file globale, dispatch via `queue_work_on`.

**Étage 2 — centre :** chaque CPU exécute `wg_packet_decrypt_worker` en boucle. `ptr_ring_consume_bh` récupère un paquet. Déchiffrement ChaCha20-Poly1305. Puis `wg_queue_enqueue_per_peer_rx` — c'est ici que se trouve le point de correction. `atomic_set_release` → CRYPTED. Et c'est ici que se trouve l'appel `napi_schedule` — conditionnel avec le patch, inconditionnel sans.

**Étage 3 — droite :** `wg_packet_rx_poll` s'exécute comme `NET_RX_SOFTIRQ`. La boucle while parcourt la file par peer depuis `tail`. Pour chaque paquet non-UNCRYPTED : si CRYPTED → `napi_gro_receive` → livraison à la pile réseau. Si DEAD → `dev_kfree_skb` → libéré. Si UNCRYPTED → sortie de boucle. `napi_complete_done` si `work_done < budget`.

**La flèche EoI** — annotée dans le diagramme — montre le lien entre le `napi_schedule` de l'Étage 2 et l'exécution GRO de l'Étage 3. C'est exactement là que se situe la correction : le patch coupe cette flèche dans le cas où la tête est UNCRYPTED.

Ce diagramme permet de voir d'un coup d'œil que les deux files sont parallèles et indépendantes, que l'ordre de livraison est fixé dès la Phase 1, et que le correctif ne touche qu'un seul point dans tout ce pipeline — 6 lignes dans `queueing.h`."

---

## Ordre suggéré et rythme

| # | Diagramme | Durée | Focus |
|---|---|---|---|
| 1 | Vue d'ensemble pipeline | 3 min | Orienter tout le monde |
| 2 | Deux files parallèles | 4 min | Fondation structurelle — indispensable |
| 3 | Déchiffrement concurrent + EoI | 5 min | L'argument central — le plus important |
| 4 | Boucle du worker (détail) | 3 min | Renforce le trigger par paquet |
| 5 | Le correctif | 6 min | Discussion principale — le diff, les cas, la limitation |
| 6 | Architecture NAPI | 2 min | Si question sur la sécurité du patch |
| 7 | Référence complète | 2 min | Vue finale, clore la présentation |

**Total : ~25 minutes**, en laissant du temps pour les questions sur le diff.

---

## Points à avoir sous la main (code source)

Si André demande à voir le code pendant la présentation :

| Claim | Fichier | Ligne |
|---|---|---|
| `napi_schedule` inconditionnel | `queueing.h` | 196 |
| Deux-phases enqueue | `queueing.h` | 152–173 |
| Round-robin CPU (et le commentaire sur la race) | `queueing.h` | 115–119 |
| Boucle GRO s'arrête à UNCRYPTED | `receive.c` | 451–453 |
| `napi_complete_done` seulement si `work_done < budget` | `receive.c` | 487–488 |
| DEAD ne bloque pas la file | `receive.c` | 458–459 |
| `tail` écrit uniquement par le consommateur | `queueing.c` | 87, 92, 101 |
| Sentinel STUB | `queueing.c` | 51, 56 |
| Un `napi_struct` par peer | `peer.c` | 57 |
| `napi_enable` après init | `peer.c` | 58 |
| `napi_disable` au teardown | `peer.c` | 120 |
