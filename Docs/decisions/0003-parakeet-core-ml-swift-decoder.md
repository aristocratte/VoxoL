# ADR-0003 — Parakeet via Core ML et décodeur Swift

- Statut : acceptée
- Date : 2026-07-20

## Contexte

Le checkpoint Parakeet officiel n'est pas livré comme artefact Core ML et le décodage TDT porte
des invariants propres aux durées et au blank token.

## Décision

Les poids officiels et leur conversion Core ML sont épinglés séparément par le manifeste, selon
l'ADR-0008. Le chemin d'inférence utilise Core ML pour l'encodeur, le décodeur et le joint, avec un
décodage TDT greedy en Swift. L'implémentation est adaptée de `parakeet-coreml-swift` à la révision
`75aec2a1c991319657ff4dec5f602c12da6c5012`, sous Apache-2.0, puis ajustée pour les invariants et le
cycle de vie de VoxoL.

Le log-mel vDSP, les entrées Core ML et les états LSTM réutilisent leurs buffers. Les captures de
moins de 30 secondes conservent leur longueur réelle et masquent le padding au niveau des features,
ce qui évite des tokens parasites produits par une normalisation sur du silence ajouté. L'encodeur
laisse Core ML choisir parmi toutes les unités de calcul ; le décodeur et le joint restent sur CPU,
configuration la plus rapide observée sur la machine de référence.

## Conséquences

Les modèles compilés sont mis en cache dans le répertoire immuable de la révision et préchargés hors
du main actor. Les poids et les bundles compilés ne sont jamais committés. Le smoke test
`Scripts/check-parakeet-runtime.sh` doit continuer à vérifier une transcription réelle, en plus des
tests unitaires du feature extractor et du tokenizer.

Pour les captures de plus de 30 secondes, le runtime mesure aussi la marge entre le token retenu et
son alternative la plus proche. Une marge du décile inférieur sous `0,75` déclenche un unique second
passage en fenêtres de 15 secondes; sa sortie ne remplace la première que si sa marge progresse de
plus de `0,10`. Ces métriques sont indépendantes du contenu et la latence publiée inclut toujours les
deux passages lorsqu'un retry a eu lieu.
