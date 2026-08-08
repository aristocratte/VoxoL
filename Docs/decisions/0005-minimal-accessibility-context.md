# ADR-0005 — Contexte minimal via Accessibility

- Statut : acceptée
- Date : 2026-07-20

## Contexte

Le formatage contextuel améliore l'insertion mais la lecture de l'application active peut exposer
des données sensibles.

## Décision

ContextKit lit à la demande un contexte borné via Accessibility : identité de l'application,
contrôle ciblé, sélection et texte proche du curseur. Aucun screenshot n'est capturé et
`AXSecureTextField` bloque toute collecte.

## Conséquences

Le contexte est éphémère par défaut, tronqué avant le modèle local et couvert par des tests de
champs sécurisés. Les permissions sont demandées au dernier moment.
