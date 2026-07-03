# Point d'avancement — CloudLab (màj 3 juillet)

> Pour Alain. Suite au point du 25 juin et à la note du 26. Depuis : la campagne
> sous-saturation (Phase A) est faite et analysée — résultat net —, et la Phase B
> (sensibilité au coût de déchiffrement) est prête et a tourné une première fois.
> Détail complet : `docs/cloudlab/RECEIVE_PATH_FINDINGS.md` et
> `docs/cloudlab/CLOUDLAB_PLAN_phase2.md`.

## Résumé en 30 secondes

1. **Phase A (sous-saturation, CPU + latence) : un null propre.** Le fix deux-côtés ne
   réduit pas le CPU mesurable sur c220g2, à aucune charge. La latence a une petite
   tendance favorable mais elle n'est pas défendable (bruit + états d'énergie du CPU).
2. **C'est cohérent avec le modèle de coût** : un poll gaspillé coûte ~1 µs, le
   déchiffrement ~5–6 µs sur ces Xeon — le travail économisé est réel mais sous le
   plancher de bruit de cette machine rapide.
3. **La suite logique est la Phase B** : ralentir artificiellement le déchiffrement
   (`wg_decrypt_delay_ns`) et chercher le seuil où le fix devient visible. Le script a
   été réécrit proprement (l'ancien s'effondrait à fort délai) et a tourné hier —
   incident bête de récupération de données, je le relance dès qu'un créneau CloudLab
   se libère (les clusters sont pleins ce matin).
4. **Une question de cadrage pour toi** (en bas) : le fix du papier (`gro_wq`) et la
   configuration combinée — toujours un livrable du 31 juillet, ou on recentre ?

## Le banc, exactement

- **Deux nœuds c220g2 identiques** (CloudLab Wisconsin), reliés en direct par le lien
  d'expérience 10 GbE (`enp6s0f0`, 192.168.1.1 côté `dut` / .2 côté `gen`) — séparé du
  réseau de contrôle. Chaque nœud : 2× Xeon E5-2660 v3 (2 sockets, 20 cœurs / 40
  threads), Ubuntu 22.04, noyau **5.15.0-177-generic**, BTF présent (bpftrace opérationnel).
- **`dut`** = le récepteur qu'on mesure ; **`gen`** = le générateur. Les 8 pairs sont 8
  namespaces réseau sur `gen`, chacun avec sa propre interface WireGuard et son propre
  port source UDP — c'est ce qui permet au hachage `sdfn` de la carte d'étaler les 8
  tunnels sur 8 files RX, donc 8 cœurs du `dut`.
- **Un seul binaire pour toutes les conditions** : `wireguard_trigger.ko`, compilé en
  clean-room depuis les sources 5.15 *vierges* du paquet Ubuntu + nos 5 fichiers
  modifiés. Les variantes sont des paramètres runtime
  (`/sys/module/wireguard/parameters/` : `wg_supp`, `wg_headwake`, `wg_trig_k`,
  `wg_decrypt_delay_ns`). Le A/B bascule un knob sur le *même module chargé* — jamais de
  recompilation ni de rechargement entre conditions, donc pas de différence cachée de
  build. La `srcversion` (`EA06EE82…`) est lue *après* l'insmod et écrite dans **chaque
  ligne** du CSV : chaque mesure porte la preuve du binaire qui l'a produite.
- Le bail CloudLab se réinitialise chaque jour ; chaque session repart d'une image
  vierge via `bootstrap_testbed.sh` (une commande : paquets, build du module, tunnel,
  8 pairs, vérification des handshakes). Le matériel étant la même classe c220g2 à
  chaque instanciation, les résultats se recoupent d'une instanciation à l'autre — le
  gain sdfn ×2,2, par exemple, a été revérifié sur trois instanciations différentes.

## Phase A — ce que j'ai mesuré et ce que ça donne

Le protocole qu'on avait convenu : en dessous de la saturation, là où le fix a de la
marge pour aider. Un pair réservé à la latence (sockperf ping-pong, aucun trafic de
fond sur lui), les 7 autres portent une charge TCP plafonnée, hachage `sdfn` (étalé sur
8 cœurs). `off` contre `both` (le fix deux-côtés), charges cibles 0/2/4/6 Gb/s, 8
répétitions, ordre mélangé — 64 runs, tout dans
`data/cloudlab/subsat_20260701_0609.csv`.

