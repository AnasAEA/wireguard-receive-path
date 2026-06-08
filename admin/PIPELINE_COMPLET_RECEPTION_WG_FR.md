# Le pipeline complet de réception WireGuard — NAPI, Workqueues, GRO

**But de ce document.** Avoir *une seule carte mentale*, complète et reliée, du trajet
d'un paquet entrant dans WireGuard : chaque appel de fonction important, chaque
changement de « contexte d'exécution » (interruption → softirq → workqueue → softirq),
et les trois mécanismes du noyau qui structurent tout ça : **NAPI**, **les workqueues**,
**GRO**. Chaque affirmation technique est rattachée à une ligne de source précise, et la
dernière partie donne les commandes pour *observer* tout cela en vrai (pas seulement
l'affirmer).

Légende des preuves : 🟢 ligne de source · 🟡 convention/upstream noyau · 🔵 mesure à
l'exécution (bpftrace/ethtool) · ⚪ raisonnement.

Fichiers cités : `linux-source/drivers/net/wireguard/` (notre build, AsahiLinux, ARM,
≈6.19). Le même code côté x86/v6.1 est dans `reference/wireguard-v6.1-x86/` (cf.
`COMPARAISON_CODE_VERSIONS_FR.md` : identique, à un drapeau de workqueue près sans effet).

---

## Comment lire ce document

Selon ton besoin, plusieurs parcours :

| Besoin | Parcours | Durée |
|---|---|---|
| **Juste comprendre le mécanisme** | §0 (la carte) → §1 (les 4 concepts) → §2 (le trajet) → §4 (le bug) | ~15 min |
| **Préparer des réponses orales** | §6 (auto-test « colle ») | ~5 min |
| **Tout prouver par le code** | §7 (dossier de preuves, extraits verbatim `[P1]`…`[P25]`) | au besoin |
| **Vérifier à l'exécution** | §5 (recettes bpftrace / ethtool) | au besoin |

> Astuce : dans VS Code, le panneau **Outline** (ou `Ctrl/Cmd+Shift+O`) donne la navigation
> cliquable entre toutes les sections.

## Sommaire

- **§0 — La carte** — schéma d'ensemble + table « chaque case = du code ».
- **§1 — Les concepts** (le « quoi » / le « pourquoi ») :
  §1.0 le *pair* · §1.1 *NAPI* (+ aparté *softirq*, + cycle de vie) · §1.2 *workqueue* ·
  §1.3 *GRO*.
- **§2 — Le pipeline étape par étape** — A → D, fonctions + contextes d'exécution.
- **§3 — Les deux fronts GRO** — tableau récapitulatif.
- **§4 — Où est le bug** (EoI) + le correctif en une phrase.
- **§5 — Le prouver à l'exécution** — bpftrace / ethtool.
- **§6 — Auto-test « colle »** — questions / réponses.
- **§7 — Dossier de preuves** — le code source *verbatim*, `[P1]`…`[P25]` (+ `[P8a]`).

---

## 0. La carte (à avoir en tête avant tout le reste)

Trois « couloirs » = trois contextes d'exécution différents. Un paquet entrant les
traverse de gauche à droite. Les deux étoiles GRO sont les **deux fronts** dont parle
Alain.

```
   COULOIR 1                  COULOIR 2                      COULOIR 1 (à nouveau)
   IRQ matérielle +           Workqueue "wg-crypt"           Softirq NET_RX
   Softirq NET_RX             (contexte processus,           (NAPI logicielle de
   (NAPI du VRAI NIC)          un worker PAR CPU)             WireGuard, par pair)
 ─────────────────────     ───────────────────────────    ──────────────────────────
                                                          
  NIC reçoit UDP chiffré                                  
        │                                                 
        │  ★ GRO #1 (paquets                              
        │     UDP EXTERNES chiffrés)                      
        ▼                                                 
  pile UDP → encap_rcv                                    
        │                                                 
   wg_receive ───────────►                                
   wg_packet_receive                                      
        │                                                 
   wg_packet_consume_data                                 
        │                                                 
   [Phase 1] file du pair (ORDRE)                         
   [Phase 2] ring global + queue_work_on(cpu)             
        │                                                 
        └──────────────────►  wg_packet_decrypt_worker    
                              (déchiffre ChaCha20-Poly1305)
                                       │                  
                              wg_queue_enqueue_per_peer_rx 
                                       │                  
                              ★ napi_schedule(&peer->napi)  ← LE SITE DU BUG (EoI)
                                       │                  
                                       └─────────────────►  wg_packet_rx_poll
                                                            (vide la file DANS L'ORDRE)
                                                                  │
                                                            wg_packet_consume_data_done
                                                                  │
                                                            skb->dev = wg0 (virtuel)
                                                                  │
                                                            ★ GRO #2 (paquets
                                                              INTERNES déchiffrés)
                                                            napi_gro_receive(&peer->napi)
                                                                  │
                                                                  ▼
                                                            pile IP de l'hôte (vraie
                                                            destination de l'appli)
```

Retiens trois bascules de contexte : **(NIC softirq) → (workqueue wg-crypt) → (softirq
NAPI WireGuard)**. Le bug est sur la 3ᵉ étape, le GRO #2 est juste après.

#### Chaque case du diagramme = du code (backing complet)

Aucune case n'est décorative : chacune renvoie à un extrait **verbatim** du **§7 — Dossier
de preuves** (les `[P#]`). Tu peux donc pointer n'importe quel élément du schéma et montrer
le code exact derrière.

| Élément du diagramme | Fonction / fait | Fichier:ligne | Preuve |
|---|---|---|---|
| « NIC reçoit UDP chiffré » | évènement matériel (hors code WG) | — | — |
| ★ GRO #1 (UDP externes) | chaîne `napi_gro_receive`→…→`udp_gro_receive` (générique, NIC) | `gro.c:464,517` ; `af_inet.c:1468,1532` ; `udp_offload.c:874,898,785,800-815` | `[P8a][P8]` |
| « pile UDP → encap_rcv » | `cfg.encap_rcv = wg_receive` ; `setup_udp_tunnel_sock` | `socket.c:353-357,393` | `[P6]` |
| `wg_receive` | crochet UDP → WireGuard | `socket.c:316-326` | `[P7]` |
| `wg_packet_receive` | aiguillage `MESSAGE_DATA` | `receive.c:542,574-576` | `[P9]` |
| `wg_packet_consume_data` | appelle l'enqueue 2-phases | `receive.c:509,526` | `[P10]` |
| [Phase 1] file du pair (ORDRE) | `wg_prev_queue_enqueue`, état `UNCRYPTED` | `queueing.h:158,162` | `[P11]` |
| [Phase 2] ring + `queue_work_on(cpu)` | tourniquet CPU | `queueing.h:168-171` ; `:120` | `[P11][P12]` |
| Workqueue « wg-crypt » (par-CPU) | `alloc_workqueue(..., WQ_PERCPU)` | `device.c:346-348` | `[P13]` |
| `wg_packet_decrypt_worker` | consomme ring, `decrypt_packet` | `receive.c:493-503` | `[P14]` |
| `wg_queue_enqueue_per_peer_rx` | enrobe le réveil | `queueing.h:188-198` | `[P15]` |
| ★ `napi_schedule(&peer->napi)` (BUG) | réveil + déduplication `MISSED` | `queueing.h:196` ; `netdevice.h:558` ; `dev.c:6729,4982` | `[P15][P16][P17][P18]` |
| `wg_packet_rx_poll` (file DANS L'ORDRE) | poll appelé par `net_rx_action` | `receive.c:438-491` ; `dev.c:7914` | `[P19][P20]` |
| « s'arrête au 1er `UNCRYPTED` » | condition d'arrêt de boucle | `receive.c:451-453` | `[P20]` |
| `wg_packet_consume_data_done` | prépare le paquet interne | `receive.c:335-413` | `[P22]` |
| « `skb->dev = wg0` (virtuel) » | rattache au netdev virtuel | `receive.c:375` | `[P22]` |
| ★ GRO #2 `napi_gro_receive(&peer->napi)` | agrège l'interne | `receive.c:411` | `[P22]` |
| « pile IP de l'hôte » | remontée standard (hors code WG) | — | — |
| *Couloir : NAPI par pair* | `struct napi_struct` dans `wg_peer` ; `netif_napi_add` | `peer.h:65` ; `peer.c:57` | `[P1][P3][P4]` |
| *Couloir : workqueue par-CPU* | `packet_crypt_wq` | `device.c:346` | `[P13]` |

---

## 1. Les concepts, expliqués simplement (le « quoi » et le « pourquoi »)

### 1.0 D'abord : c'est quoi un « pair » (*peer*) ? — le prérequis

Avant NAPI, workqueues et GRO, il faut ce mot, parce que la moitié des structures qu'on
va voir commencent par `peer->`.

**L'intuition.** WireGuard est *pair-à-pair* : au niveau du protocole il n'y a pas de
« client » ni de « serveur », juste des **pairs**. Un **pair, c'est l'autre bout d'un
tunnel** — une machine distante avec qui j'ai une relation cryptographique. Il est
**identifié par sa clé publique** (pas par son IP, qui peut changer : *roaming*). Quand je
fais `wg set wg0 peer <clé-publique> endpoint 1.2.3.4:51820 allowed-ips 10.0.0.2/32`, je
déclare *un* pair.

**Un point clé d'échelle.** *Une seule* interface `wg0` peut porter **beaucoup de pairs**
(liste `wg->peer_list`). Dans le papier, le serveur a **1000 pairs** sur son unique `wg0`
(1000 clients = 1000 pairs). C'est exactement ce que reproduisent mes expériences
multi-pairs.

**Concrètement dans le code : `struct wg_peer` (`peer.h:37` 🟢).** Chaque pair transporte
*tout* ce qui est propre à cette relation. Les champs qui nous intéressent :

- `struct wg_device *device` (`:38`) — un retour vers l'interface `wg0` qui le possède.
- **`struct prev_queue tx_queue, rx_queue` (`:39`)** — ses **propres** files ordonnées
  d'émission et de réception. **`rx_queue` est la file au cœur de notre bug** : c'est *par
  pair* qu'on doit livrer dans l'ordre.
- `struct noise_keypairs keypairs` / `struct noise_handshake handshake` (`:43`, `:47`) —
  l'**état cryptographique** de la relation (clés de session Noise, poignée de main).
- `struct endpoint endpoint` (`:44`) — l'**adresse distante** (IP:port) du moment.
- `struct list_head allowedips_list` (`:64`) — les **plages d'IP** routées vers/depuis ce
  pair (le *cryptokey routing*, voir ci-dessous).
- **`struct napi_struct napi` (`:65`)** — sa **propre** NAPI (celle de §1.1). C'est *par
  pair*.
- `struct kref refcount` (`:61`), `internal_id` (`:66`), `pubkey_hash` (`:51`, recherche par
  clé publique).

**Le *cryptokey routing* (à savoir expliquer).** Les `allowed-ips` font le lien IP interne
↔ pair, dans les deux sens : à l'**émission**, l'IP de destination interne choisit *à quel
pair* chiffrer ; à la **réception**, après déchiffrement, on vérifie que l'IP *source*
interne du paquet appartient bien à ce pair — c'est `wg_allowedips_lookup_src`
(`receive.c:404` 🟢), et si `routed_peer != peer` (`receive.c:408` 🟢) le paquet est jeté.
C'est ça qui lie « clé cryptographique » et « adresse IP autorisée ».

**Pourquoi le pair est central POUR NOTRE BUG.** Parce que `rx_queue` **et** `napi` sont
**par pair**, la contrainte d'ordre *et* le bug d'inversion sont **par pair**. Avec N
pairs, il y a **N contextes NAPI indépendants**, qui poussent tous leur déchiffrement vers
**une seule** workqueue par-CPU partagée (`packet_crypt_wq`). ⚪ D'où le fait, observé le
28 mai, que **la régression grandit avec le nombre de pairs** (1 pair : aucun effet ; 8,
16, 32 pairs : effet croissant) : plus il y a de pairs, plus les workers entrelacent le
déchiffrement *de pairs différents*, plus les complétions arrivent dans le désordre, plus
de `napi_schedule` sont gâchés. **Le « 1 pair » du quotidien ne déclenche pas le bug ; la
charge serveur multi-pairs, si.**

### 1.1 NAPI — « arrête de sonner à chaque lettre, je relèverai la boîte moi-même »

**Le problème.** Une carte réseau qui reçoit un paquet prévient le processeur par une
*interruption* : « stop tout, il y a du courrier ». Très bien pour 100 paquets/seconde.
Catastrophe pour 1 000 000/seconde : le processeur ne fait plus que répondre à la
sonnette, il n'a plus le temps de traiter le courrier (« interrupt storm »).

**L'idée de NAPI.** À la première lettre, la carte sonne **une fois**. Le noyau dit
alors : « arrête de sonner, je viendrai vider la boîte moi-même, par paquets ». Il
*désactive* l'interruption et passe en mode **polling** : il appelle régulièrement une
fonction `poll()` qui ramasse plusieurs paquets d'un coup. Quand la boîte est vide, il
réactive la sonnette. C'est le meilleur des deux mondes : réactif à faible charge,
efficace à forte charge.

**Le `budget`** (premier mot de vocabulaire) : le nombre maximum de paquets que `poll()`
a le droit de traiter en un passage, pour ne pas monopoliser le CPU. S'il atteint le
budget, il rend la main et reviendra ; s'il vide la file avant, il appelle `napi_complete`
et se rendort.

#### Aparté : c'est quoi un *softirq*, vraiment ? (on en a besoin partout)

C'est le mot le plus brumeux du lot. Prenons-le calmement, parce que tout le reste en
dépend.

**1. La règle d'or des interruptions : il faut être ULTRA bref.** Quand la carte réseau
lève une *interruption matérielle*, le CPU lâche tout et exécute le gestionnaire — et
pendant ce temps, d'autres interruptions sont *masquées*. Si tu traînes là-dedans, tu
gèles la machine. Donc on **coupe le travail en deux** :

- **moitié haute** (le gestionnaire d'interruption matérielle, *hard IRQ*) : le strict
  minimum, quelques microsecondes — « j'ai bien reçu des paquets », on le note, on ressort.
- **moitié basse** : tout le gros du traitement (faire remonter les paquets dans la pile),
  fait *juste après*, une fois l'interruption ressortie. **Le softirq est précisément un
  mécanisme de « moitié basse ».**

**2. Ce qu'est un softirq, littéralement.** « *Software interrupt* », interruption
logicielle. **Ce n'est ni un thread, ni un processus, ni une fonction qu'on appelle
directement.** C'est : un **drapeau par-CPU** « tel traitement est en attente » + une
fonction associée (pour le réseau en réception : `net_rx_action`). `raise_softirq(NET_RX)`
ne fait **qu'une chose** : *lever ce drapeau*. Rien ne s'exécute encore.

**3. Quand et où ça tourne *vraiment*.** Le noyau vérifie « y a-t-il un softirq en
attente ? » à des moments précis — le principal étant **juste à la sortie d'une
interruption matérielle** (`irq_exit`). À cet instant, il exécute la fonction du softirq
**sur place, par-dessus le thread qui se trouvait interrompu** — *pas* dans un thread à
lui. Voilà ce que veut dire « en marge » / « temps emprunté » : le softirq squatte le
contexte d'un thread-victime pris au hasard (celui qui tournait quand l'IRQ est arrivée).

**4. D'où vient l'interdiction de dormir.** Comme ce code **ne possède aucun thread
propre** (pas de `task_struct` à lui), il **ne peut pas se mettre en pause / dormir** :
« dormir », c'est demander à l'ordonnanceur de basculer vers une autre tâche — or ici on
occupe une tâche-victime empruntée, il n'y a rien de propre vers quoi basculer proprement.
Donc, dans un softirq : **pas de sommeil, pas de mutex bloquant, et ça doit rester court.**
👉 C'est *exactement* la raison pour laquelle WireGuard ne déchiffre pas dans le softirq
mais renvoie ça vers une **workqueue** (§1.2) : déchiffrer est long, donc interdit ici.

**5. La priorité (et je corrige une formulation trop rapide).** Un softirq **n'est PAS
« basse priorité »** au sens courant : il **interrompt et passe avant les threads
normaux** (utilisateur comme noyau). Il est seulement **moins prioritaire qu'une
interruption matérielle**. Échelle : *hard IRQ* > *softirq* > *threads*.

**6. La soupape de sécurité : `ksoftirqd/N`.** Si les softirqs affluent trop (carte
saturée, `net_rx_action` a sans cesse du travail), continuer à les exécuter sur le dos des
IRQ affamerait les threads normaux. Le noyau bascule alors le reste vers un **vrai thread
noyau, un par CPU** : `ksoftirqd/0`, `ksoftirqd/1`… Là, le même code tourne **dans ce
thread** (donc ordonnançable comme les autres) — mais il reste écrit pour **ne jamais
dormir**.

**En une phrase :** un softirq, c'est *du code de « moitié basse » réseau qui s'exécute
sans thread propre, juste après les interruptions (ou dans `ksoftirqd` sous forte charge),
qui passe avant les threads normaux et n'a pas le droit de dormir.* La fonction `poll()` de
NAPI tourne là-dedans.

**Mais alors, NAPI *c'est quoi* concrètement : un thread ? un kthread ? une fonction ?**
Aucun des trois. **NAPI est une *structure de données* + une *fonction* qu'on lui
associe.** Précisément :

- **L'objet** : `struct napi_struct`. Il contient un pointeur vers une fonction `poll`, un
  `weight` (le budget), des bits d'état (`state`), un chaînage `poll_list`, et — *en
  option seulement* — un `thread`. WireGuard en crée **un par pair** (`peer->napi`) et y
  attache sa fonction par `netif_napi_add(wg->dev, &peer->napi, wg_packet_rx_poll)`
  (`peer.c:57` 🟢).
- **`napi_schedule()` n'exécute rien.** Il se contente de *marquer* la NAPI « à scruter ».
  La chaîne : `napi_schedule` → `__napi_schedule` (`dev.c:6710`) → `____napi_schedule`
  (`dev.c:4957`), qui fait deux gestes (`dev.c:4984-4990` 🟢) : (1)
  `list_add_tail(&napi->poll_list, &sd->poll_list)` — ajoute la NAPI à la liste « à
  scruter » **du CPU courant** (`sd` = `softnet_data` par-CPU) ; (2)
  `raise_softirq_irqoff(NET_RX_SOFTIRQ)` — lève le **softirq NET_RX**. C'est tout. (La
  ligne `WRITE_ONCE(napi->list_owner, smp_processor_id())`, `dev.c:4985`, note juste quel
  CPU possède désormais cette NAPI.)
- **La fonction `poll` tourne *plus tard*, en contexte softirq.** Le gestionnaire du
  softirq NET_RX est `net_rx_action()` (`dev.c:7914` 🟢) : il parcourt la `poll_list` du
  CPU et, pour chaque NAPI, appelle `napi_poll(n, …)` → `n->poll()` → donc
  `wg_packet_rx_poll`. Il impose en plus un budget/temps *global* (≈2 jiffies,
  `dev.c:7917-7964`), distinct du `weight` propre à chaque NAPI.

> **Donc « où tourne la NAPI » ?** En **contexte softirq**, qui par défaut **n'est pas un
> thread** : c'est du temps « emprunté » juste après une interruption matérielle
> (`irq_exit`). Ce n'est *que* sous forte charge, quand les softirqs s'accumulent, que le
> noyau les délègue au kthread par-CPU **`ksoftirqd/N`**. La fonction `poll` tourne donc
> soit dans ce créneau post-IRQ, soit dans `ksoftirqd` — jamais dans un thread « qui
> serait » la NAPI.

> **La seule exception : la NAPI *threadée*.** Si le bit `NAPI_STATE_THREADED` est mis,
> `____napi_schedule` prend l'autre branche (`dev.c:4964-4978`) : il fait
> `wake_up_process(napi->thread)` et le `poll` tourne dans un **kthread dédié** nommé
> `napi/<dev>-<id>` (`napi_threaded_poll`, `dev.c:7887`). C'est optionnel, activé par
> netdev (`/sys/class/net/<dev>/threaded`). **WireGuard ne l'active pas** : à `peer.c:56`
> il ne pose que `NAPI_STATE_NO_BUSY_POLL`, pas `THREADED` → sa NAPI par pair tourne donc
> bien dans le **softirq**.

**Résumé de la nuance « fausse NAPI ».** Quand je dis que WireGuard fabrique une NAPI
« pour de faux », c'est un *vrai* `napi_struct`, scruté par `net_rx_action` exactement
comme celui d'un pilote matériel. La seule chose « fausse » : il est déclenché **à la
main** par le worker de déchiffrement (`napi_schedule`, `queueing.h:196` 🟢) au lieu de
l'être par une interruption de carte réseau, et il est accroché à un netdev **virtuel**.
C'est précisément ce mécanisme que WireGuard exploite (voir §2 et §3).

#### Le cycle de vie complet de la NAPI dans WireGuard (add → enable → schedule → poll → complete → disable → del)

Pour vraiment « posséder » la partie NAPI, il faut savoir **toutes** les fonctions de son
cycle de vie, pas seulement `napi_schedule`. Il n'y en a que sept, et dans WireGuard elles
tiennent dans deux fichiers. Voici chacune : *où* WireGuard l'appelle, et *ce qu'elle fait
réellement* (vérifié dans le noyau).

**① La structure elle-même — où elle vit.** `struct napi_struct napi;` est un **champ de
`struct wg_peer`** (`peer.h:65` 🟢). Donc **une NAPI par pair**, qui vit aussi longtemps que
le pair. Tout le reste manipule `&peer->napi`. (Et dans la fonction `poll`, on fait le
chemin inverse : `peer = container_of(napi, struct wg_peer, napi)`, `receive.c:440` 🟢 — on
retrouve le pair à partir de sa NAPI.)

**② `netif_napi_add(wg->dev, &peer->napi, wg_packet_rx_poll)`** (`peer.c:57` 🟢) —
*création*. Initialise le contexte NAPI, **l'attache au netdev virtuel `wg->dev`** (c'est ce
qui en fait la NAPI de `wg0`), **enregistre la fonction `poll`** (`wg_packet_rx_poll`) et le
**budget par défaut** (`NAPI_POLL_WEIGHT` = 64), et inscrit la NAPI dans la liste du netdev
(`netif_napi_add_weight_locked`, `dev.c:7558` 🟢). Juste avant, WireGuard fait
`set_bit(NAPI_STATE_NO_BUSY_POLL, &peer->napi.state)` (`peer.c:56` 🟢) : il **désactive le
busy-polling** pour cette NAPI (et, on l'a vu, n'active pas le mode *threadé*). À ce stade la
NAPI existe mais **n'est pas encore programmable**.

