# Préparation réunion — Alain Tchana
# Meeting Prep — Alain Tchana

> FR : Lis ce document une fois avant la réunion. Tu peux y jeter un œil pendant si besoin.
> EN : Read once before the meeting. Glance at it during if needed.

---

## Qui tu vas voir / Who you're meeting

Alain est le responsable de l'équipe KrakOS et l'auteur du papier WireGuard que tu viens de lire. C'est lui qui t'a donné la direction de recherche dès le premier jour. En tant que professeur, il s'attend à ce que tu aies réfléchi aux choses, pas juste lu. Il sera content si tu montres que tu as connecté tes propres expériences aux résultats de son papier.

---

## Ce que tu as fait semaine par semaine / Weekly timeline

### Semaine 1 — 29-31 janvier 2026
- Réunion de lancement avec Alain : reçu le sujet, l'hypothèse de recherche, les ressources
- Début de lecture de *Lord of the io_uring*
- Prise de notes sur les modèles de programmation async et les limites des APIs Linux classiques (select/poll/epoll ne fonctionnent pas pour les fichiers réguliers)

### Semaine 2 — 3-7 février 2026
- Début d'implémentation de code io_uring sur macOS → bloqué immédiatement (`linux/fs.h` absent)
- **Découverte importante :** io_uring est Linux-only, impossible de développer sur macOS
- Recherche et préparation du guide d'installation Fedora Asahi Remix sur MacBook M1 Pro
- Installation de Fedora Asahi Remix en dual-boot sur le M1 Pro

### Semaine 3-4 — février (suite)
- Fin de lecture de *Lord of the io_uring* — architecture complète, SQE/CQE, low-level API
- Installation et vérification de tous les outils : `perf`, `bpftrace`, `strace`, `trace-cmd`, `gcc`

### Semaine de mars 6 — Investigation noyau en direct
- Implémentation de `cat_uring` : lecture de fichier via io_uring brut, sans liburing — 372 lignes C
- Investigation noyau live avec strace + perf stat + bpftrace
- **Résultat clé :** `io_uring_queue_async_work` ne s'est jamais déclenché, même avec un cache froid → `IORING_FEAT_NO_IOWAIT` (kernel 5.18+) : les lectures fichier bufferisées bloquent inline dans `io_uring_enter()`, pas dans io-wq
- Création de `IO_URING_REFERENCE.md` — document de référence structuré
- Mise en place du dépôt GitHub, tout poussé

### Semaine de mars 12 — Article Cloudflare + udp_read.rs
- Lecture complète de l'article Cloudflare *Missing Manuals: io_uring Worker Pool*
- **Résultat clé :** par défaut, les sockets prennent le chemin poll (Path 3), pas les workers — les workers ne se déclenchent qu'avec `IOSQE_ASYNC`
- Reproduction des expériences Cloudflare en Rust : `udp_read.rs`
  - Sans flag : 1 seul thread, 4096 SQEs soumis → zéro worker spawné
  - Avec `--async` : 4097 threads (4096 workers + main)
- Lecture du papier DBMS sur io_uring

### Semaine d'avril 3 — Papier WireGuard (ton papier)
- Lecture complète du papier *"The Impact of Kernel Asynchronous APIs on the Performance of a Kernel VPN"*
- Notes complètes : background KAPIs, pipelines TX/RX WireGuard, mécanisme EoI, patch proposé, évaluation
- **Connexion clé :** le fix workqueue du papier utilise la même infrastructure (`work_struct`, `queue_work_on`) que io-wq d'io_uring — les deux sujets se connectent directement

---

## Ouverture — ce que tu dis si il demande "où t'en es ?"
## Opening line

> « J'ai terminé la phase de lecture. J'ai lu votre papier sur WireGuard, l'article Cloudflare sur le worker pool io_uring, et j'ai mené des expériences pratiques en parallèle — une investigation noyau sur io_uring avec bpftrace et perf, et j'ai reproduit les tests Cloudflare avec `udp_read.rs`. Je comprends maintenant le mécanisme EoI et où se situe exactement le bottleneck. La prochaine étape c'est la reproduction, et pour ça j'ai besoin de l'environnement WireGuard. »

Court, confiant, concret. N'en dis pas plus sauf si il pose des questions.

