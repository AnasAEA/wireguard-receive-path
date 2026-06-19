# Notes orateur — présentation du sujet (script détaillé)

Script de parole pour `SLIDES_SUJET_FR.md` (et son PDF). Une section par diapo, dans l'ordre.
Pour chaque diapo : la **durée visée**, le **texte à dire** (presque mot pour mot), la
**transition** vers la suivante, et — quand utile — les **réponses de poche** aux questions.

**Budget total ≈ 22 min de contenu → viser 15–18 min en parlant.** Priorité si on coupe le
temps : diapos **4, 9, 10, 11** (carte → assemblage → bug → correctif).

---

## Définitions express — les mots qui apparaissent sur les schémas

*(à relire avant de présenter ; à ressortir si quelqu'un bloque sur un terme)*

**Réseau / paquets**

- **paquet (`skb`)** : un morceau de données qui circule sur le réseau ; dans le noyau,
  représenté par une structure appelée `sk_buff`.
- **chiffré / déchiffré** : un paquet WireGuard arrive *chiffré* (illisible) ; le *déchiffrer*
  (calcul **ChaCha20-Poly1305**) le rend lisible.
- **UDP** : une façon simple et rapide d'envoyer des paquets ; les paquets WireGuard voyagent
  *dans* de l'UDP.

**Contextes d'exécution** (où tourne le code — important pour tout l'exposé)

- **interruption (IRQ)** : signal *matériel* qui force le CPU à tout lâcher pour traiter un
  évènement (« un paquet est arrivé »). Doit être **ultra-court**.
- **softirq** : la « moitié basse » du traitement réseau — du code exécuté *juste après* une
  interruption, **sans thread à lui**, **interdit de dormir**, doit rester court.
- **contexte processus** : l'inverse — du code qui tourne dans un *vrai thread*, peut prendre
  son temps, être mis en pause, **dormir**.
- **thread / kthread** : un fil d'exécution ordonnancé par l'OS ; un *kthread* est un thread
  *du noyau* (ex. `kworker`, `ksoftirqd`).

**NAPI**

- **NAPI** : le mécanisme « sonner une fois, puis relever la boîte par lots ». C'est une
  *fiche (structure) + une fonction `poll`*, **pas** un programme qui tourne.
- **`poll()`** : la fonction de relève d'une NAPI ; chez WireGuard, c'est `wg_packet_rx_poll`.
- **budget** : nombre max de paquets traités en un passage de `poll` (= 64).
- **`napi_schedule`** : « réveiller la NAPI » = la cocher « à faire » + lever le softirq
  (n'exécute *rien* tout de suite).
- **`napi_complete_done`** : « j'ai fini » = vider le GRO, se retirer, réactiver l'interruption.
- **`net_rx_action`** : le gestionnaire du softirq réseau qui appelle les `poll()`.
- **NAPI de WireGuard** : une NAPI *logicielle*, **une par pair**, sur `wg0` — voir l'encart
  dédié (Diapo 6).

**Workqueue**

- **workqueue** : une file de *travaux différés*, exécutés *plus tard* par des **threads
  noyau** (workers), en **contexte processus** (donc qui peuvent prendre leur temps / dormir).
- **worker / `kworker`** : le thread noyau qui exécute le travail posé dans une workqueue.
- **`queue_work_on(cpu, …)`** : « pose ce travail sur tel cœur » ; un worker de ce cœur
  l'exécutera.
- **par-CPU** : **un worker par cœur** → le travail s'exécute *en parallèle* sur plusieurs
  cœurs.

**GRO**

- **GRO** : regrouper plusieurs paquets d'un *même flux* en un seul gros, pour ne traverser la
  pile **qu'une fois**.
- **GRO #1 / #2** : #1 sur l'UDP *externe chiffré* (côté carte, **conditionnel**) ; #2 sur les
  paquets *internes déchiffrés* (côté `wg0`, fait **explicitement** par WireGuard).

**Pair / WireGuard**

- **pair (*peer*)** : l'autre bout d'un tunnel, identifié par sa **clé publique**.
- **`wg0`** : l'interface réseau **virtuelle** (logicielle) créée par WireGuard ; elle porte
  l'adresse du tunnel.
- **clé publique** : l'identité cryptographique d'un pair (≠ son adresse IP).
- **allowed-ips** : les plages d'IP qu'un pair a le droit d'utiliser (routage par clé).
- **keypairs** : les clés de session (chiffrement) de la relation avec un pair.

**File et bug**

- **`rx_queue`** : la file de réception **ordonnée** d'un pair (mémorise l'ordre de livraison).
- **MPSC (file de Vyukov)** : « multi-producteurs, **un seul consommateur** » — plusieurs
  acteurs y déposent, un seul (le `poll`) en retire ; c'est ce qui rend le correctif **sûr**.
