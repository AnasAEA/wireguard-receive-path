# Plan de présentation du sujet — ordre, logique, et déroulé diapo par diapo

**Hypothèse de cadrage** (à ajuster) : présentation de ~15–20 min, public mixte (pas
forcément expert noyau) — d'où l'intérêt des 4 diagrammes « pour débutant ». Si c'est plutôt
10 min ou un public très technique, voir « Variantes » à la fin.

## La règle d'or de l'ordre

**Monter les briques → assembler → casser → réparer → prouver.** Concrètement :

1. on **plante le décor** (pourquoi ce sujet, le résultat du papier qui motive tout) ;
2. on **donne une carte** (le trajet d'un paquet en 3 étapes) pour que l'auditoire sache *où
   on va* ;
3. on **explique les 4 briques** (pair, NAPI, workqueue, GRO) — *isolément*, avec les
   analogies ;
4. on **assemble** : le pipeline complet ;
5. **seulement maintenant** on révèle le **bug** (il devient évident une fois la machine
   comprise) ;
6. le **correctif** ;
7. **ce que j'ai fait / mesuré**, mes **limites**, et la **suite (CloudLab)**.

> Ne **jamais** ouvrir par le bug : sans la machine en tête, personne ne *sent* pourquoi
> c'en est un. Le bug doit tomber comme une évidence, pas comme une définition.

## L'ordre des 4 concepts (et pourquoi)

**Pair → NAPI → Workqueue → GRO.** La logique :

- **Pair** d'abord : c'est le *« qui »* et ça pose l'**échelle** (1 vs 1000) — tout le reste
  s'accroche au pair (`peer->napi`, `peer->rx_queue`).
- **NAPI** ensuite : le *moteur de réception*. Brique centrale ; on apprend que WireGuard
  s'en *fabrique* une par pair.
- **Workqueue** : *pourquoi* le déchiffrement sort du softirq, et surtout le **par-CPU** qui
  crée le **désordre** — la graine du bug.
- **GRO** en dernier : l'*optimisation qu'on veut préserver* — donc la **victime** du bug.

Ainsi, quand on arrive au bug, les trois ingrédients sont déjà en main : *NAPI réveillée
inutilement* (brique 2), *parce que la workqueue finit dans le désordre* (brique 3), *ce qui
fait perdre ses lots au GRO* (brique 4), *par pair* (brique 1).

---

## Déroulé diapo par diapo

| # | Titre de la diapo | Ce qu'on montre | Ce qu'on dit (l'essentiel) | ~min |
|---|---|---|---|---|
| 1 | **Titre** | sujet, nom, encadrants, dates | une phrase : « améliorer/­comprendre le chemin de réception de WireGuard sous forte charge » | 0,5 |
| 2 | **Le décor** | schéma simple : un serveur VPN, N clients | WireGuard = VPN très rapide ; mais un **serveur multi-clients** peut **saturer un cœur** en réception. Question : pourquoi, et comment faire mieux ? | 1,5 |
| 3 | **Ce qui motive** | 1 chiffre du papier (Mounah et al., SYSTOR 2025) | déplacer le **GRO dans une workqueue** → jusqu'à **4,7×** de débit. Mon sujet : **comprendre** ce chemin, le **mesurer**, et étudier un **bug connexe** (inversion d'ordre, *EoI*) + son correctif. | 1,5 |
| 4 | **La carte (teaser)** | le diagramme `diagramme.svg` en *vue d'ensemble*, sans détail | « un paquet entrant traverse **3 moteurs** : la NAPI de la carte → une **workqueue** qui déchiffre → une **2ᵉ NAPI** (WireGuard) qui remet en ordre + GRO. On va décortiquer chaque brique, puis revenir ici. » | 1 |
| 5 | **Brique 1 — le pair** | `concept_peer.svg` | analogie de la **fiche par correspondant** ; identité = clé publique ; **1 wg0 → jusqu'à 1000 pairs** ; chacun a **sa** file et **sa** NAPI, mais **un seul atelier** de déchiffrement partagé. | 1,5 |
| 6 | **Brique 2 — NAPI** | `concept_napi.svg` | analogie de la **sonnette/boîte aux lettres** ; « sonner une fois puis relever par lots » ; NAPI = **fiche + fonction**, pas un thread ; tourne en **softirq**. | 2 |
| 7 | **Brique 3 — workqueue** | `concept_wq.svg` | analogie **accueil / bureau à l'arrière** ; déchiffrer = trop long pour le softirq ; **un employé par cœur** → **déchiffrement en parallèle** → **fin dans le désordre** *(je pose le mot : c'est la graine du bug)*. | 2 |
| 8 | **Brique 4 — GRO** | `concept_gro.svg` | analogie **agrafer les enveloppes, monter l'escalier une fois** ; GRO = regrouper un même flux ; **2 fronts** chez WireGuard (externe conditionnel / interne explicite). | 2 |
| 9 | **On assemble** | `diagramme.svg` en **entier**, on suit les flèches | re-parcours rapide : NAPI(NIC) → workqueue(par-CPU) → NAPI(WireGuard) + GRO #2. « Voilà les 4 briques en place. » | 2 |
| 10 | **Le bug (EoI)** | zoom sur la jointure workqueue → 2ᵉ NAPI (★) | les workers finissent **dans le désordre** → on **réveille la NAPI après chaque paquet** → souvent la **tête de file n'est pas prête** → `rx_poll` **repart à vide** (`work_done=0`) **et GRO #2 perd ses lots**. | 2,5 |
| 11 | **Le correctif** | le diff court (lire `rx_queue.tail` avant de réveiller) | ne réveiller **que si** la tête est déchiffrée ; **sûr** car `tail` n'est écrit que par l'unique consommateur. | 1,5 |
| 12 | **Ce que j'ai fait** | extrait de résultats (28 mai) + mention du harnais | reproduit sur **M1/ARM** ; mesuré la baisse de GRO qui **grandit avec le nombre de pairs** ; **limite** : la boucle locale ne **sature pas** le débit (pas de vraie NIC). | 2 |
| 13 | **Validation x86 + suite** | tableau « code identique v6.1 ↔ Asahi » + plan CloudLab | le code (bug, correctif, file, poll) est **identique** sur x86/v6.1 ; **CloudLab** (vraie NIC 25 G, x86, 1000 pairs) pour tester le **régime de débit** du papier. | 1,5 |
| 14 | **Conclusion** | 3 puces | (1) mécanisme **compris et prouvé par le code** ; (2) bug **localisé + correctif sûr** ; (3) **mesure ARM faite**, **validation x86 en cours**. | 1 |

