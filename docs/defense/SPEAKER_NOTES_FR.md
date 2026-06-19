# Notes de présentation — Preuve EoI WireGuard
# Réunion Alain & André — Jeudi 21 mai, 9h

---

## Slide 1 — Titre

Cette présentation a un objectif précis : prouver, ligne par ligne dans le code source du noyau Linux, qu'il existe une inversion d'ordre d'exécution dans le pipeline de réception de WireGuard. Je ne vais pas citer l'article de Mounah et al. comme une autorité — je vais montrer le mécanisme exact dans le code, de façon à ce que chaque affirmation soit vérifiable indépendamment dans l'arbre source.

Le bug appartient à une classe bien connue en programmation concurrente : une étape du pipeline réveille une étape suivante avant que les données dont celle-ci a besoin soient prêtes. La conséquence ici n'est pas un crash ni une corruption de données — c'est une perte de performance silencieuse et auto-entretenue qui plafonne le débit à 19,2 % du débit théorique de la carte réseau.

---

## Slide 2 — L'affirmation centrale

Avant d'entrer dans les détails du code, je veux poser clairement ce qu'on cherche à prouver.

WireGuard a un pipeline de réception en trois étapes. L'étape 1 est le handler UDP qui tourne en contexte softirq — c'est une interruption logicielle de haute priorité. L'étape 2 est le worker de déchiffrement qui tourne dans une workqueue à priorité `SCHED_NORMAL`, comme n'importe quel processus utilisateur. L'étape 3, c'est le GRO — Generic Receive Offload — qui reassemble les paquets et les injecte dans la pile réseau, et qui tourne lui aussi en contexte softirq, donc à une priorité supérieure à l'étape 2.

Le problème : l'étape 2, après avoir déchiffré un paquet, appelle `napi_schedule` pour réveiller l'étape 3. Mais au moment où l'étape 3 se déclenche réellement, les données dont elle a besoin pour progresser ne sont souvent pas encore prêtes — parce qu'un autre CPU est encore en train de déchiffrer le paquet qui est en tête de file. L'étape 3 préempte l'étape 2, trouve une file bloquée, et sort immédiatement sans rien faire. Tout le cycle CPU est gaspillé.

Les trois chiffres à droite résument le diagnostic : le cœur saturé tourne à 94 % d'utilisation, mais seulement 19,2 % du débit attendu passe, et avec 1 000 clients le scénario du papier, chaque pair possède sa propre instance NAPI capable de déclencher ce cycle indépendamment.

---

## Slide 3 — Étape 1 : Chaque pair a sa propre instance NAPI

La première chose à comprendre, c'est l'architecture de base : dans WireGuard, chaque pair réseau — chaque machine distante connectée au tunnel — possède sa propre instance `napi_struct`. Ce n'est pas un détail d'implémentation anodin, c'est un choix architectural qui a des conséquences directes sur le bug.

`netif_napi_add` est la fonction qui enregistre cette instance auprès du sous-système réseau du noyau. Elle prend trois arguments importants : le périphérique réseau WireGuard (`wg->dev`), la structure NAPI du pair (`&peer->napi`), et la fonction de poll à appeler quand le GRO doit s'exécuter (`wg_packet_rx_poll`). À partir de ce moment, n'importe quel appel à `napi_schedule(&peer->napi)` depuis n'importe quel CPU du système va placer ce pair dans la liste de poll du CPU courant et lever le flag `NET_RX_SOFTIRQ`.

`napi_enable` qui suit juste après est la "porte d'activation" : jusqu'à cet appel, la structure NAPI existe en mémoire mais ne peut pas être schedulée. `napi_enable` efface les bits `NAPI_STATE_SCHED` et `NAPI_STATE_NPSVC` qui la maintenaient artificiellement désactivée depuis `netif_napi_add`. Après cet appel, le pair est opérationnel.

Pourquoi ce design un-NAPI-par-pair plutôt qu'un NAPI partagé pour tout le périphérique ? Deux raisons : d'abord, l'isolation de l'ordre de livraison — chaque flux de paquets d'un pair doit être délivré dans l'ordre indépendamment des autres pairs. Ensuite, le parallélisme — avec un NAPI partagé, tous les pairs se serializeraient à travers une seule fonction de poll. Avec des NAPIs par pair, différents pairs peuvent être traités simultanément sur différents CPUs.

