# Fine-tuning Parakeet FR/EN

Ce pipeline est une expérience contrôlée, pas une promotion automatique. FLEURS `train` sert à
l'entraînement, FLEURS `dev` à la validation, tandis que FLEURS `test` et MediaSpeech restent
verrouillés pour mesurer la généralisation. Un checkpoint qui améliore seulement FLEURS ne justifie
pas une conversion Core ML.

La voie la plus simple est le notebook autonome
`Notebooks/VoxoL_Parakeet_Finetune_Colab.ipynb`. Dans Google Colab, sélectionner un GPU puis
exécuter **Runtime → Run all**. Après l'autorisation Google Drive, le notebook choisit le profil
T4/L4/A100, reprend les téléchargements vérifiés, entraîne, évalue la baseline et le
candidat, puis écrit la décision dans
`My Drive/VoxoL-Parakeet/results/source-gate.json`. La version
`2026-07-27-fleurs-tsv-v2` vérifie le cache Drive avant usage,
remplace automatiquement un artefact final corrompu et retente une fois depuis zéro lorsqu'un
fichier `.partial` repris échoue au checksum. Un échec persistant est conservé dans
`My Drive/VoxoL-Parakeet/logs/` avec l'URL et le fichier concernés.

Lightning ne crée aucun checkpoint NeMo pendant l'entraînement : même un checkpoint « poids seuls »
des 627 M paramètres dépassait la RAM hôte du runtime T4. À chaque amélioration de `val_wer`, le
runner sauvegarde uniquement les couches entraînées, le décodeur et le joint en FP16 dans un
`.delta.pt`, puis le copie vers `My Drive/VoxoL-Parakeet/candidates/`. L'évaluateur recharge le
Parakeet officiel et applique ce delta après vérification de chaque tenseur. Les téléchargements et
le delta final sont persistants, mais une déconnexion pendant l'entraînement redémarre la tentative.

Les fichiers FLEURS sont des TSV bruts et leurs guillemets font partie du texte; ils ne suivent pas
les règles de citation CSV. Tous les parseurs utilisent donc `csv.QUOTE_NONE`, sinon une
transcription commençant par un guillemet peut fusionner les colonnes suivantes et provoquer un
faux `Unexpected FLEURS row`.

NeMo est installé en mode editable depuis le checkout épinglé. Comme un kernel Colab déjà lancé ne
recharge pas automatiquement le fichier `.pth` créé par `pip -e`, le notebook ajoute explicitement
`/content/NeMo` à `sys.path`, invalide le cache d'import puis vérifie `find_spec("nemo")`. Il ne faut
pas redémarrer le runtime après l'installation : **Run all** doit rester continu.

L'audit et les raisons de conserver l'architecture se trouvent dans
`Docs/parakeet-model-optimization-audit-2026-07-26.md`.

## Lanceur autonome pour un GPU loué

`VoxoL_GPU_Train.sh` est le chemin recommandé hors Colab. C'est un fichier autonome : il embarque
les sources épinglées, vérifie le GPU, la RAM, le disque et le budget avant les téléchargements,
installe NeMo dans un environnement isolé, prépare les données, entraîne, reprend les prédictions
de benchmark et crée une archive ZIP récupérable.

Sur une image Ubuntu avec PyTorch CUDA et un GPU de 24 Go, transférer uniquement ce fichier puis
lancer :

```sh
bash VoxoL_GPU_Train.sh \
  --hourly-price 0.35 \
  --budget 10 \
  --max-hours 6 \
  --yes
```

Le prix horaire doit être le prix total réellement affiché par le fournisseur. Le script refuse
un coût maximal supérieur au budget et arrête ses processus à l'échéance, mais il ne peut pas
fermer le compte fournisseur : après avoir récupéré l'archive, il faut arrêter ou détruire
l'instance dans le tableau de bord. `--auto-shutdown` éteint l'OS, sans garantir l'arrêt de la
facturation.

Le dossier de travail est `/workspace/voxol-parakeet` lorsque `/workspace` existe, sinon
`~/voxol-parakeet`; `--work-root` permet de viser explicitement un volume persistant. Relancer la
même commande réutilise les téléchargements vérifiés, un candidat terminé et les prédictions
complètes. Une coupure pendant l'entraînement redémarre la tentative, car aucun état Adam complet
n'est sérialisé, mais le meilleur delta de chaque époque reste dans `candidates/recovery`.
Sur RunPod, le lanceur utilise automatiquement le volume `/workspace` et les variables
`RUNPOD_PUBLIC_IP`/`RUNPOD_TCP_PORT_22` pour imprimer une commande `scp` directement exploitable.

À la fin, le terminal affiche `ARCHIVE À RÉCUPÉRER` et une commande `scp`. L'archive contient le
delta FP16, les scores baseline/candidat, `source-gate.json`, tous les logs, les SHA-256 et
`quantization-plan.json`. Le plan int8/int4 n'est activé que si le gate source passe; la conversion
Core ML reste exécutée et mesurée sur le Mac M4.

