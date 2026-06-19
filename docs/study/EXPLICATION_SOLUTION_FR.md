# Comment on a appliqué et testé le correctif WireGuard — explication détaillée

**But de ce document :** expliquer, étape par étape et en langage clair, tout ce
qui a été fait pour appliquer la solution d'André, recompiler WireGuard, charger
le module corrigé dans le noyau, et mesurer son effet. Chaque commande est
accompagnée de **ce qu'elle fait et pourquoi**, pour pouvoir briefer Alain sans
zone d'ombre.

**Machine :** MacBook M1 Pro, Fedora Asahi Remix 44, noyau
`6.19.13-400.asahi.fc44.aarch64+16k`.

---

## 0. Le problème en une phrase

Quand WireGuard reçoit des paquets chiffrés, il les déchiffre en parallèle sur
plusieurs cœurs CPU, puis les remet dans l'ordre avant de les livrer au système.
Le bug (« Execution Order Inversion », EoI) : après **chaque** paquet déchiffré,
le code réveille la couche de livraison (GRO) — même quand le paquet en tête de
file n'est pas encore prêt. Résultat : la couche de livraison se réveille pour
rien dans la grande majorité des cas, ce qui gaspille du CPU.

**Le correctif d'André :** avant de réveiller la couche de livraison, on vérifie
si le paquet en tête de file est prêt. S'il ne l'est pas, on ne réveille rien.
6 lignes de code.

---

## 1. C'est quoi un « module noyau » et pourquoi WireGuard en est un ?

Le **noyau Linux** (« kernel ») est le programme central qui gère le matériel, la
mémoire, le réseau, etc. Il y a deux façons d'y ajouter du code :

- **Intégré (« built-in »)** : le code fait partie du noyau au moment où on
  compile le noyau entier. Pour le modifier, il faut recompiler tout le noyau
  (long) et redémarrer.
- **Module (« loadable module »)** : un fichier `.ko` séparé qu'on peut
  **charger et décharger à chaud**, sans redémarrer. C'est comme un plugin.

WireGuard est compilé en **module** sur notre Fedora. On l'a vérifié :

```bash
grep CONFIG_WIREGUARD /boot/config-$(uname -r)
# CONFIG_WIREGUARD=m   ←  "m" = module (et non "y" = built-in)
```

> **Pourquoi c'est une bonne nouvelle ?** Parce qu'on peut recompiler **uniquement
> WireGuard** (quelques secondes) au lieu du noyau entier (30–40 min sur M1), et
> le remplacer à chaud. C'est tout l'intérêt : on itère vite.

`uname -r` affiche la version exacte du noyau en cours d'exécution. Le `+16k`
indique que le noyau Asahi utilise des pages mémoire de 16 Ko (spécificité Apple
Silicon). **Important :** un module doit être compilé pour **exactement** cette
version, sinon il refuse de se charger.

---

## 2. Ce que le correctif change dans le code (et pourquoi)

Le fichier modifié est `drivers/net/wireguard/queueing.h`, fonction
`wg_queue_enqueue_per_peer_rx`. C'est la fonction appelée par chaque cœur juste
après qu'il a fini de déchiffrer un paquet.