La conséquence directe pour le bug : avec 1 000 pairs, on a 1 000 instances NAPI indépendantes, chacune capable de saturer un CPU.

---

## Slide 4 — Étape 2 : La workqueue de déchiffrement

La workqueue `packet_crypt_wq` est créée avec trois flags qui définissent entièrement son comportement de scheduling.

`WQ_PERCPU` signifie qu'un thread worker est alloué et épinglé par CPU. Il n'y a pas de migration — le worker sur le CPU 3 reste sur le CPU 3. Sous forte charge, si ce worker est occupé ou bloqué, aucun autre worker n'est créé pour le remplacer sur ce CPU. Cette épinglage est essentiel pour comprendre la saturation : le worker et le GRO vont se retrouver sur le même cœur, sans possibilité d'évasion.

`WQ_CPU_INTENSIVE` retire ces workers du compteur de concurrence du kernel (`nr_running`). Normalement, le gestionnaire de workqueues limite le nombre de workers qui tournent simultanément sur un CPU pour éviter la sur-souscription. Avec `WQ_CPU_INTENSIVE`, ces workers sont exclus de ce mécanisme — ils peuvent tourner aussi longtemps qu'ils le souhaitent sans que le kernel crée de workers supplémentaires pour les compenser. C'est approprié ici parce que le déchiffrement ChaCha20-Poly1305 est du calcul CPU pur, sans attente, sans verrous dormants.

Mais — et c'est le point crucial — `WQ_CPU_INTENSIVE` ne change rien à la préemptibilité. Ces workers tournent à `SCHED_NORMAL`. Les softirqs tournent à un niveau de priorité supérieur, en dehors du scheduler de processus classique. Un softirq peut toujours préempter un worker `SCHED_NORMAL`, `WQ_CPU_INTENSIVE` ou non.

---

## Slide 5 — Étape 3 : La boucle du worker de déchiffrement

La boucle est simple dans sa structure : `ptr_ring_consume_bh` tire un paquet chiffré de l'anneau global, `decrypt_packet` effectue le déchiffrement ChaCha20-Poly1305 en pur calcul CPU, puis `wg_queue_enqueue_per_peer_rx` place le paquet dans la file du pair et programme le GRO.

Ce qui est important à saisir, c'est que cette boucle tourne de façon continue tant qu'il y a des paquets dans l'anneau. Elle ne traite pas un batch et ne s'arrête pas — c'est une boucle tight qui enchaîne les paquets les uns après les autres. Le `cond_resched` à la fin est un yield volontaire au scheduler, mais seulement si le scheduler a marqué le thread comme devant céder (`need_resched`). Sous forte charge, ce yield peut ne jamais se déclencher.

L'EoI n'est pas dans `decrypt_packet` — le déchiffrement lui-même est sans problème. L'EoI est dans le fait que `wg_queue_enqueue_per_peer_rx` est appelé à chaque itération, ce qui signifie que `napi_schedule` est appelé à chaque paquet déchiffré. Entre chaque paire d'itérations consécutives, le GRO peut se déclencher.

---

## Slide 6 — Étape 4 : ptr_ring_consume_bh — le cycle d'activation/désactivation des BH

Cette fonction est la clé de compréhension du timing exact. Elle tire un pointeur de l'anneau circulaire protégé par spinlock, mais elle le fait en désactivant les "bottom halves" — les softirqs — pendant la durée de l'accès.

`spin_lock_bh` désactive les softirqs sur le CPU courant en plus d'acquérir le spinlock. Pendant ce temps, aucun softirq ne peut s'exécuter sur ce CPU, même si le flag `NET_RX_SOFTIRQ` est levé. `__ptr_ring_consume` tire le paquet de l'anneau. `spin_unlock_bh` relâche le spinlock et réactive les softirqs en appelant `local_bh_enable()`. Et c'est là que tout se joue : si un softirq était en attente — c'est-à-dire si `NET_RX_SOFTIRQ` avait été levé pendant que les BH étaient désactivés, ou juste avant — il s'exécute immédiatement à l'intérieur de `spin_unlock_bh`, avant même que la fonction ne retourne à son appelant.

