# ADR-0002 — Exactement deux modèles locaux

- Statut : acceptée
- Date : 2026-07-20

## Contexte

Chaque modèle supplémentaire augmente mémoire, latence, chaîne d'approvisionnement et surface de
confidentialité.

## Décision

Le runtime autorise uniquement `nvidia/parakeet-tdt-0.6b-v3` pour l'ASR et
`Qwen/Qwen3.5-4B` pour le nettoyage textuel. L'endpointing, la normalisation, la protection et la
validation sont déterministes. Aucun fallback réseau ou modèle auxiliaire n'est permis.

## Conséquences

Le manifest et ses tests rejettent tout troisième modèle. Une proposition de changement exige une
nouvelle ADR et une validation explicite du périmètre produit.