- **`UNCRYPTED` / `CRYPTED`** : l'état d'un paquet dans la file (pas encore déchiffré /
  déchiffré).
- **`work_done`** : nombre de paquets réellement *livrés* à un passage de `poll` ;
  **`work_done = 0`** = passage **gâché** = la signature du bug.
- **EoI (inversion d'ordre d'exécution)** : le bug — on réveille la NAPI alors que la *tête*
  de file n'est pas prête.

---

## Diapo 1 — Titre  *(≈30 s)*

« Bonjour, je m'appelle Anas Ait El Hadj, je présente mon stage à l'Inria, dans l'équipe
KrakOS, encadré par Alain Tchana et André Freyssinet. Mon sujet porte sur le chemin par
lequel WireGuard — un VPN — **reçoit** les paquets, et plus précisément sur un problème de
cadencement interne qui apparaît quand un serveur a beaucoup de clients. Le titre annonce
trois verbes : comprendre, mesurer, corriger. Je n'entre pas tout de suite dans la
technique — on va d'abord poser le décor. »

- **À éviter :** lister le détail technique dès maintenant. Rester très haut niveau.
- **Transition →** « D'abord, de quoi on parle. »

---

## Diapo 2 — Le décor  *(≈1 min 15)*

« WireGuard, vous connaissez peut-être : c'est un VPN moderne, réputé pour sa simplicité et
sa rapidité, et il est directement intégré dans le noyau Linux. Un VPN, concrètement, ça
relie des machines par des **tunnels chiffrés**.

Pour un usage personnel — un client, un tunnel — aucun problème, c'est très rapide. Le
problème apparaît côté **serveur** : quand une seule machine doit gérer des centaines, voire
des milliers de clients en même temps. Et là, point important : ce n'est pas le **réseau**
qui sature, c'est le **CPU**. Le traitement, paquet par paquet, à la **réception**, peut
saturer un cœur — et le débit plafonne.

D'où la question de mon stage, en deux temps : **pourquoi** ça plafonne précisément sur ce
chemin de réception, et **comment** faire mieux. »

- **À marteler :** le goulot est le coût CPU **par paquet** à la réception, pas la bande passante.
- **Transition →** « Pour répondre, j'ai un point de départ : un article récent. »

---

## Diapo 3 — Ce qui motive  *(≈1 min 15)*

« Mon point de départ, c'est un article de 2025, publié à SYSTOR, de Mounah et ses
co-auteurs. Leur idée : dans le chemin de réception de WireGuard, **déplacer** une étape
précise — le GRO, je l'expliquerai — depuis l'endroit où elle se fait aujourd'hui vers une
"workqueue". Le résultat : jusqu'à **4,7 fois** plus de débit sur un serveur multi-clients.
C'est énorme, et ça montre que l'enjeu est réel.

Mon angle à moi n'est pas de **répéter** l'article. C'est : (1) vraiment **maîtriser** ce
mécanisme de réception — NAPI, workqueue, GRO — et le **prouver par le code**, pas juste
l'affirmer ; (2) le **mesurer** moi-même ; (3) étudier un **bug connexe** à ce chemin —
l'inversion d'ordre d'exécution, ou EoI — et son correctif. »

- **Si on demande le lien io_uring :** le stage part de l'optimisation du chemin réseau
  noyau ; l'analyse WireGuard en est l'application concrète.
