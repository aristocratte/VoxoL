# ADR-0009 — ASR système à langue verrouillée

- Statut : acceptée
- Date : 2026-07-22
- Remplace partiellement : ADR-0002

## Contexte

Parakeet TDT 0.6B v3 détecte automatiquement la langue, mais son interface de décodage ne permet
pas de forcer le français ou l’anglais. Sur des captures courtes ou ambiguës, cette contrainte peut
produire une transcription dans la mauvaise langue avant même le nettoyage Qwen.

## Décision

VoxoL conserve exactement deux artefacts de modèles distribués et vérifiés par son manifeste :
Parakeet et Qwen. Sur macOS 26 ou ultérieur, un choix explicite Français ou English utilise aussi
`DictationTranscriber` et `SpeechAnalyzer`, avec le locale correspondant et les assets gérés par le
système. Auto utilise Parakeet. Si l’API ou ses assets sont indisponibles, Parakeet reste le repli
local; aucun repli réseau n’est permis.

## Conséquences

Le sélecteur de langue parlée est séparé de la langue de l’interface. Les diagnostics indiquent le
moteur réellement utilisé et sa latence. L’application continue de cibler macOS 15 : la route Apple
est protégée par disponibilité, tandis que Parakeet couvre les versions antérieures. Les assets
système ne sont ni ajoutés au manifeste VoxoL ni traités comme des dépendances tierces.