## 1. Préparer les données sur la machine GPU

La préparation télécharge les archives françaises et anglaises à la révision épinglée, reprend un
téléchargement interrompu, vérifie chaque SHA-256, extrait uniquement les fichiers référencés et
produit les manifests NeMo. Les archives `train` représentent 3,11 Go; les splits `dev` s'ajoutent
au cache.

```sh
./Scripts/prepare-parakeet-fleurs-finetune.sh --print-plan
./Scripts/prepare-parakeet-fleurs-finetune.sh
```

Le résultat reste par défaut dans
`~/Library/Caches/VoxoL/Training/parakeet-fleurs-fr-en`. Il contient `train.jsonl`,
`validation.jsonl`, l'audio et `provenance.json`. Aucun split `test` et aucun fichier MediaSpeech
n'est admis dans ces manifests.

## 2. Préparer NeMo sur Linux NVIDIA

Le runner exige le commit NeMo
`2381f42f6979449b5b99538f8f80135831009b51`; il refuse un autre checkout et s'arrête si CUDA n'est
pas disponible. Le build PyTorch CUDA doit correspondre au pilote du serveur.

```sh
git clone https://github.com/NVIDIA-NeMo/NeMo.git
git -C NeMo checkout 2381f42f6979449b5b99538f8f80135831009b51

python3 -m venv .venv
. .venv/bin/activate
# Installer d'abord le build PyTorch CUDA adapté à la machine.
python -m pip install -e './NeMo[asr]'

export VOXOL_NEMO_ROOT="$PWD/NeMo"
export VOXOL_TRAINING_PYTHON="$PWD/.venv/bin/python"
./Scripts/run-parakeet-finetune.sh
```

La configuration conserve le tokenizer multilingue et l'architecture du modèle source. Elle
entraîne les couches supérieures de l'encodeur, le prédicteur et le joint, utilise un learning rate
`2e-5`, un warm-up de 100 pas, une taille de batch effective de 16 et cinq époques. La précision,
le micro-batch, la durée maximale et le nombre de couches entraînées sont adaptés à la mémoire GPU.
Le meilleur checkpoint local contient uniquement le sous-ensemble de tenseurs réellement entraîné,
en FP16. Aucun état d'optimiseur et aucun poids gelé n'est sérialisé.

## 3. Évaluer avant toute conversion

Le notebook exécute automatiquement ce gate sur FLEURS `test` français et anglais ainsi que
MediaSpeech français. Pour une exécution Linux manuelle, copier sur la machine GPU les dossiers de
benchmark figés, puis produire les prédictions avec le checkpoint candidat :

```sh
python Tools/training/run_nemo_asr_benchmark.py \
  --delta /chemin/vers/le-candidat.delta.pt \
  --manifest /benchmarks/fleurs-fr-test/manifest-frozen.json \
  --audio-root /benchmarks/fleurs-fr-test/audio \
  --output /resultats/fleurs-finetuned.jsonl \
  --resume

python Tools/training/run_nemo_asr_benchmark.py \
  --delta /chemin/vers/le-candidat.delta.pt \
  --manifest /benchmarks/mediaspeech-fr/manifest-frozen.json \
  --audio-root /benchmarks/mediaspeech-fr/audio \
  --output /resultats/mediaspeech-finetuned.jsonl \
  --resume
```

Les prédictions se scorent ensuite avec le même moteur que le port Core ML :

```sh
swift run -c release voxol-asr-benchmark score \
  --manifest /benchmarks/fleurs-fr-test/manifest-frozen.json \
  --predictions /resultats/fleurs-finetuned.jsonl \
  --output /resultats/fleurs-finetuned-report.json
```

Répéter la commande pour MediaSpeech. Le candidat ne passe à la conversion que s'il ne régresse
pas FLEURS de plus de 0,5 point absolu, améliore MediaSpeech d'au moins 10 % relatif, réduit les
sorties vides et ne crée pas de dérive de langue observée.

## 4. Conversion Core ML

La conversion n'est lancée qu'après le gate source. Le modèle complet doit d'abord être reconstruit
dans un processus NeMo frais à partir du modèle officiel et du delta, sans optimiseur ni données
d'entraînement en mémoire. `FluidInference/mobius` est épinglé au commit
`d2398af6042684a1b06dbc6951bdb50e1cf0366a` et sait exporter un checkpoint `.nemo`, mais son contrat
actuel utilise une fenêtre fixe de 15 secondes et des interfaces différentes du runtime VoxoL de
30 secondes. Il faut donc benchmarker son export int8 et écrire l'adaptateur Swift avant de
remplacer l'artefact actuel; copier directement ses fichiers dans le dossier des modèles casserait
le runtime.

Le gate de conversion compare obligatoirement le checkpoint NeMo et l'export Core ML sur les mêmes
WAV, jusqu'aux features, sorties encodeur, tokens et durées. Une régression supérieure à 0,5 point
de WER ou une hausse des sorties vides rejette l'export même si sa taille ou sa latence est meilleure.
