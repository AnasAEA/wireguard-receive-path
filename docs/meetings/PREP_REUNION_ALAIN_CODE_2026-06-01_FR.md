# Revue du code WireGuard — tout expliqué, preuve à l'appui
# (prep réunion Alain, lundi 1ᵉʳ juin 2026)

Le but de ce document, c'est que je puisse raconter de bout en bout ce que j'ai
fait et pourquoi, sans jamais affirmer quelque chose que je ne peux pas montrer. La
règle que je me fixe : **chaque fois que je dis « ça marche comme ça », je donne la
ligne de code, ou la commande qui le prouve à l'exécution.**

Tout le code dont je parle est maintenant dans le dépôt, dans
`linux-source/drivers/net/wireguard/` — je l'ai récupéré depuis `AsahiLinux/linux`,
branche `asahi`, c'est-à-dire exactement la version du noyau que j'ai compilée. Donc
quand je cite `receive.c:493`, tu peux ouvrir le fichier et regarder. Dans la suite
j'omets le préfixe du chemin.

Une petite précision honnête d'entrée de jeu : il y a deux sortes d'affirmations
dans ce que je raconte. Les premières se prouvent par **une ligne dans le code de
WireGuard** — celles-là, je les montre directement. Les secondes concernent le
**contexte d'exécution** (« ça tourne en softirq », « c'est un kworker », « le
budget vaut 64 ») : ça, ce n'est pas écrit dans le code de WireGuard, ça dépend de
la mécanique du noyau autour. Pour celles-là je ne devine pas — **je les prouve à
l'exécution avec `bpftrace`**, et je donne la commande à chaque fois.

---

## Le voyage d'un paquet, en une minute

Avant de plonger, voici l'histoire en gros. Un paquet chiffré arrive par le réseau.
WireGuard le met dans **deux files en même temps** : une qui fixe l'**ordre** dans
lequel les paquets de ce correspondant devront être livrés, et une autre qui sert à
choisir **sur quel CPU** il va être déchiffré. Plusieurs CPU déchiffrent donc des
paquets du même correspondant **en parallèle**. Quand un CPU a fini de déchiffrer le
sien, il réveille la couche de livraison (GRO) pour qu'elle remette les paquets dans
l'ordre et les donne au système.

Le bug est exactement là : ce réveil se fait **après chaque paquet, sans condition**.
Or la livraison part toujours de la tête de la file, et si la tête n'est pas encore
déchiffrée, il n'y a rien à livrer — le réveil n'a servi à rien. Comme les CPU
finissent dans le désordre, ça arrive la plupart du temps. Le correctif tient en une
idée : **ne réveiller la livraison que si elle a une chance de faire quelque chose.**

Maintenant, déroulons-le pour de vrai.

---

## Étape 0 — par où le paquet entre, et pourquoi je dis « softirq »

Le point d'entrée côté WireGuard, c'est `wg_packet_receive` (`receive.c:542`). Cette
fonction lit l'en-tête et aiguille : si c'est un paquet de données (`MESSAGE_DATA`),
elle appelle `wg_packet_consume_data` — on le voit aux lignes `receive.c:574-576`.

Maintenant, **qui** appelle `wg_packet_receive` ? Ce n'est pas dans `receive.c`,
c'est dans `socket.c`. La fonction `wg_receive` (`socket.c:326`) l'appelle, et cette
`wg_receive` est branchée comme **callback de réception UDP** : on le voit à
`socket.c:356`, `.encap_rcv = wg_receive`, posé par `setup_udp_tunnel_sock`
(`socket.c:393`). Autrement dit, dès qu'un datagramme UDP arrive sur le port
WireGuard, le noyau appelle `wg_receive`, qui appelle `wg_packet_receive`.

Et c'est ici que je dois être honnête : **« ça tourne en softirq » n'est écrit nulle
part dans WireGuard.** Ça vient du fait que le noyau appelle `encap_rcv` depuis le
chemin de réception UDP, lui-même exécuté dans le softirq réseau (le `NET_RX` de la
carte). Plutôt que de l'affirmer, je le montre :

```bash
sudo bpftrace -e 'kprobe:wg_packet_receive { printf("comm=%s cpu=%d\n", comm, cpu); print(kstack); exit(); }'
```

La pile d'appels affichée contient les frames du softirq (`net_rx_action`,
`__napi_poll`, le chemin `udp…`, puis `wg_receive`). Ça prouve d'un coup **le
contexte** (softirq) **et** **l'appelant** (le callback UDP). Si Alain demande
« comment tu sais ? », c'est cette pile que je montre.