- **Transition →** « Avant tout ça, il faut une carte mentale du trajet d'un paquet. »

---

## Diapo 4 — La carte (teaser)  *(≈1 min — ne pas survoler trop vite)*

« Voici la carte. Je vous demande, pour l'instant, de **ne pas** la lire en détail — retenez
juste une chose : quand un paquet chiffré arrive, il traverse **trois grands moteurs**, dans
cet ordre. Un : la **NAPI de la carte réseau**, qui le reçoit. Deux : une **workqueue**, qui
le déchiffre. Trois : une **deuxième NAPI**, celle de WireGuard, qui le remet en ordre et
fait le GRO. Et le point clé : ces trois moteurs tournent dans trois **contextes
d'exécution** différents — j'expliquerai ce que ça veut dire. On va décortiquer chaque brique
une par une, puis on reviendra **exactement** sur cette carte. »

- **But de la diapo :** donner une destination, pour que les 4 briques aient un sens.
- **Transition →** « Première brique, la plus simple : de qui parle-t-on ? »

---

## Diapo 5 — Brique 1 : le « pair »  *(≈1 min 30)*

« Première brique : le "pair". WireGuard est un VPN, donc la première question, c'est : avec
qui je parle ? Chaque correspondant à l'autre bout d'un tunnel s'appelle un **pair**.

Pensez à une **fiche par correspondant**. Sur la fiche : son identité — et son identité,
c'est sa **clé publique**, pas son adresse IP, parce que l'adresse peut changer s'il passe du
Wi-Fi à la 4G.

Le point essentiel pour la suite est double. D'abord, une seule interface — `wg0` — peut
porter **beaucoup** de pairs : dans l'article, **mille**. Ensuite, regardez le schéma :
chaque pair a **SA** propre file d'attente et **SA** propre boîte aux lettres — sa NAPI. Mais
tout en bas, il n'y a qu'**UN SEUL** atelier de déchiffrement, **partagé** par tous.

Retenez ce contraste — chacun sa file, mais un seul atelier — parce que c'est exactement ce
qui expliquera pourquoi le bug **grandit avec le nombre de pairs**. »

- **Transition →** « Cette "boîte aux lettres" que chaque pair possède, c'est quoi au juste ?
  C'est la NAPI. »

---

## Diapo 6 — Brique 2 : NAPI  *(≈2 min — brique centrale, prendre son temps)*

« Deuxième brique : NAPI. Je l'explique avec une analogie.

Une carte réseau qui reçoit un paquet prévient normalement le processeur par une
**interruption** — imaginez un facteur qui sonne à votre porte à **chaque** lettre. Pour deux
lettres par jour, ça va. Mais à un **million** de paquets par seconde, le CPU passe sa vie à
courir ouvrir la porte : il s'effondre. C'est la "tempête d'interruptions".

L'idée de NAPI : on sonne **une fois**, puis on **coupe** la sonnette, et on dit "j'irai
relever la boîte moi-même, par paquets".

Le cycle, c'est le schéma : ① la sonnette sonne une fois ; ② on coche "à faire" et on lève un
drapeau — et j'insiste : à cet instant **rien ne s'exécute encore**, "réveiller la NAPI"
c'est juste cocher une case ; ③ un peu plus tard, on relève la boîte, c'est-à-dire qu'on
appelle la fonction `poll()` ; ④ `poll()` ramasse jusqu'à **64** paquets — ce quota s'appelle
le **budget** ; ⑤ boîte vide, on dit "j'ai fini, rendors-moi" et on réactive la sonnette.

La phrase à retenir, en bas : **NAPI n'est pas un programme qui tourne — c'est une fiche +
une fonction.** Et cette fonction tourne dans un **"softirq"**. Et là, je **définis le mot
tout de suite**, parce qu'il va revenir : un *softirq*, c'est **le moment où on relève
réellement la boîte aux lettres — juste après que la sonnette a sonné**. Ce n'est pas un
employé dédié : c'est du temps pris "sur le pouce", et on n'a **pas le droit d'y traîner**,
ni de s'y endormir. Retenez juste ça pour l'instant. »

