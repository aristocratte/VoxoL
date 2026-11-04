# Dataset et fine-tuning

## Expériences de curation IA autorisées le 11 septembre 2026

Le propriétaire a explicitement confié à l'agent la collecte, le nettoyage des données,
l'entraînement et les comparaisons continues, avec Wispr comme teacher possible.
Cette autorisation ouvre une voie expérimentale distincte du gate humain historique ci-dessous :
`voxol-dataset-builder --ai-experiment`. Elle exige `source: "ai-curated-experimental"`
et `approved: false`. Les sources gelées conservent `humanReviewed: false`, les preuves,
les corrections et les exclusions. Les contrôles de fidélité et les groupes disjoints restent actifs.

Les références IA servent au développement sans devenir des preuves humaines ou indépendantes.
Le modèle parent est pristine ; les prises réservées et les benchmarks publics restent hors train.
Le contexte audio/vidéo peut expliquer une ambiguïté, mais une information inaccessible au
correcteur textuel doit être marquée comme telle. Une cible impossible à déduire de son entrée
ne doit pas enseigner au correcteur à inventer. Les anciens gates, jeux et résultats sont conservés.
L'application installée et ses poids ne sont remplacés par aucune expérience automatique.

Les exigences humaines décrites dans la suite concernent la voie historique de promotion,
et ne bloquent pas ces entraînements expérimentaux explicitement autorisés.

Parakeet reste le moteur ASR produit. Gemini Transcriber et Wispr Flow sont des challengers et des
teachers; leurs sorties ne sont jamais une référence humaine par défaut. Aucun nouveau fine-tuning
Qwen ne doit partir tant que le corpus n'atteint pas le gate humain ci-dessous.

## Niveaux de confiance

- Une cible `gold-human-reviewed` a été corrigée ou explicitement approuvée par une personne. Elle
  peut entraîner Qwen et servir de référence si elle n'a pas été utilisée pour régler le candidat.
- Une transcription Gemini/Wispr est `silver`. Le verbatim qui passe les contrôles peut alimenter
  un corpus ASR teacher, mais reste séparé des benchmarks humains.
- Une version mise en forme par Gemini est un candidat `pending`. Elle ne devient une cible Qwen
  qu'après revue humaine; préserver les nombres, noms, URLs, chemins, code et négations est bloquant.
- Les exemples synthétiques peuvent renforcer le train, jamais validation, test ou benchmark final.

Les données personnelles restent opt-in, locales et exportables seulement avec le consentement du
propriétaire. Les benchmarks verrouillés ne sont jamais réinjectés dans l'apprentissage.

## Corpus diagnostique actuel

`Data/corpus/human-v1.jsonl` conserve son nom de fichier historique, mais son rôle officiel est
`diagnostic-ai-labeled-v1` : 184 lignes issues de 92 sources, avec des cibles proposées par IA puis
revues, et non 184 références humaines indépendantes. Il sert à diagnostiquer Qwen et les
validateurs, jamais à promouvoir ou entraîner un modèle. L'audit reproductible est généré par :

```sh
python3 Scripts/audit-diagnostic-corpus.py \
  --corpus Data/corpus/human-v1.jsonl \
  --output Data/corpus/diagnostic-ai-labeled-v1-audit.json
```

Les deux lignes marquées `es` sont exclues des gates FR/EN. Training Studio produit désormais
quatre références distinctes (`verbatim_gold`, `faithful_gold`, `rewrite_gold`, `code_gold`) ; les
trois premières doivent être relues avant acceptation, et `code_gold` reste facultative hors code.

## Splits reproductibles

```sh
swift run voxol-dataset-builder \
  --input /chemin/vers/reviewed.jsonl \
  --output /chemin/vers/dataset
```

Le builder refuse les exemples non approuvés, trop longs, invalides ou perdant un token protégé,
les déduplique, puis écrit `train.jsonl`, `valid.jsonl` et `test.jsonl`. Sans `split_group`, il
dérive le split du SHA-256 de l'ID. Avec `split_group`, il hash le groupe entier; si un membre porte
un split explicite valide, tous les membres l'héritent, et deux splits explicites contradictoires
font rejeter le groupe. Une source, une session ou un locuteur ne peut donc plus traverser les
splits parce que ses lignes ont des IDs différents.

L'ancien corpus de 411 lignes franchissait les splits sur 52 groupes et 183 lignes. Le correctif
ramène ce chevauchement à zéro, mais le JSONL exact des candidats R1/R3 n'est plus disponible : ces
adapters restent quarantainés, même si leurs poids existent encore localement.

## Collecte Gemini

Le mode `training` de Gemini Transcriber découpe aux silences en segments de 30 secondes maximum et
charge chaque segment une seule fois dans Gemini.app. Un premier tour produit le verbatim, puis un
second tour textuel dans le même chat produit la version mise en forme. Le pont sélectionne Flash sans
raisonnement étendu, restaure l'application précédemment au premier plan, applique les contrôles de
qualité et reprend uniquement les segments échoués :

```sh
cd ~/Documents/stt-factory
GEMINI_TRANSCRIPTION_MODE=training \
GEMINI_SPEAKER_ID=<locuteur> \
GEMINI_SESSION_ID=<session> \
./gemini-transcribe.sh <audio|dossier|URL-YouTube>
```