**Avant (code d'origine) :**

```c
atomic_set_release(&PACKET_CB(skb)->state, state);  // marque le paquet "déchiffré"
napi_schedule(&peer->napi);                          // réveille GRO — TOUJOURS
```

`napi_schedule(...)` = « réveille la couche de livraison ». Le problème : c'est
fait **inconditionnellement**, après chaque paquet.

**Après (correctif d'André) :**

```c
atomic_set_release(&PACKET_CB(skb)->state, state);   // marque le paquet "déchiffré"

tail = READ_ONCE(peer->rx_queue.tail);               // regarde le prochain paquet à livrer
if (tail == (struct sk_buff *)&peer->rx_queue.empty ||      // file vide → on réveille par sécurité
    atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)  // tête prête → on réveille
        napi_schedule(&peer->napi);
// sinon : la tête n'est pas prête → on ne réveille rien (c'est le gain)
```

En clair : **« ne réveille la livraison que si elle a une chance de faire quelque
chose »**. Si le paquet en tête de file est encore en cours de déchiffrement, GRO
ne pourrait rien livrer de toute façon — donc on évite de le réveiller pour rien.

**Pourquoi c'est sûr (l'argument à donner à Alain) :** le seul risque serait de
« rater » un réveil. Mais si un cœur lit « pas prêt » au moment précis où un autre
cœur rend la tête « prête », alors **c'est cet autre cœur** qui fera le réveil.
Aucun paquet n'est jamais bloqué. C'est pour ça que `READ_ONCE`/`atomic_read`
(lecture simple, sans verrou) suffisent : on lit juste un indice, pas une donnée
critique.

---

## 3. Compiler le module corrigé

Compiler = transformer le code source (`.c`, `.h`, lisible par l'humain) en
fichier binaire (`.ko`, exécutable par le noyau). Voici les étapes réelles.

### 3.1 Installer les en-têtes du noyau

Pour compiler un module, le compilateur a besoin des **en-têtes** (« headers ») du
noyau : des fichiers qui décrivent les structures et fonctions internes du noyau.
Sur Asahi, le paquet s'appelle `kernel-16k-devel` (et non `kernel-devel`, à cause
des pages 16 Ko) :

```bash
sudo dnf install -y kernel-16k-devel-6.19.13-400.asahi.fc44.aarch64
```

### 3.2 Récupérer le code source de WireGuard

Fedora Asahi utilise une **version dérivée** du noyau (le fork AsahiLinux), pas le
noyau « mainline » officiel. On clone donc ce dépôt précis :

```bash
git clone https://github.com/AsahiLinux/linux.git --depth=1 -b asahi
```

`--depth=1` = on ne télécharge que la dernière version, sans tout l'historique
(~1 Go au lieu de ~4 Go). Le code de WireGuard est dans
`linux/drivers/net/wireguard/`.

### 3.3 Appliquer le correctif

On édite `linux/drivers/net/wireguard/queueing.h` pour y mettre les 6 lignes du
§2. Vérification après édition :

```bash
grep -n "READ_ONCE\|rx_queue.tail\|UNCRYPTED" linux/drivers/net/wireguard/queueing.h
```

### 3.4 Lancer la compilation (et le piège qu'on a rencontré)

**Première tentative — qui a échoué :**

```bash
cd linux
make -j$(nproc) M=drivers/net/wireguard
# Erreur : missing argument to '-mstack-protector-guard-offset='
```

**Pourquoi ça a échoué :** compiler depuis un dépôt fraîchement cloné ne marche
pas, parce qu'un fichier généré (`asm-offsets.h`) n'existe que si on a déjà
compilé le noyau entier au moins une fois. Ce fichier manquait.

**La solution :** on s'appuie sur les en-têtes **déjà installés** (§3.1), qui eux
contiennent ce fichier. On dit au compilateur : « utilise les en-têtes installés
(`-C ...`), mais compile le code WireGuard qui est dans ce dossier (`M=...`) » :

```bash
make -C /lib/modules/$(uname -r)/build \
    M=$HOME/.../Io-uring-Internship/linux/drivers/net/wireguard
```

- `-C /lib/modules/$(uname -r)/build` = « va chercher l'infrastructure de
  compilation du noyau **en cours d'exécution** » (un lien vers les en-têtes
  installés).
- `M=.../wireguard` = « le module à compiler est dans ce dossier ».

Résultat : un fichier `wireguard.ko` (~7,6 Mo). On vérifie qu'il correspond bien
au noyau en cours :

```bash
modinfo linux/drivers/net/wireguard/wireguard.ko | grep vermagic
# vermagic: 6.19.13-400.asahi.fc44.aarch64+16k ...   ← doit être identique à `uname -r`
```

Le **`vermagic`** est une « signature de version ». Si elle ne correspond pas au
noyau, le chargement est refusé. C'est un garde-fou.

---

## 4. Charger le module dans le noyau

### 4.1 Décharger l'ancien, charger le nouveau

```bash
sudo rmmod wireguard       # décharge le module actuel (s'il est chargé)
sudo insmod linux/drivers/net/wireguard/wireguard.ko   # charge NOTRE version
```

- `rmmod` = « remove module » (décharger).
- `insmod` = « insert module » (charger un fichier `.ko` précis).
- `modprobe` = variante plus intelligente qui charge aussi automatiquement les
  modules dont dépend celui qu'on charge (voir ci-dessous).

### 4.2 Le piège des dépendances