**Et la « NAPI de WireGuard », alors ? — à enchaîner, c'est important pour la suite :**

« Tout ce que je viens de décrire, c'est la NAPI **normale**, celle d'une *vraie carte
réseau*. Mais WireGuard fait quelque chose de malin : il **fabrique sa propre NAPI**, **une
par pair**, qui n'est reliée à **aucune carte matérielle**. Il l'accroche à l'interface
**virtuelle `wg0`** — un *faux* périphérique réseau, purement logiciel. Et au lieu d'être
réveillée par une *interruption de carte*, elle est réveillée **"à la main"** par les workers
de déchiffrement — c'est le fameux `napi_schedule`. À quoi sert-elle ? **Uniquement** à
refaire du **GRO** sur les paquets *déchiffrés* et à les livrer *dans l'ordre*.

Donc, dans tout l'exposé, il y a **deux NAPI** :

- la **NAPI #1** = celle de la *vraie carte* (matérielle, réveillée par une interruption) ;
- la **NAPI #2** = celle de *WireGuard* (logicielle, une *par pair*, sur `wg0`, réveillée *à
  la main*).

**Et le bug est sur la NAPI #2.** »

- **Si on demande « pourquoi fabriquer une fausse NAPI ? » :** parce que GRO ne sait
  fonctionner *que* dans une NAPI ; après déchiffrement, les paquets n'arrivent plus d'une
  carte, donc WireGuard simule une NAPI pour pouvoir quand même les regrouper.
