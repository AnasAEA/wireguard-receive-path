# Journal des expériences CloudLab — version française

> La version lisible, en français, de la campagne CloudLab sur le chemin de réception
> WireGuard : la question posée, ce qui a tourné, ce qu'on a vu, ce que ça veut dire, ce
> qu'on a décidé. La version anglaise ([`CLOUDLAB_EXPERIMENTS_LOG.md`](CLOUDLAB_EXPERIMENTS_LOG.md))
> est la référence pour les index de données et les annexes ; le carnet brut intégral
> (chaque run, chaque erreur) est dans
> [`CLOUDLAB_EXPERIMENTS_LOG_RAW.md`](CLOUDLAB_EXPERIMENTS_LOG_RAW.md).
> Auteur : Anas Ait El Hadj · Inria KrakOS (LIG).

---

## 0. Où on en est — à lire en premier (7 juillet 2026)

La campagne CloudLab a répondu à la question principale.

- **Le fix deux-côtés est réel** : il divise par deux les polls gaspillés sur du vrai
  matériel 10G (~27 % → ~14 %, stable de 8 à 64 pairs).
- **Mais ces polls gaspillés sont trop bon marché pour produire un gain visible** en CPU
  ou en latence sur c220g2. La Phase A (sous-saturation, 64 runs) est un null CPU propre ;
  la latence ne montre qu'une tendance bruitée, polluée par les états d'énergie — je ne
  la revendique pas.
- **La Phase B montre que le mécanisme répond à la dose** : le fix enlève 56 % du
  gaspillage sur crypto rapide et 89 % quand je ralentis le déchiffrement à 10 µs/paquet
  — exactement ce que le modèle prédit. Et pourtant, CPU et latence ne bougent toujours
  pas.
- **E10 a mesuré pourquoi, directement** : la totalité du budget des polls gaspillés fait
  ~0,022 équivalent-cœur, environ cent fois sous le bruit de ±2 CE. Le null n'est plus
  une déduction, c'est une mesure. *Le fix supprime beaucoup d'événements, pas beaucoup
  de cycles.*
- **E11 a trouvé une autre opportunité pour la latence** : le paquet de tête attend
  ~50–100 µs avant d'*être* déchiffré (10 à 20 fois son propre temps de déchiffrement,
  insensible au délai injecté) — il fait la queue derrière d'autres paquets, ou attend
  l'ordonnanceur. C'est ce qui motive l'idée **head-priority / steering du
  déchiffrement**, en attente d'une dernière mesure.

Le plus surprenant, c'est que le résultat négatif est devenu l'un des résultats les plus
solides : on sait *pourquoi* le fix n'améliore pas le CPU. Pas parce qu'il est cassé —
il agit, c'est vérifié par compteurs — mais parce que ce qu'il supprime est extrêmement
bon marché sur cette machine.

Reste à faire : (1) le classifieur `wg_diag` (~20 lignes) pour séparer les vrais
blocages de tête des files vides, puis re-mesurer E11 ; (2) le soak de fiabilité de
`headwake` ; (3) trancher avec Alain/André si le fix du papier (`gro_wq`) et la config
combinée restent un livrable du 31 juillet ; (4) la rédaction finale.

**Plan de lecture.**
- *2 minutes :* cette section + la figure budget du Résultat 5.
- *Le mécanisme :* §2 (modèle mental) + Résultat 2.
- *Le verdict :* Résultats 3–5.
- *La suite :* Résultat 6.

## 1. La question que je me posais

La question que j'ai apportée sur CloudLab était simple : les expériences sur le M1
avaient montré que WireGuard réveille parfois son chemin de réception alors qu'aucun
paquet ne peut être livré. Si j'évite ces polls gaspillés, est-ce que je gagne quelque
chose de réel sur du matériel 10G ?

La réponse s'est révélée plus nuancée. Le fix est réel — il supprime bien les polls
gaspillés, et la Phase B montre qu'il devient plus efficace exactement quand le modèle
le prédit. Mais sur c220g2, le travail économisé est trop petit pour apparaître en CPU
ou en latence. Le résultat utile n'est donc pas « WireGuard est devenu plus rapide ».
C'est : on sait précisément où ce gaspillage se loge dans le chemin de réception, ce
qu'il coûte, et pourquoi il reste invisible sur ce matériel.