**③ `napi_enable(&peer->napi)`** (`peer.c:58` 🟢) — *activation*. Rend la NAPI
*programmable* : concrètement, elle **efface le bit `STATE_SCHED`** (`napi_enable_locked`,
`dev.c:7665` 🟢). Tant qu'on n'a pas appelé `napi_enable`, l'étape ④ échoue. (À noter :
`netif_napi_add` laisse volontairement `STATE_SCHED` *posé*, pour qu'on ne puisse pas
programmer une NAPI avant de l'avoir activée.)

**④ `napi_schedule(&peer->napi)`** (`queueing.h:196` 🟢, appelé par le worker de
déchiffrement) — *« réveille la NAPI »*. C'est un inline (`netdevice.h:558` 🟢) :
`if (napi_schedule_prep(n)) __napi_schedule(n);`. Deux sous-étapes, et l'une est **subtile et
importante pour notre bug** :

- `napi_schedule_prep` (`dev.c:6729` 🟢) : refuse si la NAPI est en cours de désactivation
  (`STATE_DISABLE`, `:6734`) ; sinon pose `STATE_SCHED`, et **ne renvoie `true` que si
  `STATE_SCHED` n'était pas déjà posé** (`:6748`). ⭐ **Donc si la NAPI est déjà programmée
  (ou en train de tourner), un nouvel appel `napi_schedule` ne la replanifie pas** : il pose
  juste un drapeau `STATE_MISSED` (`:6744`) et s'arrête. Autrement dit, les `napi_schedule`
  répétés du worker **ne créent pas N réveils distincts** ; ils sont dédupliqués.