Cela signifie que le GRO ne s'exécute pas "après la boucle" ni "à la fin du worker". Il s'exécute à l'intérieur de `ptr_ring_consume_bh`, entre deux itérations de la boucle. Plus précisément : le `napi_schedule` de l'itération N lève le flag, et ce flag est consommé lors du `spin_unlock_bh` du `ptr_ring_consume_bh` de l'itération N+1.

---

## Slide 7 — Étape 5 : wg_queue_enqueue_per_peer_rx — le déclencheur de l'EoI

Cette petite fonction inline est le cœur du bug. Elle fait deux choses dans l'ordre :

D'abord, `atomic_set_release` marque le paquet qui vient d'être déchiffré comme `PACKET_STATE_CRYPTED`. Le "release" dans `atomic_set_release` est une barrière mémoire qui garantit que cette écriture est visible par tous les autres CPUs avant toute opération ultérieure. Le paquet courant est donc bel et bien prêt.

Ensuite, `napi_schedule(&peer->napi)` lève le flag `NET_RX_SOFTIRQ`. Il ne déclenche pas immédiatement le GRO — il enregistre que le GRO doit s'exécuter, et lie le poll NAPI au CPU courant via `this_cpu_ptr(&softnet_data)`.

La subtilité importante : le GRO ne va pas échouer à cause du paquet qu'on vient de marquer CRYPTED. Ce paquet est prêt. Le GRO va échouer à cause de la tête de la file du pair, qui appartient à un autre paquet en cours de déchiffrement sur un autre CPU. Le problème n'est pas ce paquet — c'est l'état global de la file ordonnée.

---

## Slide 8 — Étape 6 : napi_schedule — le binding au CPU

`napi_schedule` est une fonction simple qui appelle `__napi_schedule`, qui elle-même appelle `____napi_schedule` — avec trois underscores — en lui passant `this_cpu_ptr(&softnet_data)`.

`this_cpu_ptr` est une macro kernel qui retourne un pointeur vers la variable par-CPU `softnet_data` du CPU qui exécute cette instruction à cet instant précis. `softnet_data` est la structure qui contient la liste de poll NAPI pour ce CPU. `list_add_tail` ajoute la structure NAPI du pair à cette liste. `__raise_softirq_irqoff` lève le bit `NET_RX_SOFTIRQ` dans le masque de softirqs du CPU.

Deux conséquences importantes de ce mécanisme. Première : le poll NAPI est lié au CPU qui a exécuté `napi_schedule`. Si le worker de déchiffrement tourne sur le CPU 3, le GRO va se déclencher sur le CPU 3 — pas sur un CPU moins chargé, pas sur le CPU qui serait le plus efficace. Sur le CPU 3.

Deuxième : une fois `NAPI_STATE_SCHED` positionné, tout appel ultérieur à `napi_schedule` pour le même pair depuis n'importe quel CPU est un no-op — `napi_schedule_prep` retourne faux. Le pair ne peut être schedulé qu'une seule fois à la fois. Cela signifie que si d'autres workers déchiffrent des paquets du même pair simultanément, leurs appels à `napi_schedule` n'auront aucun effet jusqu'à ce que le poll courant se termine.

---

## Slide 9 — Étape 7 : Quand le softirq se déclenche réellement

Ce slide montre le timing précis de l'EoI, itération par itération.

Pendant l'itération N : le worker tire le paquet N via `ptr_ring_consume_bh` — ce qui réactive les BH à la fin. Le déchiffrement s'effectue. Le paquet N est marqué CRYPTED. `napi_schedule` lève `NET_RX_SOFTIRQ` — mais à ce moment là, le worker est sorti de `ptr_ring_consume_bh` et les BH sont déjà réactivées depuis l'itération N. `napi_schedule` utilise `local_irq_save/restore`, pas `local_bh_enable` — donc le softirq ne se déclenche pas là.

