# Comment expliquer le diagramme (script de présentation)

Ce document est le **texte à dire** en montrant `diagrams/diagramme.svg`. Il suit l'ordre
visuel du schéma, du haut vers le bas. À chaque étape : ce que je **montre** du doigt, ce
que je **dis**, et — entre crochets — la **ligne de code** à citer si on me la demande.

Le fil rouge de toute l'explication, à annoncer dès le début :

> « Un paquet entrant traverse **trois moteurs** du noyau, dans cet ordre : la **NAPI** de
> la carte réseau, puis une **workqueue** qui déchiffre en parallèle, puis une **deuxième
> NAPI** — celle de WireGuard — qui remet dans l'ordre et fait le GRO. Le bug que j'étudie
> est un problème de cadencement **entre la workqueue et cette deuxième NAPI**. »

---

## 0. D'abord, apprendre à lire le schéma (30 secondes)

Avant de raconter le trajet, j'explique la grammaire du dessin :

- **Les bandes de couleur = des contextes d'exécution différents.** C'est *le* point. Gris
  en haut = le matériel. **Bleu = un premier softirq** (la NAPI de la carte). **Rouge = une
  workqueue** (des threads noyau qui déchiffrent). **Vert = un second softirq** (la NAPI de
  WireGuard). Jaune = les structures de données partagées. Gris en bas = l'application.
- **Les flèches épaisses = un changement de contexte asynchrone.** Quand j'en franchis une,
  je dis : *« ici, on ne continue pas le même fil d'exécution : on dépose du travail, et
  quelqu'un d'autre le reprendra plus tard. »* Il y en a exactement **trois** — ce sont les
  charnières de toute l'histoire.
- **Les flèches pleines fines = des appels de fonction normaux**, dans le même contexte.
- **Les flèches en pointillé = on touche une donnée** (on écrit ou on lit une file), pas un
  appel.
- **Le rectangle à bord rouge ★ = le bug.** Les **hexagones = les deux moments GRO.**

> Phrase à dire : *« Si vous ne reteniez qu'une chose du dessin : chaque fois qu'on
> change de bande de couleur par une flèche épaisse, on a changé de "monde" d'exécution. Il
> y a trois changements, et le bug est sur le troisième. »*

---

## 1. Bande grise du haut — le paquet arrive (matériel)

**Je montre** le nœud du haut (`NIC reçoit un datagramme UDP chiffré`).

**Je dis :** « Tout part d'ici. Un paquet WireGuard, sur le réseau, c'est un simple
datagramme **UDP**, et son contenu est **chiffré**. La carte réseau le reçoit et lève une
**interruption matérielle** pour prévenir le processeur. »

**La 1ʳᵉ flèche épaisse** (vers la bande bleue) : « Règle d'or du noyau : une interruption
doit être *ultra-brève*. Donc la carte ne traite pas le paquet tout de suite ; elle note
"j'ai du courrier" et le vrai travail est repoussé juste après, dans un **softirq** — c'est
la bande bleue. »

---

## 2. Bande bleue — première NAPI : celle de la carte réseau

**Je montre** `poll() du pilote NIC`, puis l'hexagone `GRO #1`.

**Je dis :** « Dans ce softirq tourne la **NAPI de la carte** : au lieu de réagir paquet par
paquet, elle en ramasse plusieurs d'un coup. Et à la fin, elle peut faire du **GRO** — coller
les paquets d'une même connexion en un gros, pour ne traverser la pile qu'une fois. »

**Point d'honnêteté à souligner (l'hexagone est marqué *conditionnel*) :** « Ici j'ai
vérifié dans le code source : pour le trafic WireGuard, ce premier GRO **n'est pas
garanti**. WireGuard n'inscrit pas son socket pour le GRO UDP, donc l'agrégation de l'UDP
chiffré n'a lieu que si la carte a des options précises activées. C'est pour ça que je l'ai
dessiné en *conditionnel*. » [`udp_gro_receive`, `udp_offload.c:785`, branche `:800-815`]

**Je descends** par `encap_rcv → wg_receive`, `wg_packet_receive`, `wg_packet_consume_data`.

**Je dis :** « La pile UDP livre alors le paquet à WireGuard, parce que WireGuard s'est
branché sur le socket UDP via un crochet `encap_rcv`. On arrive dans le code de WireGuard
proprement dit : `wg_packet_receive` regarde le type — ici un paquet de **données** — et
appelle `wg_packet_consume_data`. » [`socket.c:355-356` → `:316` ; `receive.c:542`, `:574`,
`:509`]