Gemini.app doit être installé et connecté, et Gemini Transcriber doit avoir l'autorisation
Accessibilité. Aucune clé API n'est utilisée. Le profil inclut la langue, par exemple
`training-utterance-v5-app-fast-lang-fr`, afin qu'une capture `auto` ne puisse jamais être réutilisée
dans une campagne française. Une sortie détectée avec forte confiance dans une langue sans rapport
est rejetée et retentée, tout en autorisant les commutations français/anglais. Les manifests sont
eux aussi filtrés sur ce profil actif : les anciens records restent auditables sur disque sans entrer
dans le corpus d'entraînement courant.

`asr-manifest.jsonl` contient les verbatims silver acceptés. `polisher-review.jsonl` contient les
candidats de mise en forme, tous `pending`; `polisher-manifest.jsonl` reste vide tant qu'aucune
revue humaine n'a été appliquée. Pour valider une cible, corriger `candidate_text`, passer
`approval_status` à `approved`, puis appliquer la revue :

```sh
python3 gemini_dataset.py apply-review \
  --records <dataset>/records \
  --review <dataset>/polisher-review.jsonl \
  --dataset <dataset> \
  --reviewer owner
```

La commande conserve la cible teacher séparément, inscrit le hash de la cible humaine et refuse
une approbation qui perd un token protégé.

Il n'y a donc pas de distillation directe de Gemini vers Qwen : Gemini et Wispr proposent des
candidats et révèlent les erreurs contextuelles, tandis que seules les cibles explicitement revues
par un humain peuvent franchir le gate d'entraînement du polisher.

## Gate du prochain Qwen

L'adapter `voxol-adapter` reste le runtime local historique, mais sa lignée Wispr et son dataset
non persisté l'interdisent comme parent. Les candidats propres R1/R3 sont également non promotables
parce que leur payload d'entraînement et leur évaluation sans fuite ne sont pas reproductibles.

Le prochain essai repart du Qwen 0.8B pristine et exige au minimum 500 corrections humaines
réelles après nettoyage déterministe, dont 150 cas validation/test disjoints par source ou session,
avec représentation française et anglaise. Avant de lancer l'entraînement, le dépôt doit contenir
le dataset gelé complet, ses SHA-256, la recette et un audit à zéro groupe traversant les splits.
`Scripts/train-voxol-qwen-mass-campaign.sh` refuse désormais l'ancien gate v1 : seul un
`voxol-qwen-human-gate-v2` portant ces comptes, le hash source et la révision pristine peut lancer
un run, sans reprise depuis l'adapter Wispr.

La préparation et le lanceur utilisent tous deux `Scripts/build-qwen-human-gate.py` (raccord corrigé
le 6 septembre 2026). `--root <campagne préparée>` produit le gate v2 ; `--check` le recalcule sans
écriture et exige à la fois son éligibilité et son identité avec le fichier sauvegardé. Les hashes
couvrent la source, sa normalisation, les références, le résumé et les trois fichiers MLX. Un ancien
gate v1 ou un gate devenu périmé est refusé, même s'il contient un booléen d'éligibilité vrai.

Seules les lignes du contrat source `source: "human"` avec `approved: true` strictement booléen
contribuent aux quotas ; il s'agit d'une déclaration explicite de provenance, pas d'une certification
automatique de l'identité du relecteur. Ne jamais renommer des sources IA pour satisfaire ce contrat.
`approved` seul, les références contextuelles, Wispr, `human-authored` historique et les exemples
synthétiques ne comptent pas. Les copies après normalisation et les lignes rejetées sont exclues.
Toute ligne acceptée dont la provenance n'est ni humaine ni `synthetic-reviewed` dans le train
bloque le lancement : ajouter assez de références humaines ne blanchit donc pas un reste de
cibles teacher non relues. Les exemples synthétiques ne sont jamais admissibles dans le held-out.
Les variantes fidèle/réécriture d'une même entrée ne multiplient pas le nombre de corrections ;
les textes identiques normalisés traversant les splits bloquent également le gate, même si leurs
groupes ont été renommés. Cette déduplication prudente ne détecte pas toutes les quasi-copies audio.

Un ancien résultat `not-trained` ne clôt plus artificiellement la campagne : une fois les données
effectivement prêtes, le lanceur peut repasser le contrôle. Un blocage ne remplace plus le fichier
de résultat d'entraînement par un faux résultat terminé.

La promotion demande ensuite au moins 5 % de gain relatif sur le WER propre face au runtime actuel,
100 % de conservation des spans protégés après le validateur, aucune hausse des mots inattendus et
une latence p95 dans l'enveloppe actuelle. Le candidat ne remplace jamais l'adapter installé
automatiquement.

## Évaluation Qwen

Chaque prédiction contient `id`, `expected_text`, `actual_text` et `protected_tokens`. Le rapport
agrégé ne conserve aucun texte :

```sh
swift run voxol-dataset-builder \
  --evaluate /chemin/vers/predictions.jsonl \
  --report /chemin/vers/evaluation.json

swift run voxol-dataset-builder \
  --validate-predictions /chemin/vers/predictions.jsonl \
  --source /chemin/vers/source.jsonl \
  --report /chemin/vers/runtime-validation.json
```

Il faut comparer le modèle pristine, l'adapter runtime et le candidat sur les mêmes IDs gelés, en
séparant la génération brute de la sortie finalement acceptée par le validateur Swift.
