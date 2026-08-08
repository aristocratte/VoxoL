# Benchmarking

Tous les résultats sont des observations associées à un environnement, un commit et un schéma;
ils ne deviennent jamais des promesses produit sans corpus et protocole publiés.

Le benchmark de bootstrap mesure le coût de décodage et de validation du manifeste des modèles :

```sh
swift run voxol-benchmark \
  --manifest Models/manifests/runtime-models.json \
  --iterations 100 \
  --output Artifacts/Benchmarks/manifest-validation.json
```

Les runs locaux sont ignorés par Git. Une baseline n'est promue dans `Tests/Performance/Baselines`
qu'après revue de son protocole et de sa machine.

Le runtime Parakeet dispose aussi d'un smoke test de précision et de latence :

```sh
./Scripts/check-parakeet-runtime.sh
VOXOL_ASR_ITERATIONS=5 swift run -c release voxol-asr-smoke \
  --model-root "$HOME/Library/Application Support/VoxoL/Models/asr/<revision>" \
  --compute-units all \
  <audio-file>
```

Mesure indicative du 22 juillet 2026 sur MacBook Pro M4 16 Go, macOS 26.5.2, avec le cache Core ML
déjà compilé et cinq inférences dans le même processus : 159 ms au premier passage, puis 94–97 ms
par passage chaud pour une phrase courte. Ces nombres servent à détecter une régression locale ;
ils ne constituent pas une promesse produit.

Le polisher se compare dans un seul processus préchauffé afin de ne pas mélanger chargement et
génération. Le rapport contient les sorties synthétiques du corpus, donc il doit rester local :

```sh
.build/DerivedData/Build/Products/Debug/VoxoL.app/Contents/MacOS/VoxoL \
  --polisher-smoke \
  --model /chemin/vers/le-modele \
  --suite Tests/Performance/Fixtures/polisher-golden-v1.json
```

Le rapport sépare sorties acceptées par le validateur, exact match et latences moyenne, p50 et p95.
Une sortie acceptée n'est pas forcément la correction attendue; l'exact match et la revue des
différences restent obligatoires avant promotion ou fine-tuning.

Le benchmark privé du retry ASR fondé sur la confiance se trouve sous
`~/Library/Application Support/VoxoL/Reference/WisprFlow/asr-confidence-2026-07-23-v1`.
`inferenceAttemptCount` et `usedFallbackSegmentation` permettent de distinguer le coût réellement
payé du texte finalement retenu. Les seuils restent expérimentaux jusqu'à validation sur un nouveau
corpus multilingue qui n'a pas servi à leur exploration.

## Parité Parakeet

Le harnais de parité compare le même WAV mono 16 kHz avec le modèle Transformers officiel et le
port Core ML. Il conserve les features, masques, sorties encodeur, tokens, durées et trois meilleurs
logits de chaque décision, dans un répertoire local ignoré par Git :

```sh
swift run -c release voxol-parakeet-parity \
  --model-root "$HOME/Library/Application Support/VoxoL/Models/asr/<revision>" \
  --compute-units gpu \
  --output .build/parity/coreml \
  audio.wav

.build/parity-venv/bin/python Tools/parity/export_parakeet_reference.py \
  --revision <revision> \
  --audio audio.wav \
  --output .build/parity/source

.build/parity-venv/bin/python Tools/parity/compare_parakeet_snapshots.py \
  --source .build/parity/source \
  --coreml .build/parity/coreml \
  --output .build/parity/report.json
```

Le mode `cpu` fait partie de la matrice diagnostique, mais l'encodeur 4-bit distribué renvoie des
valeurs non finies sur le runtime Core ML CPU-only testé. Il ne doit donc pas servir de fallback
produit. `gpu`, `ane` et `all` doivent être comparés sur transcriptions, latence, énergie et mémoire.
Le rapport distingue le spectre de puissance, le log-mel avant normalisation, les features
normalisées et l'encodeur afin de localiser une divergence. Le runner ciblé rejoue les sorties
vides récupérées par le modèle source dans les deux modes de normalisation :

```sh
./Scripts/run-mediaspeech-recovered-parity.sh
```

La comparaison source/Core ML porte uniquement sur des entrées qui tiennent dans la fenêtre fixe
de 30 secondes de l'artefact distribué. La segmentation et la réconciliation des chevauchements
sont évaluées séparément.

## Corpus ASR indépendant

`voxol-asr-benchmark` impose des chemins audio relatifs, des références relues, des locuteurs et
sessions disjoints entre splits, puis fige le manifeste avec un SHA-256. Le rapport sépare WER/CER
verbatim, texte nettoyé, spans critiques, langues, tags, microphones, environnements et distributions
de latence.

Le petit corpus propriétaire sert seulement au développement et ne doit jamais calibrer ni
promouvoir un seuil :

```sh
./Scripts/run-owner-asr-pilot.sh
```

Le script reprend les captures déjà présentes, demande seulement les phrases manquantes, fige le
manifeste puis produit une nouvelle prédiction et un rapport datés. Il ne remplace aucun fichier
d'une exécution précédente.

Chaque prédiction Parakeet contient aussi les marges token/durée, le ratio de blanks, la couverture
temporelle et l'accord des overlaps. Une fois les splits de développement et de calibration
enregistrés, le modèle de risque logistique se construit hors de l'application :

```sh
.build/parity-venv/bin/python Tools/benchmarks/calibrate_asr_confidence.py \
  --manifest "$HOME/Library/Application Support/VoxoL/Benchmarks/benchmark-frozen.json" \
  --predictions "$HOME/Library/Application Support/VoxoL/Benchmarks/parakeet.jsonl" \
  --output "$HOME/Library/Application Support/VoxoL/Benchmarks/confidence-v2.json"
```