- **Rappel (le mot "softirq" est défini ci-dessus, à l'oral) :** définition complète dans le
  glossaire en tête de document si besoin d'aller plus loin.
- **Transition →** « Justement : pourquoi tout ne se fait pas dans ce poll ? Parce que
  certaines tâches sont trop longues. D'où la workqueue. »

---

## Diapo 7 — Brique 3 : la workqueue  *(≈2 min 30 — ici on plante LA cause du bug)*

**D'abord : c'est quoi une workqueue, exactement ?**

« Troisième brique : la workqueue. Définissons-la clairement, parce que c'est central. Une
workqueue, c'est un mécanisme du noyau pour **différer un travail** : au lieu de faire un
calcul *tout de suite*, on le **dépose dans une file**, et un **thread du noyau** — qu'on
appelle un *worker*, et qu'on voit dans le système sous le nom `kworker` — viendra
l'exécuter **plus tard**. Le point essentiel : ce worker tourne en **contexte processus**,
c'est-à-dire comme un *vrai thread* ordonnancé par le système — il a le droit de **prendre
son temps**, d'être mis en pause, et même de *dormir*. »

**Pourquoi WireGuard en a besoin ici :**

« Rappelez-vous le softirq de la brique précédente : c'est un créneau *emprunté*, court, où
l'on **n'a pas le droit de faire du travail long** ni de "faire une pause". Or **déchiffrer**
un paquet — le calcul cryptographique ChaCha20-Poly1305 — est **lourd**. Le faire dans le
softirq bloquerait tout le reste. Donc WireGuard **délègue** ce déchiffrement à une
workqueue. »

**L'analogie (à dire) :**

« Le softirq, c'est l'**accueil** d'une entreprise : on ne peut pas y garder un visiteur
vingt minutes, ça bloque la file. La workqueue, c'est le **bureau à l'arrière**, avec de
*vrais employés* — les workers — qui, eux, ont le temps. "Poser le travail", dans le code,
ça s'appelle `queue_work_on` : en clair, *« toi, l'employé de ce cœur-là, occupe-toi de
déchiffrer ce paquet »*. »

**Le détail décisif (la graine du bug) :**

« WireGuard met **un worker PAR CŒUR** du processeur. Donc plusieurs paquets se déchiffrent
**EN MÊME TEMPS**, sur plusieurs cœurs. C'est rapide — mais, et c'est **la graine du bug**,
retenez ce mot : ils finissent **DANS LE DÉSORDRE**. Le cœur qui traite le paquet n°5 peut
finir avant celui qui traite le n°2. Une fois fini, chaque worker "sonne" la NAPI du pair —
c'est le `napi_schedule` de tout à l'heure. »

- **Définition à retenir :** workqueue = *travail différé*, exécuté par des *threads noyau*
  (workers / `kworker`) en *contexte processus* (donc qui peuvent prendre leur temps / dormir).
- **La différence-clé à savoir dire :** softirq = court, *interdit de dormir* ; workqueue =
  *vrai thread*, peut prendre son temps. C'est *pour ça* qu'on y met le déchiffrement.
- **Piège à éviter :** ne pas dire "plusieurs workqueues". C'est **une** workqueue, avec un
  **worker** par cœur (cf. Annexe A si on me pose la question).
- **Transition →** « Dernière brique avant d'assembler : l'optimisation qu'on cherche
  justement à préserver — le GRO. »

---

## Diapo 8 — Brique 4 : GRO  *(≈2 min)*

« Quatrième brique : GRO. Le problème qu'il résout : faire monter un paquet à travers toutes
les couches du système a un **coût fixe**, payé **à chaque paquet**, peu importe sa taille.
Avec des millions de petits paquets, on paie ce "péage" des millions de fois — et c'est ça,
le goulot.

L'analogie : vous avez 40 enveloppes à monter au 10ᵉ étage. Soit vous faites **40** voyages
dans l'escalier, soit vous **agrafez** les 40 en un seul gros colis et vous montez **une
fois**. GRO, c'est la deuxième option : on regroupe les paquets d'un **même flux** en un seul
gros, et on ne traverse la pile qu'une fois.

Sur le schéma : 4 paquets, on les agrafe, ça fait un colis, et quand la NAPI a fini son
passage, on pousse le colis vers le haut.

Détail important pour WireGuard — et c'est une question qu'on m'a posée : il y a **DEUX**
moments GRO. Un sur l'enveloppe **externe chiffrée**, côté carte, qui est **conditionnel** et
que WireGuard **n'active pas** lui-même ; et un sur la lettre **interne déchiffrée**, côté
`wg0`, celui-là **explicitement** fait par WireGuard. C'est ce deuxième qui nous concerne. »

- **Transition →** « On a les quatre briques. Remettons-les ensemble. »

---

## Diapo 9 — On assemble  *(≈2 min — pointer chaque bloc en parlant)*

« On réassemble — et maintenant, vous pouvez **lire** la carte. Je suis le trajet :
① à gauche, la NAPI de la carte, avec le GRO n°1 (conditionnel) ;
② WireGuard reçoit le paquet et le met en file en **deux phases** : une file **ordonnée** par
pair d'un côté, et de l'autre il pose le déchiffrement sur un cœur ;
③ au milieu, en rouge, la workqueue par-CPU qui déchiffre **en parallèle** — donc dans le
désordre ;
④ la boîte rouge encadrée : le **réveil** de la NAPI, fait après **chaque** paquet,
**inconditionnellement** ;
⑤ la NAPI de WireGuard qui dépile **dans l'ordre** ;
⑥ et le GRO n°2 vers l'application.

Voilà la machine complète, et elle marche. La question, maintenant : **où est-ce que ça
coince ?** »

- **Note :** le schéma détaillé (avec toutes les lignes de code) est dans le rapport / le
  dossier de preuves ; ici on reste sur la version "6 blocs".
- **Transition →** « Exactement à la jointure entre la workqueue et la deuxième NAPI. »

---

## Diapo 10 — Le bug (EoI)  *(≈2 min 30 — LE CŒUR, ralentir)*

« C'est le cœur de mon exposé. Reprenons les deux ingrédients qu'on a posés.

**Un** : la workqueue déchiffre en parallèle, donc les paquets finissent **dans le désordre**
— ici, le cœur 2 a fini le paquet n°5 avant que le cœur 0 ait fini le n°2.

**Deux** : après **chaque** paquet déchiffré, on réveille la NAPI, **sans condition**.

Maintenant, que fait la NAPI quand elle se réveille ? Elle doit livrer **dans l'ordre**, donc
elle regarde la **tête** de la file. Et la tête, c'est le paquet n°2… qui n'est pas encore
prêt. Donc elle **repart sans rien faire** : `work_done = 0`. C'est ça, l'inversion d'ordre
d'exécution.

Et il y a un **double coût**. Non seulement on a gâché un passage de softirq, mais en plus,
comme la NAPI s'est réveillée pour rien, le GRO n°2 n'a rien pu agrafer — il **perd ses gros
colis**. Donc le bug ne gâche pas que du CPU : il **casse aussi le regroupement**. À droite,
en vert, je montre déjà ce qu'on va changer. »

- **Phrase-choc (à dire telle quelle) :** « on réveille pour livrer, mais il n'y a rien à
  livrer. »
- **Transition →** « Et justement, le correctif tient en une idée. »

---

## Diapo 11 — Le correctif  *(≈1 min 30)*

« Le correctif, proposé dans l'équipe, tient en une **ligne d'idée** : avant de réveiller la
NAPI, on **lit le curseur de tête** de la file, et on ne réveille **QUE SI** cette tête est
déjà déchiffrée.

Si la tête n'est pas prête, on ne fait rien — et ce n'est pas grave : le worker qui finira
justement cette tête déclenchera le réveil à ce moment-là.

Pourquoi c'est **sûr** ? Parce que ce curseur de tête n'est écrit que par **un seul** acteur
— l'unique consommateur de la file ; c'est une file dite MPSC, un seul consommateur. Donc pas
de course de données. Au pire, dans un cas limite, on rate un réveil, mais il est rattrapé
juste après.

Résultat attendu : on **supprime les réveils à vide**, et le GRO **retrouve ses lots**. »

- **À éviter :** lire le code ligne à ligne. Pointer juste la condition « si la tête != UNCRYPTED ».
- **Transition →** « Voyons ce que, moi, j'ai effectivement fait et mesuré. »

---

## Diapo 12 — Ce que j'ai fait (mesures, M1/ARM)  *(≈2 min — assumer la limite)*

« Concrètement, voici mon travail. J'ai **reproduit** le mécanisme sur ma propre machine —
un Mac M1, sous Fedora Asahi — en configuration **multi-pairs**.

Ce que j'ai mesuré confirme l'analyse : la baisse d'efficacité du GRO **grandit avec le
nombre de pairs**. À un seul pair, on ne voit rien ; à 8, 16, 32 pairs, l'effet apparaît et
augmente. C'est exactement cohérent avec "le bug est par pair".

Pour mesurer **proprement**, j'ai construit un harnais : contrôle de la variance, métriques
**directes** — les compteurs de GRO, la distribution de `work_done` — et un balayage de
paramètres.

Et je tiens à être **honnête** sur la limite : ma boucle locale **ne sature pas** le débit,
je n'ai pas de vraie carte 25 gigabits. Donc je vois bien le **mécanisme**, mais pas le
**régime de débit** du papier. »

- **Si on demande des chiffres :** campagne du 28 mai — à 8 pairs ≈ −17 % de GRO, etc.
  (rapport). Rester prudent : haute variance sur M1 (cœurs P/E).
- **Transition →** « Et c'est précisément ce qui justifie l'étape suivante. »

---

## Diapo 13 — Validation x86 + la suite (CloudLab)  *(≈1 min 30)*

« Deux points pour finir sur le concret.

D'abord : est-ce que tout ça vaut pour l'architecture du papier — x86, noyau plus ancien —
alors que moi je suis sur ARM ? J'ai vérifié **fichier par fichier** : le site du bug, le
correctif, la file, la fonction de poll sont **identiques** entre les deux versions ; la
seule différence est un **drapeau de workqueue**, sans effet sur le comportement. Donc mon
analyse et le correctif se transfèrent tels quels.

Ensuite, la suite : j'ai obtenu un accès à **CloudLab** — des machines x86, avec une vraie
carte 25 gigabits, et de quoi monter jusqu'à **mille** pairs. C'est là que je pourrai tester
le **régime de débit**, et donc le **gain réel** du correctif, là où le papier mesure. »

- **Point fort :** la comparaison ARM↔x86 est faite et tracée (`COMPARAISON_CODE_VERSIONS_FR.md`).
- **Transition →** « En résumé. »

---

## Diapo 14 — Conclusion  *(≈1 min — finir net, regarder le jury)*

« Pour conclure, trois points.

**Un** : j'ai **compris** le mécanisme de réception de WireGuard — NAPI, workqueue, GRO — et
je l'ai **prouvé par le code**, ligne par ligne.

**Deux** : j'ai **localisé** le bug — un réveil inconditionnel — et le correctif est **simple
et sûr** : lire la tête avant de réveiller.

**Trois** : je l'ai **mesuré sur ARM**, et la validation sur x86, via CloudLab, est **en
cours**.

Merci de votre attention — je suis prêt pour vos questions. »

- **En réserve (annexes A–D) :** "1 workqueue / workers par-CPU" ; cycle de vie NAPI ; chaîne
  d'appel du Front #1 ; preuve bpftrace (bucket 0 de `work_done`) ; sûreté du correctif (file
  MPSC de Vyukov, un seul consommateur écrit `tail`).