---

## Étape 1 — les deux files, et pourquoi il y en a deux

`wg_packet_consume_data` (`receive.c:509`) retrouve d'abord la clé de session
(`receive.c:516`), puis appelle la fonction centrale de mise en file :
`wg_queue_enqueue_per_device_and_peer` (`queueing.h:152`), à la ligne `receive.c:526`.

C'est cette fonction qui fait la **double mise en file**, et c'est le cœur de toute
l'affaire. Regardons-la dans l'ordre :

- D'abord elle marque le paquet `UNCRYPTED` (`queueing.h:158`) — « pas encore
  déchiffré ».
- Ensuite, **Phase 1** : `wg_prev_queue_enqueue(peer_queue, skb)` (`queueing.h:162`).
  Ça insère le paquet dans la file **du correspondant**. C'est ici, et seulement
  ici, que l'**ordre de livraison** est fixé — avant tout déchiffrement.
- Enfin, **Phase 2** : on choisit un CPU avec `wg_cpumask_next_online`
  (`queueing.h:168`), on pousse le paquet dans la file **globale** du device avec
  `ptr_ring_produce_bh` (`queueing.h:169`), et on planifie un worker sur ce CPU avec
  `queue_work_on` (`queueing.h:171`).

Donc il y a bien **deux files avec deux rôles différents**, et c'est ça qu'il faut
avoir en tête :

La **file par correspondant** (`peer->rx_queue`) sert à l'**ordre**. Sa structure est
définie à `device.h:34-38` (`struct prev_queue` : des champs `head`, `tail`,
`peeked`, `empty`, `count`). Il y en a **une par correspondant** — on le voit à
`peer.h:39`, où `rx_queue` est un champ de `struct wg_peer` (`peer.h:37`).

La **file globale** (`wg->decrypt_queue`, un `ptr_ring`) sert à répartir le travail
sur les CPU. Le choix du CPU est un tourniquet (round-robin) fait par
`wg_cpumask_next_online` (`queueing.h:120-127`). Détail amusant et important : le
commentaire juste au-dessus (`queueing.h:115-118`) dit que la fonction est « racy »
— elle peut renvoyer deux fois le même CPU — mais que les conséquences sont
inoffensives, donc ils vivent avec. Ça confirme qu'il n'y a aucune coordination
forte ici : c'est volontairement relâché.

La conséquence logique de tout ça : l'ordre est gelé en Phase 1, mais les paquets
partent ensuite sur des CPU différents en Phase 2. **C'est de là que naît la
concurrence** qui va créer le bug.

---

## Étape 2 — le déchiffrement en parallèle, et pourquoi je dis « kworker »

Le travail planifié par `queue_work_on` est exécuté par `wg_packet_decrypt_worker`
(`receive.c:493`). Sa boucle est simple : il prend un paquet de la file globale avec
`ptr_ring_consume_bh` (`receive.c:499`), il le déchiffre (ChaCha20-Poly1305,
`receive.c:501`), puis il appelle `wg_queue_enqueue_per_peer_rx` (`receive.c:503`).

Pourquoi « plusieurs CPU en parallèle » ? Parce que la file de travail est créée
avec le drapeau `WQ_PERCPU` — on le voit noir sur blanc à `device.c:346-347` :

```c
wg->packet_crypt_wq = alloc_workqueue("wg-crypt-%s",
        WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM | WQ_PERCPU, 0, dev->name);
```

`WQ_PERCPU` veut dire un worker par CPU. Donc quatre paquets d'un même
correspondant peuvent être déchiffrés sur quatre CPU à la fois.

> Nuance de version, importante à connaître : sur le noyau du **papier (6.1, x86)**,
> la ligne est `WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM` **sans** `WQ_PERCPU`. Ce n'est
> pas une différence de comportement : avant ≈6.11, une workqueue sans `WQ_UNBOUND`
> était **par-CPU par défaut**. Les noyaux récents (comme mon Asahi ≈6.19) exigent
> le drapeau explicite `WQ_PERCPU` pour garder la même sémantique. Donc « un worker
> par CPU » est vrai partout — seule la *preuve par le code* change selon la version.
> J'ai vérifié ça en comparant les deux versions (voir
> `admin/COMPARAISON_CODE_VERSIONS_FR.md`). La preuve à l'exécution (ci-dessous) est,
> elle, indépendante de la version.

