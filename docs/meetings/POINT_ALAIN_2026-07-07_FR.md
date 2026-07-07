# Point d'avancement — CloudLab (màj 7 juillet)

> Pour Alain et André. Depuis le point du 3 juillet, trois choses : la Phase B
> (sensibilité au coût de déchiffrement) est faite et le résultat est net ; j'ai
> vérifié le modèle de coût au cycle près (E10) parce que le null me dérangeait ;
> et cette vérification a fait apparaître quelque chose d'inattendu (E11) qui ouvre
> une vraie piste pour la suite. Détail complet : `docs/cloudlab/RECEIVE_PATH_FINDINGS.md`
> et le journal `CLOUDLAB_EXPERIMENTS_LOG.md`.

## Le résumé en quatre phrases

1. **Le fix marche d'autant mieux que le crypto est lent** : il supprime 56 % des
   polls gaspillés sur crypto rapide, et **89 %** quand je ralentis le déchiffrement
   à 10 µs/paquet. Exactement ce que le mécanisme prédit.
2. **Et pourtant, toujours aucun gain CPU ni latence.** Ça m'a mis en doute, donc
   j'ai arrêté de calculer et j'ai mesuré : le budget CPU *total* des polls gaspillés
   est de **0,022 équivalent-cœur** — cent fois sous le bruit de la machine. Le null
   n'est plus une explication, c'est une mesure.
3. **La phrase qui résume tout : on supprime beaucoup d'événements, pas beaucoup de
   cycles.**
4. **Mais en mesurant, j'ai trouvé autre chose** : le paquet de tête reste bloqué
   **50–100 µs** avant d'être livré — soit 10 à 20 fois son temps de déchiffrement.
   Il n'est pas lent à déchiffrer, il **attend son tour**. Ça, un fix pourrait s'y
   attaquer. C'est la piste « steering » en bas.

## Phase B — ralentir le crypto pour voir où le fix compte