---

# Réponses de poche (diapos d'annexe)

## Annexe A — « une seule workqueue » vs « par-CPU »

« Bonne question. Ce n'est pas contradictoire : il y a **un seul** objet workqueue,
`packet_crypt_wq`, alloué une fois pour l'interface. "Par-CPU" décrit les **workers** : il y
a un worker par cœur, et WireGuard garde un **work item** par CPU, qu'il soumet avec
`queue_work_on` sur un cœur **précis**. Donc "par-CPU" veut dire "les workers sont par cœur",
pas "il y a N workqueues". C'est exactement ce que montre le schéma de la brique 3 : une
boîte rouge, plusieurs employés. »

## Annexe B — cycle de vie NAPI (7 étapes)

« Le cycle de vie complet, c'est sept étapes : on **crée** la NAPI avec `netif_napi_add`, on
l'**active** avec `napi_enable`, on la **réveille** avec `napi_schedule`, sa fonction de poll
est `wg_packet_rx_poll`, elle se **termine** avec `napi_complete_done`, puis à la destruction
du pair on fait `napi_disable` et `netif_napi_del`. La structure elle-même **vit dans**
`struct wg_peer` — donc une par pair. Et "réveiller", je le rappelle, c'est juste cocher dans
une liste et lever le softirq, ça n'exécute rien. »

