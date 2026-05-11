# Préparation réunion — André Freyssinet
# Meeting Prep — André Freyssinet

> FR : Lis ce document une fois avant la réunion. Tu peux y jeter un œil pendant si besoin.
> EN : Read once before the meeting. Glance at it during if needed.

---

## Qui tu vas voir / Who you're meeting

André est ton directeur de stage côté Inria. C'est lui qui relit le rapport intermédiaire et qui doit valider que tu avances dans la bonne direction. Il a posé une question directe par email sur le rôle d'io_uring dans WireGuard — il avait du mal à voir le lien. La réunion de mercredi est en partie une réponse à cette question, en personne.

Il n'est pas auteur du papier Mounah et al., donc ne présuppose pas qu'il connaît les détails EoI aussi bien qu'Alain. Mais c'est un praticien des systèmes — explique les mécanismes, pas juste les résultats.

---

## Objectif de la réunion / Goal

Deux choses à ressortir de cette réunion :

1. **André valide le rapport** — il doit te donner son feu vert avant le 27 avril. Apporte le PDF.
2. **Avancer sur l'environnement WireGuard** — tu as besoin de Brice Ekane ou Teo Pisenti. André peut faciliter ce contact.

---

## Ouverture — ce que tu dis si il demande "où t'en es ?"
## Opening line

> « J'ai terminé la phase de lecture. J'ai lu le papier WireGuard d'Alain, l'article Cloudflare sur le worker pool io_uring, et j'ai mené deux expériences pratiques : une investigation noyau sur io_uring avec bpftrace et perf, et une reproduction des tests Cloudflare en Rust. Le rapport intermédiaire couvre tout ça — je vous l'ai apporté. La prochaine étape c'est la reproduction du plafond 4.8 Gbps, pour laquelle j'ai besoin de l'environnement WireGuard. »

Court, confiant, concret.

---

## Le lien io_uring / WireGuard — prépare cette explication
## The io_uring / WireGuard link — have this ready

C'est la question qu'André a posée par email. Il va probablement la reposer en personne. Voici la réponse exacte :

> « WireGuard n'utilise pas io_uring directement. Le lien passe par l'infrastructure kernel partagée : io-wq, le worker pool interne d'io_uring, utilise exactement les mêmes primitives que le pipeline de déchiffrement de WireGuard — `work_struct` et `queue_work_on`. Les expériences en §3 observent ce comportement en isolation, sur un système contrôlé, avant d'attaquer WireGuard directement. C'est une validation méthodologique : je confirme que je comprends le comportement du worker pool avant de mesurer le bottleneck réel. »

Si il veut plus de détail :

> « Concrètement : j'ai confirmé que `IORING_FEAT_NO_IOWAIT` fait que les lectures fichier n'activent jamais io-wq sur les kernels modernes. Et que pour les sockets, le chemin par défaut d'io_uring est le poll — les workers ne se déclenchent qu'avec `IOSQE_ASYNC`. Ça veut dire que le bottleneck workqueue est exclusivement sur le chemin réseau, exactement là où WireGuard opère. »

---

## Ce qu'il pourrait te demander — et comment répondre
## What he might ask — and how to answer

**« Le rapport est bien mais le lien io_uring/WireGuard n'est toujours pas clair »**
→ Montre-lui la version corrigée — abstract §1 explicitent maintenant le lien `work_struct`/`queue_work_on`. Dis-lui que tu as retravaillé exactement ça suite à son email.

**« C'est quoi exactement EoI ? »**
→ André n'est pas co-auteur du papier, il n'a peut-être pas tous les détails. Explication en deux phrases :
> « Dans le pipeline de réception WireGuard, le déchiffrement tourne dans une workqueue (priorité normale du scheduler). Le GRO tourne en softirq (haute priorité). `spin_unlock_bh` dans le chemin de déchiffrement réactive les bottom halves en plein milieu du pipeline — le GRO se déclenche avant que le déchiffrement soit fini, trouve rien, abandonne. Résultat : un cœur monte à 94% sur le backlog GRO pendant que les autres restent à 20%. »

**« Pourquoi comparer avec wireguard-go ? »**
→ C'est la question la plus délicate. Voici ta position :
> « wireguard-go évite EoI structurellement : les goroutines Go sont schedulées en user space, elles ne peuvent pas être préemptées par des softirqs kernel. Comparer les deux sous le même workload quantifie exactement ce que le scheduling kernel coûte. Mon hypothèse : l'élimination d'EoI (fix workqueues du papier) ferme la majorité de l'écart — mais je m'attends à un overhead résiduel dû au jitter du scheduler kernel et aux context switches, que le scheduler user-space de Go évite complètement. »