Pendant l'itération N+1 : le worker entre dans `ptr_ring_consume_bh` pour tirer le paquet N+1. `spin_lock_bh` désactive les BH. `__ptr_ring_consume` tire le paquet N+1. `spin_unlock_bh` réactive les BH via `local_bh_enable`. À cet instant, `NET_RX_SOFTIRQ` est en attente depuis l'itération N. `do_softirq` s'exécute. `wg_packet_rx_poll` tourne, trouve la tête UNCRYPTED, sort. Le worker reprend — mais il n'a pas encore traité le paquet N+1. Il vient juste de le tirer de l'anneau.

Le GRO s'intercale entre le moment où le paquet est tiré de l'anneau et le moment où le worker commence à le traiter. L'interleaving est au niveau de la granularité du paquet, pas du batch.

---

## Slide 10 — Étape 8 : Pourquoi le GRO ne trouve rien

`wg_packet_rx_poll` parcourt la file de réception du pair strictement depuis la tête, dans l'ordre, et s'arrête dès qu'il rencontre un paquet en état `PACKET_STATE_UNCRYPTED`.

La raison de cette contrainte est fondamentale : TCP exige une livraison ordonnée. Si le paquet 0 n'est pas encore déchiffré mais que le paquet 1 l'est, le GRO ne peut pas livrer le paquet 1 à la pile réseau avant le paquet 0 — cela casserait la numérotation de séquence TCP et provoquerait des retransmissions inutiles.

Sous charge concurrente avec plusieurs CPUs qui déchiffrent en parallèle, la file ressemble presque toujours à ça : la tête est UNCRYPTED — parce qu'un CPU est encore en train de travailler dessus — et des paquets CRYPTED attendent derrière. Le GRO arrive, regarde la tête, voit UNCRYPTED, et sort immédiatement. `work_done` reste à zéro. `napi_complete_done` est appelé, ce qui efface `NAPI_STATE_SCHED` et libère le NAPI pour une prochaine scheduling.

Il faut noter un détail important que j'ai vérifié dans le source : les paquets DEAD — ceux dont l'authentification a échoué — ne bloquent pas le poll. Le code à `receive.c:458` les détecte et continue avec un `goto next`. Seul UNCRYPTED bloque. Donc ce n'est pas un problème de paquets corrompus — c'est structurel.

---

## Slide 11 — Étape 9 : Saturation auto-entretenue

Ce slide montre pourquoi le problème ne se résout pas de lui-même sous charge.

Sur le CPU X, le worker de déchiffrement est épinglé par `WQ_PERCPU`. Il ne peut pas migrer. Le GRO est lui aussi épinglé au CPU X parce que `napi_schedule` a capturé `this_cpu_ptr` pendant que le worker tournait sur le CPU X. Les deux sont donc sur le même cœur.

La boucle qui s'auto-entretient : le worker déchiffre un paquet, appelle `napi_schedule`, et continue vers l'itération suivante. L'itération suivante commence par `ptr_ring_consume_bh` qui réactive les BH dans `spin_unlock_bh`, ce qui déclenche le GRO. Le GRO s'exécute à haute priorité, préempte le worker, inspecte la file, trouve la tête UNCRYPTED, sort. Le worker reprend. Déchiffre un paquet. `napi_schedule`. `ptr_ring_consume_bh`. GRO. Rien. Reprend. Et ainsi de suite, pour chaque paquet dans l'anneau.

Le résultat mesuré dans le papier est éloquent : 94 % d'utilisation CPU sur le cœur saturé. Ce cœur n'est pas inactif — il est très occupé. Mais la majorité du temps est dépensée en boucles GRO inutiles plutôt qu'en déchiffrement utile. D'où le 19,2 % de débit effectif.

---

## Slide 12 — Récapitulatif : Chaîne complète, fichiers et lignes

Ce tableau est la preuve condensée. Onze points de passage, chacun avec son fichier et son numéro de ligne dans l'arbre source `linux-source/` du repo.

Je veux insister sur deux points de ce tableau. D'abord, le point 6 et le point 7 sont sur des lignes consécutives dans `queueing.h` — 195 et 196. L'espace entre "marquer le paquet prêt" et "programmer le GRO" est littéralement d'une ligne de code. C'est là que l'inversion naît.

