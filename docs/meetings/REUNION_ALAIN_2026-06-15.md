# Réunion avec Alain — lundi 15 juin, 14h

> Notes pour la réunion. Objectif : se mettre d'accord sur **ce que je mesure** et
> **comment**, pour pouvoir provisionner le banc CloudLab et commencer
> l'instrumentation cette semaine.
> Le détail complet est dans `CLOUDLAB_MEASUREMENT_PLAN.md` — ici c'est la version
> « parlée », avec les rappels.

---

## 0. Rappel — où on en est

- **Soutenance faite le 10 juin** : ça s'est très bien passé, bons retours sur le
  rapport et la présentation. La phase notée est terminée.
- **Nouvelle direction (toi, le 12 juin)** : on ne se précipite **pas** pour
  benchmarker la correction actuelle comme si c'était la solution finale. La
  priorité, c'est d'**améliorer** la solution (vers un *déclencheur conscient du
  batching*). Pour ça il faut d'abord **mesurer** — combien coûte *chaque étape*
  du chemin de réception. Le benchmark de débit sur NIC saturé viendra **après**.
- **Compte CloudLab approuvé**, projet **WG**. L'ancien banc de Teo n'est plus
  accessible → on crée le nôtre.

## 1. Rappel — le bug et la correction (en deux phrases)

- **Le bug (Execution Order Inversion).** Le déchiffrement se fait en parallèle sur
  N cœurs, donc les paquets se terminent **dans le désordre**. Mais le code
  réveille la NAPI après *chaque* paquet déchiffré (`napi_schedule`
  inconditionnel). Comme la livraison est ordonnée (on vide la file par la tête),
  la plupart des réveils trouvent la tête encore chiffrée → **poll à vide**, GRO
  ne peut rien agréger, le batching s'effondre.
- **La correction (6 lignes).** Avant de réveiller la NAPI, on vérifie si la tête
  de la file par-pair est prête ; sinon on saute le réveil — le worker qui finira
  la tête s'en chargera.

```c
tail = READ_ONCE(peer->rx_queue.tail);
if (tail == (struct sk_buff *)&peer->rx_queue.empty ||
    atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
        napi_schedule(&peer->napi);     // sinon : on saute
```

## 2. Rappel — à quoi ressemble le pipeline de réception

Chemin d'un paquet de données (après handshake), fichiers dans
`linux-source/drivers/net/wireguard/` :

```
  [1] wg_packet_receive              receive.c:542   ─ le datagramme UDP entre dans WG
       │
  [2] wg_packet_consume_data         receive.c:509   ─ double enqueue : file ordonnée
       │   (queue_work_on → packet_crypt_wq)              par-pair  +  file de déchiffrement
       ▼
  [3] wg_packet_decrypt_worker       receive.c:493   ─ DÉCHIFFREMENT ChaCha20-Poly1305
       │   decrypt_packet            receive.c:501       (1 worker/cœur → fin dans le désordre)
       │
  [4] napi_schedule(&peer->napi)     queueing.h:196  ─ LE DÉCLENCHEUR
       │                                                 (inconditionnel = le bug ;
       ▼                                                  conditionnel = notre fix)
  [5] wg_packet_rx_poll              receive.c:438   ─ POLL : vide la file par la tête,
       │   (test tête :451-453,                          s'arrête au 1er UNCRYPTED,
       │    napi_complete_done :488)                      renvoie work_done
       ▼
  [6] napi_gro_receive               receive.c:411   ─ GRO : agrège les paquets déchiffrés
       │
  [7] napi_complete_done → flush GRO ─ remontée de la pile → copie vers l'espace utilisateur
```

File de déchiffrement = `packet_crypt_wq`,
`WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM | WQ_PERCPU` (`device.c:346`) — un worker par
cœur, d'où les fins de déchiffrement dans le désordre.

## 3. Rappel — ce que les mesures M1 ont montré

Banc M1 Pro (ARM, loopback, 5 runs) :

