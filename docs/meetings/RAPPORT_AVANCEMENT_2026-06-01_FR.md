# Rapport d'avancement — 1ᵉʳ juin 2026
# Correctif WireGuard EoI : implémentation, mesures sur M1, et plan CloudLab

**Auteur :** Anas Ait El Hadj
**Encadrants :** André Freyssinet (ScalAgent), Alain Tchana (KrakOS)
**Période couverte :** 22–29 mai 2026

---

## 1. Résumé

Depuis la réunion du 21 mai, j'ai :

1. **Appliqué le correctif d'André** (6 lignes) dans le code source de WireGuard,
   recompilé le module noyau, et l'ai chargé à chaud sur ma machine.
2. **Mené une campagne de mesures** comparant le module d'origine (« stock ») et le
   module corrigé, de 1 à 64 pairs, avec des sondes `bpftrace` directes.
3. **Établi ce que ces mesures prouvent et ne prouvent pas** : le mécanisme du
   correctif est validé (suppression de 14 à 20 % des réveils GRO inutiles, latence
   de queue ~divisée par deux à fort nombre de pairs), mais le **débit** ne peut pas
   être évalué sur ma machine, faute de pouvoir la saturer.
4. **Préparé la suite sur CloudLab** : 3 vraies machines avec de vraies cartes
   réseau, qui permettront enfin d'atteindre le régime de saturation du papier.

---

## 2. Le correctif (rappel et état du code)

### 2.1 Le problème ciblé (EoI)

Dans `wg_queue_enqueue_per_peer_rx` (`drivers/net/wireguard/queueing.h:196`), après
avoir marqué un paquet comme déchiffré, chaque cœur appelle `napi_schedule` **sans
condition**. Cela réveille la couche de livraison (GRO, en softirq). Or, sous
déchiffrement concurrent (N cœurs sur les paquets d'un même pair), la probabilité
que la **tête** de file soit prête au moment où un cœur quelconque finit est de
1/N. À N = 8, **87,5 %** des réveils sont structurellement gaspillés : GRO se
réveille, trouve la tête non déchiffrée, et ressort sans rien livrer.

### 2.2 La modification

```c
struct sk_buff *tail;

atomic_set_release(&PACKET_CB(skb)->state, state);

tail = READ_ONCE(peer->rx_queue.tail);
if (tail == (struct sk_buff *)&peer->rx_queue.empty ||
    atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
        napi_schedule(&peer->napi);
```

On ne réveille GRO que si la file est vide (sécurité) ou si la tête est prête.

### 2.3 Argument de sûreté

Le seul risque serait de rater un réveil. Mais `tail` n'est écrit que par l'unique
consommateur (le poll NAPI). Si un cœur lit « non déchiffré » au moment exact où un
autre rend la tête prête, c'est cet autre cœur qui appellera `napi_schedule`. Aucun
paquet n'est jamais bloqué. La lecture relâchée (`READ_ONCE` / `atomic_read`) est
donc correcte : c'est un indice spéculatif, pas un point de synchronisation.

### 2.4 Limite résiduelle connue

Il existe une fenêtre de timing étroite (entre l'arrêt de GRO en milieu de file et
la remise à zéro de `NAPI_STATE_SCHED`) où un réveil peut être perdu. Ce n'est
**pas** un problème de correction (le paquet est livré au prochain trafic), mais un
effet de second ordre possible sur la latence sous trafic en rafale.

---

## 3. Construction et déploiement du module

| Étape | Commande / fait | Remarque |
|---|---|---|
| Vérifier que WireGuard est un module | `grep CONFIG_WIREGUARD /boot/config-$(uname -r)` → `=m` | recompilation rapide, à chaud |
| En-têtes noyau | `dnf install kernel-16k-devel-…` | `kernel-16k` (pages 16 Ko Asahi), pas `kernel-devel` |
| Source | clone `AsahiLinux/linux -b asahi` | fork Asahi, pas mainline |
| Compilation | `make -C /lib/modules/$(uname -r)/build M=…/wireguard` | piège : clone brut → `asm-offsets.h` manquant ; d'où la compilation contre les en-têtes installés |
| Vérification | `modinfo … | grep vermagic` | doit matcher `uname -r` exactement |
| Chargement | `modprobe udp_tunnel ip6_udp_tunnel libcurve25519` puis `insmod wireguard.ko` | `insmod` ne charge pas les dépendances tout seul |

Aucun plantage, aucun message d'erreur noyau, le module se charge proprement.
Détails complets : `admin/EXPLICATION_SOLUTION_FR.md` et `admin/EXPERIMENTS_2026-05-28.md`.

---

## 4. Méthode de mesure

- **Banc d'essai :** namespaces réseau Linux. Mode multi-pairs = 1 serveur + N
  clients, tous partageant **une seule** file `packet_crypt_wq` côté serveur —
  l'architecture exacte du papier. Trafic via boucle locale (pas de NIC physique).
- **Débit :** `iperf3`, N clients × 4 flux TCP, 30 s.
- **Réveils GRO :** sonde `bpftrace` sur le retour de `wg_packet_rx_poll`
  (la fonction de poll NAPI de WireGuard) :
  - retour = 0 → réveil **gaspillé** (rien livré) ;
  - retour > 0 → réveil **utile**.

---

## 5. Résultats sur M1

### 5.1 Suppression des réveils GRO (le mécanisme)

| Pairs | Réveils totaux/s (stock → corrigé) | Δ total | Δ gaspillés |
|---|---|---|---|
| 1 | 156 378 → 157 072 | +0,4 % | ~0 |
| 8 | 156 891 → 129 518 | **−17,4 %** | −22,0 % |
| 16 | 148 823 → 119 429 | **−19,8 %** | −23,9 % |
| 32 | 139 052 → 119 004 | **−14,4 %** | −15,8 % |
| 64 (moy. 3 runs) | ~173 000 → ~148 000 | **~−14,5 %** | −22,9 % |

Le correctif supprime 14 à 20 % des réveils, et l'effet croît avec le nombre de
pairs (8 → 16 : de 17,4 % à 19,8 %) : plus de pairs = plus de déchiffrement
concurrent = plus de réveils inutiles à supprimer. À 1 pair, aucun effet (pas de
concurrence) — ce qui valide aussi la correction : le correctif ne fait rien quand
il n'y a rien à supprimer.

**Indicateur clé :** le **nombre total** de réveils, pas le pourcentage de
gaspillage. Le correctif empêche le réveil d'avoir lieu plutôt que de le rendre
utile ; l'effet se lit donc sur le total (qui baisse), pas sur le ratio (~29 % dans
les deux cas).