---

## Tes résultats clés à détailler si demandé
## Key results — be ready to go deep on any of these

### 1. Investigation noyau — `cat_uring` + bpftrace

**Ce que tu as fait :** Implémenté `cat_uring` (io_uring brut, 372 lignes C, aucune liburing), puis instrumenté le kernel pendant l'exécution avec strace, perf et bpftrace.

**Ce que tu as trouvé :**
- `io_uring_queue_async_work` n'a jamais été déclenché — même avec cache froid
- Sur kernel 6.x, `IORING_FEAT_NO_IOWAIT` fait que les lectures fichier bloquent *inline* dans `io_uring_enter()` plutôt que dans io-wq
- **Conséquence :** Le bottleneck workqueue est exclusivement sur le chemin réseau/socket — exactement ce que WireGuard utilise
- Chiffres : 3.7µs cache chaud vs 132µs cache froid (×35.9), 4 changements de contexte + 1 migration CPU pour une seule lecture de 11Ko

### 2. Worker pool io_uring — `udp_read.rs`

**Ce que tu as fait :** Reproduit l'expérience Cloudflare — socket UDP sans paquets entrants, lectures qui ne complètent jamais → on peut compter les workers.

**Ce que tu as trouvé :**
- **Par défaut :** io_uring ne spawne AUCUN worker pour les sockets. Il tente un read non-bloquant → EAGAIN → enregistre un wakeup via `vfs_poll`. Zéro worker même avec 4096 SQEs soumis
- **Avec `IOSQE_ASYNC` :** 4097 threads (4096 workers + thread principal) — un par requête
- **Contrôle optimal :** `IORING_REGISTER_IOWQ_MAX_WORKERS` — limite par thread et par nœud NUMA. `RLIMIT_NPROC` et cgroup `pids.max` causent des boucles de retry qui brûlent un cœur CPU

### 3. Ton papier — ce que tu en as retenu

- **Cause racine EoI :** `spin_unlock_bh` dans le chemin de déchiffrement WireGuard réactive les bottom halves en plein milieu du pipeline → le NAPI/GRO se déclenche avant que le déchiffrement soit terminé
- **Boucle de feedback :** `napi_schedule()` épingle les pollers NAPI sur le cœur où le worker de déchiffrement tournait, sans tenir compte de la charge → un cœur monte à 94%, les autres restent à 20%
- **Le fix :** déplacer GRO de softirq (haute priorité) vers kthreads ou workqueues (priorité normale du scheduler) → alignement des priorités → EoI éliminé
- **Résultats :** workqueues : 4.7× débit, -46% latence / kthreads : 4× débit, -65% latence / TX non affecté dans les deux cas
- **Connexion io_uring :** Le fix workqueue du papier repose sur `work_struct` / `queue_work_on` — exactement la même infrastructure qu'io-wq. Les deux sujets sont liés architecturalement

---

## Ce qu'il pourrait te demander — et comment répondre
## What he might ask — and how to answer

**« Qu'est-ce que tu as retenu du papier ? »**
→ L'EoI. Et le fait que c'est un problème général : n'importe quel pipeline où une étape en aval tourne dans un contexte de priorité plus haute que l'étape en amont peut exhiber ça. Le fix est donc général : aligner les priorités des contextes d'exécution sur tout le pipeline.

**« Pourquoi les workqueues sont meilleures que les kthreads en débit ? »**
→ Pool de threads fixe (1 worker/cœur peu importe le nombre de clients) vs 1 thread par peer. Avec 1000 clients, kthreads = 1000+ threads → overhead scheduling, migrations fréquentes. Workqueues gardent le nombre de threads constant, charge scheduler faible.

