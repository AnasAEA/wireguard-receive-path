# Le code est-il le même sur ARM/Asahi et sur x86/v6.1 (papier & CloudLab) ?

**Pourquoi cette question :** j'ai développé et mesuré le correctif sur ma machine
(Apple M1, ARM, Fedora Asahi, noyau ≈6.19). Mais le papier tourne sur **Debian 12,
noyau 6.1, x86**, et CloudLab est **Ubuntu x86**. Avant d'affirmer que mon analyse
et mon patch s'appliquent là-bas, il faut **vérifier que c'est le même code**, pas
le supposer.

**Méthode :** j'ai récupéré le module WireGuard de `torvalds/linux` au tag `v6.1`
(la version du papier) et je l'ai comparé, fichier par fichier, à celui que j'ai
compilé (branche `asahi`). Les fichiers v6.1 sont dans le dépôt :
`reference/wireguard-v6.1-x86/`. Les nôtres : `linux-source/drivers/net/wireguard/`.

**Conclusion en une phrase :** le site du bug, le correctif, le pipeline de
réception et la file MPSC sont **identiques** entre les deux versions. Il existe une
seule vraie différence (un drapeau de workqueue) qui **ne change pas le
comportement**. Donc l'analyse et le patch se transfèrent tels quels sur x86/6.1.

---

## Ce qui est identique (et c'est tout ce qui compte pour nous)

**`wg_queue_enqueue_per_peer_rx` — le site du bug ET du correctif — est identique
au caractère près.** En v6.1 comme chez nous, c'est :

```c
atomic_set_release(&PACKET_CB(skb)->state, state);
napi_schedule(&peer->napi);     // inconditionnel, après chaque paquet
```

Donc mon patch (lire `peer->rx_queue.tail` avant de réveiller) s'applique exactement
de la même façon sur le noyau du papier.

**`queueing.c` — la file MPSC (head/tail/STUB, enqueue/dequeue) — est identique.**
La sémantique de `tail` (curseur du consommateur, écrit seulement par lui) sur
laquelle repose la sûreté du correctif est donc la même.

