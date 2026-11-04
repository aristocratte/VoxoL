# ADR-0011 — Transcriptions avec locuteurs en Swift et Core ML

- Statut : acceptée pour la version isolée à vérifier
- Date : 2026-09-23
- Remplace partiellement : ADR-0002 et ADR-0008 pour le mode Réunions

## Contexte

L’utilisateur demande une prise en charge native des intervenants et accepte deux réseaux séparés
si leur fusion n’est pas immédiatement possible. L’écran Réunions existant était une maquette.

## Décision

Les fichiers audio importés, jusqu’à une heure, passent par Parakeet puis Nemotron 3 Diarization.
Les deux reçoivent exactement le même signal mono à 16 kHz. Les horodatages Parakeet (80 ms par
frame) sont rapprochés des probabilités de voix Nemotron (10 ms par frame). Les frontières
incertaines restent sans attribution. Les voix simultanées sont signalées; cette chaîne ne sépare
pas leurs signaux et ne garantit pas la transcription de toutes les paroles superposées.

Le modèle supplémentaire est facultatif, chargé à la demande dans le mode Réunions. Le manifeste
des deux modèles de dictée conserve son contrat. `SpeakerModelAssets` épingle séparément les cinq
fichiers nécessaires, leurs tailles, SHA-256 et URLs immuables. Le téléchargement ne concerne que
ces fichiers publics; aucun audio ni texte n’est envoyé. Aucun runtime Python n’est utilisé.

- Source : https://huggingface.co/nvidia/Nemotron-3-Diarization
- Conversion : https://huggingface.co/FluidInference/nemotron-3-diarization-coreml
- Révision : `53445f72d5735e33406ccce7b92116bce7ab1ab7`, preset `fast32`, OpenMDW-1.1.
- Runtime Swift : FluidAudio `5c51c5c93afff0d89594a2a93c3103e790ba648c`, Apache-2.0,
  dépendance SPM avec les traits facultatifs désactivés. Aucun autre modèle FluidAudio n’est chargé.

Les transcriptions structurées possèdent leur propre archive versionnée dans `VoxoL/Meetings`.
Les réglages d’historique et de mode privé contrôlent l’enregistrement automatique. Le fichier
audio importé n’est pas copié. Les noms saisis ne valent que pour cet enregistrement; aucune
identification biométrique persistante. Renommage, copie et exports TXT/SRT/JSON conservent les
étiquettes et les temps. Les erreurs d’archive empêchent sa réécriture automatique.

## Vérification et limites

Tests de l’alignement Unicode, des changements de voix, de l’incertitude, du chevauchement, de la
persistance et des exports, de l’intégrité des modèles, et de la conversion audio. Un test de
bout en bout sur l’extrait public annoté de pyannote doit compléter compilation et tests unitaires.
Cela ne constitue pas une qualification sur un corpus français de réunions. Les timestamps ASR
restent approximatifs. La première version traite les enregistrements importés; elle ne capture
pas le son système d’une visioconférence et n’affiche pas de sous-titres en direct.

La validation s’effectue dans une copie de l’état de travail, avec un identifiant d’application,
des archives et des modèles de test séparés. L’application installée reste intacte.
