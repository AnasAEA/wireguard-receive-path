Here's the full script, slide by slide. Written to sound like you're talking, not reading.

---

## Slide 1 — Context

*"Je vais vous présenter ce que j'ai fait pendant la période à temps partiel, et où j'en suis sur le sujet du stage.*

*Le point de départ, c'est ce chiffre : WireGuard, le VPN implémenté directement dans le noyau Linux, atteint 4,8 Gbps sur un lien à 25 Gbps avec 1 000 clients. C'est 19,2% de la bande passante disponible. Ce n'est pas une limite matérielle. Ce n'est pas une mauvaise configuration. C'est un bug de scheduling enfoui dans le noyau.*

*Ce que Mounah et al. ont montré, c'est que le fix fonctionne. Ce qu'on ne sait pas encore, c'est exactement quels mécanismes convertissent ce désalignement de priorités en dégradation observable. C'est ça, l'objectif du stage."*

---

## Slide 2 — WireGuard Reception Pipeline & EoI

*"Le pipeline de réception de WireGuard a trois étapes. La désencapsulation — dans le handler UDP, contexte softirq. Le déchiffrement — dans un workqueue, priorité normale SCHED\_NORMAL. Et le GRO, Generic Receive Offload, qui réassemble les paquets — en softirq, haute priorité.*

*Le problème vient d'une seule instruction dans le chemin de déchiffrement : spin\_unlock\_bh. C'est une opération composée — elle relâche le spinlock ET appelle local\_bh\_enable() sur le CPU local. Résultat : n'importe quel softirq en attente, y compris GRO, se déclenche immédiatement au site du unlock. GRO arrive, ne trouve aucun paquet déchiffré, et abandonne.*

*Ensuite, napi\_schedule() enregistre le CPU qui vient de faire tourner un worker de déchiffrement, et épingle GRO à ce cœur. C'est un pointeur périmé — pas une requête de charge en temps réel. Quand ce cœur sature, les workers migrent sous la pression du scheduler, mais la prochaine rafale de paquets cible quand même le même cœur enregistré. Ce cœur monte à 94%. Les autres restent à 20%. Le déséquilibre se renforce à chaque rafale.*

*Le fix de Mounah et al. : déplacer GRO dans un workqueue, même priorité que le déchiffrement. Plus de préemption. 4,7× de débit, 46% de réduction de latence tail."*

---

## Slide 3 — io\_uring Architecture : les trois chemins

*"Maintenant, io\_uring. Pourquoi io\_uring dans un stage sur WireGuard — j'y reviens sur la slide suivante. D'abord, l'architecture.*

*io\_uring expose deux ring buffers partagés entre userspace et le noyau : une Submission Queue et une Completion Queue. Quand une requête est soumise, elle prend un de trois chemins à l'intérieur de io\_uring\_enter().*

*Chemin 1 : inline. La donnée est disponible immédiatement, la requête se complète sans spawner aucun thread. C'est le chemin par défaut pour les lectures fichier bufférisées depuis le kernel 5.18, grâce à IORING\_FEAT\_NO\_IOWAIT.*

*Chemin 3 — je le prends avant le 2 parce que c'est le défaut pour les sockets : poll wakeup. La tentative non-bloquante retourne EAGAIN, io\_uring enregistre une attente via vfs\_poll(). Zéro thread spawné. La complétion arrive depuis le softirq du device.*

*Chemin 2 : io-wq offload. C'est le chemin pertinent pour WireGuard. Il s'active quand IOSQE\_ASYNC est positionné, ou pour des opérations qui ne peuvent pas poller. Il dispatche un work\_struct sur le worker pool io-wq.*

*Ce que j'ai découvert expérimentalement : le chemin que je dois étudier n'est PAS le défaut. Sur les kernels modernes, les lectures fichier n'atteignent jamais io-wq. L'overhead du workqueue vit exclusivement sur le chemin socket. Tous les articles publiés avant 2022 décrivent un comportement qui n'existe plus."*

---

## Slide 4 — io-wq Internals

*"io-wq maintient deux pools de workers.*

*Les bounded workers : un par CPU, pour les block devices et les fichiers réguliers. Le pool est fixe, conçu pour ne jamais sur-souscrire un cœur.*

*Les unbounded workers : dynamiques, pour les sockets et les char devices. C'est le pool pertinent pour WireGuard — un worker par requête en vol. Le pool grandit à la demande, cappé via IORING\_REGISTER\_IOWQ\_MAX\_WORKERS.*

*Le chemin de dispatch pour Path 2 : io\_wq\_enqueue() appelle queue\_work\_on() avec un work\_struct. C'est exactement le même appel que WireGuard utilise pour ses workers de déchiffrement.*

*Un détail important : sans IOSQE\_ASYNC, une lecture socket fait une tentative non-bloquante, retourne EAGAIN, et s'enregistre en poll. Zéro worker spawné. Avec IOSQE\_ASYNC, la tentative non-bloquante est sautée — on va directement dans io-wq. Un worker par SQE en vol.*