Et « kworker » ? Là encore, ce n'est pas une ligne de WireGuard : c'est le contexte
d'exécution d'un worker de `workqueue`. Je le prouve :

```bash
sudo bpftrace -e 'kprobe:wg_packet_decrypt_worker { @[comm, cpu] = count(); }'
```

À l'arrêt, ça affiche des `comm` du genre `wg-crypt-…` (donc bien des threads
kworker, et le nom vient du `"wg-crypt-%s"` qu'on vient de voir) répartis sur
**plusieurs `cpu`**. Une seule commande prouve à la fois le contexte workqueue **et**
le parallélisme.

---

## Étape 3 — le réveil, et le bug en une ligne

À la fin du déchiffrement, le worker appelle donc `wg_queue_enqueue_per_peer_rx`
(`queueing.h:188`). Dans la version d'origine, elle fait deux choses : elle marque le
paquet `CRYPTED` (`queueing.h:195`), puis elle réveille la livraison :

```c
napi_schedule(&peer->napi);   // queueing.h:196 — SANS CONDITION, à chaque paquet
```

Voilà le bug, à la ligne 196. Et quand je dis « à chaque paquet », ce n'est pas une
impression : cet appel est **à l'intérieur de la boucle par-paquet** du worker
(`receive.c:499-503`). Si je veux le vérifier à l'exécution, je peux compter les
appels (en sondant `__napi_schedule`, le vrai symbole, car `napi_schedule` est
`inline`), mais structurellement la boucle suffit à le voir.

Petite parenthèse utile : il y a **un `napi_struct` par correspondant** (`peer.h:65`),
et la fonction de livraison associée est enregistrée à la création du correspondant
par `netif_napi_add(wg->dev, &peer->napi, wg_packet_rx_poll)` (`peer.c:57`), activée
juste après (`peer.c:58`) et désactivée à la destruction (`peer.c:120`). Donc
`napi_schedule(&peer->napi)` réveille bien la livraison **de ce correspondant**.

---

## Étape 4 — la livraison, et pourquoi le réveil est souvent gaspillé

La livraison, c'est `wg_packet_rx_poll` (`receive.c:438`). Elle part de la tête de la
file du correspondant et avance tant que les paquets sont prêts ; elle **s'arrête au
premier paquet `UNCRYPTED`** — c'est exactement la condition de sa boucle
`receive.c:451-453`. Les paquets prêts sont remontés au système par
`napi_gro_receive` (`receive.c:411`). Elle respecte un budget (`receive.c:483`) et
n'appelle `napi_complete_done` que si elle a traité moins que le budget
(`receive.c:487-488`). Au passage, l'`enum packet_state` avec `UNCRYPTED`,
`CRYPTED`, `DEAD` est défini à `queueing.h:53-55`.

Maintenant le point décisif : **si la tête est `UNCRYPTED`, la boucle sort
immédiatement avec `work_done = 0`.** Le réveil n'a rien livré. C'est ça, un
« réveil gaspillé ». Et comme les CPU finissent dans le désordre (la tête, le paquet
0, est souvent le dernier prêt parce que son CPU était occupé), ça arrive très
souvent. En probabilité, la chance que la tête soit la première finie parmi N
déchiffrements en parallèle est de 1/N — sur 8 cœurs, ça veut dire que ~87 % des
réveils ne servent à rien. (Ça, c'est du raisonnement, pas une ligne de code ; mais
je le **mesure** directement, voir plus bas.)

Tant qu'on y est, deux affirmations de contexte que je dois prouver et pas affirmer :

« `wg_packet_rx_poll` tourne en `NET_RX_SOFTIRQ` » :

```bash
sudo bpftrace -e 'kprobe:wg_packet_rx_poll { print(kstack); exit(); }'
```

La pile montre `net_rx_action` / `__napi_poll` → c'est bien le softirq.

