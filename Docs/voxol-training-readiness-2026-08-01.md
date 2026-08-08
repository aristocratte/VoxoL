# VoxoL — décision d'entraînement au 1er août 2026

Le prochain fine-tune Parakeet est justifié comme challenger mesuré, mais il ne doit pas remplacer
le modèle actuel sans passer les gates. Le fine-tune Qwen est également nécessaire pour viser un
refining meilleur que Wispr, mais il serait prématuré avant la nouvelle adjudication fondée sur le
raw Parakeet exact.

## Parakeet

Le dataset v2 conserve les 15 anciens enregistrements dans leur split historique et assigne 20
nouvelles sources sans chevauchement de locuteur ni d'enregistrement. Après filtrage, il contient
16,22 h de train, 3,39 h de validation et 3,97 h de test.

Le modèle de production obtient 8,22 % de WER sur les 559 segments du test figé : 5,36 % en anglais
et 10,77 % en français. Le retry strict simulé descend à 8,01 % ; il améliore 46 des 289 segments
difficiles examinés sans régression observée, mais ses seuils ont été choisis sur ce corpus et
restent donc un candidat de développement. En Release, un segment rejoué prend environ 506 ms en
moyenne et 592 ms au p95.

Le prochain candidat ne sera promu que s'il atteint simultanément : WER global ≤ 7,81 %, français
≤ 10,23 %, anglais ≤ 5,56 %, aucun nouvel output vide, régression FLEURS/MediaSpeech ≤ 0,5 point,
parité Core ML et latence produit non dégradée.

## Qwen

Les 320 revues GPT Pro existantes ont été réalisées sur le raw Wispr. Face au vrai raw Parakeet,
seulement 24 entrées sont équivalentes après normalisation et 3 sont vides ; les cibles ne peuvent
donc pas être réutilisées aveuglément.

Le package de réalignement contient 16 lots de 20 segments, sans audio. Le raw Parakeet exact est
l'unique autorité ; le raw/edited Wispr et les anciennes revues servent seulement d'indices. Après
retour des 320 JSON, Codex doit les valider, exclure les transformations non récupérables, figer un
test source-disjoint puis lancer un LoRA Qwen pilote. Aucune donnée de ce package n'est encore
training-ready.

## Artefacts prêts

- Dataset Parakeet : `/Volumes/0_Oueillez/wispr-data/prepared/voxol-wispr-asr-v2-20260801.tar.gz`
  (`SHA-256 6ff3c5eaf5cfd60a86fbd7d1a9c1bd267d9748f76c1d0018c9565ac5f09697e8`).
- Lanceur RunPod : `Scripts/launch-voxol-runpod-training.sh`.
- Package Qwen à envoyer :
  `/Volumes/0_Oueillez/wispr-data/review-packages/VoxoL-GPT-Pro-Parakeet-Refining-Adjudication-v1-20260801T203000Z/bulk-upload/VoxoL-GPT-Pro-Parakeet-Refining-Adjudication-v1-20260801T203000Z-16-batches.zip`.
- Archive maître Qwen :
  `/Volumes/0_Oueillez/wispr-data/review-packages/VoxoL-GPT-Pro-Parakeet-Refining-Adjudication-v1-20260801T203000Z.zip`
  (`SHA-256 8b828e4a8f95e0fcdfaf257e80d2549c0c67dd22a7e63e32682a29919e7da360`).

Validation locale : 124 tests Swift et 27 tests Python passent.
