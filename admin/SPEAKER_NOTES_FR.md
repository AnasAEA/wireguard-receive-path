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
