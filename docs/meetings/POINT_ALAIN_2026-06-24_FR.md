# Point d'avancement — CloudLab (màj 26 juin)

> Pour Alain et André. Suite à notre point d'hier. Je remets le correctif à sa place (il
> sert bien à quelque chose) et je détaille les mesures. Il y a pas mal de chiffres et un
> peu de code cette fois. Le détail complet est dans `docs/cloudlab/RECEIVE_PATH_FINDINGS.md`.

## D'abord le débit : c'était la carte réseau, pas WireGuard

J'ai galéré un moment à comprendre pourquoi je plafonnais à 4 Gb/s sur un lien à 10. En
regardant les cœurs pendant un test, un seul tournait à 100 % et les autres ne faisaient
rien. En fait la carte réseau envoyait tous mes tunnels sur une seule file de réception,
donc un seul cœur : son hachage ne regarde que les adresses IP, et mes tunnels partagent
tous la même IP, du coup ils retombent au même endroit. Je l'ai vu noir sur blanc dans
`/proc/softirqs` : un seul CPU prenait ~85 % des interruptions NET_RX, les autres ~0.

Il a suffi d'une option de la carte (`rx-flow-hash udp4 sdfn`, qui ajoute les ports au
hachage) pour que les tunnels se répartissent sur les cœurs. Je passe de 4 à 9 Gb/s, à peu
près le débit ligne, sans rien changer à WireGuard.

![Avant / après : étaler sur les cœurs](figures/fig_spread.png)

| Hachage de la carte | Débit | Cœurs qui reçoivent |
|---|---|---|
| par IP seule (le goulot) | 4,1 Gb/s | 1 (à 100 %) |
| + ports (sdfn) | 9,0 Gb/s | 8 (~55 % chacun) |

Donc le vrai levier pour le débit, c'est le parallélisme. Ce qui est un peu ironique,
parce que le parallélisme est aussi la cause du bug que j'étudie : c'est le déchiffrement
en parallèle qui crée le désordre, et le désordre qui crée les polls gaspillés.

## Le correctif : il sert bien à quelque chose

Je reviens dessus parce que dans la version précédente de ce point j'avais écrit qu'il « ne
servait à rien ». Au point d'hier on a vu que c'est faux, et c'est juste : il supprime un
vrai travail inutile, je le mesurais simplement avec le mauvais critère (le débit).

Le problème en deux mots. Comme on déchiffre en parallèle, les paquets finissent dans le
désordre, mais on doit les livrer dans l'ordre. Le poll de réception ne regarde que la tête
de la file. Tant qu'elle n'est pas déchiffrée, il ne livre rien. Et le pire : il se relance
tout seul. Quand un autre cœur finit un paquet *qui n'est pas la tête*, il « sonne la
cloche » ; comme un poll tourne déjà, le noyau ne le relance pas tout de suite mais pose un
drapeau (MISSED) qui veut dire « re-sonne en finissant ». À la fin du poll, il voit le
drapeau et relance un poll, qui retombe sur la même tête pas encore prête. Gaspillé.

Comme on en avait parlé, j'ai mis le correctif des deux côtés :

- côté consommateur (`wg_supp`) : à la fin du poll, si la tête n'est toujours pas prête,
  j'efface le drapeau MISSED. On ne relance pas un poll pour rien ; c'est la complétion de
  la tête elle-même qui réveillera un poll utile.
- côté producteur (`wg_headwake`) : le poll publie quel paquet il attend (la tête), et
  seule la complétion de ce paquet-là le réveille. Les autres se taisent.

L'idée de garder les deux, c'est exactement ton point d'hier : le consommateur annule bien
le re-réveil, mais celui-ci revient par la voie normale (la complétion suivante re-sonne la
cloche), et c'est le côté producteur qui le rattrape.

### Ce que ça donne

J'ai mesuré les polls gaspillés (compteurs dans le module + sonde bpftrace) pour les quatre
cas, de 8 à 64 pairs, en régime réparti :

![Polls gaspillés selon le nombre de pairs](figures/fig_twosided_peers.png)

