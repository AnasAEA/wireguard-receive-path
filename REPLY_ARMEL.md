**Objet:** Re: BRAINSTORMING AU SUJET D'IO_URING

Slt Armel,

On s'était parlé la semaine dernière — t'avais dit que tu m'enverrais des infos, je voulais juste relancer.

J'ai mieux cerné le sujet depuis. En gros : kernel WireGuard plafonne à 4.8 Gbps sur un lien à 25 Gbps parce que le GRO tourne en softirq (haute priorité) et préempte le déchiffrement qui est dans une workqueue (priorité normale). Le batching est cassé, un cœur monte à 94%, les autres restent à 20%. wireguard-go n'a pas ce problème — les goroutines sont en user space, pas de préemption softirq. C'est cet écart qu'on cherche à reproduire et quantifier.

Mon angle pour caractériser ça en isolation c'est io-wq, le worker pool interne d'io_uring — même infrastructure que WireGuard (`work_struct`, `queue_work_on`).

Mes questions de la semaine dernière tiennent toujours : comportement du work item après préemption, priorité des workqueues, vulnérabilité de io-wq, et outils pour mesurer la latence de scheduling. Si t'as des trucs à partager là-dessus je suis preneur.

Anas
