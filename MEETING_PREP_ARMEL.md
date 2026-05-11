# Préparation réunion — Armel NGUETOUM

> PhD KrakOS, spécialiste io_uring / workqueues. On se connaît déjà. Échange informel.

---

## Contexte à lui donner au début (2 minutes max)

Armel sait ce qu'est io_uring et les workqueues, mais pas ce sur quoi tu bosses exactement.

**Ce que tu lui dis :**
> Je travaille sur WireGuard — pourquoi il est beaucoup plus lent que l'implémentation Go en réception. Le problème c'est une collision de priorités : GRO tourne en softirq (haute priorité) et finit par préempter les workers de déchiffrement WireGuard qui sont dans une workqueue (priorité normale). Le GRO se déclenche avant que le déchiffrement soit fini, trouve rien, abandonne. Plus tard il traite un gros backlog sur un seul cœur à 94% pendant que les autres sont à 20%. Et ça se répète en boucle.

Ne pas utiliser le terme "EoI" — il ne connaît pas. Décris juste le mécanisme.

---

## Questions à poser

### 1. Comportement du work item après préemption
> Quand un softirq préempte un worker de workqueue en plein milieu d'une tâche — le work item reprend sur le même cœur ou il peut migrer ?

Ce que tu veux savoir : est-ce que la préemption empire le problème de cache locality en plus du problème de priorité ?

---

### 2. Priorité des workqueues
> Y'a un moyen de donner plus de priorité à une workqueue pour éviter ce genre de préemption par les softirqs ?

Ce que tu veux savoir : est-ce que `WQ_HIGHPRI` ou un mécanisme similaire peut aider, ou est-ce que les softirqs préemptent toujours quoi qu'il arrive ?

---

### 3. io-wq spécifiquement
> io_uring a ses propres workers internes (io-wq, bounded/unbounded). Est-ce qu'ils ont le même problème — ils peuvent aussi être préemptés par des softirqs ?

Ce que tu veux savoir : si on passe le chemin réseau par io-wq, on hérite du même problème ou io-wq a des protections ?

---

### 4. Mesure de la latence de scheduling
> Pour mesurer la latence entre le moment où un work item est mis en queue et le moment où il s'exécute vraiment — t'utilises quoi ? bpftrace, perf sched ?

Ce que tu veux savoir : le meilleur outil/tracepoint pour quantifier précisément l'overhead de scheduling des workqueues.

---

### 5. Si la discussion s'y prête
> Dans le cas Go — les goroutines sont en user space, donc pas soumises à la préemption softirq kernel. C'est ça qui explique l'écart de perf ?

---

## Ce que tu dois sortir de la réunion

- [ ] Comprendre exactement ce qui se passe au niveau kernel quand un softirq préempte une workqueue
- [ ] Savoir si `WQ_HIGHPRI` est une piste viable
- [ ] Avoir un setup de mesure concret pour la latence de scheduling (outil + tracepoints)
- [ ] Comprendre si io-wq est aussi vulnérable ou s'il a des mécanismes différents

---

## Ce qu'il pourrait te demander

**"T'as déjà mesuré le problème ?"**
→ Pas encore sur WireGuard — j'ai confirmé `IORING_FEAT_NO_IOWAIT` sur le path fichier et reproduit le worker pool UDP (Cloudflare). La prochaine étape c'est monter l'env WireGuard et reproduire le plafond à 4.8 Gbps.

**"Pourquoi io_uring est impliqué si WireGuard est dans le kernel ?"**
→ io_uring est l'angle d'étude du stage — on cherche à comprendre si passer par io-wq changerait quelque chose au comportement du worker pool. Le vrai bottleneck est sur le path socket/réseau, pas fichier.

---

## À ne pas faire

- Ne pas rentrer dans tous les détails du papier Mounah et al. — reste sur le mécanisme
- Ne pas utiliser "EoI" sans expliquer ce que c'est
- Si tu ne sais pas répondre à quelque chose : "je n'ai pas encore creusé ça"