---

## 3. Le nœud-clé `enqueue_per_device_and_peer` — deux flèches, deux mondes

**Je montre** `wg_queue_enqueue_per_device_and_peer`, puis ses **deux** flèches en pointillé
vers les cylindres jaunes, et la flèche épaisse vers la workqueue.

**Je dis, lentement, parce que c'est le cœur de l'architecture :** « Ce seul nœud fait
**deux choses sur le même paquet**, et c'est ça qu'il faut voir :

1. **Pour l'ordre** — il range le paquet dans la file du pair, `rx_queue` (cylindre jaune),
   dans l'ordre d'arrivée, marqué "pas encore déchiffré". *(Phase 1.)* [`queueing.h:162`,
   état `UNCRYPTED` `:158`]
2. **Pour le parallélisme** — il pousse *le même paquet* dans un ring global, et appelle
   `queue_work_on(cpu)` : il **dépose le déchiffrement sur un CPU**, choisi à tour de rôle.
   *(Phase 2 — la flèche épaisse.)* [`queueing.h:168-171`]

Donc le même paquet est **à la fois** dans une file qui se souvient de l'ordre **et** confié
à un worker qui peut tourner sur **n'importe quel CPU**. Retenez cette dualité : *ordre d'un
côté, parallélisme de l'autre.* C'est de là que viendra le bug. »

---

## 4. Bande rouge — la workqueue : déchiffrement en parallèle

**Je montre** le cylindre `packet_crypt_wq`, puis `wg_packet_decrypt_worker` → `decrypt_packet`.

**Je dis :** « On a changé de monde (flèche épaisse) : on n'est plus dans un softirq mais
dans une **workqueue**, c'est-à-dire de vrais **threads noyau** qui, eux, ont le droit de
prendre leur temps. Pourquoi ? Parce que **déchiffrer** (ChaCha20-Poly1305) est lourd, et
qu'on n'a pas le droit de faire des choses longues dans un softirq. Et surtout : cette
workqueue est **par-CPU**, donc **plusieurs cœurs déchiffrent en même temps**. »
[`device.c:346` ; worker `receive.c:493`, `decrypt_packet :501`]

**Je pointe** la flèche pointillée du worker qui **réécrit l'état** dans `rx_queue`.

**Je dis :** « Quand un worker a fini, il marque, dans la file ordonnée, que *ce* paquet est
maintenant "déchiffré". Mais — c'est crucial — comme plusieurs cœurs travaillent en
parallèle, ils **ne finissent pas dans l'ordre** : le cœur qui traite le paquet n°5 peut
finir avant celui qui traite le n°2. » [`enqueue_per_peer_rx`, `queueing.h:188`]

---

## 5. Le rectangle rouge ★ — le site du bug, et la 3ᵉ charnière

**Je montre** le nœud `★ napi_schedule(&peer->napi)`.

**Je dis :** « Et juste après avoir déchiffré **chaque** paquet, le worker fait
`napi_schedule` : il **réveille la deuxième NAPI**, celle de WireGuard, pour qu'elle aille
livrer. Le problème est **là**, et il est tout bête : ce réveil est **inconditionnel** — on
réveille après *chaque* paquet, **sans vérifier** si ça sert à quelque chose. »
[`queueing.h:196`]

**Je franchis la 3ᵉ flèche épaisse** vers la bande verte : « `napi_schedule` ne fait
d'ailleurs pas le travail lui-même : il met la NAPI dans une liste et **lève un softirq** —
encore un changement de monde. » [`dev.c:4984`, `:4990`]

---

## 6. Bande verte — deuxième NAPI : celle de WireGuard, sur l'interface virtuelle

**Je montre** `net_rx_action → poll()`, puis `wg_packet_rx_poll`.

**Je dis :** « On retombe dans un softirq, mais une **deuxième NAPI**, complètement
distincte de celle de la carte. Celle-ci, WireGuard l'a **fabriquée lui-même**, une **par
pair**, et l'a accrochée à une **interface réseau virtuelle**, `wg0` — un faux périphérique,
sans matériel, juste pour pouvoir refaire du GRO sur les paquets déchiffrés. »
[`peer.c:57` ; `wg_packet_rx_poll receive.c:438`]