## Annexe C — Front #1 : chaîne d'appel (générique, hors WireGuard)

« Voici la chaîne d'appel complète du premier front, du poll de la carte jusqu'à
`udp_gro_receive` : `napi_gro_receive`, `gro_receive_skb`, `dev_gro_receive` — qui aiguille
par type Ethernet —, `inet_gro_receive` — qui aiguille par protocole IP —, puis
`udp4_gro_receive`, puis `udp_gro_receive`. **Tout** ça est dans le noyau générique :
WireGuard n'y apparaît **jamais**. Et la fusion de l'UDP externe est **conditionnelle** —
WireGuard n'active pas le GRO UDP, donc ce front ne coalesce que si la carte a certaines
options activées. C'est pour ça que je l'ai dessiné "conditionnel". »

## Annexe D — preuve à l'exécution (bpftrace)

« Pour le prouver à l'exécution, j'utilise bpftrace : je trace la **valeur de retour** de
`wg_packet_rx_poll` — c'est `work_done`, le nombre de paquets livrés à chaque passage. Un
**pic dans le bucket 0**, ce sont les passages où on n'a rien livré : la signature exacte du
bug. Et le correctif doit **faire fondre ce bucket 0** et déplacer la masse vers des valeurs
supérieures à 1 — c'est-à-dire de vrais lots, donc un GRO efficace. C'est une mesure
**directe** du mécanisme, et elle est **indépendante de la version** du noyau. »