L'hypothèse du 25 juin : sur du crypto lent, la tête de file reste chiffrée plus
longtemps, donc plus de re-polls gaspillés, donc le fix enlève plus. Je l'ai testée
proprement cette fois : charge plafonnée à 2 Gb/s (l'essai du 26 juin s'effondrait à
fort délai — c'était un artefact de charge non plafonnée, pas un « genou » réel), une
seule fenêtre de mesure par run qui capture ensemble latence, CPU, débit réel vérifié
et polls gaspillés. 50 runs, tous valides.

![Le fix devient plus efficace quand le déchiffrement ralentit](figures/fig_decsweep_wasted.png)

| délai injecté | stock gaspille | fix (`both`) gaspille | le fix enlève |
|---:|---:|---:|---:|
| 0 µs | 34,4 % | 15,2 % | **56 %** du gaspillage |
| 1 µs | 34,7 % | 12,8 % | 63 % |
| 2 µs | 34,8 % | 12,0 % | 66 % |
| 5 µs | 33,3 % | 7,5 % | 78 % |
| 10 µs | 34,6 % | **3,8 %** | **89 %** |

Deux lectures. D'abord le stock reste plat (~34 %) quel que soit le délai : le
gaspillage est structurel, pas une affaire de vitesse. Ensuite la courbe du fix
descend de façon monotone, avec des intervalles serrés : **c'est une réponse à la
dose**, le résultat mécanistique le plus propre du projet. Ton intuition du 25 juin
était bonne.

Mais côté utilisateur : CPU indiscernable à tous les délais (signes mélangés,
−13 %…+3 %), latence pareille. Même à un ratio déchiffrement:poll de 10 contre 1,
rien. D'où la question qui fâche.

## E10 — « où partent les cycles ? » : j'ai arrêté de calculer, j'ai mesuré

Le paradoxe apparent : on enlève 89 % d'une opération gaspillée et l'utilisateur ne
voit rien. Jusqu'ici l'explication reposait sur une arithmétique (« un poll ≈ 1 µs,
donc c'est petit ») — pas suffisant pour un rapport. Donc mesure directe, deux
instruments indépendants, sans jamais les faire tourner en même temps :

- **BPF** : sommer la *durée réelle* de chaque poll qui revient vide (pas les
  compter — les chronométrer) ;
- **perf** : attribution des cycles par fonction sur tous les cœurs.

![Le budget mesuré des polls gaspillés](figures/fig_e10_budget_fr.png)

Résultat : un poll gaspillé coûte **1,14–1,36 µs** (le modèle disait ~1 µs — confirmé
en conditions réelles). Le stock en fait ~500 000 par fenêtre de 30 s, soit **657 ms
de CPU = 0,022 équivalent-cœur**. Le bruit run-à-run de la machine est de ±2 CE.
Autrement dit : même en supprimant **100 %** du gaspillage, l'effet attendu est cent
fois sous ce qu'on sait mesurer. Et perf confirme par l'autre bout : toute la
machinerie poll + réveil (`wg_packet_rx_poll`, `napi_complete_done`,
`__napi_schedule`), **travail utile compris**, pèse moins de 0,7 % des cycles occupés.

Les cycles ne « partent » nulle part : ils n'ont jamais été là. Les 34 % de polls
gaspillés, c'est 34 % *des polls* — et un poll est l'opération la moins chère de
toute la chaîne. Le vrai budget est dans la livraison par paquet, le déchiffrement,
TCP/IP, l'espace utilisateur.

Il y a aussi une raison *structurelle* pour la latence, qu'on aurait dû formuler plus
tôt : **le fix ne livre jamais aucun paquet plus tôt.** La tête est livrée quand son
déchiffrement finit, et le fix ne touche pas au déchiffrement — il supprime des polls
inutiles *entre-temps*. Un gain de latence ne pouvait venir qu'indirectement, via le
CPU libéré. CPU libéré : 0,017 CE. Fin de l'histoire.

Petit bonus au passage : avec le fix, les polls sont **moins nombreux mais plus
longs** (15 → 23 µs en moyenne) — les livraisons se regroupent en plus gros lots.
C'est l'effet « batch GRO » qu'on avait vu sur le M1, retrouvé sur vrai matériel.

## E11 — la surprise : la tête n'est pas lente à déchiffrer, elle attend son tour

En vérifiant le modèle de coût, j'ai mesuré autre chose : quand un poll trouve la
tête non déchiffrée, **combien de temps la livraison reste-t-elle bloquée** (du
premier poll raté au poll productif suivant) ?

![Distribution des blocages de livraison](figures/fig_e11_stall_fr.png)

Je m'attendais à des blocages de l'ordre de T_decrypt (~5 µs). Ce n'est pas ça du
tout : **le gros de la distribution est à 32–128 µs, 10 à 20 fois T_decrypt**. Et le
test décisif : quand j'injecte +10 µs de délai de déchiffrement, la médiane **ne bouge
pas**. Si le blocage était dominé par le temps de déchiffrement, il devrait suivre le
délai. Il ne le suit pas.

Conclusion mécanistique : la tête n'est pas lente à *déchiffrer* — elle est lente à
*être déchiffrée*. Elle fait la queue derrière d'autres paquets sur le cœur de son
worker, ou elle attend que le worker soit ordonnancé (ça recoupe le Δ_complete
bimodal ~5 µs / ~100 µs du modèle de coût).

Et ça change la perspective, parce que c'est un problème **différent** de celui que
le fix actuel résout :

```text
le fix actuel dit :   « ne sonne pas la cloche tant que la tête n'est pas prête »
                       → enlève des polls inutiles (pas cher : 0,022 CE)

le steering dirait :  « déchiffre la tête EN PRIORITÉ »
                       → livrerait les paquets PLUS TÔT (50–100 µs en jeu)
```

C'est l'idée qu'Anas a lancée cette semaine (« bloquer le déchiffrement tant que la
tête n'est pas faite ») — la version bloquante ne tient pas (elle sérialiserait le
pipeline et le déchiffrement n'est jamais gaspillé), mais la version *priorisante*
(faire prendre la tête par le prochain cœur libre au lieu du FIFO de son worker
attitré) vise exactement le blocage mesuré.

**L'honnêteté oblige** : cette mesure est une *borne supérieure* contaminée. Environ
46 % des polls ratés trouvent une file *vide* (pas une tête chiffrée), et ma sonde ne
distingue pas les deux cas ; la population milliseconde de l'histogramme (files vides
entre rafales, ~6 % des épisodes) est déjà exclue. Chaîne de lecture prudente :

```text
écart brut                        = borne sup. du temps de livraison bloquée
× fraction tête-chiffrée (~54 %)  = borne sup. des blocages pertinents
− plancher de déchiffrement       = estimation prudente de ce que le steering
                                    pourrait récupérer
```

Ce qui donne : **typiquement ~30–90 µs récupérables, avec une queue à 200–800 µs**.
La règle de décision qu'on s'est fixée : sous 5–20 µs, on laisse tomber ; au-dessus
de 100 µs et croissant, ça devient une vraie direction. On est **au-dessus de la
bande basse, avec une queue au-delà du seuil haut** — mais la contamination
tête-vs-vide n'est pas levée.

**Donc la prochaine étape n'est PAS d'implémenter le steering.** C'est un classifieur
d'une vingtaine de lignes dans les compteurs diagnostics du module (à chaque poll
raté : file vide ou tête chiffrée ? + durée de l'épisode par classe), puis re-mesurer.
Si les blocages « tête chiffrée » confirment 50–100 µs médians, le steering devient
du futur-travail avec des preuves. Sinon, on aura évité de construire pour rien.

## Où en est l'histoire complète

| Question | Réponse | Statut |
|---|---|---|
| Mécanisme EoI (re-polls MISSED) | confirmé, 95–99,7 % des polls gaspillés | prouvé |
| Le fix deux-côtés enlève du travail | 56 % du gaspillage, → 89 % sur crypto lent | prouvé, dose-réponse |
| Levier du débit | parallélisme (sdfn), ×2,2 — pas le fix | prouvé |
| Gain CPU du fix | non — **0,022 CE en jeu, mesuré au cycle** | null mesuré |
| Gain latence du fix | non — structurel : il ne livre rien plus tôt | null expliqué |
| Où un gain latence peut vivre | blocage de tête 50–100 µs (attente d'ordonnancement) | **piste E11, à classifier** |

C'est une histoire qui se tient de bout en bout : le fix est mécaniquement correct et
répond à la dose ; son null CPU/latence est *mesuré*, pas supposé ; et la mesure de
vérification a elle-même produit la direction suivante.

## D'ici le 31 juillet

1. **Classifieur wg_diag** (~20 lignes, préservant le comportement) + re-run E11
   classifié à délai 0/5/10 µs — tranche la question steering. *(J'ai besoin d'une
   nouvelle instanciation CloudLab pour ça.)*
2. **Soak headwake** (15–30 min de charge soutenue) — le garde-fou avant de
   recommander `both`.
3. **Rédaction** de la synthèse finale.
4. *(Reste ouvert de la dernière fois : le fix du papier / config combinée — livrable
   du 31 juillet ou pas ?)*
