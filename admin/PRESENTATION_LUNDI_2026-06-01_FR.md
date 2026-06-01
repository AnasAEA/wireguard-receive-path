# Présentation — Lundi 1ᵉʳ juin 2026 (Alain + André)
# Correctif WireGuard EoI : code, mesures sur M1, et plan CloudLab

**Format :** points de discussion, une section = une « diapo ». Pour chaque diapo :
**[À montrer]** et **[À dire]**. Durée visée : ~20 min + discussion.
**Support visuel :** les 7 diagrammes existants (`diagrams/diagram1.png` … `diagram7.png`).

---

## Diapo 1 — Où on en est (rappel rapide)

**[À montrer]** Une phrase + le diagramme 1 (pipeline en 3 étapes).

**[À dire]**
« Pour rappel : le problème, c'est l'Execution Order Inversion. WireGuard déchiffre
les paquets en parallèle sur plusieurs cœurs, puis les livre dans l'ordre. Après
**chaque** paquet déchiffré, le code réveille la couche de livraison (GRO) de façon
inconditionnelle — `napi_schedule` à `queueing.h:196`. La plupart du temps la tête
de file n'est pas encore prête, donc GRO se réveille pour rien.
Depuis la dernière fois j'ai : appliqué le correctif d'André, recompilé et chargé
le module, et fait une première campagne de mesures sur ma machine. Aujourd'hui je
vous montre le code, les résultats, et le plan pour mesurer sur de vraies machines
via CloudLab. »

---

## Diapo 2 — Le correctif appliqué (le code)

**[À montrer]** Le diff (6 lignes) dans `wg_queue_enqueue_per_peer_rx`.

```c
atomic_set_release(&PACKET_CB(skb)->state, state);

tail = READ_ONCE(peer->rx_queue.tail);
if (tail == (struct sk_buff *)&peer->rx_queue.empty ||
    atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
        napi_schedule(&peer->napi);
```

**[À dire]**
« On lit la queue de file (`tail`) — c'est le prochain paquet que GRO traiterait.
Si ce paquet est encore en cours de déchiffrement, GRO ne pourrait rien livrer :
on ne le réveille pas. On ne réveille que si la file est vide (sécurité) ou si la
tête est prête. C'est exactement votre idée, André. C'est inline, dans le chemin
chaud — pas de coût ajouté.
Sûreté : le seul risque serait de rater un réveil. Mais si je lis "pas prêt" pile
au moment où un autre cœur rend la tête prête, c'est cet autre cœur qui fera le
réveil. Aucun paquet bloqué. D'où `READ_ONCE`/`atomic_read` sans verrou : on lit un
indice, pas une donnée critique. »

---

## Diapo 3 — Comment je l'ai construit et chargé

**[À montrer]** 4 puces.

**[À dire]**
« Concrètement :
1. WireGuard est un **module** sur Fedora Asahi (`CONFIG_WIREGUARD=m`), donc je
   recompile juste le module, pas tout le noyau.
2. Piège rencontré : compiler depuis un clone brut échoue (`asm-offsets.h`
   manquant). Solution : compiler contre les en-têtes installés
   (`kernel-16k-devel`) avec `make -C /lib/modules/$(uname -r)/build M=…`.
3. Le `vermagic` du module doit matcher le noyau exactement — vérifié.
4. Chargement : `insmod` après avoir chargé 3 modules dépendants
   (`udp_tunnel`, `ip6_udp_tunnel`, `libcurve25519`). `dmesg` confirme. »

*(Détails complets dans `admin/EXPLICATION_SOLUTION_FR.md` et
`admin/EXPERIMENTS_2026-05-28.md`.)*

---

## Diapo 4 — Comment je mesure