Le script refuse un split de développement trop petit et inscrit `promotionAllowed=false` tant que
les 200 cas de calibration et 700 cas blind requis ne sont pas présents. Aucun coefficient n'entre
dans l'application avant ces gates.

La promotion reste réservée au corpus verrouillé : 1 200 enregistrements originaux, 60 locuteurs,
splits disjoints par locuteur/session/pièce, plus 300 cas de stress. Les 101 audios Wispr et ce
petit corpus propriétaire restent des suites de régression, jamais le test final.

## Corpus public léger français/anglais

Le smoke public télécharge les splits de développement FLEURS épinglés et vérifiés, puis extrait
par hash 50 phrases françaises et 50 phrases anglaises distinctes. Les WAV mono 16 kHz et le
manifeste figé restent petits; le cache source partagé ajoute environ 313 Mo. Ce corpus de parole
lue détecte efficacement les régressions FR/EN et reste insuffisant pour mesurer la dictée longue,
le code, le bruit moderne ou les reformulations.

```sh
./Scripts/run-public-asr-lite.sh
```

Le nombre d'items peut être changé sans écraser le benchmark précédent :

```sh
VOXOL_PUBLIC_ASR_ITEMS_PER_LANGUAGE=100 ./Scripts/run-public-asr-lite.sh
```

Les références FLEURS mesurent l'ASR brut. Leur texte propre identique au verbatim permet aussi
de vérifier qu'un pipeline final ne dégrade pas une phrase déjà propre, mais ne constitue pas un
benchmark de correction par LLM.

Pour une mesure officielle française plus stable, le split `test` complet de FLEURS est préparé,
figé puis scoré séparément :

```sh
./Scripts/run-fleurs-fr-test-benchmark.sh
```

MediaSpeech français ajoute dix heures de segments issus de médias réels, transcrits manuellement.
Le runner vérifie l'archive OpenSLR SLR108, extrait les 2 498 paires FLAC/texte puis utilise le même
normaliseur, le même moteur et le même rapport que FLEURS :

```sh
./Scripts/run-mediaspeech-fr-benchmark.sh
```

FLEURS et MediaSpeech restent deux domaines distincts; leurs WER sont publiés séparément et ne sont
jamais moyennés en un seul score marketing.

Le run complet du 26 juillet 2026 et son interprétation sont conservés dans
`Docs/public-asr-benchmark-2026-07-26.md`. MediaSpeech est un stress test verrouillé : ses clips ne
doivent pas être réutilisés pour régler des seuils, entraîner ou fine-tuner le modèle évalué.

Les archives, fichiers audio, prédictions et rapports restent par défaut sous
`~/Library/Caches/VoxoL/Benchmarks` afin de survivre aux reconstructions SwiftPM; ils ne sont pas
distribués avec l'application. `VOXOL_BENCHMARK_ROOT` permet de choisir un autre cache.

Pour attribuer une faiblesse MediaSpeech au modèle officiel ou au port Core ML, le diagnostic
stratifié compare 20 sorties Core ML vides, 20 erreurs fortes et 10 cas de contrôle. Le modèle
Transformers officiel est chargé une seule fois et les résultats sont repris après interruption :

```sh
./Scripts/run-mediaspeech-source-diagnostic.sh
```

## Fine-tuning ASR

La chaîne de fine-tuning Parakeet est décrite dans `Docs/parakeet-finetuning.md`. Son préparateur
épingle FLEURS français/anglais, utilise uniquement `train` pour l'apprentissage et `dev` pour la
validation, puis produit des manifests NeMo traçables :

```sh
./Scripts/prepare-parakeet-fleurs-finetune.sh --print-plan
```

L'entraînement s'exécute exclusivement sur Linux NVIDIA avec le commit NeMo attendu. Les
prédictions du checkpoint source sont scorées sur FLEURS `test` et MediaSpeech avant toute
conversion Core ML; les jeux verrouillés ne sont jamais réinjectés dans l'entraînement.

## Challengers ASR

Les challengers restent dans `.build` et ne deviennent jamais un troisième artefact distribué. Le
runner MLX est reprenable ligne par ligne et garde modèle, mode de langue, latence et pic mémoire :

```sh
.build/asr-challenger-venv/bin/python Tools/benchmarks/run_mlx_asr_challenger.py \
  --model mlx-community/Qwen3-ASR-0.6B-4bit \
  --manifest <parakeet-results.jsonl> \
  --audio-root <racine-du-corpus> \
  --output .build/benchmarks/results/qwen3-asr.jsonl \
  --language-mode auto \
  --resume

python3 Tools/benchmarks/score_asr_challengers.py \
  --baseline <parakeet-results.jsonl> \
  --candidate qwen3=.build/benchmarks/results/qwen3-asr.jsonl \
  --output .build/benchmarks/results/asr-challengers.json
```

WhisperKit se lance avec son CLI natif dans un seul processus, puis ses rapports sont convertis
vers le même schéma challenger avec `Tools/benchmarks/collect_whisperkit_results.py`. Le chargement
à froid, la latence par audio et la langue détectée restent séparés.

Le corpus Wispr est explicitement étiqueté `teacher-not-human-ground-truth` dans le rapport et ne
peut promouvoir aucun modèle.

## Latence produit

Les diagnostics de l'application utilisent une horloge monotone et exposent arrêt de capture,
features, encodeur, décodeur, détokénisation, texte prêt et insertion. Des signposts
`dictation-performance` permettent la lecture dans Instruments sans journaliser le texte.

La sonde contrôlée mesure séparément le raccourci jusqu'au texte réellement visible dans TextEdit :

```sh
./Scripts/check-live-insertion.sh
```