| Pairs | rien (stock) | consommateur seul | producteur seul | les deux |
|---|---|---|---|---|
| 8  | 27,0 % | 25,8 % | 15,4 % | 14,8 % |
| 16 | 27,3 % | 26,1 % | 15,9 % | 13,8 % |
| 32 | 26,8 % | 25,1 % | 15,0 % | 13,1 % |
| 64 | 27,5 % | 25,3 % | 15,4 % | 14,4 % |

Trois choses que je lis là-dessus :

1. **Les deux côtés ensemble divisent par ~2 les polls gaspillés** (~27 % → ~14 %), et
   c'est additif : le consommateur seul gratte peu (~2 points), le producteur fait le gros,
   et les deux ensemble font un peu mieux que le producteur seul.
2. **On voit la régénération dont on parlait.** Quand je regarde *de quel type* sont les
   polls gaspillés : avec le consommateur seul, la part qui vient d'un réveil « frais »
   (régénéré) monte (de ~3 % à ~6 % des gaspillés) — la preuve qu'annuler le re-réveil le
   fait juste revenir par l'autre porte. Dès que j'ajoute le côté producteur, cette part
   retombe à ~1 %. Les deux côtés se complètent vraiment.
3. **C'est plat de 8 à 64 pairs.** Au M1 (banc loopback) le bénéfice *grandissait* avec le
   nombre de pairs ; ici non, il est constant. C'est une info en soi : sur ce matériel et en
   régime réparti, le correctif divise par ~2 les polls gaspillés quel que soit le nombre de
   pairs.

Pourquoi ça compte même si le débit ne bouge pas : au débit ligne le débit est déjà au max,
donc forcément il ne monte pas. Mais chaque poll gaspillé en moins, c'est ~1 µs de CPU
rendu sur le cœur de réception. En supprimer la moitié est une vraie économie (énergie, et
« combien de pairs je peux mettre sur une machine »), juste pas visible sur le débit.

### Le code (l'essentiel)

Côté consommateur, à la fin du poll (`build/wg515-trigger/receive.c`) :

```c
/* la boucle s'est arrêtée parce que la tête n'est pas déchiffrée */
if (wg_supp) {
    struct sk_buff *head = wg_prev_queue_peek(&peer->rx_queue);
    if (head && atomic_read_acquire(&PACKET_CB(head)->state) == PACKET_STATE_UNCRYPTED) {
        clear_bit(NAPI_STATE_MISSED, &napi->state);   /* on ne relance pas un poll pour rien */
        smp_mb__after_atomic();
        head = wg_prev_queue_peek(&peer->rx_queue);    /* re-vérif : si la tête est devenue */
        if (head && atomic_read_acquire(&PACKET_CB(head)->state) != PACKET_STATE_UNCRYPTED)
            set_bit(NAPI_STATE_MISSED, &napi->state);  /* prête entre-temps, on relance */
    }
}
```

Côté producteur, quand un paquet finit d'être déchiffré (`queueing.h`) : on ne réveille que
si c'est la tête attendue.

```c
if (wg_headwake && state == PACKET_STATE_CRYPTED) {
    smp_mb();                                   /* barrière (paire avec la re-vérif du poll) */
    b = READ_ONCE(peer->rx_blocked_on);         /* le paquet que le poll attend */
    if (b == NULL || b == skb)
        napi_schedule(&peer->napi);             /* sinon : on se tait */
    ...
}
```