**Total ≈ 22 min** de contenu → vise 15–18 en parlant ; garde 2–3 diapos « de secours »
(annexe) pour les questions.

---

## Les phrases de transition (le liant — souvent ce qui manque)

- **3 → 4 :** « Avant le bug lui-même, il faut voir *la machine*. Voici la carte ; ne
  retenez pour l'instant que les 3 grandes étapes. »
- **4 → 5 :** « Première brique, la plus simple : *avec qui* WireGuard parle. »
- **5 → 6 :** « Chaque pair a sa propre "boîte aux lettres". C'est quoi, au juste ? »
- **6 → 7 :** « Cette boîte ne peut pas faire de calcul long. Or déchiffrer est long…
  comment on s'en sort ? »
- **7 → 8 :** « Le déchiffrement parallèle finit dans le désordre — gardez ça en tête. Une
  dernière brique : l'optimisation qu'on veut protéger. »
- **8 → 9 :** « On a les 4 morceaux. Remettons-les ensemble. »
- **9 → 10 :** « La machine marche. Maintenant, *où* ça coince ? Exactement ici. » *(on
  pointe l'étoile)*
- **10 → 11 :** « Une fois qu'on a vu ça, le correctif tient en une idée. »

---

## Variantes

- **Version 10 min :** garder 1, 2+3 fusionnées, **4** (carte), puis **fusionner les briques**
  en une seule diapo « les 3 moteurs » (NAPI / workqueue / GRO) + une demi-diapo « pair »,
  puis 10 (bug), 11 (fix), 13 (suite). On sacrifie le détail des analogies.
- **Public très technique (Alain/André) :** on peut **réduire les analogies** et **montrer le
  code** (le **§7 Dossier de preuves** de `PIPELINE_COMPLET_RECEPTION_WG_FR.md`) sur les
  diapos 6–11 ; garder l'ordre identique.
- **Si on me coupe sur le temps :** priorité absolue aux diapos **4, 9, 10, 11** (carte →
  assemblage → bug → fix). Le reste est du confort.

## Diapos d'annexe (pour les questions)

- le **cycle de vie NAPI** (7 étapes) ; la nuance **« une seule workqueue, workers par-CPU »** ;
  la **chaîne d'appel du Front #1** (`[P8a]`) ; les **recettes bpftrace** (§5) ; le **détail du
  correctif** et sa **sûreté** (file MPSC de Vyukov).

---

*Artefacts : `diagrams/concept_{peer,napi,wq,gro}.svg`, `diagrams/diagramme.svg`. Scripts de
parole : `admin/EXPLICATION_DIAGRAMME_FR.md` (pipeline) et les blocs « À dire » de
`admin/DIAGRAMMES_CONCEPTS_SPEC_FR.md` (concepts). Preuves : `PIPELINE_COMPLET_RECEPTION_WG_FR.md`.*