Ensuite, le point 9 et le point 6 pointent vers le même fichier et la même ligne : `ptr_ring.h:371`. C'est parce que c'est le même appel — `ptr_ring_consume_bh` — qui à la fois déclenche le softirq (via `spin_unlock_bh`) et tire le paquet suivant. Le site où le GRO s'exécute et le site où les données du prochain paquet sont disponibles sont le même endroit dans le code. L'interleaving est inévitable par construction.

---

## Slide 13 — Le correctif du papier

Le correctif est d'une élégance remarquable parce qu'il change exactement une chose : le niveau de priorité auquel s'exécute le GRO.

Au lieu d'appeler `napi_schedule(&peer->napi)` — ce qui schedule le poll NAPI en tant que softirq à haute priorité sur le CPU courant — le correctif appelle `queue_work_on(cpu, gro_wq, &peer->rx_work)`, ce qui dispatche `wg_packet_rx_poll` comme un work item sur une workqueue dédiée, tournant à `SCHED_NORMAL`.

Deux conséquences immédiates. Première : le GRO ne peut plus préempter le worker de déchiffrement — ils sont au même niveau de priorité `SCHED_NORMAL`. Le scheduler décide de leur ordonnancement, et typiquement le worker continue jusqu'à ce qu'il yield volontairement ou que son quantum expire. Deuxième : le GRO peut être dispatché sur un CPU différent de celui du worker — ce qui brise le co-épinglage sur le même cœur.

Le couplage tight entre Stage 2 et Stage 3 est brisé. Le cycle de préemption disparaît. Et le résultat mesuré : 4,7× d'augmentation du débit et 46 % de réduction de la latence de queue. La topologie du pipeline n'a pas changé — les mêmes trois étapes, les mêmes données, le même matériel. Seule la priorité d'exécution du GRO a changé.

---

## Annexe — Définitions pouvant être demandées

---

### Qu'est-ce que les Bottom Halves (BH) ?

Dans le noyau Linux, le traitement d'une interruption matérielle est divisé en deux parties. La première partie — la "top half" — s'exécute immédiatement lors de l'interruption, avec toutes les interruptions désactivées. Elle doit être aussi courte que possible : elle se contente d'acquitter le matériel et de noter qu'il y a du travail à faire. La seconde partie — la "bottom half" — est le traitement différé : elle s'exécute un peu plus tard, dans un contexte où les interruptions sont ré-activées, ce qui permet au système de rester réactif.

Les softirqs sont l'implémentation la plus basse et la plus rapide des bottom halves. Ils s'exécutent dès que le noyau les autorise — typiquement à la sortie d'une section critique, quand `local_bh_enable()` est appelé, ou au retour d'une interruption matérielle. Ils tournent en dehors du scheduler de processus classique : il n'y a pas de context switch, pas de `task_struct` associé, pas de time slice. Un softirq qui tourne empêche tout autre softirq de s'exécuter sur le même CPU (sauf si le thread ksoftirqd prend le relais), et surtout il préempte n'importe quel thread `SCHED_NORMAL` ou `SCHED_IDLE` sans que ce thread ait son mot à dire.

`spin_lock_bh` et `spin_unlock_bh` sont des spinlocks qui désactivent/réactivent les bottom halves en plus d'acquérir/relâcher le verrou. C'est un pattern très courant pour protéger des structures de données partagées entre un thread normal et un softirq sur le même CPU.

**Ce qui est important pour cette présentation :** `NET_RX_SOFTIRQ` est le softirq dédié à la réception réseau. Quand il est levé via `__raise_softirq_irqoff`, il ne s'exécute pas immédiatement — il attend le prochain `local_bh_enable()`. C'est ce délai d'une itération qui définit le timing précis de l'EoI.

---

### Qu'est-ce que NAPI et comment est-il utilisé ?

NAPI — New API — est le mécanisme de polling réseau du noyau Linux, introduit pour remplacer le modèle purement interruptif qui saturait les CPUs sous forte charge réseau.

**Le problème que NAPI résout :** dans le modèle original, chaque paquet réseau qui arrive déclenche une interruption matérielle. Sous forte charge — par exemple 10 Gbps de trafic réseau entrant — le CPU peut recevoir des millions d'interruptions par seconde, et le traitement des interruptions lui-même devient le goulot d'étranglement. Le CPU passe plus de temps à gérer les interruptions qu'à traiter les paquets.