La seule subtilité, c'est qu'il ne faut pas perdre un réveil (si je me tais au mauvais
moment, le tunnel se bloque). Je gère ça avec une double barrière mémoire (le poll publie ce
qu'il attend *puis* re-vérifie) ; ça marche, mais c'est le point que je surveille de près.

## Le modèle de coût (pourquoi le gain est du CPU, pas du débit)

J'ai mesuré le coût de chaque étape de la réception. Un poll gaspillé coûte ~1 µs. La
livraison d'un paquet coûte ~1,64 µs (plus ~3,7 µs de coût fixe par poll), et un
déchiffrement ~5–6 µs. Le poll gaspillé est donc bon marché par rapport au mur de livraison
des paquets. C'est exactement pour ça que le gain du correctif est du CPU rendu et pas du
débit : il enlève le µs de poll inutile, pas le travail de livraison qui sature le cœur.

![Coût par paquet selon la taille du lot](figures/fig_cout_modele.png)

Le modèle dit donc *où* chercher le gain (côté CPU et latence), pas qu'il n'y en a pas.

## Ce que je suis encore en train de mesurer

Le plan qu'on a arrêté, c'était de mesurer ce que j'économise plutôt que le débit. État
honnête des trois axes :

1. **Latence de queue à charge non saturée.** J'ai le banc (charge plafonnée pour laisser de
   la marge sur les cœurs, puis je mesure les RTT). Mais pour l'instant c'est bruité : d'un
   run à l'autre le correctif passe devant puis derrière, avec des valeurs aberrantes
   isolées (10–12 ms) des deux côtés. Je dois resserrer la méthode (plus d'échantillons,
   isoler le tunnel de mesure de la charge) avant de conclure quoi que ce soit. Pas de
   chiffre fiable encore.
2. **Sensibilité à la vitesse de déchiffrement.** J'ai ajouté un bouton qui ralentit le
   déchiffrement exprès (sans toucher au coût du poll), pour tester l'idée « si le
   déchiffrement est plus lent, le correctif sert plus ». La tendance va dans le bon sens :
   en ralentissant, les polls gaspillés sans correctif montent (28 % → ~44 %) et le
   correctif en enlève davantage. Mais si je ralentis trop, le pipeline s'effondre et la
   mesure n'a plus de sens. Je dois refaire ça à charge plus basse pour avoir une courbe
   propre. Encourageant, pas encore un résultat net.
3. **Nombre de pairs.** Fait — c'est la figure plus haut. Le bénéfice est constant de 8 à 64
   pairs (contrairement au M1). Celui-là est solide.

## Où j'en suis

Je suis concentré sur ce plan. Le correctif est en place des deux côtés dans un seul module,
avec des boutons que j'active à chaud, donc je compare facilement avec/sans. Le banc
CloudLab expire tous les jours, du coup j'ai scripté tout le redéploiement en une commande
pour ne pas reperdre du temps à chaque fois (ça m'a déjà servi deux fois). Les expériences
tournent sur 8 à 64 pairs.

Je refais un point dans un jour ou deux. Dispo si vous voulez qu'on en parle.

---

## Annexe — chiffres, commandes, code

Chiffres (régime réparti sdfn). Polls gaspillés selon le nombre de pairs : voir le tableau
plus haut (stock ~27 %, consommateur ~25 %, producteur ~15 %, les deux ~14 %). Débit :
4,1 Gb/s en mono-cœur, 9,0 Gb/s réparti. Coûts mesurés : poll gaspillé ~1 µs, livraison
~1,64 µs/paquet (+ ~3,7 µs fixe/poll), déchiffrement ~5–6 µs.

Les commandes que je lance (sur `dut`, un seul module, boutons à chaud) :

```bash
# polls gaspillés : stock / consommateur / producteur / les deux, sur 8 à 64 pairs
for N in 8 16 32 64; do sudo bash ~/measure_missed.sh "$N" 12; done
# latence à charge non saturée (en cours de fiabilisation)
for N in 8 16 32 64; do sudo bash ~/measure_taillat.sh "$N" 2000 20; done
# effet de la vitesse de déchiffrement (bouton wg_decrypt_delay_ns)
sudo bash ~/measure_decrypt_sweep.sh 8 "0 5000 10000 20000 40000" 12
# le levier débit (mono-cœur vs tous-cœurs)
sudo bash ~/measure_spread.sh 8
```

Activer le correctif des deux côtés à chaud :

```bash
echo 1 > /sys/module/wireguard/parameters/wg_supp
echo 1 > /sys/module/wireguard/parameters/wg_headwake
```

Le bouton pour ralentir le déchiffrement (nanosecondes par paquet, 0 = matériel réel) :

```bash
echo 20000 > /sys/module/wireguard/parameters/wg_decrypt_delay_ns
```

Tout le code modifié est dans `build/wg515-trigger/` (5 fichiers, à partir de la source
WireGuard 5.15 d'origine).