| pairs | polls à vide (stock → patché) | taille batch GRO | Δ gaspillé |
|------:|:-----------------------------:|:----------------:|:----------:|
| 1  | 42 638 → 38 872 | 3,1 → 3,3 | −8,8 %  |
| 8  | 64 318 → 50 217 | 8,7 → 9,6 | **−21,9 %** |
| 32 | 64 987 → 51 553 | 7,7 → 8,9 | **−20,7 %** |

→ La réduction **grandit avec le nombre de pairs** (cohérent avec le modèle 1/N),
et la **taille de batch monte** : GRO est réveillé moins souvent mais livre plus à
chaque fois. **Le débit est plat** sur loopback : le softirq ne sature jamais. D'où
le besoin d'un **vrai NIC** sur CloudLab.

---

## 4. L'objectif de cette phase, en une ligne

Construire le **modèle de coût du chemin de réception** — combien de temps prend
*chaque étape* — pour concevoir le **déclencheur conscient du batching** à partir
de vrais chiffres, pas d'un seuil deviné.

## 5. Ce que je veux faire

1. **Monter un vrai banc** sur CloudLab (projet WG) : un nœud bare-metal x86 avec
   un vrai NIC 10 G comme **machine sous test (DUT)**, plus un générateur de charge.
   Le loopback du M1 ne saturait pas le softirq → il me faut du trafic NIC réel.
2. **Reproduire l'EoI hors loopback** à faible nombre de pairs (1→32) pour
   confirmer que le pic de polls à vide apparaît sur du matériel serveur.
3. **Instrumenter chaque étape** du chemin et en extraire cinq grandeurs :
   - `C_poll` — coût fixe d'un passage de poll (l'overhead qu'un réveil doit justifier)
   - `C_deliver` — coût de traiter un paquet de plus *dans* le poll
   - `C_stack` — ce que le batching GRO **économise** par paquet (le bénéfice)
   - `T_decrypt` — temps de déchiffrement d'un paquet
   - `Δ_complete` — écart entre deux fins de déchiffrement successives
4. **En déduire la règle du déclencheur** : réveiller seulement quand le bénéfice
   attendu du batch `(k−1)·C_stack` dépasse l'overhead `C_poll` plus la latence
   d'attente. Puis prototyper et re-mesurer.

## 6. Comment — concrètement (le détail méthodo)

Tout tourne sur le `dut`. Outil principal : **bpftrace**, avec agrégation
**en noyau** (maps/histogrammes) plutôt que dump par événement, pour ne pas fausser
les temps mesurés. Recoupement avec **perf**. Chaque grandeur du modèle de coût a
sa sonde dédiée.

### 6.0 Préalable — vérifier les symboles sondables

Certaines fonctions du module sont `static` et peuvent être **inlinées** (donc pas
de symbole kprobe). Avant tout, sur le `dut` :

```bash
sudo bpftrace -l 'kprobe:*wg_packet*'      # worker, poll, receive, consume...
sudo bpftrace -l 'kprobe:*decrypt*'        # decrypt_packet visible ? sinon inliné
grep -E 'wg_packet_rx_poll|decrypt_packet|napi_gro_receive' /proc/kallsyms
```

- Si `decrypt_packet` est inliné → on sonde la **frontière du worker**
  `wg_packet_decrypt_worker` (receive.c:493) à la place, qui englobe le
  déchiffrement, et/ou on recompile le module avec `noinline` sur `decrypt_packet`
  le temps de la mesure.
- `wg_packet_rx_poll` (receive.c:438) et `napi_gro_receive` (receive.c:411) sont
  des symboles exportés/visibles → OK directement.

### 6.1 Banc & génération de charge

- **Topologie** `gen ──10G── dut`. WireGuard configuré côté `dut` (récepteur,
  instrumenté) ; le `gen` pousse du trafic chiffré vers lui.
- **N pairs sans N clients physiques** : sur `gen`, N **espaces de noms réseau**,
  chacun = un pair WireGuard (sa keypair, ses allowed-ips), tous routés vers
  l'unique tunnel-récepteur du `dut`. C'est exactement la méthode du banc M1
  (`scripts/setup_multipeer.sh`), portée du loopback au lien réel.