**`wg_packet_rx_poll` et `wg_packet_decrypt_worker` — le pipeline — sont
identiques.** La boucle qui s'arrête au premier `UNCRYPTED`, le `napi_complete_done`,
le budget : tout est pareil. (La seule « différence » détectée sur ce fichier à la
ligne 499 est en réalité **mon propre commentaire** ajouté pendant l'étude.)

**`peer.c` / `peer.h` — un `napi_struct` par correspondant, `netif_napi_add` — sont
identiques.** Le budget par défaut (`NAPI_POLL_WEIGHT`) est donc le même.

---

## Les différences cosmétiques (sans effet sur l'analyse)

Dans `receive.c`, les seuls écarts réels sont des modernisations mécaniques, aucune
ne touche la logique de l'EoI :

- `keypair->receiving_counter.counter` → `READ_ONCE(...)` (durcissement data-race) ;
- `counter->counter = …` → `WRITE_ONCE(...)` ;
- `++dev->stats.rx_errors` → `DEV_STATS_INC(dev, ...)` (compteurs de stats) ;
- `skb->data - skb_network_header(skb)` → `-skb_network_offset(skb)` (fonction utilitaire) ;
- la signature de `wg_queue_enqueue_per_device_and_peer` : en v6.1 le curseur
  round-robin est passé en argument (`next_cpu`), chez nous il est lu dans la
  structure (`device_queue->last_cpu`). **Même logique de tourniquet**, juste rangée
  différemment.

---

## La seule vraie différence : le drapeau `WQ_PERCPU` (à bien expliquer)

La création de la workqueue de déchiffrement diffère :

| Version | `device.c` — `alloc_workqueue("wg-crypt-%s", …)` |
|---|---|
| v6.1 (papier, x86) | `WQ_CPU_INTENSIVE \| WQ_MEM_RECLAIM` — **pas de `WQ_PERCPU`** |
| Asahi (notre build, ARM) | `WQ_CPU_INTENSIVE \| WQ_MEM_RECLAIM \| WQ_PERCPU` |

**Est-ce que ça change le comportement ? Non.** Et c'est le point important à savoir
expliquer :

- Historiquement, une workqueue créée **sans** `WQ_UNBOUND` est **par-CPU par
  défaut**. En v6.1, `packet_crypt_wq` n'a ni `WQ_UNBOUND` ni `WQ_PERCPU` → elle est
  donc **par-CPU par défaut** → un worker par CPU → déchiffrement concurrent → EoI.
  Exactement le même mécanisme que chez nous.
- Dans les noyaux récents (le défaut des workqueues a changé, ≈6.11+), il faut le
  drapeau **explicite** `WQ_PERCPU` pour **conserver** la sémantique par-CPU. Asahi
  (≈6.19) l'ajoute donc pour garder le comportement d'avant.

Autrement dit : **même concurrence par-CPU dans les deux cas**, obtenue par défaut en
6.1 et par drapeau explicite en 6.19. Conséquence concrète pour mes documents : mon
affirmation « un worker par CPU » reste vraie partout, mais **la preuve par le code
diffère selon la version** — `WQ_PERCPU` chez nous, « par-CPU par défaut » en 6.1.
(L'argument *à l'exécution* avec bpftrace, lui, est identique et indépendant de la
version : les workers `wg-crypt-…` apparaissent bien sur plusieurs CPU.)

---

## Et CloudLab précisément ?

CloudLab est Ubuntu/x86, mais **la version exacte du noyau reste à confirmer** (c'est
une de mes questions à Teo — selon l'image choisie sur le nœud `c220g2`). Quoi qu'il
en soit :

- Une Ubuntu d'avant ≈6.11 (ex. 20.04→noyau 5.4, 22.04→5.15, ou un 6.1/6.x ancien)
  → workqueue **par-CPU par défaut**, comme la v6.1 du papier.
- Une Ubuntu très récente (noyau ≥6.11) → drapeau `WQ_PERCPU` explicite, comme Asahi.

Dans les deux cas, le comportement par-CPU (donc l'EoI) est le même, et
`wg_queue_enqueue_per_peer_rx` est inchangé depuis des années → **mon patch
s'applique à l'identique.**

**Vérification définitive à faire sur le nœud CloudLab** (une fois `uname -r` connu) :

```bash
uname -r
grep -n "napi_schedule\|rx_queue" \
    /usr/src/linux-source-*/drivers/net/wireguard/queueing.h   # ou les sources du noyau du nœud
grep -n "alloc_workqueue(\"wg-crypt" -A1 \
    /usr/src/.../drivers/net/wireguard/device.c                 # voir le drapeau exact
```

Si `wg_queue_enqueue_per_peer_rx` contient toujours le `napi_schedule` inconditionnel
(ce qui sera le cas), le patch est valide tel quel.

---

## Récapitulatif

| Élément | v6.1 (papier/x86) vs Asahi (nous) | Impact |
|---|---|---|
| `wg_queue_enqueue_per_peer_rx` (bug + patch) | **identique** | patch transférable tel quel |
| File MPSC `queueing.c` (`tail`/STUB) | **identique** | sûreté du patch identique |
| `wg_packet_rx_poll` / decrypt worker | **identique** | pipeline EoI identique |
| `peer.c/.h` (NAPI par pair, budget) | **identique** | — |
| Round-robin CPU | même logique, signature rangée autrement | aucun |
| `receive.c` (READ_ONCE, stats, helper) | cosmétique | aucun |
| Drapeau workqueue `WQ_PERCPU` | **présent (6.19) vs absent (6.1)** | **comportement identique** (par-CPU par défaut en 6.1) ; seule la *preuve par le code* change |