**La solution NAPI :** au lieu d'interrompre le CPU pour chaque paquet, la carte réseau déclenche une seule interruption pour signaler qu'il y a des paquets à traiter. Le noyau désactive alors les interruptions pour cette carte et passe en mode polling : il interroge activement la carte pour vider la file de paquets reçus, en traitant autant de paquets que possible en un seul appel (`weight` paquets maximum, typiquement 64). Une fois la file vidée ou le budget épuisé, les interruptions sont ré-activées.

**La structure `napi_struct` :** chaque source de paquets qui utilise NAPI possède une instance `napi_struct`. Elle contient principalement : `state` (les bits d'état atomiques — SCHED, NPSVC, MISSED, etc.), `poll` (le pointeur vers la fonction de poll à appeler), `weight` (le budget en nombre de paquets), `poll_list` (le chaînage dans la liste de poll du CPU), et `gro` (l'état du Generic Receive Offload).

**Dans WireGuard :** WireGuard n'utilise pas NAPI pour la raison originelle — il n'y a pas de file DMA à drainer. Il l'utilise comme mécanisme de scheduling pour déclencher `wg_packet_rx_poll`, la fonction qui prend les paquets déchiffrés dans la file ordonnée du pair et les injecte dans la pile réseau. `napi_schedule` est détourné de son usage habituel : au lieu de signaler "la carte réseau a des paquets", il signale "ce pair a des paquets prêts à être injectés dans le stack".

---

### Qu'est-ce que GRO (Generic Receive Offload) ?

GRO est une optimisation du noyau Linux qui fusionne plusieurs paquets TCP/IP de petite taille en un seul paquet plus grand avant de les passer à la couche réseau supérieure. L'idée est de réduire le nombre d'appels aux couches réseau en regroupant les paquets qui appartiennent au même flux.

Sans GRO, chaque paquet de 1500 octets remonte toute la pile TCP/IP individuellement. Avec GRO, le noyau peut fusionner 10 paquets de 1500 octets en un seul paquet virtuel de 15 000 octets avant de le passer à TCP — réduisant le nombre d'appels de 10× et donc le coût CPU par octet transféré.

Dans le contexte WireGuard, GRO s'exécute dans `wg_packet_rx_poll`. Cette fonction prend les paquets déchiffrés depuis la file ordonnée du pair et appelle `napi_gro_receive` pour chacun. C'est `napi_gro_receive` qui tente la fusion avant de livrer à la couche IP.

**Ce qui est important pour cette présentation :** GRO a besoin de paquets dans l'ordre pour fonctionner correctement. Si un paquet manque ou n'est pas encore disponible, GRO ne peut pas fusionner les suivants avec le précédent — il doit attendre. C'est la raison directe pour laquelle `wg_packet_rx_poll` s'arrête à la première tête UNCRYPTED.

---

### Qu'est-ce qu'une Workqueue dans le noyau Linux ?

Une workqueue est un mécanisme du noyau Linux pour exécuter du travail différé dans le contexte d'un thread kernel dédié — appelé "worker thread". Contrairement aux softirqs qui s'exécutent en dehors du scheduler, les workers de workqueue sont des threads normaux avec une `task_struct`, un contexte de scheduling, et la capacité de se bloquer (dormir en attendant un verrou, une ressource, etc.).

**L'API de base :**
- `INIT_WORK(&work, func)` — associe une fonction à un `work_struct`
- `queue_work(wq, &work)` — soumet le work item à la workqueue
- `queue_work_on(cpu, wq, &work)` — soumet sur un CPU spécifique
- `flush_workqueue(wq)` — attend que tous les work items en cours soient terminés