- **Charge** : `iperf3` (et/ou un flood UDP) depuis chaque namespace, dimensionné
  pour pousser le chemin de réception du `dut` vers la saturation du softirq.

### 6.2 A/B stock vs patché

Les deux `.ko` côte à côte, on bascule entre chaque run (scripts déjà présents :
`scripts/load_stock.sh`, `scripts/load_patched.sh`) :

```bash
sudo rmmod wireguard; sudo insmod ./wireguard_stock.ko     # ou _patched.ko
# (re)configurer wg0, relancer la charge, attacher la même sonde
```

Chaque mesure ci-dessous est prise **pour les deux modules**, ≥5 runs, on rapporte
médiane + dispersion.

### 6.3 Les sondes, une par grandeur

**(a) `T_decrypt` — temps de déchiffrement d'un paquet**
```c
kprobe:decrypt_packet        { @start[tid] = nsecs; }            // ou wg_packet_decrypt_worker
kretprobe:decrypt_packet /@start[tid]/ {
    @T_decrypt = hist(nsecs - @start[tid]);                      // histogramme ns
    delete(@start[tid]);
}
```

**(b) `Δ_complete` — écart entre deux fins de déchiffrement, par pair**
La fin de déchiffrement réveille la NAPI via `wg_queue_enqueue_per_peer_rx`
(receive.c:503). On horodate par pair (pointeur `peer` en argument) :
```c
kprobe:wg_queue_enqueue_per_peer_rx {
    $peer = arg0;                                                // confirmer l'index d'arg
    if (@last[$peer]) { @delta_complete = hist(nsecs - @last[$peer]); }
    @last[$peer] = nsecs;
}
```

**(c) `C_poll` et `C_deliver` — d'un seul coup, via la durée du poll par `work_done`**
C'est la sonde centrale. On mesure la **durée** de `wg_packet_rx_poll` et on la
**range par valeur de retour** (`work_done` = nb de paquets livrés) :
```c
kprobe:wg_packet_rx_poll  { @s[tid] = nsecs; }
kretprobe:wg_packet_rx_poll /@s[tid]/ {
    $dur = nsecs - @s[tid];
    @workdone = lhist(retval, 0, 64, 4);          // distribution de work_done (pic à 0 = EoI)
    @poll_dur[retval] = hist($dur);               // durée séparée pour chaque work_done
    @sum_dur[retval]  = sum($dur);                // pour la régression
    @cnt[retval]      = count();
    delete(@s[tid]);
}
```
- `@poll_dur[0]` (durée quand `work_done==0`) = **`C_poll`** : un poll qui ne livre
  rien, donc coût fixe pur.
- **`C_deliver`** = pente de la durée en fonction de `work_done` : on régresse
  `@sum_dur[k]/@cnt[k]` sur `k` (durée moyenne vs nb de paquets). L'ordonnée à
  l'origine recoupe `C_poll`, la pente donne `C_deliver`.

**(d) `C_stack` — le bénéfice du batching GRO**
Ce que GRO économise par paquet en partageant une traversée de pile + une copie.
Deux angles, on croise :
```c
kprobe:napi_gro_receive   { @g[tid] = nsecs; }
kretprobe:napi_gro_receive /@g[tid]/ {
    @gro_cost = hist(nsecs - @g[tid]); delete(@g[tid]);
}
// taille de batch : nb d'appels napi_gro_receive entre deux napi_complete_done
kprobe:napi_gro_receive    { @gro_in_batch = count(); }
kprobe:napi_complete_done  { @batch = hist(@gro_in_batch); @gro_in_batch = 0; }
```
- Le coût *agrégé* de la remontée de pile (flush GRO → IP/UDP → copie userspace) se
  voit mieux au **flamegraph perf** (cf. 6.4) : `C_stack` ≈ coût par paquet de ce
  segment quand le batch=1, qui est justement ce que le batching amortit.

**(e) La signature EoI (sanity de la phase B)**
`@workdone` ci-dessus suffit : un **pic au bucket 0** = polls à vide. Patché vs
stock, le bucket 0 doit s'effondrer et la masse glisser vers >1 (comme sur M1).

### 6.4 perf & système (recoupement)

