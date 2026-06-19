# Point d'avancement — banc CloudLab, semaine du 16 juin

> Pour Alain. Résumé court de ce qui tourne sur CloudLab et d'un résultat important.

## Ce qui est en place

Banc monté et validé sous le projet **WG** : deux nœuds bare-metal **c220g2**
(Wisconsin, 2× Xeon E5-2660 v3 = 20c/40t, NIC Intel X520 **10 GbE**), reliés par un
lien privé 10 G.

- `dut` = récepteur WireGuard instrumenté (kprobes bpftrace, BTF présent, noyau
  5.15.0-177 — la structure `prev_queue` y est déjà rétroportée, donc **le patch M1
  s'applique tel quel**).
- `gen` = générateur de charge ; les **N pairs** sont créés via N **espaces de noms
  réseau** (méthode du banc M1, portée au lien réel), chacun un tunnel WireGuard
  distinct → vraie concurrence multi-cœur de déchiffrement.

Modules **stock** et **patché** compilés depuis les sources 5.15 (srcversions
distincts, vérifiés). Tout est scripté et versionné (`scripts/cloudlab/`).

## L'EoI se reproduit bien sur vrai NIC

À 8 pairs, sous charge `iperf3`, **33 % des polls `wg_packet_rx_poll` ne livrent
aucun paquet** (work_done == 0) — la signature de l'EoI, bien présente hors loopback.
Le débit est plafonné par le cœur softirq (~4 Gb/s à 1 pair, loin du lien 10 G),
comme attendu.

## Résultat important : la correction M1 est **sans effet** sur vrai NIC

A/B stock vs patché à iso-conditions :

| | polls à vide | fraction |
|---|---:|---:|
| stock   | 911 900 | **33,0 %** |
| patché  | 905 486 | **33,2 %** |

→ **Aucune amélioration** (à 1 et 8 pairs), alors que M1 (ARM, loopback) montrait
−21,9 % à 8 pairs.

**Diagnostic (build instrumenté avec compteurs).** La correction **fonctionne** : elle
saute bien 9,4 % des réveils (`napi_schedule`) quand la tête de file n'est pas prête.
Mais **`napi_schedule` est un no-op ~63 % du temps en charge** : sur 7,48 M de
tentatives de réveil, seules 2,73 M deviennent de vrais polls (la NAPI est déjà
`SCHED`). Supprimer 9,4 % des *appels* — pris dans un ensemble déjà à 63 % redondant —
ne change donc pas le nombre de *polls* à vide.

**Interprétation.** Sur un NIC réel saturé, la NAPI du pair est quasi en permanence
déjà programmée ; **agir sur l'appel `napi_schedule` est le mauvais levier**. Le gain
M1 était un artefact du régime loopback (NAPI non saturée). C'est exactement ce que la
mesure sur vrai matériel devait révéler — et ça oriente le déclencheur à concevoir :
il doit agir au niveau **du poll / de la livraison**, pas de l'appel de réveil.

## Modèle de coût — **complet** (stock, 8 pairs)

| grandeur | valeur | sens |
|---|---|---|
| `T_decrypt` | ~5–6 µs/paquet | vitesse à laquelle les paquets deviennent prêts |
| `Δ_complete` | bimodal ~5 µs (cœur actif) / ~100 µs (cœur au repos) | délai jusqu'à la prochaine fin de déchiffrement |
| `C_poll` (poll à vide) | ~1,0 µs | coût d'un poll qui ne livre rien |
| coût fixe de livraison | ~3,7 µs | payé dès qu'un poll livre ≥1 (entrée GRO/pile) |
| `C_deliver` | ~1,64 µs/paquet | coût marginal par paquet dans le poll |
| `C_stack` (gain batching) | ~3,7 µs/poll évité | coût fixe amorti quand on agrège |

Le coût par paquet tombe de **5,3 µs (batch 1) à 1,9 µs (batch 16)**. Or la
distribution des polls est **très tassée vers le bas** (la plupart livrent 0–4
paquets) → quasiment rien n'est amorti aujourd'hui. Sur 20 s : ~0,87 s CPU en polls à
vide + ~7 s en coût fixe de livraison (réparti sur les cœurs) → **c'est l'overhead par
poll qui domine**, et c'est lui que le batching attaque.

## Piste de déclencheur que les chiffres soutiennent

Quand un poll tombe sur une tête **non déchiffrée**, la prochaine fin de déchiffrement
est à **~5–10 µs** (cadence active, ≈ `T_decrypt`). Un déclencheur qui **retarde le
poll de ~5–10 µs (ou attend ≥k paquets prêts)** laisserait la tête + quelques suivants
se déchiffrer, transformant les polls de 0–4 paquets en batchs plus gros et amortissant
les ~3,7 µs/poll — pour seulement quelques µs de latence ajoutée. Comme le récepteur est
**borné CPU** (un cœur softirq sature à ~4 Gb/s, loin des 10 G), troquer un peu de
latence contre du CPU est gagnant.

## Prochaines étapes

1. Prototyper le déclencheur **au niveau du poll** (délai borné / seuil k), re-mesurer.
2. Confirmer que les coûts tiennent à 32/64/128 pairs (passage à l'échelle).

## Question pour toi

Le constat « la correction actuelle ne tient pas sur vrai NIC, et voici pourquoi », plus
le modèle de coût ci-dessus, te semblent-ils une bonne base pour concevoir un
déclencheur conscient du batching **au niveau du poll** (délai ~5–10 µs / seuil k) ?