**« Tu as une hypothèse sur ce que vont montrer tes mesures ? »**
→ Oui. Formule-la clairement :
> « Mon hypothèse : la majorité de la dégradation de WireGuard vient de la collision de priorités EoI, pas d'un overhead workqueue générique. Si c'est vrai, le fix workqueue du papier doit reproduire le 4.7× de débit. L'overhead résiduel — ce qui reste après le fix — c'est là que la comparaison avec wireguard-go devient intéressante. »

**« Tes tracepoints pour la phase de mesure ? »**
→ `workqueue_queue_work` et `workqueue_execute_start` pour mesurer la latence de scheduling des workers de déchiffrement WireGuard. `napi_poll` pour le côté GRO/NAPI. Les deux ensemble permettent de chronométrer l'intervalle entre la mise en queue d'un work item et son exécution réelle — c'est l'overhead à quantifier.

**« T'as regardé le code source de WireGuard pour confirmer `spin_unlock_bh` ? »**
→ Si tu ne l'as pas fait, dis : *« Pas encore en détail, mais c'est pointé précisément dans le papier Mounah et al. Je vais vérifier dans le source avant la phase de reproduction. »*

**« Quand tu penses pouvoir avoir les premiers résultats WireGuard ? »**
→ *« Dès que j'ai l'environnement de test, je devrais pouvoir reproduire le plafond 4.8 Gbps en une à deux semaines — c'est la même expérience que dans le papier, pas un nouveau setup. »*

---

## Ce dont tu as besoin — demande ces choses
## What you need — ask for these

**Priorité 1 — Validation du rapport**
> « Est-ce que vous pouvez relire le rapport avant le 27 avril et me donner votre feu vert pour le soumettre ? »

**Priorité 2 — Environnement WireGuard**
> « Pour passer à la reproduction, j'aurais besoin d'accéder à l'environnement de test WireGuard. Est-ce que Brice Ekane ou Teo Pisenti peuvent m'aider à le mettre en place ? »

**Priorité 3 — Contact Toulouse (si pas encore eu)**
> « Il y avait mention d'un chercheur à Toulouse avec une suite de benchmarks io_uring — est-ce que vous avez ses coordonnées ? »

---

## À ne pas faire / What NOT to do

- Ne t'excuse pas de ne pas avoir de résultats WireGuard — la phase de lecture était le plan, elle est faite, le rapport le documente
- Ne rentre pas dans tous les détails du papier Mounah et al. sans qu'on te le demande — André n'est pas co-auteur, calibre ton niveau de détail à ce qu'il pose comme questions
- Ne dis pas "j'ai lu..." cinq fois — cite un ou deux résultats expérimentaux concrets, c'est ce qui montre que tu as vraiment travaillé
- Si il te pose une question à laquelle tu ne sais pas répondre : *"Je n'ai pas encore creusé ça, mais je peux le faire"* — ne bluffe pas

---

## Chiffres clés — à savoir par cœur
## Key numbers — know these cold

| Fait / Fact | Chiffre / Number |
|---|---|
| Débit RX WireGuard à 1000 clients | 4.8 Gbps = 19.2% des 25 Gbps disponibles |
| Gain débit — workqueues (fix EoI) | **4.7×** |
| Gain débit — kthreads (fix EoI) | 4× |
| Réduction latence — kthreads | 65% tail latency |
| Réduction latence — workqueues | 46% tail latency |
| Cœur surchargé (softirq GRO) | ~94% |
| Autres cœurs | ~20% |
| Lecture io_uring cache chaud | 3.7 µs |
| Lecture io_uring cache froid | 132 µs (×35.9) |
| Workers io-wq sans IOSQE_ASYNC (4096 SQEs) | 0 |
| Workers io-wq avec IOSQE_ASYNC (4096 SQEs) | 4096 |

---

## Après la réunion / After the meeting

- Envoie un email de suivi résumant ce qui a été décidé (contacts obtenus, feu vert rapport, prochaines étapes)
- Mets à jour le tracker
- Deadline rapport intermédiaire : **27 avril** — soumets sur Moodle 295 dès qu'André valide