**Les flags importants dans ce contexte :**
- `WQ_PERCPU` — un worker thread par CPU, épinglé. Pas de migration, pas de remplacement si bloqué.
- `WQ_UNBOUND` — workers non épinglés, le scheduler les place sur n'importe quel CPU disponible. Résilient aux blocages car un worker bloqué libère son slot.
- `WQ_CPU_INTENSIVE` — retire le worker du compteur de concurrence `nr_running` dès le début de l'exécution. Le kernel ne crée pas de workers supplémentaires pour compenser. Approprié pour du calcul CPU pur.
- `WQ_FREEZABLE` — le worker est gelé lors d'une suspension système (hibernation, suspend-to-RAM).
- `WQ_MEM_RECLAIM` — garantit qu'un worker peut toujours s'exécuter même sous pression mémoire, via un thread "rescuer" dédié.

**Différence clé avec les softirqs :** un worker de workqueue peut dormir, acquérir des mutex, appeler `kmalloc(GFP_KERNEL)`. Un softirq ne peut rien faire de tout cela — il doit être non-bloquant. C'est pourquoi le déchiffrement ChaCha20-Poly1305 tourne dans une workqueue (il pourrait théoriquement bloquer sur des allocations mémoire) tandis que le dispatch initial des paquets tourne en softirq.

---

### Qu'est-ce que SCHED_NORMAL et la préemption par les softirqs ?

Linux a plusieurs classes de scheduling pour les threads. `SCHED_NORMAL` (aussi appelé `SCHED_OTHER`) est la classe par défaut pour les processus et threads utilisateur, et pour les worker threads des workqueues. Elle utilise le Completely Fair Scheduler (CFS) et donne à chaque thread un quantum de temps proportionnel à sa priorité nice.

Les softirqs ne font pas partie de ce système. Ils s'exécutent dans un contexte qui est en dehors du scheduler CFS — ils ne sont pas des tâches schedulées, ils sont exécutés directement par le CPU quand les conditions le permettent (BH activés, pas de section critique noyau). Ils ont toujours la priorité sur n'importe quel thread `SCHED_NORMAL`, `SCHED_BATCH` ou `SCHED_IDLE`. Seul `SCHED_FIFO` ou `SCHED_RR` avec une priorité temps-réel peut techniquement prendre le dessus, mais WireGuard ne l'utilise pas.

Concrètement : quand `local_bh_enable()` est appelé dans `spin_unlock_bh`, si un softirq est en attente, le CPU l'exécute immédiatement — le thread `SCHED_NORMAL` qui venait d'appeler `spin_unlock_bh` ne reprend la main qu'après que le softirq ait terminé. C'est de la préemption non-coopérative, déclenchée par le mécanisme BH lui-même.

---

### Qu'est-ce que ChaCha20-Poly1305 et pourquoi est-il utilisé dans WireGuard ?

ChaCha20-Poly1305 est un schéma de chiffrement authentifié (AEAD — Authenticated Encryption with Associated Data). Il combine deux primitives cryptographiques : ChaCha20, un chiffrement de flot rapide conçu par Daniel Bernstein, et Poly1305, un code d'authentification de message (MAC) universel.

WireGuard l'utilise à la place d'AES-GCM pour plusieurs raisons. ChaCha20-Poly1305 est rapide sur des processeurs qui n'ont pas d'instructions AES matérielles — comme les anciens processeurs ARM ou les microcontrôleurs embarqués. Il est également résistant aux attaques par canal auxiliaire de timing (timing side-channels) sur ces architectures. Sur les processeurs modernes avec AES-NI (comme les Intel/AMD récents), AES-GCM est plus rapide ; sur ARM sans cryptographic extensions, ChaCha20-Poly1305 est compétitif ou supérieur.

**Ce qui est important pour cette présentation :** ChaCha20-Poly1305 est un calcul CPU pur — pas d'accès disque, pas de réseau, pas de verrous dormants. C'est pourquoi `WQ_CPU_INTENSIVE` est approprié pour les workers de déchiffrement : ils monopolisent volontairement le CPU pour la durée du calcul cryptographique, sans jamais se bloquer. Si l'authentification Poly1305 échoue (tag invalide), le paquet est marqué `PACKET_STATE_DEAD` et silencieusement abandonné — c'est la protection contre les paquets forgés ou corrompus.

---

### Qu'est-ce qu'un spinlock et comment diffère-t-il d'un mutex ?