« le budget vaut 64 » (c'est le défaut du noyau, `NAPI_POLL_WEIGHT`, parce qu'on
n'a passé aucun poids à `netif_napi_add`) :

```bash
sudo bpftrace -e 'kprobe:wg_packet_rx_poll { printf("budget=%d\n", arg1); exit(); }'
```

`arg1` est le deuxième paramètre, donc `budget`.

Et la mesure principale, celle qui prouve tout le raisonnement — combien de réveils
sont gaspillés (retour 0) contre utiles (retour > 0) :

```bash
sudo bpftrace -e '
  kretprobe:wg_packet_rx_poll /retval == 0/ { @gaspilles += 1; }
  kretprobe:wg_packet_rx_poll /retval > 0/  { @utiles += 1; }
  interval:s:1 { printf("gaspilles=%lld utiles=%lld\n", @gaspilles, @utiles); @gaspilles=0; @utiles=0; }'
```

C'est cette sonde qui m'a donné les chiffres de la campagne (−14 à −20 % de réveils
avec le correctif).

---

## Le correctif — ce que j'ai changé, et pourquoi c'est sûr

L'idée tient en une phrase : avant de réveiller la livraison, regarder si le prochain
paquet qu'elle traiterait est encore `UNCRYPTED` ; si oui, ne pas réveiller.
Concrètement :

```diff
 static inline void wg_queue_enqueue_per_peer_rx(struct sk_buff *skb, enum packet_state state)
 {
 	struct wg_peer *peer = wg_peer_get(PACKET_PEER(skb));
+	struct sk_buff *tail;
 
 	atomic_set_release(&PACKET_CB(skb)->state, state);
-	napi_schedule(&peer->napi);
+
+	tail = READ_ONCE(peer->rx_queue.tail);
+	if (tail == (struct sk_buff *)&peer->rx_queue.empty ||
+	    atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
+		napi_schedule(&peer->napi);
+
 	wg_peer_put(peer);
 }
```

Pourquoi je lis `tail` et pas `head` ? Attention, c'est le piège de tout ce code :
**dans cette file, `head` et `tail` veulent dire l'inverse de l'intuition.** C'est
une file **MPSC** (plusieurs producteurs, un seul consommateur) de type Vyukov —
tout est dans `queueing.c:50-106`. La convention y est :

- `head` = le côté des **producteurs** = le paquet **le plus récent** (celui qu'on
  vient d'ajouter). Les producteurs écrivent ici : `xchg_release(&queue->head, skb)`
  `queueing.c:69`.
- `tail` = le côté du **consommateur** = le paquet **le plus ancien** = **l'avant de
  la file** = le prochain à livrer. Le consommateur lit ici : `wg_prev_queue_dequeue`
  part de `queue->tail` (`queueing.c:82`) et l'avance.

Les liens internes (`NEXT`, qui réutilise `skb->prev`) vont du plus ancien vers le
plus récent, donc le parcours se fait de `tail` vers `head` :

```
   producteurs ajoutent ici                consommateur (GRO) lit ici
            │                                        │
            ▼                                        ▼
        queue->head                             queue->tail
        (+ récent)                              (+ ancien = prochain livré)
            │                                        │
   skb_recent ◄──NEXT── … ──NEXT── skb_ancien ──► STUB
   parcours GRO :  tail ──► NEXT ──► … ──► head   (du + ancien au + récent)
```

Donc « l'avant de la file » — ce que j'appelais la tête au sens courant — c'est le
champ littéralement nommé **`tail`**. Et le premier paquet que `wg_packet_rx_poll`
regarde, c'est bien celui en `queue->tail`.

**Pourquoi vérifier seulement `tail` (l'avant) suffit :** parce que la livraison
**s'arrête au premier paquet `UNCRYPTED`** (`receive.c:451-453`). Si l'avant
(`tail`) est `UNCRYPTED`, GRO ne livre rien, quoi qu'il y ait derrière — inutile de
parcourir la file. Si l'avant est `CRYPTED`/`DEAD`, GRO peut livrer au moins ce
paquet-là. L'état du seul paquet d'avant décide donc à lui seul si un réveil sert à
quelque chose.

Et surtout : `tail` n'est écrit **que** par le consommateur (`queueing.c:87`, `92`,
`101`), jamais par les producteurs. Le lire depuis un worker producteur est donc
sans danger — c'est juste un **indice**.

Le `READ_ONCE` / `atomic_read` sans verrou, c'est cohérent avec ça : je ne fais pas
de synchronisation, je lis un indice. Une lecture périmée n'est pas un problème —
j'y reviens dans la sûreté.

Le cas du `STUB` : `&peer->rx_queue.empty` est la **sentinelle** de file vide
(`#define STUB` à `queueing.c:51`, initialisée à `queueing.c:56`). Quand `tail`
pointe dessus, je ne vais pas déréférencer la sentinelle pour lire un état — je
réveille par sécurité. Un réveil de trop est inoffensif.

La sûreté, maintenant, c'est l'argument important à donner à Alain. Le seul risque
serait de **rater** un réveil. Imaginons que mon worker A lise `UNCRYPTED` à
l'instant précis où un autre worker B fait passer la tête à `CRYPTED`. A ne réveille
pas — mais B, juste après avoir marqué la tête `CRYPTED`, exécute la même fonction,
lit `CRYPTED`, et appelle `napi_schedule` lui-même. Donc le réveil a lieu quand
même. **Aucun paquet ne reste bloqué.** C'est ce qui rend la lecture relâchée
acceptable.

Il reste une limite que j'assume : une fenêtre de timing étroite entre le moment où
la livraison s'arrête en milieu de file et le moment où elle remet le drapeau
`NAPI_STATE_SCHED` à zéro. Dans ce trou, un réveil peut être perdu. Ce n'est **pas**
un problème de correction (le paquet sera livré au paquet suivant), c'est un effet de
second ordre sur la latence en cas de trafic en rafale. Je le mentionne dans le
rapport en toute transparence.

---

## Comment je compile et charge le module — et ce que chaque étape veut dire

Ce qui rend tout ça praticable, c'est que WireGuard est compilé en **module** chez
nous, pas intégré au noyau. Je le vérifie avec
`grep CONFIG_WIREGUARD /boot/config-$(uname -r)` qui donne `=m`. Un module, c'est un
fichier `.ko` qu'on recompile en quelques secondes et qu'on charge à chaud, sans
toucher au noyau ni redémarrer.

Pour compiler un module, il faut les **en-têtes** du noyau. Sur Asahi le paquet
s'appelle `kernel-16k-devel` (à cause des pages mémoire de 16 Ko), et non
`kernel-devel`. Première tentative qui a échoué : compiler depuis un clone brut du
noyau, ça plante parce qu'un fichier généré (`asm-offsets.h`) n'existe que si on a
déjà compilé le noyau entier. La solution, c'est de compiler **contre les en-têtes
déjà installés** :

```bash
make -C /lib/modules/$(uname -r)/build M=$PWD/linux/drivers/net/wireguard
```

Le `-C …/build` dit « prends l'infrastructure de compilation du noyau qui tourne »
(un lien vers les en-têtes installés, qui contiennent `asm-offsets.h`), et le `M=…`
dit « le module à compiler est ici ». Ça produit `wireguard.ko`.

Avant de le charger, je vérifie son `vermagic` avec
`modinfo wireguard.ko | grep vermagic` : il doit être identique à `uname -r`, sinon
le noyau refuse le module — c'est un garde-fou de version.

Enfin le chargement. `insmod` ne charge pas tout seul les modules dont WireGuard
dépend, alors je les charge d'abord, puis j'insère le mien :

```bash
sudo rmmod wireguard
sudo modprobe udp_tunnel ip6_udp_tunnel libcurve25519
sudo insmod linux/drivers/net/wireguard/wireguard.ko
journalctl -k | grep wireguard   # "WireGuard 1.0.0 loaded."
```

---

## Si Alain me pose une question — où je pointe

S'il demande « comment tu sais que c'est en softirq ? », je montre la pile bpftrace
(la commande de l'étape 0), et côté code le `.encap_rcv = wg_receive` à
`socket.c:356`. S'il demande « pourquoi le parallélisme casse l'ordre ? », je montre
la Phase 1 qui fige l'ordre (`queueing.h:162`) et la Phase 2 qui disperse sur N CPU
(`queueing.h:168-171`). S'il demande « pourquoi `tail` et pas `head` ? », je montre
que `tail` est le curseur du consommateur, écrit seulement par lui
(`queueing.c:87,92,101`). S'il doute du « un worker par CPU », je montre `WQ_PERCPU`
(`device.c:347`) et la sonde qui liste les CPU (étape 2). Et s'il demande « le budget
c'est bien 64 ? », je l'affiche en direct (étape 4).

---

## L'essentiel en une phrase

Le bug est à `queueing.h:196` : un réveil de la livraison après chaque paquet, alors
que la livraison ne peut rien faire tant que la tête de file n'est pas déchiffrée.
Mon changement, à `queueing.h:188`, lit le curseur du consommateur (`tail`, écrit
seulement par lui) et ne réveille que si la livraison a une chance d'avancer — c'est
sûr parce que le cœur qui rend la tête prête réveillera de toute façon.

*(Pour le reste : présentation large + résultats + plan CloudLab dans
`PRESENTATION_LUNDI_2026-06-01_FR.md` ; détails build/mesures dans
`EXPLICATION_SOLUTION_FR.md` et `EXPERIMENTS_2026-05-28.md`.)*
