# ADR-0004 — Qwen text-only via MLX Swift

- Statut : acceptée
- Date : 2026-07-20

## Contexte

Qwen3.5-4B est publié comme modèle multimodal, tandis que VoxoL n'a besoin que du language
model et doit rester un binaire Swift natif.

## Décision

Le runtime utilise uniquement les poids textuels de `Qwen/Qwen3.5-4B`, quantifiés 4-bit et chargés
par MLX Swift. Le vision encoder n'est ni converti ni distribué. La génération est stateless,
greedy, non-thinking et bornée.

Le package `mlx-swift-lm` est épinglé exactement en `2.31.3`, première révision vérifiée ici avec
le support Qwen3.5 textuel. Le binaire Xcode embarque le `default.metallib` produit par le composant
Metal Toolchain ; un build SwiftPM seul reste réservé aux tests qui ne lancent pas MLX.

## Conséquences

Le smoke test natif charge l'artefact text-only 4-bit installé, préchauffe le modèle et valide une
génération fidèle via `Scripts/check-qwen-runtime.sh`. Toute mise à jour du package ou des poids
doit refaire ce test et les goldens de fidélité avant intégration.