### 5.2 Latence de queue (le résultat le plus net)

À 64 pairs, la latence maximale passe de **~82 ms (stock) à ~43 ms (corrigé)**,
soit ~−47 %, alors que la latence **moyenne** reste identique (3,1 ms). Le correctif
supprime précisément les pics dus aux blocages de GRO, sans toucher au régime
permanent.

### 5.3 Débit

Le débit reste plat (~13 Gbps à 8–32 pairs ; variable et bruité à 48–64 pairs). Une
possible régression de −7,7 % à 48 pairs a été observée sur 3 runs, mais dans un
régime à forte variance — à confirmer statistiquement.

### 5.4 Correction d'une de mes mesures

J'avais d'abord mesuré une baisse de −43,7 % des migrations CPU et l'avais
attribuée aux workers WireGuard. En isolant la sonde sur ces workers précis, j'ai
constaté qu'ils **ne migrent jamais** (épinglés par cœur via `WQ_PERCPU`) : la
baisse venait des autres kworkers du système. La vraie valeur du correctif est sur
les réveils et la latence, pas sur les migrations.

---

## 6. Ce que ces mesures ne permettent pas de conclure

| Condition | Papier (Mounah et al., SYSTOR 2025) | Ma machine |
|---|---|---|
| Carte réseau | NIC 25 Gbps | boucle locale (aucune NIC) |
| Clients | 800–1000 | ≤ 64 |
| Charge CPU | ~94 % sur un cœur (NET_RX softirq) | ~10–15 % |
| Chiffrement | x86 AVX2 | ARM NEON (~10 Go/s/cœur) |

Le gain de débit du papier (×4,7) provient d'une **boucle de saturation** : un cœur
saturé par les réveils inutiles. En boucle locale, le M1 chiffre trop vite pour
saturer ; supprimer 20 % d'un surcoût qui n'est pas le goulot d'étranglement ne
change donc pas le débit. **Conclusion honnête : mécanisme et latence validés, mais
le régime où le correctif est censé aider le débit reste hors de portée sur ma
machine.**

---

## 7. Prochaines étapes — CloudLab

CloudLab (accès via le compte d'Alain, testbed de Teo, 3 machines réservables)
apporte exactement ce qui manque : de vraies cartes réseau et la possibilité de
générer beaucoup de clients réels pour **saturer** le serveur.

1. **Visio avec Teo (mar. 30 mai, matin)** — prise en main CloudLab, montage de
   WireGuard sur les machines, méthode de mesure.
2. **Monter le tunnel WireGuard réel** sur les 3 machines (1 serveur, 2 générateurs
   de trafic, ou selon ce que Teo recommande).
3. **Baseline réelle stock vs corrigé sous saturation** — c'est là qu'on mesure si
   le correctif récupère du débit.
4. **Bonus architecture :** les machines CloudLab sont x86 → comparaison directe
   ARM (M1) vs x86, ce qui répond à la remarque du rapport intermédiaire.
5. **Reproduction du fix du papier** (workqueue dédiée) si le temps le permet, pour
   comparer les trois configurations.

**Articulation avec le rapport final (5 juin) :** si CloudLab donne des chiffres de
débit à temps, ils deviennent la preuve principale ; les mesures M1 restent la
preuve du **mécanisme** (suppression directe des réveils) et du **gain de latence**.
Si CloudLab prend du retard, le rapport s'appuie sur le mécanisme + la latence, en
positionnant CloudLab comme la validation de débit en cours.

---

## 8. Questions pour Alain et André

1. Le diff convient-il en l'état (gestion du STUB, lecture relâchée) ?
2. La limite résiduelle (§2.4) : à documenter dans le rapport, ou hors périmètre ?
3. CloudLab : combien de clients / quelle NIC viser pour reproduire la saturation ?
   Faut-il porter le fix du papier pour comparer les trois configs ?
4. Périmètre du rapport du 5 juin si les chiffres CloudLab n'arrivent pas à temps.
