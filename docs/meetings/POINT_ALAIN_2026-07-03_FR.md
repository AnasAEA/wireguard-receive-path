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

## Phase A — ce que j'ai mesuré et ce que ça donne

Le protocole qu'on avait convenu : en dessous de la saturation, là où le fix a de la
marge pour aider. Un pair réservé à la latence (sockperf ping-pong, aucun trafic de
fond sur lui), les 7 autres portent une charge TCP plafonnée, hachage `sdfn` (étalé sur
8 cœurs). `off` contre `both` (le fix deux-côtés), charges cibles 0/2/4/6 Gb/s, 8
répétitions, ordre mélangé — 64 runs, tout dans
`data/cloudlab/subsat_20260701_0609.csv`.

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

**Verdict : un null propre, pas un échec de mesure.** La méthodo tient (charges
appariées, ordre randomisé, trois métriques CPU, placement enregistré) — c'est le
résultat « le travail économisé est réel mais invisible ici », pas « on n'a pas su
mesurer ». Ça correspond exactement au modèle de coût qu'on a construit : ~1 µs de poll
contre une queue de latence en millisecondes dominée par les états d'énergie.

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
