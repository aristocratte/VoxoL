# Audit d'optimisation Parakeet — 26 juillet 2026

## Verdict

Le premier candidat conserve l'architecture FastConformer-TDT officielle. Il spécialise uniquement
les six à huit dernières couches de l'encodeur, le prédicteur et le joint, puis doit passer les
benchmarks source avant tout export. C'est la seule modification de modèle actuellement assez
réversible pour être exécutée sur un GPU Colab de 16 à 40 Go sans casser le tokenizer, le décodeur
TDT ou la conversion Core ML.

Une réduction structurelle ne serait pas un fine-tuning : elle demanderait une distillation avec
beaucoup plus de données audio indépendantes. La faire sur FLEURS seul optimiserait probablement le
benchmark de parole lue au détriment des noms, des nombres, du code-switch et de MediaSpeech.

## Ce qui coûte réellement du temps

Le modèle officiel contient environ 600 millions de paramètres. Sa configuration utilise un
encodeur FastConformer de 24 couches, une dimension cachée de 1 024, des blocs feed-forward de
4 096, un sous-échantillonnage par huit et un prédicteur LSTM à deux couches de dimension 640. Le
tokenizer partagé contient 8 192 entrées.

Sur le Mac M4 de référence, une dictée courte chaude prend environ 97 à 100 ms :

- 85 à 87 ms dans l'encodeur Core ML;
- 10 à 12 ms dans le prédicteur/joint et le greedy TDT Swift;
- 1 à 2 ms dans le log-mel.

Réduire seulement le décodeur ne peut donc pas produire un gain produit important. L'encodeur et sa
quantification sont les cibles utiles.

## Décisions d'architecture

| Variante | Gain possible | Risque qualité et intégration | Décision |
|---|---:|---|---|
| Spécialisation des 6–8 couches supérieures | Meilleure adaptation avec moins de mémoire d'optimiseur | Modéré, architecture et export inchangés | Tester maintenant |
| Fine-tuning complet des 24 couches | Qualité potentiellement supérieure avec beaucoup de données | Oubli multilingue et mémoire élevée sur T4/L4 | Différer |
| Suppression de 24 à 16 couches | Environ un tiers d'encodeur en moins en théorie | Forte régression sans distillation; nouveaux poids et export | Rejeter maintenant |
| Dimension 1 024 → 768 ou FFN 4 096 → 3 072 | Réduction importante de calcul et de taille | Réentraînement/distillation structurelle obligatoire | Rejeter maintenant |
| Sous-échantillonnage 8 → 16 | Moins de frames encodeur | Perte probable sur mots courts, nombres et noms; contrat Core ML modifié | Rejeter maintenant |
| Prédicteur LSTM plus petit | Quelques millisecondes au mieux | Effort de conversion disproportionné | Rejeter maintenant |
| Attention locale/streaming | Meilleure échelle sur les longues réunions | Cache, alignement et export différents du push-to-talk actuel | Phase Réunion |
| Export int8 | Meilleure parité attendue que le 4-bit, taille encore raisonnable | Environ 140 Mo de plus que l'int4 Mobius documenté | Challenger prioritaire après le gate |
| Export int4 | Taille minimale | L'encodeur 4-bit actuel est déjà le principal écart source/Core ML | Challenger taille, jamais candidat unique |

La mesure publiée par Mobius sur LibriSpeech donne 2,64 % de WER et environ 425 Mo pour l'int8,
contre 3,76 % et environ 285 Mo pour l'int4. Ces chiffres ne prédisent pas VoxoL, mais justifient un
bake-off int8/int4 plutôt qu'une quantification plus agressive imposée sans gate.

## Recette retenue

Le profil Colab garde un batch effectif de 16 et adapte la mémoire :

| GPU | Précision | Batch × accumulation | Durée maximale | Couches encodeur entraînées |
|---|---|---:|---:|---:|
| T4 16 Go | FP16 mixed | 1 × 16 | 12 s | 6 |
| L4 24 Go | BF16 mixed | 2 × 8 | 18 s | 8 |
| A100 ≥40 Go | BF16 mixed | 4 × 4 | 30 s | 8 |

Les couches inférieures sont gelées, y compris leurs statistiques BatchNorm. Le tokenizer, le
front-end, le sous-échantillonnage, les 24 couches et le chemin TDT restent inchangés à
l'inférence. Le learning rate est `2e-5`, avec warm-up de 100 pas, cosine decay, SpecAugment, cinq
époques et un seul meilleur checkpoint reprenable sur Drive.

Si CUDA manque de mémoire, le notebook relance automatiquement un profil batch 1, 10 secondes et
quatre couches supérieures. Un échec qui n'est pas un OOM s'arrête au lieu de masquer une erreur de
données ou de dépendances.

## Gate

FLEURS `train/dev` sert uniquement à l'entraînement et à la validation. Les splits officiels
FLEURS `test` français et anglais ainsi que MediaSpeech français sont téléchargés séparément et
restent aveugles.

Le checkpoint source passe seulement si :

- le WER micro FLEURS global, français et anglais ne régresse pas de plus de 0,5 point absolu;
- MediaSpeech s'améliore d'au moins 10 % relatif;
- le nombre de sorties MediaSpeech vides diminue.

Un succès autorise un export Core ML int8 et int4. Il ne promeut pas encore le modèle dans l'app :
les deux exports doivent ensuite passer la parité source/Core ML, le WER/CER, les sorties vides, la
latence M4, la mémoire, l'énergie et la taille installée.

## Limite de cette expérience

FLEURS est de la parole lue propre. Cette vingtaine d'heures FR/EN peut valider le pipeline et
préserver les deux langues, mais elle a peu de chances de résoudre seule les 39,66 % de WER du port
actuel sur MediaSpeech. Si le gate rejette le checkpoint, l'action rationnelle est de collecter ou
licencier un corpus d'entraînement distinct de parole média et de dictée réelle, puis de garder
MediaSpeech verrouillé. Modifier davantage l'architecture ne remplace pas les données acoustiques
manquantes.

## Sources primaires

- [NVIDIA Parakeet TDT 0.6B v3 — modèle, entraînement et résultats](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [Configuration officielle Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/blob/main/config.json)
- [NeMo — fine-tuning ASR](https://docs.nvidia.com/nemo/speech/nightly/asr/fine_tuning.html)
- [Google Colab — disponibilité, limites et durée des runtimes](https://research.google.com/colaboratory/faq.html)
- [Mobius — export Core ML Parakeet int8/int4](https://github.com/FluidInference/mobius/blob/d2398af6042684a1b06dbc6951bdb50e1cf0366a/models/stt/parakeet-tdt-v3-0.6b/coreml/README.md)