- `__napi_schedule` → `____napi_schedule` (`dev.c:4957` 🟢) : ajoute la NAPI à la `poll_list`
  du CPU (`:4984`) et **lève le softirq NET_RX** (`:4990`). C'est seulement ici qu'un futur
  passage de `poll` est réellement programmé.

**⑤ `wg_packet_rx_poll` — la fonction `poll`** (`receive.c:438` 🟢). Elle n'est jamais
appelée directement par WireGuard : c'est `net_rx_action` (`dev.c:7914`) → `napi_poll`
(`:7786`) → `__napi_poll` (`:7719`) → `n->poll(n, budget)` qui l'invoque, dans le softirq,
avec le **budget**. Elle traite les paquets prêts et **renvoie `work_done`** (le nombre
traité).

**⑥ `napi_complete_done(napi, work_done)`** (`receive.c:488` 🟢, def. `dev.c:6771` 🟢) —
*« j'ai fini, rendors-moi »*. WireGuard l'appelle quand `work_done < budget`, c.-à-d. quand
la file est vidée (`receive.c:487`). Ce qu'elle fait réellement : **flush la couche GRO**
(`gro_flush_normal`, `:6803` — c'est là que les lots GRO #2 partent vraiment), **retire la
NAPI de la `poll_list`** (`:6808`), et **efface `STATE_SCHED`** (`:6817`). ⭐ **ET** : si
`STATE_MISSED` était posé (quelqu'un a fait `napi_schedule` pendant qu'on tournait), elle
**relance `__napi_schedule`** (`:6829-6830`) pour un tour de poll de plus. C'est ce qui
garantit qu'aucun réveil n'est *perdu* — mais c'est *aussi* ce qui peut générer un passage de
poll supplémentaire qui, si la tête est encore `UNCRYPTED`, repartira à vide. (Le lien direct
avec l'EoI, §4.)

**⑦ Démontage**, à la suppression du pair (`peer_remove_after_dead`) :
- `napi_disable(&peer->napi)` (`peer.c:120` 🟢) — pose `STATE_DISABLE`, **attend la fin du
  poll en cours** (`usleep_range` tant que `STATE_SCHED` est posé, `dev.c:7615-7618` 🟢),
  puis bloque tout futur `napi_schedule`. Peut dormir → contexte processus obligatoire.
- `netif_napi_del(&peer->napi)` (`peer.c:124` 🟢) — retire définitivement la NAPI du netdev.

**Récapitulatif — les 11 endroits où `peer->napi` est touché** (réponse à « où la struct
NAPI est-elle utilisée ? ») :

| Endroit | Appel | Rôle |
|---|---|---|
| `peer.h:65` | `struct napi_struct napi;` | **déclaration** (1 par pair) |
| `peer.c:56` | `set_bit(NAPI_STATE_NO_BUSY_POLL, …)` | désactive le busy-poll |
| `peer.c:57` | `netif_napi_add(wg->dev, …, wg_packet_rx_poll)` | **création** + attache à `wg0` + poll |
| `peer.c:58` | `napi_enable(&peer->napi)` | **activation** |
| `queueing.h:196` | `napi_schedule(&peer->napi)` | **réveil** (site du bug) |
| `receive.c:438` | `wg_packet_rx_poll(napi, budget)` | **la fonction poll** |
| `receive.c:440` | `container_of(napi, struct wg_peer, napi)` | retrouver le pair depuis la NAPI |
| `receive.c:488` | `napi_complete_done(napi, work_done)` | **fin de passage** + flush GRO |
| `receive.c:411` | `napi_gro_receive(&peer->napi, skb)` | livre un paquet **dans** le GRO #2 |
| `peer.c:120` | `napi_disable(&peer->napi)` | **désactivation** (attend le poll en cours) |
| `peer.c:124` | `netif_napi_del(&peer->napi)` | **destruction** |

### 1.2 Les workqueues — « ce travail est trop lourd pour le faire à la porte d'entrée »

**Le problème.** Dans le créneau softirq (cf. ci-dessus), on n'a pas le droit de dormir ni
de prendre du temps. Or **déchiffrer** un paquet (ChaCha20-Poly1305) est *coûteux en
CPU*. Le faire dans le softirq bloquerait tout le reste.

**L'idée de la workqueue.** On confie la tâche lourde à un **thread noyau de back-office**
qui, lui, tourne en *contexte processus* normal : il peut prendre son temps, être
ordonnancé comme n'importe quel thread. C'est une **workqueue**. On y « pose » du travail
(`queue_work_on`) et un *worker* le ramassera.

Trois propriétés d'une workqueue, utiles pour nous :

- **par-CPU vs unbound** : une workqueue par-CPU a un worker attaché à *chaque* CPU (le
  travail posé sur le CPU 3 sera exécuté sur le CPU 3) ; une workqueue *unbound* laisse
  l'ordonnanceur choisir. WireGuard veut du **par-CPU** pour le déchiffrement, afin de
  faire travailler tous les cœurs en parallèle.
- **`WQ_CPU_INTENSIVE`** : « ces tâches mangent du CPU, ne les compte pas comme des tâches
  courtes » (évite de pénaliser les autres workqueues).
- **`WQ_MEM_RECLAIM`** : garantit un worker de secours même quand la mémoire est tendue
  (le chemin réseau doit toujours pouvoir avancer).

C'est précisément ce que crée WireGuard pour le déchiffrement (`device.c:346` 🟢) :
`alloc_workqueue("wg-crypt-%s", WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM | WQ_PERCPU, ...)`.
(Sur v6.1/x86 le drapeau `WQ_PERCPU` est absent mais le par-CPU est le défaut historique →
**même comportement** ; cf. `COMPARAISON_CODE_VERSIONS_FR.md`.) 🟡

**Pourquoi c'est central pour nous.** Plusieurs workers (un par CPU) déchiffrent **en
parallèle**. Donc les paquets ne finissent **pas** d'être déchiffrés dans l'ordre où ils
sont arrivés (le CPU 3 peut finir le paquet n°5 avant que le CPU 1 finisse le n°2). C'est
la *source* du désordre qui crée le bug d'inversion (§4).

#### Le worker de déchiffrement peut-il être interrompu ? (ordonnanceur ET softirqs)

Question fréquente, et **centrale pour comprendre le coût de l'EoI** : pendant qu'un worker
déchiffre, peut-il être *arrêté par l'ordonnanceur* et/ou *préempté par les bottom halves
(softirqs)* ? **Réponse : oui aux deux**, mais ce sont **deux mécanismes distincts** qu'il
faut séparer.

Rappel du code du worker (`receive.c:493` 🟢) :

```c
while ((skb = ptr_ring_consume_bh(&queue->ring)) != NULL) {        // :499
    state = decrypt_packet(skb, …) ? CRYPTED : DEAD;              // :501  gros calcul ChaCha20
    wg_queue_enqueue_per_peer_rx(skb, state);                     // :503  appelle napi_schedule
    if (need_resched()) cond_resched();                           // :504-505
}
```

Et la fonction de retrait `ptr_ring_consume_bh` (`include/linux/ptr_ring.h:371` 🟢) :

```c
spin_lock_bh(&r->consumer_lock);
ptr = __ptr_ring_consume(r);
spin_unlock_bh(&r->consumer_lock);     // :377  les bottom halves sont RÉACTIVÉES ici
```

Enfin, la workqueue (`device.c:346` 🟢) est créée sans `WQ_HIGHPRI` → les workers sont de
simples **threads noyau `SCHED_NORMAL`** (priorité ordinaire).

**① Arrêté par l'ordonnanceur — oui.** Le worker tourne en **contexte processus**, comme un
thread `SCHED_NORMAL` normal (`kworker`). Il est donc une entité ordonnançable ordinaire :
sur un noyau préemptible, il peut être **désordonnancé** (fin de quantum, ou réveil d'une
tâche plus prioritaire) ; et WireGuard le fait en plus **céder volontairement** avec
`cond_resched()` après *chaque* paquet (`receive.c:504` 🟢). ⚪ `WQ_CPU_INTENSIVE` ne change
rien à ça : ce drapeau exempte seulement le long calcul de la *régulation de concurrence* de
la workqueue, il **n'élève pas la priorité**.

**② Préempté par les bottom halves (softirqs) — oui, et c'est le point qui compte.** Les
softirqs sont **plus prioritaires que le contexte tâche**. Ils frappent le worker de deux
façons :

- **À la sortie d'une interruption matérielle.** Crucial : `decrypt_packet` s'exécute avec
  les **bottom halves ACTIVÉES** — seul le bref retrait du ring tient `spin_lock_bh`. Donc
  pendant le déchiffrement, **toute IRQ matérielle qui survient déclenche, à `irq_exit`,
  l'exécution des softirqs en attente *sur place, par-dessus le worker*** avant qu'il
  reprenne. 🟡 (convention noyau : `irq_exit` → `invoke_softirq`).
- **Au propre point de réactivation des BH du worker.** Chaque tour de boucle appelle
  `ptr_ring_consume_bh`, dont le `spin_unlock_bh` (`ptr_ring.h:377` 🟢) **réactive les bottom
  halves et draine immédiatement tout softirq en attente**. Donc le `NET_RX_SOFTIRQ` que le
  worker a lui-même levé via `napi_schedule` au tour *précédent* s'exécute au tout prochain
  retrait : **le poll GRO tourne dans le thread du worker, entre deux paquets.**

**La distinction à garder précise :** un softirq qui s'exécute par-dessus le worker (cas ②)
**n'est pas** un changement de contexte de l'ordonnanceur — le softirq *emprunte* le thread
du worker (ou tourne à la sortie d'IRQ) ; le worker reste `current`, simplement suspendu sur
place. Le désordonnancement (cas ①) est autre chose. La question mélange souvent « arrêté par
l'ordonnanceur » et « préempté par les softirqs » : les deux sont vrais, par des mécanismes
différents.

**Pourquoi ça compte pour la thèse.** C'est *exactement* le coût de l'EoI : le softirq GRO,
plus prioritaire que le worker `SCHED_NORMAL`, **préempte sans cesse le déchiffrement** — et
(à cause du bug) le plus souvent pour ne rien faire, puisque la tête est encore `UNCRYPTED`.
C'est cette asymétrie de priorité que le correctif du papier supprime (déplacer GRO dans une
workqueue de même priorité), et ce sont ces réveils gâchés que notre correctif supprime.

> **Réserve :** ceci vaut pour un noyau standard. Sous `CONFIG_PREEMPT_RT`, les softirqs
> tournent en contexte threadé et le tableau change — mais Asahi (et le banc du papier) ne
> sont pas RT, donc l'analyse tient ici.

### 1.3 GRO — « agrafe les enveloppes d'une même conversation, monte-les en un seul voyage »

**Le problème.** Faire remonter un paquet à travers toute la pile réseau (IP, transport,
socket…) a un coût *fixe par paquet*. Avec des millions de petits paquets, ce coût fixe,
payé des millions de fois, devient le goulot d'étranglement.

**L'idée de GRO (Generic Receive Offload).** Avant de monter les paquets dans la pile, on
*fusionne* ceux qui appartiennent à la **même connexion** (mêmes IP/ports, séquence
contiguë) en **un seul gros « super-paquet »**. On monte ce gros paquet une seule fois : le
coût fixe est payé une fois au lieu de N. Les données sont identiques, on a juste amorti le
trajet. GRO s'accroche **dans le `poll()` de NAPI** : c'est `napi_gro_receive()` qui, au
lieu de pousser tout de suite vers le haut, essaie d'abord d'agrafer.

**Pourquoi GRO apparaît DEUX fois chez WireGuard (le point d'Alain).** Parce qu'il y a deux
« niveaux » de paquets :

- **Front #1 — les enveloppes EXTERNES (chiffrées, UDP).** Elles arrivent sur la vraie
  carte réseau ; c'est le GRO *générique du noyau*, piloté par la NAPI du *vrai* pilote du
  NIC, sur l'*interface physique*. **Attention (vérifié source, voir §2 étape A1) :** WireGuard
  n'opte **pas** son socket dans le GRO UDP, donc la fusion des UDP externes n'arrive **que
  si** la NIC a `NETIF_F_GRO_FRAGLIST`/`NETIF_F_GRO_UDP_FWD` activé. Ce front est donc
  *conditionnel*, pas garanti — contrairement au Front #2 que WireGuard fait explicitement.
- **Front #2 — les lettres INTERNES (déchiffrées).** Une fois WireGuard a ouvert et
  déchiffré, les paquets *internes* (le vrai trafic IP de l'application) doivent à leur
  tour remonter la pile. Mais ils n'arrivent **pas** d'une carte réseau : ils sortent d'un
  *worker* de déchiffrement. Pour pouvoir quand même les agrafer avec GRO, **WireGuard
  fabrique une fausse carte réseau** — l'interface **virtuelle `wg0`** — et une **fausse
  NAPI** (une par pair) accrochée dessus, juste pour appeler `napi_gro_receive()` sur les
  paquets internes. C'est `napi_gro_receive(&peer->napi, skb)` à `receive.c:411` 🟢, avec
  `skb->dev = wg->dev` (le netdev virtuel) posé juste avant à `receive.c:375` 🟢.

> **L'interface virtuelle, c'est quoi exactement ?** C'est le `struct net_device` que crée
> WireGuard quand on fait `ip link add wg0 type wireguard` — un périphérique réseau
> *purement logiciel*, sans file matérielle, sans pilote de carte. C'est lui qui porte ton
> adresse de tunnel (ex. `10.0.0.1`). La NAPI par pair y est rattachée par
> `netif_napi_add(wg->dev, &peer->napi, wg_packet_rx_poll)` à `peer.c:57` 🟢. À noter :
> WireGuard n'utilise **pas** `gro_cells` (l'aide générique d'autres tunnels) ; il gère
> **une `napi_struct` par pair**, directement. C'est une de ses particularités.

**Notre bug est entièrement sur le Front #2** : c'est le réveil de cette NAPI logicielle
(`napi_schedule(&peer->napi)`) qui est déclenché inutilement.

> ⚠️ **Sur ma machine (M1, loopback/netns), le Front #1 n'existe pas vraiment** : sans vraie
> carte réseau, il n'y a pas de GRO matériel sur l'externe. Le Front #1 ne sera pleinement
> observable que sur **CloudLab** (vraie NIC 25 G). Le Front #2, lui, est observable
> partout.

---

## 2. Le pipeline complet, étape par étape (avec les fonctions et les contextes)

On suit *un* paquet de données entrant. À chaque étape : la fonction, son fichier:ligne, et
**dans quel couloir** elle tourne.

### Étape A — Le paquet chiffré arrive sur la carte réseau · *Couloir 1 : IRQ + softirq NET_RX du NIC*

1. La carte reçoit un datagramme **UDP chiffré**. Son pilote, via **sa propre NAPI**,
   appelle `napi_gro_receive` (générique noyau). La **chaîne d'appel complète** (toute dans
   le noyau générique, **hors WireGuard**) est : `napi_gro_receive` → `gro_receive_skb` →
   `dev_gro_receive` (dispatch ETH_P_IP → `inet_gro_receive`) → `inet_gro_receive` (dispatch
   IPPROTO_UDP → `udp4_gro_receive`) → `udp_gro_receive` — code verbatim en `[P8a]`. **Mais
   GRO *fusionne*-t-il réellement ces UDP externes ? Pas automatiquement — et c'est un point
   que j'ai vérifié dans la source.** Le cœur de la décision est `udp_gro_receive`
   (`net/ipv4/udp_offload.c:785` 🟢).
   Comme WireGuard **n'enregistre aucun callback GRO de tunnel** sur son socket (`socket.c`
   ne pose que `encap_type`/`encap_rcv`, `:355-356` 🟢 ; le *seul* `gro` de tout le module
   est `napi_gro_receive` à `receive.c:411`, c.-à-d. le Front #2 🟢), le pointeur
   `udp_sk(sk)->gro_receive` est **NULL** → on entre dans la branche `udp_offload.c:800` 🟢.
   Là, l'agrégation de l'UDP externe **n'a lieu que si** la carte expose
   `NETIF_F_GRO_FRAGLIST` ou `NETIF_F_GRO_UDP_FWD`, *ou* si le socket a opté `UDP_GRO` (ce
   que WireGuard **ne fait pas**) (`:807-812` 🟢). Sinon : *« no GRO »*, le paquet est
   flushé tel quel (`:814-815` 🟢). **Conclusion : le Front #1 est *conditionnel* aux
   réglages GRO de la NIC, et WireGuard ne l'active jamais lui-même.** ★ GRO Front #1 (s'il
   a lieu).
2. La pile UDP livre la charge utile au socket-tunnel de WireGuard. WireGuard s'est
   enregistré pour ça : `setup_udp_tunnel_sock(...)` avec `.encap_rcv = wg_receive`
   (`socket.c:355-356`, `:393` 🟢). C'est le *crochet* qui fait passer du monde UDP au monde
   WireGuard.
3. `wg_receive` (`socket.c:316` 🟢) appelle `wg_packet_receive(wg, skb)` (`socket.c:326` 🟢).

### Étape B — Aiguillage et mise en file · *Couloir 1 (toujours softirq)*

4. `wg_packet_receive` (`receive.c:542` 🟢) lit l'en-tête (`prepare_skb_header`, `:544`) et
   regarde le type. Pour un paquet de données : `case MESSAGE_DATA` (`:574`) →
   `wg_packet_consume_data`.
5. `wg_packet_consume_data` (`receive.c:509` 🟢) retrouve la clé du pair, puis appelle la
   **mise en file à deux phases** : `wg_queue_enqueue_per_device_and_peer(&wg->decrypt_queue,
   &peer->rx_queue, skb, wg->packet_crypt_wq)` (`receive.c:526` 🟢).
6. Dans cette fonction (`queueing.h:152` 🟢), deux gestes essentiels :
   - **Phase 1 — l'ORDRE.** `wg_prev_queue_enqueue(peer_queue, skb)` (`:162`) place le paquet
     dans la **file du pair**, dans l'ordre d'arrivée. État initial : `UNCRYPTED` (`:158`).
     *C'est cette file qui mémorise l'ordre correct de livraison.*
   - **Phase 2 — le PARALLÉLISME.** On choisit un CPU en **tourniquet** :
     `wg_cpumask_next_online(&device_queue->last_cpu)` (`:168`, def. `:120` 🟢), on pousse le
     paquet dans le ring global (`:169`), puis **`queue_work_on(cpu, wq, …)`** (`:171`) :
     « pose ce travail de déchiffrement sur tel CPU ». ⚪ *Le même paquet est donc à la fois
     dans la file ordonnée du pair ET poussé vers un worker possiblement sur un autre CPU.*

### Étape C — Déchiffrement en parallèle · *Couloir 2 : workqueue « wg-crypt », un worker par CPU*

7. Sur chaque CPU, `wg_packet_decrypt_worker` (`receive.c:493` 🟢) tourne en **contexte
   processus**. Il consomme le ring (`ptr_ring_consume_bh`, `:499`), déchiffre
   (`decrypt_packet`, `:501`), et fixe l'état à `CRYPTED` (déchiffré OK) ou `DEAD`.
8. Puis il appelle `wg_queue_enqueue_per_peer_rx(skb, state)` (`receive.c:503` 🟢).
9. **LE SITE DU BUG.** Dans cette fonction (`queueing.h:188` 🟢) :
   ```c
   atomic_set_release(&PACKET_CB(skb)->state, state);   // :195  le paquet est marqué prêt
   napi_schedule(&peer->napi);                          // :196  réveil INCONDITIONNEL
   ```
   Le worker **réveille la NAPI du pair après *chaque* paquet déchiffré**, sans regarder si
   c'est utile. ⚪ *(Comme plusieurs CPU déchiffrent en parallèle, ils finissent dans le
   désordre — d'où le problème à l'étape suivante.)*

### Étape D — Remontée ordonnée + GRO interne · *Couloir 1 : softirq NET_RX, NAPI logicielle de WireGuard*

10. Le `napi_schedule` planifie l'exécution de `wg_packet_rx_poll` (`receive.c:438` 🟢),
    enregistrée comme fonction `poll` du pair (`peer.c:57` 🟢). Elle tourne dans le softirq.
11. Elle vide la file **dans l'ordre**, mais **s'arrête au premier paquet encore `UNCRYPTED`**
    (`receive.c:451-453` 🟢) : on ne peut pas livrer le n°3 avant le n°2, sinon on casse
    l'ordre. Pour chaque paquet prêt, elle appelle `wg_packet_consume_data_done`
    (`receive.c:474` 🟢). Quand la file est épuisée, `napi_complete_done` (`:487-488`).
12. `wg_packet_consume_data_done` (`receive.c:335` 🟢) prépare le paquet *interne* :
    `skb->dev = dev` (le netdev **virtuel** `wg0`, `:375` 🟢), vérifie l'IP source autorisée,
    puis **★ `napi_gro_receive(&peer->napi, skb)` (`receive.c:411` 🟢) → GRO Front #2**
    (agrafage des paquets internes déchiffrés).
13. Le super-paquet remonte la pile IP de l'hôte → arrive à l'application destinataire. Fin
    du trajet.

---

## 3. Les deux fronts GRO, côte à côte (résumé)

| | **Front #1** | **Front #2** |
|---|---|---|
| Sur quels paquets | UDP **externes chiffrés** | IP **internes déchiffrés** |
| Quelle NAPI | celle du **vrai pilote NIC** | `peer->napi`, **logicielle**, une par pair |
| Quel netdev | l'interface **physique** (eth/NIC) | l'interface **virtuelle** `wg0` |
| Qui appelle GRO | le pilote du NIC (`napi_gro_receive`) | WireGuard, `napi_gro_receive` `receive.c:411` 🟢 |
| Fusion garantie ? | **Non** — conditionnel à `NETIF_F_GRO_FRAGLIST`/`UDP_FWD` ; WG n'opte pas (`udp_offload.c:800-815` 🟢) | **Oui** — WG l'appelle explicitement |
| Contexte | softirq NET_RX du NIC | softirq NET_RX, poll = `wg_packet_rx_poll` |
| Observable sur M1 ? | **non** (loopback, pas de NIC) | **oui** |
| Observable sur CloudLab ? | possible (NIC 25 G) **si** GRO UDP activé | oui |

Phrase à retenir : *« WireGuard fabrique une fausse carte réseau (`wg0`) et une fausse NAPI
par pair, uniquement pour pouvoir refaire du GRO sur les paquets déchiffrés — comme si une
deuxième carte les recevait. »* Et : *« le Front #1, lui, WireGuard ne l'active pas ; il
dépend des réglages GRO de la vraie NIC. »*

---

## 4. Où est le bug, sur cette carte

Tout se joue à l'**étape C9 → étape D11**.

- Le worker de déchiffrement appelle `napi_schedule(&peer->napi)` **après chaque paquet**,
  inconditionnellement (`queueing.h:196` 🟢).
- Mais la livraison doit être **dans l'ordre**, et `wg_packet_rx_poll` **s'arrête dès que la
  tête de file est encore `UNCRYPTED`** (`receive.c:451-453` 🟢).
- **Inversion d'ordre d'exécution (EoI).** Comme les CPU déchiffrent en parallèle, un worker
  peut finir un paquet « plus loin » dans la file alors que la **tête** n'est pas encore
  prête. Son `napi_schedule` réveille alors `rx_poll`, qui regarde la tête, la voit
  `UNCRYPTED`, et **repart sans rien faire** (`work_done = 0`) : un passage de softirq
  gâché, et surtout **pas de lot pour GRO** (Front #2 perd son efficacité).
- **Le correctif d'André.** Avant de réveiller, lire le **curseur du consommateur**
  (`peer->rx_queue.tail` — qui désigne la *tête* à livrer, par la convention de la file MPSC
  de Vyukov) : ne déclencher `napi_schedule` **que si** la tête est effectivement déchiffrée.
  Sinon, ne rien faire — le worker qui finira la tête s'en chargera. On supprime les réveils
  inutiles, GRO retrouve ses lots. (Diff et sûreté : `PREP_REUNION_ALAIN_CODE_2026-06-01_FR.md`.)

---

## 5. Le prouver en vrai (à montrer, pas seulement à dire)

### 5.1 Confirmer l'interface virtuelle et les deux GRO

```bash
# wg0 est bien un netdev virtuel de type wireguard, sans matériel :
ip -d link show wg0                 # "link/none ... wireguard"

# GRO est activé sur les deux interfaces (les deux fronts) :
ethtool -k wg0   | grep generic-receive-offload     # Front #2 (virtuel)
ethtool -k <NIC> | grep generic-receive-offload     # Front #1 (physique, sur CloudLab)
```
🔵 Attendu : `wg0` apparaît comme `wireguard` (logiciel), GRO `on` des deux côtés.

### 5.2 Voir les deux `napi_gro_receive`, ventilés par interface

```bash
sudo bpftrace -e '
kprobe:napi_gro_receive {
    $skb = (struct sk_buff *)arg1;
    $dev = $skb->dev;
    @gro[str($dev->name)] = count();   // "wg0" = Front #2 ; "<NIC>" = Front #1
}
interval:s:5 { print(@gro); clear(@gro); }'
```
🔵 Attendu : sous trafic tunnel, `@gro[wg0]` grimpe (Front #2). Sur CloudLab, `@gro[<NIC>]`
grimpe aussi (Front #1). Sur M1/loopback, seul `wg0` bouge.

### 5.3 Voir la NAPI logicielle de WireGuard tourner (le `poll` du pair)

```bash
sudo bpftrace -e '
kprobe:wg_packet_rx_poll { @polls = count(); }
kretprobe:wg_packet_rx_poll { @work_done = lhist(retval, 0, 64, 8); }
interval:s:5 { print(@polls); print(@work_done); clear(@polls); clear(@work_done); }'
```
🔵 Le `lhist` de `work_done` est *la* mesure du bug : un pic dans le **bucket 0** = des
réveils gâchés (EoI). Le correctif doit faire **fondre le bucket 0** et concentrer la masse
sur des valeurs > 1 (des lots, donc GRO efficace).

### 5.4 Voir les workers de déchiffrement par-CPU (la workqueue)

```bash
sudo bpftrace -e '
kprobe:wg_packet_decrypt_worker { @worker_cpu[cpu] = count(); }
interval:s:5 { print(@worker_cpu); clear(@worker_cpu); }'
```
🔵 Attendu : plusieurs CPU actifs → confirme le déchiffrement **parallèle par-CPU** (la
cause du désordre). C'est la preuve à l'exécution, **indépendante de la version** du noyau.

### 5.5 Confirmer le réveil inconditionnel (le site du bug)

```bash
sudo bpftrace -e '
kprobe:napi_schedule { @sched = count(); }
kprobe:wg_packet_rx_poll { @poll = count(); }
interval:s:5 { print(@sched); print(@poll); clear(@sched); clear(@poll); }'
```
⚪🔵 Si `@sched` ≫ `@poll` utiles (cf. 5.3), on visualise les réveils superflus.

---

## 6. Auto-test (« colle ») — sache répondre à ça sans réfléchir

1. **C'est quoi un « pair » ?** L'autre bout d'un tunnel, identifié par sa **clé
   publique**. `struct wg_peer` ; une `wg0` en porte plusieurs (1000 dans le papier).
   Chaque pair a sa **propre** `rx_queue` et sa **propre** `napi` (`peer.h:39`, `:65`) — ce
   qui rend l'ordre *et* le bug **par pair**.
2. **À quoi sert NAPI, en une phrase ?** À passer de « une interruption par paquet » à « je
   relève la boîte par lots en polling », pour tenir la charge.
3. **NAPI, c'est un thread / kthread / une fonction ?** Aucun : c'est une **structure**
   (`struct napi_struct`) + une **fonction `poll`** associée. `napi_schedule` ne fait que
   l'ajouter à la liste du CPU et lever le softirq NET_RX ; le `poll` tourne ensuite dans
   `net_rx_action` en **contexte softirq** (post-IRQ, ou `ksoftirqd/N` sous charge) — sauf
   NAPI *threadée* (kthread `napi/<dev>-<id>`), que WireGuard n'active pas.
4. **C'est quoi le budget d'une NAPI ?** Le nombre max de paquets traités par passage de
   `poll`, pour ne pas monopoliser le CPU.
5. **Le cycle de vie complet d'une NAPI WireGuard ?** `netif_napi_add` (création + attache à
   `wg0` + enregistre `poll`, `peer.c:57`) → `napi_enable` (rend programmable, `:58`) →
   `napi_schedule` (réveil, `queueing.h:196`) → `wg_packet_rx_poll` (le poll, appelé par
   `net_rx_action`) → `napi_complete_done` (fin + flush GRO, `receive.c:488`) → `napi_disable`
   (`peer.c:120`) → `netif_napi_del` (`:124`). La struct vit dans `struct wg_peer` (`:65`).
6. **Que fait `napi_schedule` si la NAPI tourne déjà ?** Rien de plus qu'un drapeau : via
   `napi_schedule_prep` (`dev.c:6729`), il ne replanifie pas (renvoie `false`) et pose
   `STATE_MISSED` ; à la fin, `napi_complete_done` verra `MISSED` et relancera **un** tour de
   poll. Donc les réveils répétés du worker sont **dédupliqués** — mais le tour de poll, lui,
   peut repartir à vide (lien EoI).
7. **Pourquoi déchiffrer dans une workqueue et pas dans le softirq ?** Le softirq interdit de
   dormir / les tâches longues ; ChaCha20 est lourd → contexte processus = workqueue.
8. **Pourquoi la workqueue de crypto est-elle par-CPU ?** Pour déchiffrer en parallèle sur
   tous les cœurs. Conséquence : fin de déchiffrement **dans le désordre**.
9. **À quoi sert GRO ?** Fusionner les paquets d'une même connexion en un gros, pour payer le
   coût de remontée *une fois* au lieu de N.
10. **Pourquoi GRO apparaît-il deux fois ?** Front #1 sur les UDP **externes chiffrés** (NIC
    physique) ; Front #2 sur les paquets **internes déchiffrés** (interface virtuelle `wg0`).
    ⚠ Nuance vérifiée source : le Front #1 n'est **pas garanti** — WireGuard n'opte pas son
    socket dans le GRO UDP (`udp_sk(sk)->gro_receive` NULL → `udp_offload.c:800`), donc la
    fusion des UDP externes dépend des features de la NIC (`NETIF_F_GRO_FRAGLIST`/`UDP_FWD`).
    Seul le Front #2 est fait *explicitement* par WireGuard (`receive.c:411`).
11. **C'est quoi l'interface virtuelle ?** Le `net_device` logiciel `wg0` créé par WireGuard,
    sans matériel ; il porte une **NAPI par pair** (`peer->napi`) servant juste à refaire du
    GRO sur les paquets déchiffrés. Pas de `gro_cells`, une `napi_struct` par pair.
12. **Quelle fonction est le `poll` de cette NAPI ?** `wg_packet_rx_poll` (`receive.c:438`),
    enregistrée par `netif_napi_add` (`peer.c:57`).
13. **Où est exactement le bug ?** `napi_schedule(&peer->napi)` inconditionnel après chaque
    paquet (`queueing.h:196`), alors que `rx_poll` s'arrête à la première tête `UNCRYPTED`
    (`receive.c:451-453`).
14. **Pourquoi des réveils gâchés ?** Déchiffrement parallèle → désordre → on réveille alors
    que la *tête* n'est pas prête → `rx_poll` repart à vide (`work_done=0`), et GRO ne fait
    pas de lot.
15. **Le correctif ?** Lire `peer->rx_queue.tail` (la tête à livrer) avant de réveiller ; ne
    `napi_schedule` que si cette tête est déchiffrée.
16. **Pourquoi c'est sûr ?** `tail` n'est écrit que par l'unique consommateur (file MPSC de
    Vyukov) → pas de course ; au pire on ne réveille pas, et le worker qui complétera la tête
    réveillera.
17. **Ça se transfère à x86/v6.1 ?** Oui : site du bug, correctif, file MPSC, `rx_poll`
    identiques ; seul `WQ_PERCPU` diffère, sans changer le comportement.

---

## 7. Dossier de preuves — le code source verbatim (`[P1]`…`[P25]`)

Chaque extrait est **copié tel quel** du dépôt (chemins ci-dessous), avec ses numéros de
ligne. Tout `[P#]` cité plus haut renvoie ici. C'est la réponse à « montre-moi le code ».

- Module WireGuard : `linux-source/drivers/net/wireguard/`
- Cœur réseau du noyau : `linux-source/net/core/dev.c`, `linux-source/net/core/gro.c`,
  `linux-source/net/ipv4/udp_offload.c`, `linux-source/net/ipv4/af_inet.c`,
  `linux-source/include/linux/netdevice.h`

### Mise en place (création du pair et de sa NAPI)

**`[P1]` — `struct wg_peer` : le pair porte sa file `rx_queue` ET sa `napi`.** (`peer.h:37`)

```c
struct wg_peer {
	struct wg_device *device;                              // :38  -> wg0
	struct prev_queue tx_queue, rx_queue;                  // :39  files ORDONNÉES, par pair
	/* ... */
	struct noise_keypairs keypairs;                        // :43  état crypto
	struct endpoint endpoint;                              // :44  adresse distante
	/* ... */
	struct kref refcount;                                  // :61
	struct list_head peer_list;                            // :63
	struct list_head allowedips_list;                      // :64  cryptokey routing
	struct napi_struct napi;                               // :65  une NAPI PAR PAIR
	u64 internal_id;                                       // :66
};
```

**`[P2]` — création : init de `rx_queue`, NAPI ajoutée à `wg0`, activée.** (`peer.c:50`)

```c
	wg_prev_queue_init(&peer->tx_queue);
	wg_prev_queue_init(&peer->rx_queue);                       // :51
	/* ... */
	set_bit(NAPI_STATE_NO_BUSY_POLL, &peer->napi.state);       // :56  pas de busy-poll
	netif_napi_add(wg->dev, &peer->napi, wg_packet_rx_poll);   // :57  add + poll + attache wg0
	napi_enable(&peer->napi);                                  // :58  rend programmable
```

**`[P3]` — `netif_napi_add` fixe le budget par défaut `NAPI_POLL_WEIGHT` (= 64).** (`netdevice.h:2831`)

```c
static inline void
netif_napi_add(struct net_device *dev, struct napi_struct *napi,
	       int (*poll)(struct napi_struct *, int))
{
	netif_napi_add_weight(dev, napi, poll, NAPI_POLL_WEIGHT);  // :2835
}
```

**`[P4]` — ce que `netif_napi_add` fait vraiment : `poll`, `weight`, `dev`, état GRO,
`STATE_SCHED` posé, inscription dans la liste du netdev.** (`dev.c:7558`)

```c
void netif_napi_add_weight_locked(struct net_device *dev, struct napi_struct *napi,
				  int (*poll)(struct napi_struct *, int), int weight)
{
	if (WARN_ON(test_and_set_bit(NAPI_STATE_LISTED, &napi->state)))   // :7564
		return;
	INIT_LIST_HEAD(&napi->poll_list);                                // :7567
	gro_init(&napi->gro);                                            // :7570  l'état GRO vit DANS la napi
	napi->poll = poll;                                              // :7572  -> wg_packet_rx_poll
	napi->weight = weight;                                          // :7576  -> 64
	napi->dev = dev;                                               // :7577  -> wg0
	set_bit(NAPI_STATE_SCHED, &napi->state);                       // :7582  (bloque schedule avant enable)
	netif_napi_dev_list_add(dev, napi);                            // :7584
	/* ... */
}
```

**`[P5]` — `napi_enable` efface `STATE_SCHED` → la NAPI devient programmable.** (`dev.c:7653`)

```c
void napi_enable_locked(struct napi_struct *n)
{
	unsigned long new, val = READ_ONCE(n->state);
	/* ... */
	do {
		BUG_ON(!test_bit(NAPI_STATE_SCHED, &val));
		new = val & ~(NAPIF_STATE_SCHED | NAPIF_STATE_NPSVC);   // :7665  efface SCHED
		if (n->dev->threaded && n->thread)
			new |= NAPIF_STATE_THREADED;
	} while (!try_cmpxchg(&n->state, &val, new));
}
```

### Étape A — entrée (front #1 conditionnel, crochet UDP)

**`[P6]` — WireGuard branche `wg_receive` comme récepteur d'encapsulation UDP, sans aucun
réglage GRO.** (`socket.c:353`)

```c
	struct udp_tunnel_sock_cfg cfg = {
		.sk_user_data = wg,
		.encap_type = 1,
		.encap_rcv = wg_receive            // :356  (aucun gro_receive : cf. [P8])
	};
	/* ... */
	setup_udp_tunnel_sock(net, new4, &cfg);   // :393
```

**`[P7]` — `wg_receive` → `wg_packet_receive`.** (`socket.c:316`)

```c
static int wg_receive(struct sock *sk, struct sk_buff *skb)
{
	struct wg_device *wg;
	if (unlikely(!sk)) goto err;
	wg = sk->sk_user_data;
	if (unlikely(!wg)) goto err;
	skb_mark_not_on_list(skb);
	wg_packet_receive(wg, skb);            // :326
	return 0;
err:
	kfree_skb(skb);
	return 0;
}
```

**`[P8a]` — la chaîne d'appel complète du Front #1 : du `poll` du NIC jusqu'à
`udp_gro_receive`.** Tout est dans le **noyau générique**, déclenché par la NAPI du *vrai*
NIC ; **WireGuard n'y apparaît jamais.** Le dispatch se fait deux fois par pointeur de
callback : d'abord par type Ethernet (ETH_P_IP → `inet_gro_receive`), puis par protocole IP
(IPPROTO_UDP → `udp4_gro_receive`).

```c
// (1) linux-source/include/linux/netdevice.h:4251 — appelé par le poll du pilote NIC
static inline gro_result_t napi_gro_receive(struct napi_struct *napi, struct sk_buff *skb)
{
	return gro_receive_skb(&napi->gro, skb);          // GRO de CETTE napi (celle du NIC)
}

// (2) linux-source/net/core/gro.c:626
gro_result_t gro_receive_skb(struct gro_node *gro, struct sk_buff *skb)
{
	...
	ret = gro_skb_finish(gro, skb, dev_gro_receive(gro, skb));   // :635
	...
}

// (3) linux-source/net/core/gro.c:464 — dispatch par TYPE ETHERNET
static enum gro_result dev_gro_receive(struct gro_node *gro, struct sk_buff *skb)
{
	...
	pp = INDIRECT_CALL_INET(ptype->callbacks.gro_receive,
				ipv6_gro_receive, inet_gro_receive,   // :517-518  ETH_P_IP -> inet_gro_receive
				&gro_list->list, skb);
	...
}

// (4) linux-source/net/ipv4/af_inet.c:1468 — dispatch par PROTOCOLE IP
struct sk_buff *inet_gro_receive(struct list_head *head, struct sk_buff *skb)
{
	...
	proto = iph->protocol;
	ops = rcu_dereference(inet_offloads[proto]);          // :1487  proto = IPPROTO_UDP
	...
	pp = indirect_call_gro_receive(tcp4_gro_receive, udp4_gro_receive,
				       ops->callbacks.gro_receive, head, skb);  // :1532  -> udp4_gro_receive
	...
}

// (5) linux-source/net/ipv4/udp_offload.c:874
INDIRECT_CALLABLE_SCOPE
struct sk_buff *udp4_gro_receive(struct list_head *head, struct sk_buff *skb)
{
	...
	pp = udp_gro_receive(head, skb, uh, sk);              // :898  <-- enfin [P8]
	return pp;
}
```

Et les **enregistrements** qui câblent ces callbacks (faits une fois à l'init) :

```c
// linux-source/net/ipv4/af_inet.c:1875 — ETH_P_IP -> inet_gro_receive
		.gro_receive = inet_gro_receive,

// linux-source/net/ipv4/udp_offload.c:991 — IPPROTO_UDP -> udp4_gro_receive
		.gro_receive  = udp4_gro_receive,
```

Récapitulatif du chemin : `poll()` du NIC → `napi_gro_receive` *(netdevice.h:4251)* →
`gro_receive_skb` *(gro.c:626)* → `dev_gro_receive` *(gro.c:464, dispatch :517)* →
`inet_gro_receive` *(af_inet.c:1468, dispatch :1532)* → `udp4_gro_receive`
*(udp_offload.c:874, appel :898)* → **`udp_gro_receive`** *(udp_offload.c:785 → `[P8]`)*.

**`[P8]` — GRO #1 *conditionnel* : sans `gro_receive` de tunnel, la fusion de l'UDP externe
n'a lieu qu'avec `FRAGLIST`/`UDP_FWD`/`GRO_ENABLED`.** (`udp_offload.c:785`)

```c
struct sk_buff *udp_gro_receive(struct list_head *head, struct sk_buff *skb,
				struct udphdr *uh, struct sock *sk)
{
	/* ... */
	NAPI_GRO_CB(skb)->is_flist = 0;
	if (!sk || !udp_sk(sk)->gro_receive) {                         // :800  cas WireGuard
		if (skb->encapsulation) goto out;
		if (skb->dev->features & NETIF_F_GRO_FRAGLIST)             // :807
			NAPI_GRO_CB(skb)->is_flist = sk ? !udp_test_bit(GRO_ENABLED, sk) : 1;
		if ((!sk && (skb->dev->features & NETIF_F_GRO_UDP_FWD)) || // :810
		    (sk && udp_test_bit(GRO_ENABLED, sk)) || NAPI_GRO_CB(skb)->is_flist)
			return call_gro_receive(udp_gro_receive_segment, head, skb);
		goto out;     /* :814  "no GRO, be sure flush the current packet" */
	}
	/* ... */
}
```

### Étape B — aiguillage et mise en file à deux phases

**`[P9]` — `wg_packet_receive` aiguille un `MESSAGE_DATA` vers `wg_packet_consume_data`.** (`receive.c:542`)

```c
void wg_packet_receive(struct wg_device *wg, struct sk_buff *skb)
{
	if (unlikely(prepare_skb_header(skb, wg) < 0))   // :544
		goto err;
	switch (SKB_TYPE_LE32(skb)) {
	/* ... handshakes ... */
	case cpu_to_le32(MESSAGE_DATA):                  // :574
		PACKET_CB(skb)->ds = ip_tunnel_get_dsfield(ip_hdr(skb), skb);
		wg_packet_consume_data(wg, skb);         // :576
		break;
	/* ... */
	}
}
```

**`[P10]` — `wg_packet_consume_data` appelle l'enqueue à deux phases.** (`receive.c:509`)

```c
static void wg_packet_consume_data(struct wg_device *wg, struct sk_buff *skb)
{
	/* ... lookup keypair + peer ... */
	ret = wg_queue_enqueue_per_device_and_peer(&wg->decrypt_queue, &peer->rx_queue, skb,
						   wg->packet_crypt_wq);   // :526
	/* ... */
}
```

**`[P11]` — les deux phases : (1) file ORDONNÉE du pair, état `UNCRYPTED` ; (2) ring global +
`queue_work_on(cpu)`.** (`queueing.h:152`)

```c
static inline int wg_queue_enqueue_per_device_and_peer(
	struct crypt_queue *device_queue, struct prev_queue *peer_queue,
	struct sk_buff *skb, struct workqueue_struct *wq)
{
	int cpu;
	atomic_set_release(&PACKET_CB(skb)->state, PACKET_STATE_UNCRYPTED);  // :158
	if (unlikely(!wg_prev_queue_enqueue(peer_queue, skb)))               // :162  Phase 1 (ORDRE)
		return -ENOSPC;
	cpu = wg_cpumask_next_online(&device_queue->last_cpu);               // :168  tourniquet
	if (unlikely(ptr_ring_produce_bh(&device_queue->ring, skb)))         // :169  Phase 2 (ring)
		return -EPIPE;
	queue_work_on(cpu, wq, &per_cpu_ptr(device_queue->worker, cpu)->work); // :171  -> workqueue
	return 0;
}
```

**`[P12]` — le tourniquet CPU (round-robin).** (`queueing.h:120`)

```c
static inline int wg_cpumask_next_online(int *last_cpu)
{
	int cpu = cpumask_next(READ_ONCE(*last_cpu), cpu_online_mask);   // :122
	if (cpu >= nr_cpu_ids)
		cpu = cpumask_first(cpu_online_mask);
	WRITE_ONCE(*last_cpu, cpu);
	return cpu;
}
```

### Étape C — la workqueue par-CPU déchiffre, puis réveille

**`[P13]` — la workqueue de crypto est créée **par-CPU** (`WQ_PERCPU`).** (`device.c:346`)

```c
	wg->packet_crypt_wq = alloc_workqueue("wg-crypt-%s",
			WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM | WQ_PERCPU, 0,   // :347
			dev->name);
```

**`[P14]` — le worker : consomme le ring, déchiffre, ré-enfile (avec l'état).** (`receive.c:493`)

```c
void wg_packet_decrypt_worker(struct work_struct *work)
{
	struct crypt_queue *queue = container_of(work, struct multicore_worker, work)->ptr;
	struct sk_buff *skb;
	while ((skb = ptr_ring_consume_bh(&queue->ring)) != NULL) {            // :499
		enum packet_state state =
			likely(decrypt_packet(skb, PACKET_CB(skb)->keypair)) ?    // :501
				PACKET_STATE_CRYPTED : PACKET_STATE_DEAD;
		wg_queue_enqueue_per_peer_rx(skb, state);                     // :503
		if (need_resched())
			cond_resched();
	}
}
```

**`[P15]` — LE SITE DU BUG : réveil **inconditionnel** après chaque paquet.** (`queueing.h:188`)

```c
static inline void wg_queue_enqueue_per_peer_rx(struct sk_buff *skb, enum packet_state state)
{
	struct wg_peer *peer = wg_peer_get(PACKET_PEER(skb));        // :193
	atomic_set_release(&PACKET_CB(skb)->state, state);          // :195  marque l'état du skb (déjà dans rx_queue)
	napi_schedule(&peer->napi);                                // :196  *** réveil inconditionnel ***
	wg_peer_put(peer);                                         // :197
}
```

**`[P16]` — `napi_schedule` n'est qu'un inline : `prep` puis `__napi_schedule`.** (`netdevice.h:558`)

```c
static inline bool napi_schedule(struct napi_struct *n)
{
	if (napi_schedule_prep(n)) {       // :560
		__napi_schedule(n);
		return true;
	}
	return false;
}
```

**`[P17]` — `napi_schedule_prep` : déduplication via `STATE_MISSED` (ne replanifie pas si déjà
programmée).** (`dev.c:6729`)

```c
bool napi_schedule_prep(struct napi_struct *n)
{
	unsigned long new, val = READ_ONCE(n->state);
	do {
		if (unlikely(val & NAPIF_STATE_DISABLE))   // :6734  refuse si en désactivation
			return false;
		new = val | NAPIF_STATE_SCHED;
		/* pose MISSED si SCHED était déjà mis : */
		new |= (val & NAPIF_STATE_SCHED) / NAPIF_STATE_SCHED * NAPIF_STATE_MISSED;  // :6744
	} while (!try_cmpxchg(&n->state, &val, new));
	return !(val & NAPIF_STATE_SCHED);             // :6748  true SEULEMENT si SCHED n'était pas posé
}
```

**`[P18]` — `____napi_schedule` : ajoute à la `poll_list` du CPU + lève le softirq NET_RX.** (`dev.c:4982`)

```c
use_local_napi:
	list_add_tail(&napi->poll_list, &sd->poll_list);   // :4984  liste "à scruter" du CPU
	WRITE_ONCE(napi->list_owner, smp_processor_id());  // :4985
	if (!sd->in_net_rx_action)
		raise_softirq_irqoff(NET_RX_SOFTIRQ);      // :4990  lève le softirq
```

### Étape D — la 2ᵈᵉ NAPI : poll ordonné + GRO #2

**`[P19]` — `net_rx_action` (gestionnaire du softirq NET_RX) parcourt la liste et appelle le
`poll` de chaque NAPI.** (`dev.c:7914`)

```c
static __latent_entropy void net_rx_action(void)
{
	struct softnet_data *sd = this_cpu_ptr(&softnet_data);
	int budget = READ_ONCE(net_hotdata.netdev_budget);   // :7920  budget GLOBAL
	/* ... */
	list_splice_init(&sd->poll_list, &list);             // :7928
	for (;;) {
		struct napi_struct *n;
		/* ... */
		n = list_first_entry(&list, struct napi_struct, poll_list);  // :7952
		budget -= napi_poll(n, &repoll);             // :7953  -> n->poll() = wg_packet_rx_poll
		/* ... budget/time_limit ... */
	}
}
```

**`[P20]` — `wg_packet_rx_poll` : vide la file DANS L'ORDRE, **s'arrête au 1er `UNCRYPTED`**,
puis `napi_complete_done`.** (`receive.c:438`)

```c
int wg_packet_rx_poll(struct napi_struct *napi, int budget)
{
	struct wg_peer *peer = container_of(napi, struct wg_peer, napi);   // :440  retrouve le pair
	/* ... */
	while ((skb = wg_prev_queue_peek(&peer->rx_queue)) != NULL &&      // :451  regarde la TÊTE
	       (state = atomic_read_acquire(&PACKET_CB(skb)->state)) !=
		       PACKET_STATE_UNCRYPTED) {                          // :453  STOP si pas déchiffrée
		wg_prev_queue_drop_peeked(&peer->rx_queue);
		/* ... */
		wg_packet_consume_data_done(peer, skb, &endpoint);        // :474  livre le paquet prêt
		/* ... */
		if (++work_done >= budget)
			break;
	}
	if (work_done < budget)
		napi_complete_done(napi, work_done);                      // :488  file vidée -> termine
	return work_done;
}
```

**`[P20] décryptage` — les trois états, et « une seule boucle, deux tests ».** Point de
confusion fréquent : on croit voir *deux boucles* (une sur `UNCRYPTED`, une sur `CRYPTED`).
Il n'y en a qu'**une** ; le piège, c'est qu'il y a **trois** états, pas deux.

L'énumération (`queueing.h:53` 🟢) :

```c
enum packet_state {
    PACKET_STATE_UNCRYPTED,  // 0 : encore EN ATTENTE (aucun worker n'a fini)
    PACKET_STATE_CRYPTED,    // 1 : fini, VALIDE   -> à livrer
    PACKET_STATE_DEAD        // 2 : fini, INVALIDE -> à jeter
};
```

Un `enum` ne « contient » rien par lui-même : ce sont trois entiers nommés (0, 1, 2).
L'état *réel* de chaque paquet vit dans un champ du paquet (`queueing.h:59` 🟢) :
`PACKET_CB(skb)->state`, un `atomic_t` — atomique car **deux CPU y touchent** : le worker
l'écrit (`atomic_set_release`), le poll le lit (`atomic_read_acquire`). Le couple
*release/acquire* garantit que lorsque le poll *voit* `CRYPTED`, les octets déchiffrés par
le worker lui sont aussi **visibles** (pas seulement le drapeau).

| État | Posé où | Sens | Que fait `rx_poll` |
|---|---|---|---|
| `UNCRYPTED` | Phase 1, à l'enfilage (`queueing.h:158`) | **en attente** | **STOP** : on ne peut pas avancer (ordre) |
| `CRYPTED` | worker, succès (`receive.c:501`) | fini, **valide** | **livrer** (→ GRO) |
| `DEAD` | worker, échec | fini, **invalide** | **jeter** et continuer |

**(A) La condition du `while` (`:451-453`) — `state != UNCRYPTED`.** On continue tant que la
tête est *résolue* (plus en attente). Pourquoi `!= UNCRYPTED` et **pas** `== CRYPTED` ? Parce
qu'un paquet fini peut être `CRYPTED` **ou** `DEAD` : les deux veulent dire « le worker en a
terminé ». La boucle doit pouvoir consommer **les deux**, sinon une tête `DEAD` bloquerait la
file pour toujours (elle ne deviendra jamais `CRYPTED`). La boucle **s'arrête donc à la
première tête encore `UNCRYPTED`** — c'est la règle d'ordre : livrer dans l'ordre, ne jamais
sauter un paquet en attente.

**(B) Le `if` interne (`:458`) — `state != CRYPTED` → `goto next`.** Ce n'est **pas** une
seconde boucle : c'est un *embranchement*, à l'intérieur du corps, sur un paquet déjà résolu.
Il sépare les deux états « finis » : `CRYPTED` → on poursuit (valider le nonce + l'endpoint,
puis livrer) ; sinon (`DEAD`) → `goto next`, qui **jette** le `skb` (le drapeau `free` est
resté `true` → `dev_kfree_skb`). Le drapeau `free` n'est que « dois-je jeter ce paquet ? » :
il vaut `true` par défaut et passe à `false` seulement à la livraison réussie. (À noter : même
un paquet `CRYPTED` peut finir jeté si `counter_validate` échoue — rejeu/nonce invalide — ou
si l'endpoint est illisible : deux autres `goto next`.)

**À retenir en une ligne :** `UNCRYPTED` = *« attends »* (on s'arrête), `CRYPTED` = *« livre »*,
`DEAD` = *« jette et continue »*. Le `while` sépare *attendre* des *deux autres* ; le `if`
sépare *livrer* de *jeter*. **Et le bug est ici :** si un worker réveille la NAPI alors que la
tête est encore `UNCRYPTED`, la condition (A) est fausse dès le premier `peek` → le corps ne
s'exécute jamais → `work_done = 0` (réveil gâché), quel que soit le nombre de paquets déjà
`CRYPTED` *derrière* la tête.

**`[P21]` — la file MPSC (Vyukov) : les producteurs écrivent `head` (`xchg_release`), seul le
consommateur touche `tail`. C'est ce qui rend le correctif (lire `tail`) sûr.** (`device.h:34`,
`queueing.c:50`)

```c
/* device.h:34 */
struct prev_queue {
	struct sk_buff *head, *tail, *peeked;
	struct { struct sk_buff *next, *prev; } empty;   // imite les 2 1ers membres de sk_buff
	atomic_t count;
};

/* queueing.c — producteur : écrit HEAD */
static void __wg_prev_queue_enqueue(struct prev_queue *queue, struct sk_buff *skb)
{
	WRITE_ONCE(NEXT(skb), NULL);
	WRITE_ONCE(NEXT(xchg_release(&queue->head, skb)), skb);   // :69  HEAD (côté producteurs)
}

/* queueing.c — consommateur unique : écrit TAIL */
struct sk_buff *wg_prev_queue_dequeue(struct prev_queue *queue)
{
	struct sk_buff *tail = queue->tail, *next = smp_load_acquire(&NEXT(tail));  // :82
	/* ... */
	queue->tail = next;     // :87/:92/:101  TAIL (écrit uniquement ici, consommateur)
	/* ... */
}
```

**`[P22]` — `wg_packet_consume_data_done` : `skb->dev = wg0`, contrôle cryptokey-routing,
**GRO #2** `napi_gro_receive`.** (`receive.c:335`)

```c
static void wg_packet_consume_data_done(struct wg_peer *peer, struct sk_buff *skb,
					struct endpoint *endpoint)
{
	struct net_device *dev = peer->device->dev;     // :339  = wg0 (virtuel)
	/* ... */
	skb->dev = dev;                                 // :375  rattache à wg0
	/* ... */
	routed_peer = wg_allowedips_lookup_src(&peer->device->peer_allowedips, skb);  // :404
	wg_peer_put(routed_peer);
	if (unlikely(routed_peer != peer))              // :408  cryptokey routing : sinon on jette
		goto dishonest_packet_peer;
	napi_gro_receive(&peer->napi, skb);             // :411  *** GRO #2 (interne) ***
	update_rx_stats(peer, message_data_len(len_before_trim));
	return;
	/* ... */
}
```

**`[P23]` — `napi_complete_done` : **flush GRO**, retire de la `poll_list`, efface `SCHED` ; si
`MISSED`, relance un tour.** (`dev.c:6771`)

```c
bool napi_complete_done(struct napi_struct *n, int work_done)
{
	/* ... */
	gro_flush_normal(&n->gro, !!timeout);              // :6803  *** envoie les lots GRO #2 ***
	if (unlikely(!list_empty(&n->poll_list))) {
		list_del_init(&n->poll_list);              // :6808  retire de la liste du CPU
	}
	/* efface SCHED (et MISSED/...) : */
	new = val & ~(NAPIF_STATE_MISSED | NAPIF_STATE_SCHED | /* ... */);   // :6817
	/* si MISSED était posé, garde SCHED pour rappeler poll() : */
	new |= (val & NAPIF_STATE_MISSED) / NAPIF_STATE_MISSED * NAPIF_STATE_SCHED;  // :6825
	/* ... */
	if (unlikely(val & NAPIF_STATE_MISSED)) {
		__napi_schedule(n);                        // :6830  un tour de poll de plus
		return false;
	}
	/* ... */
}
```

### Démontage

**`[P24]` — à la suppression du pair : `napi_disable` puis `netif_napi_del`.** (`peer.c:116`)

```c
	flush_workqueue(peer->device->packet_crypt_wq);   // :116
	flush_workqueue(peer->device->packet_crypt_wq);   // :118
	napi_disable(&peer->napi);                        // :120  attend le poll en cours
	netif_napi_del(&peer->napi);                      // :124  retire la NAPI du netdev
```

**`[P25]` — `napi_disable` : pose `STATE_DISABLE` et **attend** la fin du poll (peut dormir →
contexte processus).** (`dev.c:7604`)

```c
void napi_disable_locked(struct napi_struct *n)
{
	might_sleep();                                            // :7608
	set_bit(NAPI_STATE_DISABLE, &n->state);                  // :7611  bloque tout futur schedule
	val = READ_ONCE(n->state);
	do {
		while (val & (NAPIF_STATE_SCHED | NAPIF_STATE_NPSVC)) {
			usleep_range(20, 200);                   // :7616  attend le poll en cours
			val = READ_ONCE(n->state);
		}
		/* ... */
	} while (!try_cmpxchg(&n->state, &val, new));
	clear_bit(NAPI_STATE_DISABLE, &n->state);                // :7633
}
```