**« Et côté io_uring, tu comprends comment ça interagit ? »**
→ io-wq (la workqueue interne d'io_uring) utilise exactement la même infrastructure que le subsystème workqueue Linux — `work_struct`, `queue_work_on`, pool de workers. Le fix du papier et io-wq reposent sur la même base. Ce qu'on apprend sur le sizing du worker pool (article Cloudflare) s'applique directement.

**« T'as eu des surprises ? »**
→ Deux choses. D'abord, que sur les kernels modernes io-wq ne se déclenche plus du tout pour les lectures fichier bufferisées — les articles classiques décrivent un comportement obsolète depuis 5.18. Ensuite, que pour les sockets, le chemin par défaut d'io_uring est le poll, pas les workers — les workers n'apparaissent qu'avec `IOSQE_ASYNC`. Le bottleneck que décrit le papier nécessite donc ce flag ou un chemin bloquant similaire.

**« C'est quoi ta prochaine étape concrète ? »**
→ Reproduire la Figure 1a — le plafond à 4.8 Gbps avec 1000 clients. Pour ça il faut l'environnement de test WireGuard. Une fois que je peux reproduire ce chiffre de manière fiable (<10% de variance), je peux commencer à attribuer l'overhead à des mécanismes spécifiques avec bpftrace.

**« Tu as regardé les articles LWN sur les workqueues ? »**
→ Pas encore — j'ai priorisé les papiers recommandés et l'article Cloudflare. C'est dans ma liste pour après le rapport intermédiaire.

---

## Ce dont tu as besoin — demande ces choses
## What you need — ask for these

**Priorité 1 — Environnement WireGuard**
> « Pour passer à la reproduction, j'aurais besoin d'accéder à l'environnement de test WireGuard. Est-ce que Brice Ekane ou Teo Pisenti peuvent m'aider à le mettre en place ? »

**Priorité 2 — Contact Toulouse**
> « Il y avait mention d'un chercheur à Toulouse avec une suite de benchmarks io_uring — est-ce que vous pouvez me donner ses coordonnées ? »

**Priorité 3 — Rapport intermédiaire**
> « J'ai un rapport intermédiaire à rendre le 27 avril (2 pages, format IJCAI). Est-ce que vous avez des attentes particulières sur ce que je dois couvrir étant donné où j'en suis ? »

**Priorité 4 — Vérification de direction**
> « En lisant votre papier, j'ai vu que le fix workqueue utilise la même infrastructure qu'io-wq d'io_uring. L'angle que vous voulez que j'explore, c'est l'overhead du scheduling workqueue lui-même, ou plutôt la comparaison io_uring vs l'implémentation Go ? »

---

## À ne pas faire / What NOT to do

- Ne t'excuse pas de ne pas avoir de résultats expérimentaux — la phase de lecture était le plan, et elle est faite
- Ne sur-explique pas tout sans qu'on te le demande — réponds à ce qu'on te pose, va plus loin seulement si il pousse
- Ne dis pas "j'ai lu..." cinq fois de suite — cite un ou deux résultats clés, pas une liste de papiers
- Si il te pose une question à laquelle tu ne sais pas répondre : *"Je n'ai pas encore regardé ça, mais je peux le faire"* — ne bluffe pas

---

## Le truc qui va l'impressionner / The one thing that will land

Parle de `spin_unlock_bh` spécifiquement. Ça montre que tu n'as pas juste lu l'abstract — tu as compris le chemin exact dans le code kernel qui déclenche l'EoI. C'est le genre de détail qu'un professeur remarque immédiatement.

---

## Chiffres clés — à savoir par cœur
## Key numbers — know these cold

| Fait / Fact | Chiffre / Number |
|---|---|
| Débit RX WireGuard à 1000 clients | 4.8 Gbps = 19.2% des 25 Gbps disponibles |
| Gain débit — workqueues | **4.7×** |
| Gain débit — kthreads | 4× |
| Réduction latence — kthreads | 65% tail latency |
| Réduction latence — workqueues | 46% tail latency |
| Cœur surchargé | ~94% (softirq) |
| Autres cœurs | ~20% |
| Taille du patch | 136 LoC NAPI + 55 LoC WireGuard |
| Lecture io_uring cache chaud | 3.7µs |
| Lecture io_uring cache froid | 132µs (×35.9) |
| Changements de contexte (1 lecture froide) | 4 ctx switches + 1 migration CPU |

---

## Après la réunion / After the meeting

- Envoie un email de suivi résumant ce qui a été décidé (contacts, prochaines étapes)
- Mets à jour le tracker avec les nouvelles infos / contacts obtenus
- Lance-toi sur le rapport intermédiaire dès que possible — deadline TWS : **14 avril**, deadline internship : **27 avril**
