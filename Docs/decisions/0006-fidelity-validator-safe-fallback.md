# ADR-0006 — Validation obligatoire et fallback déterministe

- Statut : acceptée
- Date : 2026-07-20

## Contexte

Un modèle de nettoyage peut modifier un nombre, une négation, un nom ou répondre au contenu dicté;
la faible fréquence de ces erreurs ne les rend pas acceptables à l'insertion.

## Décision

Toute sortie Qwen passe par FidelityKit. Les tokens protégés, nombres, dates, négations, langue,
longueur et motifs de réponse sont contrôlés avant insertion. Un rejet ou timeout retourne
immédiatement la transcription déterministe normalisée, sans seconde génération.

## Conséquences

L'insertion ne dépend jamais de la réussite de Qwen. Chaque nouveau contrôle a des cas positifs,
négatifs et un test explicite du fallback, sans journaliser le contenu en production.