**Le déroulé d'un run, concrètement.** Pour chaque triplet (charge, condition,
répétition), tiré dans un **ordre aléatoire global** pour décorréler toute dérive de la
machine : (1) le knob de condition est écrit sur le module chargé ; (2) `gen` lance la
charge de fond plafonnée (`iperf3 -b`, 4 flux TCP par pair, la cible répartie sur les
pairs 1..7) ; (3) deux secondes plus tard s'ouvre la fenêtre de mesure : un instantané
de `/proc/stat` (tous les cœurs), puis 30 s de sockperf ping-pong TCP depuis le pair 0
(~20–45 k échantillons de RTT → p50/p99/p99,9), puis le second instantané `/proc/stat`.
Le CPU est donc le **delta exact sur la fenêtre de latence**, en équivalents-cœurs, sur
trois métriques (softirq seul ; système+IRQ+softirq ; total non-idle). (4) À la fin,
le débit *réellement reçu* est agrégé depuis les JSON iperf3 (`sum_received`) avec les
retransmissions TCP ; un run dont la charge réelle dévie de plus de 40 % de la cible
est marqué REJECT. Un sidecar par campagne enregistre le placement complet :
`rx-flow-hash`, affinité des IRQ de la carte, gouverneur CPU, topologie NUMA — parce
que le premier résultat de cette étude était justement une affaire de placement.

Deux choix méthodo à noter : les cibles de charge sont *nominales* (le pacing iperf3
sous-atteint de ~20–30 %) — mais `off` et `both` à une même cible voient la même
génération, donc la même charge réelle, et c'est ça qui rend la comparaison valide ;
et **aucune sonde bpftrace ne tourne pendant les fenêtres de latence** (elle les
perturberait) — le taux de polls gaspillés est recoupé depuis la campagne dédiée
`measure_missed.sh`, déjà caractérisée (~27 % → ~14 %, stable de 8 à 64 pairs).

**L'équité de la comparaison est propre** : la charge réelle `off` vs `both` diffère
d'au plus 3,4 % (≈1 % à 4 et 6 Gb/s). Donc `both` ne bride pas le débit, et on compare
bien la même chose.

**CPU : rien, proprement.** Sur les trois mesures (softirq seul, système+IRQ, total
occupé, en équivalents-cœurs) les écarts vont de −4,7 % à +1,6 % selon la charge, sans
direction cohérente, p≈0,4–1,0. Le fix n'économise pas de CPU mesurable en
sous-saturation sur cette machine.

**Latence : tendance favorable mais pas défendable.** `both` est ~7–8 % plus bas en p99
à 2 et 4 Gb/s, mais les intervalles se recouvrent largement (p≈0,37–0,71). Et surtout
la queue est *la pire à la charge non nulle la plus basse* (~1,5 ms à 1,1 Gb/s réel,
mieux à 3,1 Gb/s) — c'est l'inverse de ce que ferait une file d'attente, et la
signature classique des états d'énergie du CPU (gouverneur `schedutil`, C-states). Donc
je ne revendique rien sur la latence.

**Verdict : un null propre, pas un échec de mesure.** C'est le résultat « le travail
économisé est réel mais invisible ici », pas « on n'a pas su mesurer ». Ça correspond
exactement au modèle de coût qu'on a construit : ~1 µs de poll contre une queue de
latence en millisecondes dominée par les états d'énergie.

## Pourquoi je fais confiance à ces résultats

