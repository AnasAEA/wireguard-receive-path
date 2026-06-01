# Source de ces fichiers

Module WireGuard extrait de **`torvalds/linux`, tag `v6.1`** — c'est la version
utilisée par le papier (Mounah et al., SYSTOR 2025 : Debian 12, noyau 6.1) et
représentative d'un noyau Ubuntu/x86 de cette génération (CloudLab).

Récupéré le 2026-06-01 via
`https://raw.githubusercontent.com/torvalds/linux/v6.1/drivers/net/wireguard/`.

Sert **uniquement de référence de comparaison** avec notre build
(`linux-source/drivers/net/wireguard/`, AsahiLinux/linux branche `asahi`, ARM, ≈6.19).
Voir l'analyse : `admin/COMPARAISON_CODE_VERSIONS_FR.md`.

Seuls les fichiers du chemin de réception (le périmètre de notre étude) sont inclus :
`queueing.h`, `queueing.c`, `receive.c`, `device.c`, `peer.c`, `peer.h`, `socket.c`.
