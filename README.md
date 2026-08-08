# VoxoL

VoxoL est une application macOS native de dictée intelligente, privée et entièrement
locale après l'installation explicite de ses modèles. Le dépôt est une création neuve et ne
dérive d'aucune application existante.

## État actuel

La fondation de capture et d'insertion de la Phase 1 est fonctionnelle. Le dépôt expose les états
techniques réels sans simuler le moteur :

- un preflight bilingue français/anglais qui demande les permissions macOS réelles ;
- un installateur avec progression par octets, pause/reprise persistante, vérification SHA-256,
  compilation Core ML et activation atomique ;
- un tableau de bord local avec mots, débit, activité et historique révisable ;
- une capsule flottante compacte qui adapte sa forme aux étapes et aux erreurs ;
- un raccourci global `⌥ Espace` avec capture micro mono Float32 à 16 kHz, buffer borné et
  endpointing déterministe ;
- une transcription Parakeet TDT entièrement locale via Core ML, préchargée hors du thread UI et
  accélérée par les unités de calcul Apple disponibles ;
- une insertion macOS via Accessibility, avec fallback presse-papiers restauré uniquement si
  l'utilisateur ne l'a pas modifié, testable avec `⌥ ⇧ Espace` ;
- une identité VoxoL monochrome déclinée dans l'app, la barre des menus et l'icône macOS ;
- un aperçu « Coming soon » du futur mode réunion, encore inaccessible ;
- le contrat local des deux modèles autorisés, sans poids ;
- les contrôles CI de build, tests, formatage, localisation et politique du dépôt.

La dictée Parakeet fonctionne jusqu'à l'insertion et à l'historique. Le nettoyage Qwen via MLX est
branché derrière un prétraitement déterministe et un validateur de fidélité ; le mode instantané
utilise par défaut la voie déterministe, et l'utilisateur peut le désactiver pour toujours tenter
Qwen.

## Contraintes de runtime

VoxoL utilisera exactement deux modèles locaux :

1. `nvidia/parakeet-tdt-0.6b-v3` pour l'ASR via Core ML et un décodeur Swift ;
2. `Qwen/Qwen3.5-0.8B`, quantifié 4-bit, via MLX Swift et protégé par le validateur de fidélité.

Aucun poids n'est versionné dans Git et l'application livrée ne dépendra d'aucun service cloud.

## Vérification locale

Prérequis : macOS sur Apple Silicon, Xcode 26 ou plus récent et Swift 6.2 ou plus récent.

```sh
./Scripts/verify.sh
```

Après avoir accordé Microphone, Accessibilité et Surveillance de l’entrée à la build locale, le
smoke test matériel maintient réellement le raccourci, vérifie l’apparition de la capsule via Core
Graphics et échoue si le callback audio fait tomber le processus :

```sh
./Scripts/check-live-hotkey.sh
```

La sonde suivante vérifie séparément, sans audio, le raccourci et l’insertion réelle dans un
document TextEdit temporaire :

```sh
./Scripts/check-live-insertion.sh
```

Pour exécuter uniquement le benchmark de bootstrap :

```sh
swift run voxol-benchmark --iterations 100
```

Avec Parakeet installé, le smoke test suivant synthétise une phrase locale et vérifie le texte
réellement produit par Core ML :

```sh
./Scripts/check-parakeet-runtime.sh
```

Le fine-tuning expérimental FR/EN se lance dans Google Colab avec
`Notebooks/VoxoL_Parakeet_Finetune_Colab.ipynb` : sélectionner un GPU puis exécuter toutes les
cellules. Le notebook reprend les interruptions et refuse automatiquement un candidat qui ne passe
pas les gates FLEURS FR/EN et MediaSpeech.

Le plan maître se trouve dans `voxol_codex_master_plan.md`. L'architecture Phase 0, le système
visuel et la cartographie des écrans sont détaillés respectivement dans
`Docs/phase-0-bootstrap.md`, `Docs/design-system.md` et `Docs/screen-map.md`.