Le danger qu'on avait identifié dans le plan, c'est le **null ambigu** (« on a enlevé
les polls mais rien ne bouge » — sans savoir si c'est le fix, la mesure, ou le bruit).
Le harnais a été conçu pour lever chaque ambiguïté, et chaque garde-fou a été vérifié :

1. **Le fix agit vraiment.** Ce n'est pas supposé : les compteurs in-module le
   prouvent causalement. `supp_cleared` vaut **exactement 0 fix éteint** et ~720–800 k
   fix allumé (96 % de ses cas cibles), pendant que le classificateur indépendant du
   fix reste constant. Et l'effet agrégé est là : ~27 % → ~14 % de polls gaspillés,
   reproduit à 8/16/32/64 pairs et sur plusieurs instanciations.
2. **La comparaison est équitable, run par run.** Charge réelle vérifiée à chaque run
   (pas de « both plus lent donc moins de CPU » caché) : écarts ≤3,4 %.
3. **Le même binaire, prouvé.** `srcversion` dans chaque ligne de CSV ; A/B par knob
   runtime sans rechargement.
4. **Les biais temporels sont cassés** : ordre (charge × condition × rep) entièrement
   randomisé, warm-up avant la boucle — précisément parce qu'on s'est déjà fait avoir
   (le bug du démarrage à froid qui donnait `polls=1` sur la première condition a été
   trouvé, compris et corrigé le 26 juin).
5. **Trois métriques CPU indépendantes** concordent sur le null (softirq seul,
   système+IRQ, total occupé) — le coût ne se cache pas dans une couche non mesurée.
6. **La puissance statistique est honnête** : 8 répétitions, médianes + IQR ; le
   Mann-Whitney est un appui, pas la preuve — la preuve du null, c'est des effets
   minuscules **aux signes mélangés** (−4,7 %…+1,6 %, aucune monotonie), très en
   dessous de la dispersion run-à-run.
7. **Le confound latence est identifié, pas ignoré** : la queue est la pire à la
   charge non nulle la plus basse — l'inverse d'un effet de file d'attente, la
   signature des C-states sous `schedutil` (enregistré dans le sidecar de placement).
   C'est exactement pourquoi je ne revendique pas les 7 % : je sais *à quoi* ils
   peuvent être dus, et le re-test qui trancherait (gouverneur `performance`, sonde
   isolée) est déjà spécifié.
8. **Ce qu'on ne peut pas comparer n'est pas comparé** : en Phase B la sonde bpftrace
   tourne dans la fenêtre (il faut compter les polls) — c'est équitable off-vs-both
   car la perturbation est identique des deux côtés, mais je ne comparerai jamais ces
   latences absolues à celles de la Phase A, non sondées. C'est écrit dans le script.

## Où un gain peut encore exister — et comment je le cherche (Phase B)

Ton hypothèse du 25 juin : sur du crypto plus lent (machines plus modestes, autres
chiffrements), la tête de file reste UNCRYPTED plus longtemps, donc plus de re-polls
gaspillés, donc le fix enlève plus. Le knob `wg_decrypt_delay_ns` (busy-wait injecté
par déchiffrement) permet de balayer ça sur la même machine.

Le premier essai de ce balayage (26 juin) avait montré la bonne direction — le gaspillage
stock monte de ~28 % à ~44 % quand on ralentit le déchiffrement, et le fix en enlève
plus — mais la méthodo cassait à fort délai : charge non plafonnée, le pipeline
s'effondrait, débit → 0, chiffres ininterprétables.

**J'ai réécrit le script de mesure** sur la structure de la Phase A : charge plafonnée
(2 Gb/s au total, sous le goulot de déchiffrement sur toute la plage), un pair latence
dédié, et une seule fenêtre de mesure par run qui capture ensemble latence, CPU
(3 métriques), débit réel vérifié, polls gaspillés, retransmissions. L'effondrement
devient une *donnée* (`status=collapse`, la ligne est gardée : c'est elle qui localise
le genou) au lieu d'un artefact. Balayage : délais 0/1/2/5/10 µs × off/both × 5
répétitions, ~35 minutes.

**État : le sweep a tourné hier soir sur une instanciation fraîche** (bootstrap en une
commande, 8/8 handshakes, bon module vérifié avant de lancer) et s'est terminé sans
encombre. Par contre le bail CloudLab a expiré avant que je rapatrie le CSV — leçon
répétée, maintenant notée dans le protocole : on scp les artefacts dans la même session
qui les produit. Les clusters sont pleins ce matin ; je relance dès qu'un créneau se
libère. Coût du re-run : ~45 minutes tout compris, le harnais est validé.

## Ce que ça donne comme histoire (état au 3 juillet)

| Question | Réponse | Statut |
|---|---|---|
| Le mécanisme (EoI, re-polls MISSED) | Confirmé, 95–99,7 % des polls gaspillés | prouvé |
| Le fix deux-côtés enlève du travail | ~27 % → ~14 % de polls gaspillés, stable 8–64 pairs | prouvé |
| Levier du débit | Le parallélisme (sdfn), ×2,2 — pas le fix | prouvé |
| Gain CPU en sous-saturation (c220g2) | Non — null propre | mesuré |
| Gain latence | Tendance ~7 % non significative, confondue | non revendiqué |
| Gain sous crypto lent | Direction favorable, **à quantifier** | Phase B en cours |

C'est une histoire défendable dans les deux sens : soit la Phase B trouve le seuil
(« le fix compte quand le ratio déchiffrement:poll est élevé »), soit elle est nulle
aussi et la conclusion est « le fix est mécaniquement correct et supprime la moitié des
polls gaspillés, mais ce travail n'est de premier ordre nulle part sur ce matériel » —
valide avec cette méthodo.

## Après la Phase B (d'ici le 31 juillet)

1. **Soak `headwake`** (15–30 min de charge soutenue) avant de recommander `both` —
   le garde-fou contre le lost-wakeup.
2. *(Option)* re-test latence avec le confound retiré (`governor=performance`, sonde
   isolée, plus de répétitions) — seulement si on veut convertir la tendance de 7 % en
   chiffre réel.
3. **Rédaction** de la synthèse finale.

## La question de cadrage

Le suivi de stage mentionne encore l'évaluation du fix du papier (`gro_wq`) et de la
configuration combinée (leur fix + le nôtre). Le plan CloudLab s'est recentré depuis le
25 juin sur le fix deux-côtés, le résultat CPU/latence, et la sensibilité au coût de
déchiffrement. **Est-ce que la combinaison avec le fix du papier reste un livrable
attendu pour le 31 juillet, ou on la retire explicitement pour concentrer le temps
restant sur la Phase B, le soak headwake et la rédaction ?**