`insmod` a d'abord échoué avec « Unknown symbol in module ». WireGuard a besoin
d'autres modules pour fonctionner (tunnels UDP, courbe cryptographique
Curve25519). `insmod` ne les charge **pas** automatiquement, contrairement à
`modprobe`. On les a donc chargés à la main :

```bash
sudo modprobe udp_tunnel ip6_udp_tunnel libcurve25519
sudo insmod linux/drivers/net/wireguard/wireguard.ko
```

Vérification que tout est en place :

```bash
lsmod | grep wireguard        # liste les modules chargés
journalctl -k | grep wireguard
# wireguard: WireGuard 1.0.0 loaded.   ← message du noyau confirmant le chargement
```

> **À retenir pour Alain :** charger le module « stock » (d'origine) = un simple
> `modprobe wireguard`. Charger notre version corrigée = `insmod` du `.ko` qu'on a
> compilé, après avoir chargé ses dépendances. Les scripts `load_stock.sh` et
> `load_patched.sh` automatisent ce basculement.

---

## 5. Le banc d'essai : les « namespaces réseau »

Pour mesurer WireGuard il faut un tunnel entre deux machines. Comme on n'a qu'une
seule machine, on utilise les **namespaces réseau** (« network namespaces ») de
Linux.

**Analogie :** un namespace réseau, c'est une « machine virtuelle réseau » très
légère à l'intérieur de la même machine — sa propre carte réseau, ses propres
adresses IP, isolée du reste. On en crée deux (ou plus) et on monte un vrai tunnel
WireGuard **entre eux**, sur la même machine. Le trafic passe par la boucle locale
(loopback, `127.0.0.1`), donc aucune carte réseau physique n'est nécessaire.

### 5.1 Cas simple : un tunnel à deux extrémités

```
ns1 (10.0.0.1) ←──── tunnel WireGuard ────→ ns2 (10.0.0.2)
```

`scripts/setup_tunnel.sh` fait, en résumé :

```bash
sudo ip netns add ns1                  # crée le namespace ns1
sudo ip netns add ns2                  # crée le namespace ns2
sudo ip link add wg1 type wireguard    # crée une interface WireGuard
sudo ip link set wg1 netns ns1         # la place dans ns1
# ... génère les clés, configure les pairs, les adresses IP, active les interfaces
```

### 5.2 Cas « multi-pairs » : reproduire le scénario du papier

Le bug n'apparaît vraiment qu'avec **beaucoup de clients** qui partagent **une
seule file de déchiffrement** côté serveur (c'est l'architecture du papier
Mounah et al.). `scripts/setup_multipeer.sh N` crée donc 1 serveur + N clients :

```
ns_mp_client_0  ─╮
ns_mp_client_1  ─┤
...              ┤──→  ns_mp_server   (N pairs, UNE seule file packet_crypt_wq)
ns_mp_client_N  ─╯
```

C'est ça qui fait travailler plusieurs cœurs en parallèle sur les paquets d'un
même pair — la condition exacte qui déclenche l'EoI.

---

## 6. Mesurer : iperf3 et bpftrace

On veut deux choses : (1) le débit, (2) le nombre de réveils « gaspillés ».

### 6.1 iperf3 — mesurer le débit

`iperf3` est l'outil standard pour mesurer un débit réseau. Un côté est
« serveur » (`-s`), l'autre « client » (`-c`) qui envoie du trafic :

```bash
# serveur dans ns2
sudo ip netns exec ns2 iperf3 -s
# client dans ns1 : 8 flux en parallèle, pendant 30 s
sudo ip netns exec ns1 iperf3 -c 10.0.0.2 -t 30 -P 8
```

`ip netns exec ns1 <commande>` = « exécute cette commande **à l'intérieur** du
namespace ns1 ». Le résultat clé est le débit (Gbps).

### 6.2 bpftrace — compter les réveils gaspillés

`bpftrace` permet d'**observer le noyau en direct** sans le modifier : on accroche
une sonde sur une fonction et on compte les appels. C'est l'outil qui prouve que
le bug existe et que le correctif agit.

On surveille la fonction de livraison `wg_packet_rx_poll`. Sa **valeur de retour**
indique combien de paquets ont été livrés :

- retour `= 0` → réveil **gaspillé** (rien à livrer).
- retour `> 0` → réveil **utile** (au moins un paquet livré).

```bash
sudo bpftrace -e '
  kretprobe:wg_packet_rx_poll /retval == 0/ { @gaspilles += 1; }
  kretprobe:wg_packet_rx_poll /retval > 0/  { @utiles += 1; }
  interval:s:1 { printf("%lld %lld\n", @gaspilles, @utiles); @gaspilles=0; @utiles=0; }
'
```

- `kretprobe:wg_packet_rx_poll` = « accroche-toi à la **sortie** de cette
  fonction » (kret = kernel return).
- `/retval == 0/` = filtre sur la valeur de retour.
- `interval:s:1` = affiche un compte toutes les secondes.

**Le verdict de la mesure :** sur le module d'origine, ~24–32 % des réveils sont
gaspillés. Sur le module corrigé, le **nombre total de réveils** baisse de 14 à
20 % (on en supprime carrément, au lieu de les exécuter à vide).

---

## 7. Résumé pour briefer Alain (l'essentiel)

1. **Le problème :** WireGuard réveille la couche de livraison (GRO) après chaque
   paquet déchiffré, même quand c'est inutile → CPU gaspillé. C'est l'EoI.
2. **Le correctif :** 6 lignes dans `queueing.h` — on ne réveille que si le paquet
   en tête de file est prêt. Prouvé sûr (pas de paquet bloqué).
3. **WireGuard est un module noyau** (`.ko`), donc on le recompile en quelques
   secondes et on le remplace à chaud, sans toucher au reste du noyau.
4. **Compilation :** on s'appuie sur les en-têtes installés (`kernel-16k-devel`),
   pas sur un clone brut (qui manquait `asm-offsets.h`). Le `vermagic` doit
   correspondre au noyau en cours.
5. **Chargement :** `insmod` du `.ko` après avoir chargé ses 3 modules dépendants.
6. **Banc d'essai :** des namespaces réseau simulent plusieurs machines sur une
   seule ; le mode « multi-pairs » reproduit le scénario du papier.
7. **Mesure :** `iperf3` pour le débit, `bpftrace` pour compter les réveils
   gaspillés vs utiles.
8. **Résultat à ce stade :** le correctif fonctionne (−14 à −20 % de réveils, et
   latence de queue ~divisée par 2 à fort nombre de pairs), mais le débit ne bouge
   pas car notre machine ne peut pas être saturée en boucle locale (le M1 chiffre
   trop vite). C'est pour ça qu'on durcit maintenant les mesures (contrôle de la
   variance, métriques directes, et un essai où l'on ralentit artificiellement le
   déchiffrement pour reproduire la saturation du papier).

---

## 8. Glossaire express

| Terme | Signification simple |
|---|---|
| Noyau (kernel) | Le cœur de Linux qui gère matériel, mémoire, réseau |
| Module / `.ko` | Bout de code noyau chargeable à chaud (comme un plugin) |
| `insmod` / `rmmod` / `modprobe` | Charger / décharger / charger-avec-dépendances un module |
| `vermagic` | Signature de version d'un module ; doit matcher le noyau |
| en-têtes (headers) | Fichiers décrivant l'intérieur du noyau, nécessaires pour compiler |
| GRO | Couche qui regroupe et livre les paquets reçus au système |
| `napi_schedule` | La fonction qui « réveille » GRO |
| softirq | Tâche noyau de haute priorité (GRO tourne ainsi) |
| workqueue | File de travaux exécutés par des threads noyau (le déchiffrement) |
| EoI | Le bug : réveils de GRO inutiles à cause de l'ordre de déchiffrement |
| namespace réseau | « Mini-machine » réseau isolée dans la même machine |
| iperf3 | Outil de mesure de débit réseau |
| bpftrace | Outil d'observation du noyau en direct (sondes) |

----
meeting with Alain

- got to talk to TEO , and he said they have a setup of wireguard where they can reserve 3 machines , and run wireguard on them, and do the measurements there. 
- I will need to use cloudlab to do that, Alain said he will give me access to his account on cloudlab,  and that way it will be faster to get access.
- So he put me in contact with TEO, and we agreed to have a visio meeting tomorrow morning (have to verify what time) , so he can explain to me how to use cloudlab, and how to set up wireguard on the machines, and do the measurements there.
- Alain said to also present the code changes to him and André on Monday, so I will prepare a presentation for that, and I will also prepare a report on the code changes, and the measurements I did on my machine, and the results I got, and the next steps I will take to do the measurements on cloudlab.