Et ça a changé la direction du projet. Le fix côté réveil évite des vérifications
inutiles, mais il ne fait jamais finir le paquet de tête plus tôt. E11 suggère que la
vraie opportunité latence est ailleurs : la tête passe des dizaines de microsecondes à
attendre *avant même d'être déchiffrée*. Ça pointe vers le steering du déchiffrement
comme travail futur.

## 2. Le modèle mental : pourquoi WireGuard gaspille des polls

### 2.1 Le chemin de réception normal

![D'où viennent les polls gaspillés](../meetings/figures/fig_eoi_pipeline_fr.png)

Trois choses à garder en tête : le déchiffrement parallèle est ce qui donne le débit
multi-cœurs (tant mieux) ; la livraison ordonnée est une exigence du protocole (non
négociable) ; les polls gaspillés sont la friction *entre* les deux — le moteur de
livraison n'arrête pas de vérifier une tête qui n'est pas prête.

### 2.2 Où l'EoI apparaît

![L'EoI en une image](../meetings/figures/fig_eoi_timeline_fr.png)

Chaque fois qu'un paquet *non-tête* (P2/P3/P4) finit, il sonne la cloche de livraison
(`napi_schedule`). Ces coups de cloche pendant que P1 se déchiffre encore, c'est ce qui
produit les ~27–34 % de polls gaspillés. Pire : une cloche sonnée *pendant* un poll pose
un drapeau MISSED qui force un re-poll immédiat — et 95 à 99,7 % des polls gaspillés
sont exactement ces re-polls MISSED. (Notez la bande grise dans la figure — P1 *fait la
queue avant même que son déchiffrement commence*. Gardez-la en tête : elle revient au
Résultat 6.)

### 2.3 Ce que fait le fix deux-côtés

![Le fix deux-côtés](../meetings/figures/fig_twosided_fr.png)

Un seul côté fuit : supprimez seulement le re-poll, et la prochaine fin de déchiffrement
non-tête sonne une cloche *neuve* (le gaspillage « se régénère ») ; barrez seulement le
producteur, et les re-polls MISSED déjà en vol partent quand même. C'est l'argument de
composition d'Alain, et les compteurs le confirment (Résultat 2).

### 2.4 Ce que le fix ne peut pas faire — par construction

Le fix décide *quand vérifier* la file. Il ne touche jamais à *quand P1 finit de se
déchiffrer* — donc il ne peut livrer aucun paquet plus tôt. Son seul bénéfice visible
possible, c'est le CPU qu'il libère. À garder en tête pour les Résultats 3–5 : le null
latence n'est pas un accident, il est structurel. (Ce qui *pourrait* livrer plus tôt,
c'est le Résultat 6.)

### 2.5 Vocabulaire

| Terme | Sens |
|---|---|
| **EoI** | Execution Order Inversion : le déchiffrement parallèle finit dans le désordre, mais la livraison doit être dans l'ordre. |
| **poll gaspillé** | Un poll NAPI (`wg_packet_rx_poll`) qui ne livre aucun paquet — il a tourné, trouvé la tête pas prête, et est reparti. |
| **re-poll MISSED** | Le re-poll auto-programmé du noyau : une cloche sonnée pendant un poll force un autre poll juste après. |
| **fresh wake** | Un poll gaspillé lancé par un `napi_schedule` tout neuf — comment le gaspillage se régénère avec un fix à un seul côté. |
| **`off`** | WireGuard de base (appelé *stock* dans les vieilles entrées ; tous les knobs à 0). |
| **`wg_supp` / `wg_headwake` / `both`** | Suppression consommateur / barrière producteur / le fix deux-côtés (anciens noms : `move` / `root`). |
| **`sdfn`** | Réglage du hachage NIC ajoutant les ports UDP → les tunnels s'étalent sur les cœurs (défaut : IP seules → un seul cœur). |
| **CE (équivalent-cœur)** | CPU normalisé par le temps : 0,5 CE = un demi-cœur occupé en continu ; 8 CE = huit cœurs pleins. |
| **p99 / latence de queue** | Le 99ᵉ percentile du temps aller-retour — les « pires moments » que ressent un utilisateur. |
| **`wg_decrypt_delay_ns`** | Knob injectant une attente active par déchiffrement — émule un crypto plus lent, coût du poll inchangé. |
| **épisode de blocage** | Du premier poll gaspillé après un poll productif au prochain poll productif sur la même NAPI : combien de temps la livraison est restée bloquée. |
| **Phase A / Phase B / E10 / E11** | Campagne sous-saturation CPU+latence / balayage du délai de déchiffrement / comptabilité directe des coûts / mesure des blocages. |
| **srcversion** | L'empreinte de build du module, écrite dans chaque ligne de CSV (`EA06EE82…` = le build deux-côtés composable). |

## 3. Les résultats

### Résultat 1 — Le débit était un problème de parallélisme, pas un problème de fix

À ce stade, le vrai goulot n'était pas du tout la logique WireGuard. La carte réseau
envoyait simplement tous les tunnels sur le même cœur de réception : son hachage par
défaut ne regarde que les adresses IP, et tous mes tunnels partagent la même IP.

| Hachage NIC | Débit | Cœurs qui reçoivent |
|---|---|---|
| `sd` (IP seules — l'entonnoir) | 4,1 Gb/s | 1 (à 100 %) |
| `sdfn` (+ ports UDP) | **9,0 Gb/s (×2,2)** | 8 (~55 % chacun) |

![Un cœur → huit cœurs](../meetings/figures/fig_spread.png)

Revérifié sur trois instanciations différentes. Toutes les campagnes suivantes tournent
en régime étalé `sdfn`. *(Le fil rouge : le parallélisme est à la fois la cause du bug
EoI et le remède du débit.)*

> **Ce que j'ai retenu.** Le débit était le mauvais critère pour juger ce fix. La machine
> n'était pas lente à cause des polls gaspillés ; elle était lente parce que tous les
> paquets atterrissaient sur un seul cœur.

### Résultat 2 — Le fix deux-côtés divise le gaspillage par deux (Alain avait raison)

Le fix « six lignes » du M1, côté producteur seul, est un **null sur du vrai matériel**
(au moment de sonner, la cloche sonne déjà — voir l'annexe C de la version anglaise). La
version deux-côtés du §2.3 est celle qui marche. Balayage en pairs, régime `sdfn`
(`data/cloudlab/twosided_peersweep_20260626.csv`) :

| pairs | `off` | consommateur seul | producteur seul | **deux-côtés (`both`)** |
|---|---|---|---|---|
| 8  | 27,0 % | 25,8 % | 15,4 % | **14,8 %** |
| 16 | 27,3 % | 26,1 % | 15,9 % | **13,8 %** |
| 32 | 26,8 % | 25,1 % | 15,0 % | **13,1 %** |
| 64 | 27,5 % | 25,3 % | 15,4 % | **14,4 %** |

![Polls gaspillés vs nombre de pairs](../meetings/figures/fig_twosided_peers.png)

La fuite prédite au §2.3 se voit dans les compteurs : le consommateur seul *augmente* la
part fresh-wake du gaspillage de ~3 % à ~6 % (le re-poll annulé revient en cloche
neuve), et ajouter la barrière producteur la fait tomber à ~1 %. La réduction est
**plate de 8 à 64 pairs** — l'effet « croît avec les pairs » du M1 ne se reproduit pas,
mais la division par deux est solide. Et le fix agit, c'est vérifié : les compteurs
in-module montrent `wg_supp` actif dans 96 % de ses cas cibles, et exactement 0 fix
éteint — les nulls qui suivent ne sont pas « un fix qui ne se déclenche pas ».

> **Ce que j'ai retenu.** Le fix à un côté était incomplet, et l'argument de composition
> d'Alain était exactement juste : chaque côté rattrape la fuite de l'autre.

### Résultat 3 — Ni le CPU ni la latence n'en profitent sur c220g2 (un null propre)

La Phase A pose la question : avec de la marge CPU (sous-saturation), le travail
économisé apparaît-il là où un utilisateur regarde ? Le point de conception qui compte :
le pair 0 ne portait *que* la sonde de latence (sockperf ping-pong) — pour ne jamais
mesurer un paquet de latence coincé derrière son propre trafic — pendant que les pairs
1 à 7 créaient une pression WireGuard plafonnée en arrière-plan. `off` contre `both` ×
charges cibles 0/2/4/6 Gb/s × 8 répétitions, ordre entièrement mélangé — 64 runs
(`subsat_20260701_0609.csv`).

- **Comparaison équitable, vérifiée run par run** : les charges réelles off/both
  concordent à ≤3,4 % (≤1,2 % à 4/6 Gb/s) — `both` ne bride pas le débit.
- **CPU : null propre.** Trois mesures indépendantes (softirq / système+IRQ / total
  occupé) indiscernables à toutes les charges : écarts −4,7 %…+1,6 %, signes mélangés,
  p≈0,4–1,0.
- **Latence : non concluante et confondue.** `both` penche 7–8 % plus bas en p99 à 2 et
  4 Gb/s mais sans signification (p≈0,37–0,71, IQR qui se recouvrent), et la queue est
  *la pire à la plus basse charge non nulle* (~1,5 ms à 1,1 Gb/s contre ~1,0 ms à 3,1 ;
  plancher à vide ~370 µs) — le sens inverse d'une file d'attente, la signature des
  C-states sous `schedutil`. Non revendiqué.

> **Ce que j'ai retenu.** Un null propre est quand même un résultat — *parce que* les
> charges étaient appariées, l'ordre mélangé et le CPU mesuré trois fois, « rien n'a
> bougé » est une affirmation défendable, pas une ambiguïté.

### Résultat 4 — Le mécanisme répond à la dose (la figure vedette)

La Phase B injecte une attente active par paquet dans le déchiffrement
(`wg_decrypt_delay_ns`), pour émuler un crypto plus lent, avec le même protocole à
charge plafonnée (`decsweep_20260706_0321.csv`, 50 runs sur 50 valides) :

![L'efficacité du fix croît avec le coût de déchiffrement](../meetings/figures/fig_decsweep_wasted.png)

| délai injecté | `off` gaspille | `both` gaspille | le fix enlève |
|---:|---:|---:|---:|
| 0 µs | 34,4 % | 15,2 % | **56 %** du gaspillage |
| 1 µs | 34,7 % | 12,8 % | 63 % |
| 2 µs | 34,8 % | 12,0 % | 66 % |
| 5 µs | 33,3 % | 7,5 % | 78 % |
| 10 µs | 34,6 % | **3,8 %** | **89 %** |

La base reste plate (~34 % — le gaspillage est structurel, pas une affaire de vitesse)
pendant que le fix s'améliore de façon monotone, avec des intervalles serrés : **une
réponse à la dose**, le résultat mécanistique le plus propre du projet. Plus le
déchiffrement est lent, plus la tête reste chiffrée longtemps, plus la barrière
producteur a de cloches à intercepter — exactement la prédiction du modèle. Et pourtant
les écarts CPU restent à signes mélangés à tous les délais, et le p99 aussi — même à un
ratio déchiffrement:poll de ~10:1. (Suggestif seulement, non revendiqué : 10 à 30 fois
moins de retransmissions TCP avec le fix à 5–10 µs ; n=5, forte variance.) L'ancienne
observation « le gaspillage stock monte à ~44 % » était un artefact d'effondrement à
charge non plafonnée.

> **Ce que j'ai retenu.** Le mécanisme est réel précisément parce qu'il répond à la
> dose : quand j'aggrave la maladie, le remède en enlève plus. C'est une preuve bien
> plus forte que n'importe quel A/B isolé.

### Résultat 5 — Les cycles manquants n'ont jamais existé

C'est la partie qui semblait fausse au début. À 10 µs de délai injecté, le fix
deux-côtés enlève presque tous les polls gaspillés. Intuitivement, ça devrait bien
économiser *quelque chose* de visible. E10 a mesuré pourquoi ce n'est pas le cas — avec
deux instruments indépendants, dans des fenêtres séparées (sommes de durées bpftrace ;
attribution des cycles perf).

La résolution : « 89 % des polls gaspillés », ce n'est pas « 89 % du CPU ». Un poll
gaspillé est une vérification très bon marché — **1,14–1,36 µs**, mesuré en conditions
réelles (le modèle disait ~1,0 ; le surcoût du kretprobe en fait une borne supérieure).
Les ~500 000 polls gaspillés de la base par fenêtre de 30 s totalisent :

```text
CPU total occupé sous charge :   ~7–9  CE
bruit run-à-run :                ±2    CE
TOUS les polls gaspillés :        0,022 CE   ← toute la maladie
récupéré par le fix :             0,017–0,022 CE
```

![Le budget mesuré](../meetings/figures/fig_e10_budget_fr.png)

perf confirme par l'autre bout : toute la machinerie poll + réveil
(`wg_packet_rx_poll` *travail utile compris* + `napi_complete_done` +
`__napi_schedule`) pèse **moins de 0,7 % des cycles occupés** dans toutes les
conditions. Le CPU vit dans la livraison par paquet, les workers de déchiffrement,
TCP/IP et l'espace utilisateur — pas dans les polls.

L'interprétation finale est donc simple : **le fix supprime beaucoup d'événements, pas
beaucoup de cycles.** Le compteur d'événements bouge beaucoup parce qu'on vise
exactement cet événement ; le compteur CPU ne bouge pas parce que cet événement était
une fraction minuscule du coût total. Et d'après le §2.4, la latence ne pouvait pas
bouger non plus — le fix ne rend jamais la tête livrable plus tôt. Observation bonus :
avec le fix, les polls sont moins nombreux mais plus longs (15 → 23 µs en moyenne) —
les livraisons se regroupent en plus gros lots, l'effet « batch GRO » du M1 retrouvé
sur vrai matériel.

> **Ce que j'ai retenu.** Un compte d'événements n'est pas un coût CPU. Un pourcentage
> ne vaut que par le budget de la chose dont il est le pourcentage — on aurait dû
> chiffrer le gaspillage en CE dès le premier jour.

### Résultat 6 — La prochaine opportunité latence : le steering de la tête

E11 a mesuré combien de temps la livraison reste réellement bloquée quand un poll
trouve la tête pas prête (épisodes de blocage, base, délais 0/2/5/10 µs) :

![Distribution des blocages](../meetings/figures/fig_e11_stall_fr.png)

Le gros des blocages se situe à **32–128 µs ≈ 10–20 fois T_decrypt** (~5 µs) — et la
médiane **ne bouge pas** quand j'injecte +10 µs de délai de déchiffrement. Cette
distinction compte : le crypto lui-même n'est pas le délai. La tête passe l'essentiel de
son temps bloqué à attendre *qu'un worker s'occupe d'elle* — en file derrière d'autres
paquets sur son CPU attitré, ou en attente d'ordonnancement du kworker (ça recoupe le
Δ_complete bimodal ~5 µs / ~100 µs du modèle de coût). C'est pour ça que le fix côté
réveil ne peut pas aider la latence, et pour ça que l'idée head-priority est plus
intéressante :

![Pourquoi le fix côté réveil ne peut pas bouger la latence](../meetings/figures/fig_fix_vs_steering_fr.png)

En étant précis sur le statut épistémique :

```text
Ce qu'E11 prouve :        les blocages font des dizaines de µs et ne s'expliquent
                          pas par le temps de déchiffrement.
Ce qu'E11 suggère :       la file du worker / l'ordre de déchiffrement en est
                          responsable.
Ce qu'E11 ne prouve PAS : que tous ces blocages sont de vrais blocages de tête —
                          ~46 % des polls gaspillés trouvent une file VIDE, et la
                          sonde ne sait pas les distinguer épisode par épisode.
Prochaine étape :         classifier les épisodes dans wg_diag (~20 lignes),
                          re-mesurer E11.
```

Borne prudente, avec la chaîne de correction convenue (écart brut = borne sup. du temps
bloqué ; × ~54 % de fraction tête-chiffrée ; − plancher de déchiffrement) :
**typiquement ~30–90 µs récupérables, population de queue à 200–800 µs** — au-dessus de
la bande « pas la peine » (5–20 µs), queue au-delà du seuil « on y va » (100 µs). La
population milliseconde (~6 % des épisodes) est de l'inactivité entre rafales, exclue.
**Décision : ne pas implémenter le steering maintenant ; construire d'abord le
classifieur.**

> **Ce que j'ai retenu.** Le fix côté réveil et la latence n'allaient jamais se
> rencontrer — le fix optimise la *vérification*, pas la *disponibilité*. S'il existe un
> gain de latence dans cette histoire, il vit dans l'ordonnancement du déchiffrement, et
> un petit classifieur décidera si on le poursuit.

## 4. Chronologie

| Date | Expérience | Ce qui a changé | Résultat | Statut |
|---|---|---|---|---|
| 17/06 | Banc en ligne (instanciation #1) | 2× c220g2, lien 10G, noyau 5.15 | sondes confirmées | réglé |
| 18/06 | Reproduction EoI (1 pair) | premier bpftrace sur vraie carte | 35,8 % de polls gaspillés | réglé |
| 19/06 | A/B du fix six-lignes (8 pairs) | premier A/B réel | **null** + diagnostic (cloche déjà en cours ~63 %) | réglé |
| 19–24/06 | Modèle de coût (E2–E5) | sondes par étape | T_decrypt 5–6 µs, C_poll ~1 µs | réglé |
| 22/06 | Diagnostic de saturation | CPU par cœur sous charge | entonnoir mono-cœur : hachage IP-seules | réglé |
| 24/06 | `wg_headwake` + **étalement sdfn** | barrière producteur ; hachage NIC | 33→20 % gaspillés ; **4,1→9,0 Gb/s (×2,2)** | réglé |
| 25/06 | Point avec Alain | composer le fix ; CPU en sous-saturation ; sensibilité crypto | build deux-côtés (`EA06EE82…`) | réglé |
| 26/06 | Balayage pairs deux-côtés | 8–64 pairs, warm-up ajouté | **27→14 % gaspillés, plat** | réglé |
| 01–02/07 | Phase A (64 runs) + analyse | sous-saturation | **null CPU propre** ; latence confondue | réglé |
| 02–03/07 | Tentative Phase B (#6) | sweep réécrit à charge plafonnée | tourné proprement ; **données perdues (bail expiré)** | remplacé le 06/07 |
| 06/07 | Phase B (#7, 50 runs) | sweep du délai de déchiffrement | **dose-réponse 56→89 % ; CPU/latence toujours null** | réglé |
| 06/07 | E10 comptabilité des coûts | bpftrace + perf | budget gaspillage **0,022 CE**, 100× sous le bruit | réglé |
| 06/07 | E11 blocages | sonde d'épisodes, délais 0–10 µs | blocage médian 50–100 µs, insensible au délai | **classifieur requis** |

## 5. Incidents et corrections de méthodo

| Date | Problème | Effet | Correction | Leçon |
|---|---|---|---|---|
| 26/06 | Première condition mesurée à froid après rechargement du module | fausses lignes `polls=1`, fausse alerte « stall » | rafale de warm-up avant la boucle | vérifier les comptes de polls avant de croire un zéro |
| 26/06 | Sweep de déchiffrement à charge non plafonnée | effondrement du pipeline au-delà de ~10 µs | réécriture à charge plafonnée, fenêtre unique | un effondrement n'est une donnée que si la charge est contrôlée |
| 03/07 | Bail expiré avant le scp (instanciation #6) | données Phase B perdues, re-run complet | — | **rapatrier les artefacts dans la session qui les produit** |
| 06/07 | Sweep lancé deux fois en parallèle | chaque setup a détruit le tunnel de l'autre : lignes toutes NA | verrou `flock` mono-instance | les scripts de mesure doivent être mono-instance |
| 06/07 | Seuil REJECT 0,40 vs sous-atteinte du pacing iperf3 (~45–50 %) | runs sains marqués « collapse » | seuil 0,60 ; genou localisé à l'analyse | connaître la marge du générateur avant de flaguer |
| 06/07 | bpftrace 0.14 refuse les scripts avec un bloc `END` | toutes les fenêtres E11 silencieusement vides | retirer `END` | ne jamais jeter le stderr d'une sonde en phase de validation |
| 06/07 | Une fenêtre E10 a tourné sans charge (deux fois, même cellule) | cellules froides dans les répertoires bruts | garde `ensure_load` (delta rx_bytes) | chaque fenêtre doit vérifier son propre trafic |

## 6. Où trouver le reste

- **Données, scripts et figures, cellule par cellule** : §7 de la version anglaise
  ([`CLOUDLAB_EXPERIMENTS_LOG.md`](CLOUDLAB_EXPERIMENTS_LOG.md)) — y compris la table de
  provenance E10/E11 (les répertoires bruts contiennent des fenêtres froides).
- **Journal détaillé entrée par entrée** (gabarit Question → Montage → Résultat →
  Interprétation → Décision → Artefacts) : §5 de la version anglaise.
- **Annexes** (instanciations, points de sonde, srcversions des modules, résultats
  remplacés et pourquoi) : §8 de la version anglaise.
- **Carnet brut intégral** : [`CLOUDLAB_EXPERIMENTS_LOG_RAW.md`](CLOUDLAB_EXPERIMENTS_LOG_RAW.md).
- **Points d'avancement pour Alain** : `../meetings/POINT_ALAIN_2026-06-24_FR.md`,
  `POINT_ALAIN_2026-07-03_FR.md`, `POINT_ALAIN_2026-07-07_FR.md`.