```bash
sudo perf stat -a -C <cœur_softirq> -e cycles,instructions,cache-misses -- sleep 10
sudo perf record -a -g -C <cœur_softirq> -- sleep 10 && sudo perf report   # flamegraph du softirq
mpstat -P ALL 1                                                            # voir LE cœur saturé
```
- Confirme la **saturation mono-cœur** du `NET_RX_SOFTIRQ`, et **où** partent les
  cycles (déchiffrement vs poll vs pile) — recoupe `C_poll`/`C_stack`.

### 6.5 Comment je sors chaque chiffre (récap)

| Grandeur | Source directe | Dérivation |
|----------|----------------|-----------|
| `T_decrypt` | `@T_decrypt` (6.3a) | médiane de l'histogramme |
| `Δ_complete` | `@delta_complete` (6.3b) | médiane par pair |
| `C_poll` | `@poll_dur[0]` (6.3c) | durée du poll à vide |
| `C_deliver` | `@sum_dur/@cnt` vs `work_done` (6.3c) | pente de la régression |
| `C_stack` | `@gro_cost` + flamegraph perf (6.3d, 6.4) | coût/paquet du segment pile, batch=1 |
| signature EoI | `@workdone` (6.3e) | pic au bucket 0, stock vs patché |

### 6.6 Rigueur — ne pas fausser ce qu'on mesure

- **Agrégation en noyau** (maps), jamais de `printf` par événement sur le chemin chaud.
- **Run de contrôle d'overhead** : même charge, sondes **attachées mais sur une
  fonction froide** vs **détachées** → quantifie le biais des sondes lui-même.
- **Épingler** la charge et lire **par cœur** pour isoler le cœur softirq.
- Mesures **stock ET patché** systématiquement, pour que tout soit comparé à
  iso-conditions.

## 7. Ce qui est déjà fait (à montrer)

- Compte CloudLab approuvé ; **profil `wg-recv-measure` créé et validé** sous le
  projet WG (geni-lib parse, la topologie s'affiche). Versionné dans le repo :
  `scripts/cloudlab/profile.py`.
- Chemin de réception cartographié au `fichier:ligne` près (worker de
  déchiffrement, le déclencheur `queueing.h:196`, le poll, GRO) → table
  d'instrumentation prête.
- Baseline M1 disponible comme point de comparaison (−9 à −22 % de polls à vide).

→ Je suis à **un clic** (Instantiate) d'un nœud vivant ; j'ai attendu qu'on
s'aligne aujourd'hui avant de lancer.

## 8. Décisions dont j'ai besoin de ta part

1. **Nœud / cluster.** J'ai pris `c220g2` (Wisconsin, 20c/40t, X520 10 GbE) pour
   coller au setup de Teo. OK, ou tu préfères un nœud plus gros / 25–100 G
   (`c6525`, `d6515`) ? Et est-ce qu'on veut un **nœud ARM** pour la question
   x86↔ARM du rapport ?
2. **Échelle de pairs pour la *mesure*.** 1→32 (puis 128) suffit pour bâtir le
   modèle de coût, ou tu veux que je pousse vers ~1 000 dès maintenant ? (1 000,
   c'est plutôt une question de *benchmark*, qu'on a justement reportée.)
3. **Périmètre du modèle de coût.** Ces cinq grandeurs sont le bon ensemble, ou tu
   veux aussi instrumenter le côté chiffrement/TX ou le handshake ?
4. **Forme du déclencheur.** Une préférence a priori — seuil en nombre `k`, borne
   de temps `τ`, ou adaptatif — ou on laisse les données décider ?
5. **Méthode de sonde.** OK avec bpftrace/BTF, ou tu veux des compteurs intégrés au
   module pour le chemin chaud, par prudence sur l'overhead ?

## 9. Ce que je fais juste après la réunion

Instancier le nœud convenu → builder les modules stock + patché → lancer la
**phase B** (reproduire le pic de polls à vide sur le vrai NIC). C'est le point de
décision avant d'investir dans le modèle de coût complet.
**Cible : banc vivant + EoI reproduit cette semaine.**