**Je pointe** la flèche pointillée de `rx_poll` qui **lit la tête** de `rx_queue`, **et** la
boucle rouge en pointillé sur lui-même.

**Je dis — la chute :** « Et voici pourquoi le réveil inconditionnel pose problème. Quand
`rx_poll` se réveille, il regarde la **tête** de la file ordonnée. S'il doit livrer dans
l'ordre, il ne peut pas livrer le n°3 tant que le n°2 n'est pas prêt. Donc s'il a été
réveillé par un worker qui a fini un paquet "plus loin" alors que la **tête** n'est pas
encore déchiffrée, il **repart sans rien faire** : zéro paquet livré, un passage de softirq
**gâché**. C'est ça, l'**inversion d'ordre d'exécution** : on déchiffre dans le désordre, on
réveille à chaque fois, et la plupart des réveils tombent à vide. » [`receive.c:451-453`]

**Je pointe** l'hexagone `GRO #2` puis la sortie vers l'application.

**Je dis :** « Quand la tête *est* prête, là `rx_poll` livre les paquets et fait le **GRO
#2** — le vrai, celui que WireGuard fait explicitement — avant de pousser vers la pile IP de
la machine, jusqu'à l'application. Et le réveil gâché a un second coût : en réveillant trop
tôt, trop souvent, on **prive ce GRO de ses lots**, donc on perd aussi l'efficacité du
regroupement. » [`receive.c:411`, livraison `:375`]

---

## 7. La conclusion en pointant les deux bandes NAPI

**Je montre** d'un geste la bande bleue (haut) puis la bande verte (bas).

**Je dis :** « Regardez : **la même mécanique NAPI apparaît deux fois** — en haut la carte,
en bas WireGuard — et **la workqueue est le pont entre les deux**. Le bug n'est pas dans une
boîte isolée : il est sur la **jointure** entre la workqueue et la deuxième NAPI. On
déchiffre en parallèle (bon pour le débit), mais on **signale** ce parallélisme à une étape
qui, elle, doit rester **ordonnée** — et on le signale mal. »

**Le correctif, en une phrase, en repointant le rectangle rouge :** « La correction
d'André tient en une ligne d'idée : **avant** de réveiller, **lire la tête de la file** ; ne
réveiller **que si** la tête est effectivement déchiffrée. Sinon, ne rien faire — ce sera au
worker qui complétera la tête de réveiller. On supprime les réveils à vide, et le GRO
retrouve ses lots. »

---

## 8. Si on me pose une question (réponses de poche)

- **« Pourquoi deux NAPI / deux GRO ? »** Parce qu'il y a deux niveaux de paquets :
  l'**enveloppe UDP chiffrée** (côté carte, GRO #1) et la **lettre interne déchiffrée**
  (côté `wg0`, GRO #2). WireGuard ne fait explicitement que le second.
- **« C'est quoi `wg0` exactement ? »** Une interface réseau **virtuelle**, logicielle, sans
  carte ; elle porte l'adresse du tunnel et héberge la NAPI par pair.
- **« Pourquoi une workqueue et pas tout dans le softirq ? »** Parce qu'on n'a pas le droit
  de faire du travail long (déchiffrer) dans un softirq ; la workqueue, ce sont de vrais
  threads qui le peuvent, et en plus en parallèle par-CPU.
- **« Pourquoi le bug grandit-il avec le nombre de pairs ? »** Chaque pair a sa **propre**
  file et sa **propre** NAPI, mais tous partagent **la même** workqueue par-CPU. Plus il y a
  de pairs, plus les workers entrelacent des paquets de pairs différents, plus les
  complétions sont désordonnées, plus de réveils gâchés.
- **« Le bug se voit-il à 1 pair ? »** Non. À 1 pair, peu de désordre. C'est un problème de
  **charge serveur multi-pairs** — exactement le cas du papier (1000 clients).
- **« Comment tu le prouves à l'exécution ? »** En traçant `wg_packet_rx_poll` : le bug, ce
  sont les retours à **`work_done = 0`** ; le correctif doit les faire fondre. (Recettes
  bpftrace dans `PIPELINE_COMPLET_RECEPTION_WG_FR.md`, §5.)

---

*Figure : `diagrams/diagramme.svg`. Détails et preuves complètes :
`admin/PIPELINE_COMPLET_RECEPTION_WG_FR.md`. Spécification du dessin :
`admin/DIAGRAMME_PIPELINE_SPEC_FR.md`.*