*Et un piège que j'ai trouvé dans l'article Cloudflare : RLIMIT\_NPROC et cgroup pids.max peuvent créer des retry loops qui brûlent un cœur CPU. Facile à confondre avec un vrai pic de charge."*

---

## Slide 5 — La connexion architecturale

*"Une fois qu'on comprend io-wq à ce niveau de détail, quelque chose devient évident.*

*io-wq et le workqueue de déchiffrement de WireGuard utilisent exactement les mêmes primitives kernel : work\_struct et queue\_work\_on, définis dans include/linux/workqueue.h. Ce n'est pas un choix que j'ai fait. C'est un fait architectural.*

*Ça veut dire que tout ce que je peux observer sur io-wq — latence de dispatch des workers, migrations CPU, context switches — reflète les mêmes mécanismes qui gouvernent les workers de déchiffrement de WireGuard. Les tracepoints que j'utilise pour mesurer io-wq — workqueue\_queue\_work, workqueue\_execute\_start — s'appliquent directement au workqueue de WireGuard sans modification.*

*C'est ça la contribution intellectuelle de la phase à temps partiel : pas les expériences elles-mêmes, mais établir pourquoi io-wq est un proxy valide — depuis des primitives kernel partagées, pas par analogie."*

---

## Slide 6 — Ce que j'ai construit

*"Deux reproducers. Deux questions auxquelles j'ai répondu.*

*Premier : cat\_uring. 372 lignes de C, sans liburing, io\_uring brut. La question : est-ce que io-wq se déclenche sur les lectures fichier sur un kernel 6.x ? J'ai instrumenté avec bpftrace et tracé le tracepoint io\_uring\_queue\_async\_work en live. Résultat : zéro fires, même avec un cache froid. IORING\_FEAT\_NO\_IOWAIT confirmé. Les lectures fichier bloquent inline dans io\_uring\_enter() et n'atteignent jamais io-wq. Le chemin fichier est éliminé comme source d'overhead workqueue sur les kernels modernes.*

*Les métriques : 3,7 µs en cache chaud, 132 µs en cache froid — facteur 35,9. 4 context switches et 1 migration CPU par lecture froide. C'est à petite échelle, mais c'est déjà la preuve que le coût de scheduling est réel.*

*Deuxième : udp\_read.rs. Le reproducer Cloudflare, réécrit en Rust. La question : est-ce que IOSQE\_ASYNC force io-wq sur le chemin socket ? Sans le flag : zéro worker spawné sur 4 096 SQEs soumis. Avec le flag : 4 096 workers immédiatement, un par requête en vol. L'activation est déterministe et contrôlable par flag.*

*Les trois tracepoints identifiés pour la phase suivante : workqueue\_queue\_work pour la latence de dispatch, workqueue\_execute\_start pour l'intervalle queue-to-execution, napi\_poll côté NAPI. Ils s'appliquent à WireGuard sans modification."*

---

## Slide 7 — Périmètre full-time : une proposition

*"Voilà comment je vois la phase à temps plein. Je vous présente ça comme une proposition — je veux m'assurer que ça correspond à ce que vous avez en tête.*

*Phase 1 : Reproduire. Mettre en place l'environnement WireGuard et reproduire le plafond de 4,8 Gbps avec moins de 10% de variance run-to-run. Sans baseline stable, n'importe quelle mesure est du bruit.*

*Phase 2 : Attribuer. C'est le cœur de la contribution. Avec les tracepoints que j'ai identifiés, quantifier exactement où va la bande passante perdue — par CPU, par étape, par mécanisme. Combien vient de la latence de réveil des workers, combien des migrations CPU, combien des context switches.*

*Phase 3 : Comparer. Kernel WireGuard contre wireguard-go sous la même charge. wireguard-go utilise des goroutines schedulées en userspace — la préemption softirq est structurellement impossible. L'écart quantifie ce que le pipeline workqueue coûte par rapport à un scheduler userspace. C'est une borne inférieure — wireguard-go a ses propres coûts via le device TUN et les syscalls, mais ça donne un ordre de grandeur.*

*Le bloqueur actuel pour la Phase 1 : l'environnement de test WireGuard — Brice Ekane et Téo Pisenti.*"*

*[pause — laisser Alain répondre]*

*"Est-ce qu'il y a une partie du problème que vous pensez que je sous-pondère ?"*

---

**Notes pour la présentation :**

Sur la slide 2 — ralentir sur spin\_unlock\_bh et "pointeur périmé." C'est là qu'Alain verra que vous avez lu le code, pas juste l'abstract.

Sur la slide 5 — ne pas se presser. C'est la slide pivot.

Sur la slide 7 — poser la question et s'arrêter. Ne pas remplir le silence.