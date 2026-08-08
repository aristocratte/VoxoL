# Dataset et fine-tuning Qwen

Les exemples personnels sont désactivés par défaut et ne doivent être exportés qu'après un
consentement explicite. Chaque ligne source suit le format de la section 19 du cahier des charges,
porte `approved: true` après revue humaine et conserve les tokens protégés dans la cible.

Construire les splits reproductibles :

```sh
swift run voxol-dataset-builder \
  --input /chemin/vers/reviewed.jsonl \
  --output /chemin/vers/dataset
```

Le builder refuse les exemples non approuvés, trop longs ou perdant un token protégé, déduplique
les paires et produit `train.jsonl`, `valid.jsonl` et `test.jsonl` au format chat accepté par MLX
LM. Sans split explicite, le split 80/10/10 est dérivé de SHA-256 de l'identifiant. Pour un corpus
audio, les champs `split` et `split_group` doivent plutôt reprendre le split source/locuteur gelé ;
le builder rejette alors tout groupe présent dans plusieurs splits.

Après génération sur le split isolé, chaque ligne de prédiction contient `id`, `expected_text`,
`actual_text` et `protected_tokens`. Le rapport agrégé ne contient aucun texte :

```sh
swift run voxol-dataset-builder \
  --evaluate /chemin/vers/predictions.jsonl \
  --report /chemin/vers/evaluation.json
```

Le rapport mesure l'exact match, la distance d'édition normalisée, le rappel des tokens protégés et
le taux de mots ajoutés. Il faut comparer le modèle générique et l'adapter LoRA sur les mêmes IDs.

Le corpus Wispr privé se prépare et s'entraîne en une commande :

```sh
caffeinate -dimsu python3 Tools/training/run_qwen_wispr_finetune.py \
  --memory-gb 6
```

Le runner filtre les paires aberrantes, réutilise les groupes FR/EN gelés du benchmark Parakeet,
ajoute des cas no-op, limite MLX à 6 Gio et entraîne seulement les quatre derniers blocs
d'attention hybride. `select_qwen_checkpoint.py` compare ensuite les checkpoints sur un
sous-ensemble de validation fixe avant un test complet unique.

La génération brute et la sortie réellement insérable sont deux métriques distinctes. Le rapport
Python mesure la sortie brute et le fallback minimal sur placeholders. Pour rejouer le validateur
Swift exact de l'application :

```sh
swift run voxol-dataset-builder \
  --validate-predictions /chemin/vers/predictions.jsonl \
  --source /chemin/vers/source.jsonl \
  --report /chemin/vers/runtime-validation.json
```

Ce dernier rapport ne contient aucun texte. Un modèle fusionné et requantifié ne peut remplacer
l'artefact générique qu'après le validateur réel, les goldens de fidélité, les benchmarks M4 et un
nouveau manifeste signé.
