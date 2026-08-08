# ADR-0001 — Application native Swift

- Statut : acceptée
- Date : 2026-07-20

## Contexte

VoxoL doit réagir comme une extension du système et accéder aux interfaces macOS de capture,
raccourci, accessibilité, insertion et accélération matérielle.

## Décision

L'application livrée est écrite en Swift 6, avec SwiftUI pour l'interface et AppKit,
AVFoundation, Accessibility, Core ML, Accelerate et Metal aux seams qui le nécessitent. Aucun
runtime web ni serveur Python n'est embarqué. App Sandbox est désactivé parce qu'Apple documente
l'usage des APIs Accessibility par une application assistive comme incompatible avec le sandbox;
la release utilisera Developer ID, Hardened Runtime et notarisation.

## Conséquences

Le build et les tests produit exigent macOS/Xcode. Python reste autorisé dans `Tools/` pour les
opérations hors application, et ses artefacts doivent être consommés par des interfaces natives.
L'absence de sandbox impose des contrôles TCC, réseau, signature et privilèges plus stricts avant
release.