Un spinlock est un mécanisme de synchronisation qui protège une section critique en faisant attendre le CPU en boucle active ("spinning") jusqu'à ce que le verrou soit disponible. Contrairement à un mutex, le thread qui attend ne se met pas en sommeil — il tourne en boucle, consommant du CPU, jusqu'à ce qu'il obtienne le verrou.

**Quand utiliser un spinlock :** les spinlocks sont utilisés quand la section critique est très courte (quelques instructions) et quand le code ne peut pas dormir — notamment dans les contextes softirq, les handlers d'interruptions, et tout code qui tourne avec les interruptions désactivées. Dans ces contextes, un mutex est interdit parce qu'un mutex peut mettre le thread en sommeil, ce qui est impossible en contexte d'interruption.

**Quand utiliser un mutex :** les mutexes sont utilisés quand la section critique peut être longue ou quand le code peut raisonnablement attendre. Un thread qui attend un mutex est mis en sommeil par le scheduler et ne consomme pas de CPU en attendant. C'est ce qu'on appelle un "sleeping lock".

**Dans WireGuard :** `ptr_ring_consume_bh` utilise un spinlock (`consumer_lock`) parce qu'il tourne dans une workqueue qui partage des données avec le contexte softirq. `handshake->lock` dans `noise.c` est un rwsemaphore — un sleeping lock — parce que les opérations de handshake Noise peuvent être longues (calculs Diffie-Hellman) et ne s'exécutent jamais en contexte interruptif.

---

### Qu'est-ce que le Noise Protocol et pourquoi WireGuard l'utilise-t-il ?

Le Noise Protocol Framework est un framework de protocoles cryptographiques conçu par Trevor Perrin. Il définit une famille de protocoles d'établissement de clés basés sur l'échange Diffie-Hellman, avec différents patterns selon les besoins d'authentification mutuelle.

WireGuard utilise le pattern `Noise_IKpsk2` : un échange en deux messages (initiation + réponse) avec authentification mutuelle par clés statiques et un pre-shared key optionnel. À l'issue de cet échange, les deux parties dérivent un keypair symétrique ChaCha20-Poly1305 partagé sans jamais avoir transmis les clés secrètes sur le réseau.

**Pourquoi Noise plutôt que TLS :** Noise est minimaliste — le handshake WireGuard complet tient en deux messages UDP. TLS 1.3 nécessite plusieurs aller-retours et transporte des certificats X.509. Noise offre des propriétés de sécurité formellement prouvées (forward secrecy, identity hiding, resistance to replay), avec une implémentation beaucoup plus petite et auditables.

**Ce qui est important pour cette présentation :** le handshake Noise dans `noise.c` contient des `down_write(&handshake->lock)` — des rwsemaphores dormants. Ce sont des sleeping locks : si un autre CPU tient le verrou, le thread se met en sommeil et attend. C'est la raison pour laquelle les workers de handshake (`wg_packet_handshake_receive_worker` et `wg_packet_handshake_send_worker`) sont classifiés comme BLOQUANTS dans notre analyse.

---

### Qu'est-ce que le GFP_ATOMIC et pourquoi est-il utilisé dans les contextes non-bloquants ?

`GFP_ATOMIC` est un flag d'allocation mémoire dans le noyau Linux qui indique au système d'allocation qu'il ne peut pas dormir pour attendre que de la mémoire soit disponible. Si la mémoire n'est pas immédiatement disponible, l'allocation échoue et retourne `NULL` — plutôt que de bloquer jusqu'à ce que de la mémoire soit libérée.

Dans les contextes softirq, les handlers d'interruptions, et tout code qui tourne avec les interruptions ou les BH désactivés, `GFP_KERNEL` (l'allocation standard qui peut dormir) est strictement interdit. `GFP_ATOMIC` est obligatoire dans ces contextes.

Dans `decrypt_packet`, `skb_cow_data` utilise `GFP_ATOMIC` parce que le worker de déchiffrement partage son contexte avec des sections où les BH sont désactivées. Si l'allocation `GFP_ATOMIC` échoue — ce qui est rare mais possible sous pression mémoire extrême — le paquet est marqué DEAD et silencieusement abandonné. C'est un comportement correct : il vaut mieux perdre un paquet que de bloquer ou crasher le système.

---
