# Phase 0 — bootstrap et mesures

## Hypothèses explicites

- Le produit s'appelle VoxoL même si le dossier parent du workspace s'appelle encore `Zphyr`.
- `com.voxol.VoxoL` est un bundle identifier de développement provisoire.
- La signature Phase 0 est ad hoc. L'identité Developer ID et l'équipe Apple seront décidées avant
  distribution.
- Le build produit est non sandboxé : Apple classe l'usage des APIs Accessibility par une
  application assistive parmi les activités incompatibles avec App Sandbox. La distribution visée
  est donc Developer ID + notarisation, avec permissions TCC demandées au dernier moment.
- Aucune licence open source du code n'est choisie implicitement. Le dépôt reste tous droits
  réservés jusqu'à décision produit.
- La cible de déploiement initiale est macOS 15 sur Apple Silicon; la machine de référence reste
  le Mac M4 16 Go du cahier des charges.

## Arborescence cible exacte

Les répertoires sans comportement ne sont pas créés en Phase 0. Ils apparaissent ici pour fixer
leur destination, puis seront ajoutés par le vertical slice qui les rend réels.

```text
VoxoL/
├── .github/workflows/ci.yml
├── App/
│   ├── VoxoLApp.swift
│   ├── AppDelegate.swift
│   ├── MenuBar/
│   ├── Settings/
│   ├── Overlay/
│   ├── Onboarding/
│   └── Diagnostics/
├── Packages/
│   ├── AudioCaptureKit/
│   ├── EndpointingKit/
│   ├── ParakeetCore/
│   ├── QwenPolisher/
│   ├── ContextKit/
│   ├── DictionaryKit/
│   ├── FidelityKit/
│   ├── InjectionKit/
│   ├── PersonalizationKit/
│   ├── StorageKit/
│   ├── ModelManagerKit/
│   └── ObservabilityKit/
├── Models/
│   ├── manifests/
│   ├── checksums/
│   └── README.md
├── Tools/
│   ├── parakeet-conversion/
│   ├── qwen-conversion/
│   ├── qwen-finetuning/
│   ├── dataset-builder/
│   ├── benchmark-cli/
│   └── release-tools/
├── Tests/
│   ├── Unit/
│   ├── Integration/
│   ├── GoldenAudio/
│   ├── GoldenCleanup/
│   ├── Accessibility/
│   ├── Performance/
│   └── Privacy/
├── Docs/
│   ├── architecture.md
│   ├── model-pipeline.md
│   ├── dataset-policy.md
│   ├── benchmarking.md
│   ├── threat-model.md
│   ├── accessibility-integration.md
│   └── decisions/
├── Scripts/
├── VoxoL.xcodeproj/
├── Package.swift
├── README.md
├── LICENSE
├── SECURITY.md
├── PRIVACY.md
├── CONTRIBUTING.md
└── CHANGELOG.md
```

## Décisions d'architecture

Les ADR 0001 à 0006 sont acceptées dans `Docs/decisions/`. Les ADR suivantes restent à écrire au
moment où leur vertical slice commence : SQLite et rétention, distribution des modèles, streaming
sans injection partielle, puis apprentissage opt-in.

## Risques techniques à lever

### Parakeet vers Core ML

Le checkpoint officiel cible NeMo/Transformers, pas Core ML. Le FastConformer contient des formes
dynamiques et le chemin TDT combine encodeur, prédicteur, joint network et durées; une conversion
monolithique risque de produire des opérations non prises en charge, un mauvais placement ANE ou
des temps de compilation et de chargement excessifs. La Phase 2 devra commencer par un modèle
minimal tracé, un inventaire des opérations, puis un rapport de parité par sous-graphe avant toute
optimisation.

Le décodeur de référence officiel reste lié aux détails du tokenizer, au blank token, aux durées
TDT et à `max_symbols_per_step`. Ces valeurs doivent venir de la configuration épinglée; les coder
en dur dans plusieurs modules créerait des divergences silencieuses.

### Qwen3.5-4B vers MLX Swift

Le dépôt officiel Qwen est multimodal : son `config.json` contient un `vision_config` et un
`text_config` de type `qwen3_5_text`. L'export VoxoL doit donc prouver qu'il exclut réellement
le vision encoder et ses poids. Le modèle textuel utilise une architecture hybride avec attention
linéaire et attention complète; la compatibilité du chargeur, du cache et de la quantification
doit être testée avec une version MLX Swift LM épinglée.

MLX Swift LM prend désormais en charge Qwen3.5 text-only, mais sa branche majeure 3.x a introduit
des changements d'interface. Ajouter cette dépendance avant le spike de Phase 4 figerait une
version sans mesure. Le runtime devra aussi contrôler le template non-thinking, le budget de sortie
et l'absence de téléchargement implicite.

### Co-résidence sur 16 Go

Les objectifs mémoire des deux modèles sont plausibles mais non prouvés. La conversion, le mmap,
les caches et les buffers peuvent dépasser le budget même si la taille des poids semble correcte;
les gates imposeront donc des mesures de mémoire résidente et de pression mémoire avec les deux
runtimes chargés.

### Distribution et privilèges macOS

L'insertion Accessibility requise par le produit n'est pas compatible avec App Sandbox selon la
documentation Apple. Le binaire devra être distribué hors Mac App Store, signé Developer ID,
notarisé et renforcé par le Hardened Runtime. Cette liberté système augmente la portée d'un défaut;
les permissions TCC minimales, l'absence de réseau et le threat model deviennent donc des gates de
release plutôt que des options.

## Tests et benchmarks initiaux

- Le manifest doit contenir exactement deux rôles uniques et les deux dépôts autorisés.
- Chaque révision doit être un commit Git immuable de 40 caractères.
- Un artefact `ready` doit contenir au moins un fichier et chaque SHA-256 doit être valide.
- Le format de benchmark doit survivre à un aller-retour JSON et calculer des percentiles
  déterministes.
- Le CLI mesure le décodage et la validation du manifest, puis émet un JSON versionné.
- Le build Xcode doit produire une application arm64 ad hoc signée.
- Un smoke test doit lancer le binaire, vérifier qu'il reste actif, puis l'arrêter proprement.
- Le contrôle de dépôt doit refuser poids, artefacts de modèle et fichier supérieur à 50 Mo.
- La CI doit exécuter formatage, tests SwiftPM, benchmark smoke test et build Xcode sans poids.

Les futurs corpus audio, goldens de nettoyage et mesures modèle ne sont pas simulés en Phase 0;
ils seront ajoutés avec le runtime qu'ils évaluent.

## Premier vertical slice

Le slice `LF-001..LF-004 + LF-010 bootstrap` traverse le dépôt sans prétendre implémenter la dictée :

1. l'application menu-bar se lance ;
2. `ModelManagerKit` charge et valide localement le manifest épinglé ;
3. `ObservabilityKit` définit un résultat de mesure stable ;
4. `voxol-benchmark` mesure le contrat du manifest ;
5. les tests, la CI et la vérification de signature ferment le slice.

Ce slice est terminé quand `./Scripts/verify.sh` passe sans téléchargement de modèle ni dépendance
runtime externe.