**[À montrer]** Schéma multi-pairs (diagramme du banc d'essai) + 2 outils.

**[À dire]**
« Le bug n'apparaît qu'avec beaucoup de pairs partageant **une seule** file de
déchiffrement — l'architecture du papier. Comme je n'ai qu'une machine, j'utilise
les **namespaces réseau** : 1 serveur + N clients, vrai tunnel WireGuard entre eux,
sur la boucle locale.
Deux mesures :
- **iperf3** → le débit.
- **bpftrace** sur `wg_packet_rx_poll` → je compte les réveils GRO **gaspillés**
  (retour = 0, rien livré) vs **utiles** (retour > 0). C'est la preuve directe que
  le correctif supprime des réveils. »

---

## Diapo 5 — Résultats sur M1 : le correctif agit

**[À montrer]** Tableau résumé.

| Pairs | Réveils GRO totaux/s (stock → corrigé) | Δ |
|---|---|---|
| 8 | 156 891 → 129 518 | **−17,4 %** |
| 16 | 148 823 → 119 429 | **−19,8 %** |
| 32 | 139 052 → 119 004 | **−14,4 %** |
| 64 (moy. 3 runs) | ~173 000 → ~148 000 | **~−14,5 %** |

**[À dire]**
« Le correctif fonctionne exactement comme prévu : il supprime 14 à 20 % des
réveils de GRO, et la tendance monte avec le nombre de pairs — plus de pairs = plus
de déchiffrement concurrent = plus de réveils inutiles à supprimer.
Point méthodologique important : le bon indicateur, c'est le **nombre total** de
réveils, pas le pourcentage de gaspillage. Le correctif n'transforme pas un réveil
gaspillé en réveil utile — il **empêche le réveil d'avoir lieu**. Donc l'effet se
voit sur le total, pas sur le ratio. »

---

## Diapo 6 — Le meilleur résultat : la latence de queue

**[À montrer]** 64 pairs : latence max ~82 ms (stock) → ~43 ms (corrigé).

**[À dire]**
« À 64 pairs, la latence de queue (tail latency) est ~divisée par deux : ~82 ms
côté stock, ~43 ms côté corrigé — alors que la latence **moyenne** est identique
(3,1 ms). Ça veut dire que le correctif supprime précisément les "pics" de latence
dus aux blocages de GRO, sans toucher au régime permanent. C'est le résultat le
plus net et le plus défendable. »

---

## Diapo 7 — Ce que je ne peux PAS conclure sur ma machine (honnêteté)

**[À montrer]** Tableau « papier vs ma config ».

| Condition | Papier (Mounah et al.) | Ma machine |
|---|---|---|
| Carte réseau | NIC 25 Gbps | Boucle locale (pas de NIC) |
| Clients | 800–1000 | jusqu'à 64 |
| CPU | ~94 % sur un cœur | ~10–15 % |
| Chiffrement | x86 AVX2 | ARM NEON (très rapide) |

**[À dire]**
« Le débit ne bouge pas dans mes mesures — et c'est attendu. Le gain de débit du
papier (×4,7) vient d'une **saturation** : un cœur à 94 % noyé sous les réveils
inutiles. Sur ma machine en boucle locale, le M1 chiffre trop vite (NEON ~10 Go/s
par cœur) : je ne peux pas saturer, donc supprimer 20 % d'un surcoût qui n'est pas
le goulot d'étranglement ne change rien au débit.
Conclusion honnête : **j'ai validé le mécanisme et un gain de latence, mais je ne
peux pas tester le régime où le correctif est censé aider le débit.** D'où
CloudLab. »

*(Note : j'ai aussi corrigé une de mes propres mesures — une baisse de migrations
CPU de −43,7 % que j'avais attribuée aux workers WireGuard. En isolant la sonde,
j'ai vu que ces workers ne migrent jamais — ils sont épinglés par cœur via
`WQ_PERCPU`. La vraie valeur du correctif est sur les réveils et la latence.)*

---

## Diapo 8 — CloudLab : enfin le bon régime

**[À montrer]** Schéma 3 machines (à compléter après la visio avec Teo).

**[À dire]**
« Grâce à vous et à Teo, j'aurai 3 vraies machines sur CloudLab avec de vraies
cartes réseau. C'est exactement le régime du papier : je pourrai générer beaucoup
de clients réels, saturer le serveur, et là **mesurer si le correctif récupère du
débit**. Visio avec Teo demain matin pour la prise en main.
Bonus : ça répond aussi à la remarque du rapport intermédiaire sur la dépendance à
l'architecture (ARM vs x86) — les machines CloudLab sont x86, donc je compare
directement avec mon ARM. »

---

## Diapo 9 — Plan et calendrier

**[À montrer]** Mini-frise.

**[À dire]**
« - **Demain (mar.) :** visio Teo, prise en main CloudLab.
- **Week-end / début de semaine :** monter WireGuard sur CloudLab, baseline réelle
  stock vs corrigé sous saturation.
- **D'ici le 5 juin (midi) :** rapport final (6 pages) avec les chiffres CloudLab
  comme preuve principale de débit, et les mesures M1 comme preuve du mécanisme.
- **Soutenance :** 10 juin, 16 h–16 h 30, salle F117.
Questions sur lesquelles j'aimerais votre avis aujourd'hui : voir diapo suivante. »

---

## Diapo 10 — Questions pour André et Alain

**[À montrer / demander]**
1. Le diff vous convient-il en l'état (gestion du STUB, lecture relâchée) ?
2. La limite résiduelle (fenêtre de timing) : à traiter dans le rapport, ou hors
   périmètre pour le 5 juin ?
3. CloudLab : combien de clients / quelle config NIC viser pour reproduire la
   saturation du papier ? Faut-il aussi porter le « fix du papier » (workqueue
   dédiée) pour comparer les trois configs ?
4. Périmètre du rapport : si CloudLab donne des chiffres de débit à temps, ils
   passent en résultat principal ; sinon, est-ce que les preuves de mécanisme +
   latence suffisent pour le 5 juin ?

---

## Aide-mémoire — chiffres clés à avoir en tête

- Suppression des réveils GRO : **−14 à −20 %** (8–32 pairs), tendance ↑ avec les pairs.
- Réveils gaspillés : **−22 à −24 %**.
- Latence de queue à 64 pairs : **~82 ms → ~43 ms (~−47 %)**, moyenne inchangée.
- Débit : **plat** (pas de saturation en boucle locale — attendu).
- 1 pair : aucun effet → validation de correction (pas de plantage, pas de retransmission).
- Source des détails : `admin/EXPERIMENTS_2026-05-28.md`.
