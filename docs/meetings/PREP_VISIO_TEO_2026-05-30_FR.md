# Préparation visio Teo — CloudLab (30 mai 2026, 15h)

**Lien :** `meet.jit.si/reuProjetCryptOnce`
**Interlocuteur :** Téo Pisenti (doctorant, Toulouse-INP / IRIT / équipe SEPIA)
**But de la réunion :** prise en main de CloudLab + monter WireGuard sur de vraies
machines pour les mesures sous saturation.

---

## 1. Objectif côté Anas (en une phrase)

Obtenir **l'accès** + **un banc de test fonctionnel** sur CloudLab pour comparer
WireGuard d'origine vs corrigé **sous saturation réseau réelle** — le régime que ma
machine M1 (boucle locale) ne peut pas atteindre.

---

## 2. Contexte à donner à Teo (2 min, pour qu'il conseille la bonne config)

- J'étudie un bug de perf dans le module noyau WireGuard : l'**Execution Order
  Inversion** (EoI). Le chemin de réception réveille la couche de livraison (GRO)
  après chaque paquet déchiffré, même quand c'est inutile → un cœur sature, le
  débit s'effondre (papier Mounah et al., SYSTOR 2025 : 19 % de la ligne sur 1000
  clients, 25 Gbps).
- J'ai appliqué un correctif (6 lignes) et mesuré sur ma machine : il supprime
  14–20 % des réveils inutiles et divise ~par 2 la latence de queue. **Mais** le
  M1 en boucle locale ne sature jamais, donc je ne peux pas mesurer l'effet sur le
  **débit**. C'est pour ça qu'il me faut de vraies machines.
- Ce que je dois faire tourner : un **serveur** WireGuard (la cible des mesures),
  des **clients** qui génèrent assez de trafic pour le saturer, et des sondes
  `bpftrace` sur le serveur.

---

## 3. Ce dont mon expérience a besoin (la « checklist matériel »)

| Besoin | Pourquoi |
|---|---|
| 1 serveur + ≥1–2 générateurs de trafic | reproduire 1 serveur saturé par N clients |
| **NIC rapide (idéalement ≥ 25 Gbps)** | le débit doit dépasser ce qu'un cœur peut chiffrer, sinon pas de saturation |
| Accès **root** sur les nœuds | charger un module noyau custom |
| Pouvoir **recompiler/charger un module** WireGuard | déployer la version corrigée (`insmod`) |
| **Sources/headers du noyau** dispo | compiler le module contre le noyau qui tourne |
| `bpftrace` / `perf` fonctionnels (BTF, kprobes) | sonde sur `wg_packet_rx_poll` (réveils gaspillés) |
| `iperf3`, `wireguard-tools` | générer le trafic + monter le tunnel |

---

## 4. Questions à poser à Teo

### A. Accès et compte

1. As-tu le **Project ID** du projet CloudLab pour que je le rejoigne à
   l'inscription (« Join Existing Project ») ? *(Alain devait aussi m'envoyer des
   identifiants — sinon je crée mon compte et je rejoins ton projet.)*
2. Je m'inscris avec mon compte perso + clé SSH, et tu me valides dans le projet ?
   Ou je passe par le compte d'Alain ?

### B. Matériel disponible

3. Combien de machines je peux réserver en même temps (on parlait de 3) ?
4. Quels **types de nœuds** sont dispo, et surtout quelle **vitesse de NIC**
   (10 / 25 / 100 Gbps) ? Combien de cœurs / quelle archi (x86) ?
5. Quelle **topologie réseau** entre les nœuds (lien direct, switch, latence) ?

### C. Réservations

6. Durée max d'une réservation, et est-ce que je peux la **prolonger** jusqu'au
   5 juin (deadline rapport) ?
7. Comment on **instancie** une expérience : profil existant, RSpec, interface web ?
8. Est-ce que tu as **déjà un profil WireGuard / un banc** que je peux réutiliser
   comme point de départ ? *(ça me ferait gagner un temps fou)*

### D. Logiciel sur les nœuds

9. Quelles **images / distributions** dispo (Ubuntu ? version noyau ?), et est-ce
   que je peux **charger un module noyau custom** (ou booter un noyau recompilé) ?
10. `bpftrace` et `perf` marchent-ils sur ces images (BTF activé) ?
11. Comment je **transfère mes fichiers** (mes scripts, le `.ko`) sur les nœuds —
    git, scp, dataset CloudLab ?

### E. Méthode de mesure

12. Pour saturer : tu conseilles plutôt **plusieurs machines clientes**, ou un seul
    client avec beaucoup de flux, ou un générateur dédié (pktgen, TRex…) ?
13. Comment tu mesures le débit/latence habituellement sur ce banc — je peux
    réutiliser tes outils ou je reste sur `iperf3` + `bpftrace` ?


iperf3: Two modes:
- par defaut: upload. clients -> serveur (serveur reçoit, c'est ce qui m'intéresse)
- bombarde le plus possible une connecxion tcp
- monothreadé, saturé par un flux à la fois


leurs setup: 

target -> plusieurs iperf3 servers
server -> wireguard
ideally we want clients ; each client saturates the server with a flow, but iperf3 is single-threaded, so we can only have one flow per client. So we need multiple clients to saturate the server.
to have multiple clients -> multiple namespaces on the same machine, each with its own iperf3 client. This way we can have multiple flows saturating the server from a single machine.

- the namespaces have differnt ips, how does it work with wireguard ?
- wireguard can handle multiple peers, each peer can have multiple allowed ips. So we can set up multiple namespaces, each with its own iperf3 client, and configure wireguard to treat each namespace as a different peer with its own allowed ips. This way we can have multiple flows from the same machine, each treated as a different peer by wireguard.
- we can do NAT on the server side to map different ports to different namespaces, or we can use different IPs for each namespace and configure wireguard accordingly.
- what they did they change the routing table on the target to route traffic to different namespaces based on the destination IPs, and configured wireguard to recognize those IPs as different peers.
- there is a console in cloudlab
brice.ekane@gmail.com
---

## 5. Ce avec quoi je veux repartir (objectifs concrets)

- [ ] Le **Project ID** (ou la confirmation que mon compte est validé).
- [ ] Savoir **combien de machines + quelle vitesse NIC** je peux avoir.
- [ ] Un **profil / banc de départ** (idéalement celui de Teo).
- [ ] Le **workflow** : réserver → instancier → SSH → déployer mon module → mesurer.
- [ ] Confirmation que je peux **charger mon module** + que `bpftrace` marche.
- [ ] Un plan pour monter la **baseline réelle** (stock vs corrigé) dès que possible.

---

## 6. Pour mémoire — ce que j'apporte déjà

- Le module corrigé + le diff (`admin/PATCH_DECRYPT_DELAY.md`,
  `admin/EXPERIMENTS_2026-05-28.md`).
- Tous mes scripts de mesure (`scripts/`) — adaptables des namespaces vers de
  vraies machines (iperf3 multi-clients + sonde bpftrace identique).
- Mes résultats M1 comme preuve du mécanisme.

brice.ekane@gmail.com


---

## 7. Notes de la réunion (à remplir pendant)

**Project ID / accès :**

**Machines dispo (nombre, NIC, cœurs) :**

**Profil / banc à réutiliser :**

**Workflow réservation → instanciation → SSH :**

**OS / noyau / module custom OK ? bpftrace OK ?**

**Conseils de Teo sur la saturation / la mesure :**

**Prochaines étapes convenues :**


-- c220g2 - machine recommeneded by teo - good balance
-- rsync to copy files to the nodes
-- 3 machines : 1 server + 2 clients
