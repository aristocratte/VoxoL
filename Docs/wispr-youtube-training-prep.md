# Lot YouTube Wispr : préparation expérimentale

Le lot 1 contient les 25 vidéos de
`Data/corpus/wispr-youtube-lot1-sources.json` (12 FR, 13 EN). Les indications
`All` / `None` y reproduisent le tableau fourni par l'utilisateur : elles ne
constituent pas une nouvelle vérification des droits. Le périmètre demandé est
de **conserver tous les audios**, même si une requête Wispr échoue. Une absence
de transcription valide reste visible et ne devient pas une cible d'entraînement.

## Stockage et reprise

Le dossier de collecte actif reste `~/Documents/wispr/transcripts`. Ses dossiers
`dataset/records` et `youtube-audio` sont des liens vers
`/Volumes/0_Oueillez/wispr-data/youtube-lot1-2026-09-24`. Le SSD doit donc être
monté avant de reprendre une collecte ou d'exploiter les audios. Les états de
jobs et les manifestes consolidés restent locaux ; une copie des jobs antérieurs
à la migration est conservée sur le SSD.

L'interface autonome est sur `http://127.0.0.1:62581/`. Le 25 septembre 2026,
le job de ce lot est arrêté : 16 vidéos sont `done` et 9 sont
`transcription_failed` avec des enregistrements partiels conservés. Les 25
audios sources et leurs empreintes sont présents. Wispr a rendu 4 930 segments
`edited` en HTTP 200 et 205 en HTTP 500 sur 5 135 segments. La relance des
requêtes en échec a reproduit des HTTP 500 (`status: empty`) ; aucune cible
manquante n'est fabriquée. L'état exact est dans
`prepared/finalization-report.json` et `prepared/import/import-report.json`.

`Tools/training/finalize_wispr_youtube_lot.py` reconstruit l'import et le
paquet ASR, tout en gardant `job_complete: false` dans le rapport lorsque ces
erreurs subsistent. Ne pas relancer aveuglément le lot : sauvegarder l'état du
job et diagnostiquer Wispr avant de retenter les seuls segments en échec.
Pour appliquer les mêmes exclusions lors d'une nouvelle préparation, passer
`--asr-quarantine prepared/asr-risk-quarantine-20260925.jsonl` au finaliseur.
Cette liste lie chaque exclusion à l'empreinte du verbatim et de l'audio ; un
nouveau verbatim invalide la liste et exige une nouvelle revue.

## Import exhaustif

Depuis la racine du dépôt :

```sh
python3 Tools/training/build_wispr_youtube_campaign.py \
  --collection-root /Volumes/0_Oueillez/wispr-data/youtube-lot1-2026-09-24 \
  --source-table Data/corpus/wispr-youtube-lot1-sources.json \
  --jobs-dir ~/Documents/wispr/transcripts/youtube-jobs \
  --output-root /Volumes/0_Oueillez/wispr-data/youtube-lot1-2026-09-24/prepared/import
```

`audio-inventory.jsonl` répertorie les MP3 sources, tous les WAV découpés et
les WAV complets intermédiaires. `source-catalog.json` répertorie aussi les
vidéos sans audio ou sans enregistrement. `teacher-all.jsonl` garde chaque
segment et chaque erreur de requête, avec l'audio et le texte Wispr associés.
`qwen-targets-pending.jsonl` garde les textes édités disponibles. La procédure
Qwen expérimentale ci-dessous produit ensuite le texte brut du runtime VoxoL
sur le même segment et contrôle la fidélité de chaque paire. Les sorties Wispr
et les corrections textuelles Luna restent `silver`, `approved: false`,
`humanReviewed: false` et `audio_verified: false`.

## Paquet ASR silver du lot partiel

```sh
python3 Tools/training/prepare_wispr_teacher_asr.py \
  --input /Volumes/0_Oueillez/wispr-data/youtube-lot1-2026-09-24/prepared/import/teacher-all.jsonl \
  --dataset-root /Volumes/0_Oueillez/wispr-data/youtube-lot1-2026-09-24/dataset \
  --output-root /Volumes/0_Oueillez/wispr-data/youtube-lot1-2026-09-24/prepared/asr-silver \
  --archive /Volumes/0_Oueillez/wispr-data/youtube-lot1-2026-09-24/prepared/asr-silver.tar.gz \
  --quarantine-jsonl /Volumes/0_Oueillez/wispr-data/youtube-lot1-2026-09-24/prepared/asr-risk-quarantine-20260925.jsonl \
  --freeze-timestamp 2026-09-24T00:00:00Z
```

Le paquet figé le 25 septembre 2026 est `prepared/asr-silver.tar.gz` (SHA-256
`cb18a22dd7c1f6ec2c801e62c1dfe362fe3bc78e94d96f92da7c1e2cbc9d9325`).
Il contient 4 770 segments : 3 252 train, 765 validation et 753 test. Les
365 autres segments restent dans l'import et leurs audios sont conservés. Huit
segments initialement retenus ont été mis en quarantaine pour répétition forte,
audio quasi silencieux ou échec de la seconde requête Wispr ; voir
`prepared/asr-risk-quarantine-20260925-report.json`. Cette exclusion prudente
est automatique et ne remplace pas une écoute humaine.

Le filtre ASR exige une empreinte audio vérifiée et un texte raw Wispr exploitable. Il
consigne dans `excluded.jsonl` tout segment écarté pour erreur, langue douteuse,
densité anormale ou doublon ; l'audio reste dans l'inventaire exhaustif.
`train`, `validation` et `test` sont séparés par vidéo. Les identités réelles
des locuteurs ne sont pas connues, donc la séparation de locuteurs n'est pas
prouvée. Le test issu de Wispr est un contrôle **silver**, pas un benchmark
humain indépendant. Aucun modèle installé n'est remplacé par ces étapes.

## Paquet Qwen expérimental au 25 septembre 2026

La revue textuelle Luna figée dans
`prepared/luna-edited-review-20260925/full-campaign-audit.json` couvre les
4 930 sorties `edited` disponibles. Elle marque 1 058 segments
`needs_audio` et 170 avertissements numériques ; cette revue n'a pas écouté
les audios et ne vaut pas validation humaine.

`Tools/training/run_wispr_youtube_qwen_runtime.py` a transcrit 3 693 segments
admissibles avec le modèle ASR VoxoL installé, en 37 lots repris par empreinte.
Les manifestes d'inférence ne contiennent que l'identité et le chemin/empreinte
des audios, jamais les textes Wispr. Le modèle, l'exécutable, les entrées et les
prédictions sont liés par `prepared/qwen-youtube-experimental-20260925/runtime/runtime-report.json`.

`Tools/training/prepare_wispr_youtube_qwen.py` a ensuite gardé 3 269 paires
VoxoL brut → cible Wispr/Luna dans
`prepared/qwen-youtube-experimental-20260925/source/source.jsonl`. Les 1 866
autres segments sont justifiés dans `source/excluded.jsonl` : plusieurs motifs
peuvent concerner le même segment. `source/provenance.jsonl` garde pour chaque
paire l'empreinte de l'audio et l'origine de la cible. Le rapport est
`source/report.json` ; il confirme que les 3 693 prédictions attendues sont
présentes. Les 25 sources restent inventoriées dans l'import.

Le builder du projet, exécuté avec `--ai-experiment`, applique aussi son
contrat `faithful`. Il accepte **471 paires** : 344 train, 41 validation, 86
test, avec des vidéos distinctes entre les trois splits. Il refuse 2 798
autres candidats. Les fichiers MLX sont dans
`prepared/qwen-youtube-experimental-20260925/mlx-data/` et les IDs refusés
dans `mlx-data/summary.json`. Aucune de ces paires ne provient des huit
segments ASR mis en quarantaine. Sur un diagnostic de 1 407 paires sans jetons
protégés, les principaux motifs du validateur sont 733 ajouts non justifiés et
352 suppressions de contenu (`diagnostics/target-validation-tokenfree-report.json`).
Le mode `rewrite` n'en accepterait que 604 au total sur ces mêmes 3 269
candidats (`diagnostics/rewrite-summary.json`) ; il reste donc un diagnostic
distinct, pas la cible du paquet fidèle.

Ces fichiers permettent un **essai ASR silver** et un **petit essai Qwen
expérimental**. Ils ne prouvent ni la fin de la collecte Wispr (`job_complete:
false`), ni un benchmark humain, ni la qualité d'un modèle entraîné. Aucun
entraînement n'a été lancé pendant cette préparation. Pour agrandir le corpus
Qwen fiable, écouter les cas `needs_audio`, retenter les 205 requêtes Wispr
en échec lorsque le service sera rétabli, puis reconstruire les paires exactes
et les revalider avec le builder. Les audios sources ne sont pas supprimés par
ces filtres.

`prepared/training-readiness-20260925.json` rassemble les empreintes et les
comptages revérifiés des deux paquets. Il ne vaut pas feu vert pour une
promotion de modèle : les labels et les tests de ce lot sont toujours `silver`.

## Dossier de préparation et revue humaine

Le dossier figé est
`/Volumes/0_Oueillez/wispr-data/youtube-lot1-2026-09-24/prepared/training-handoff-20260925/`.
`handoff.json` relie l'archive ASR, les trois fichiers MLX, la configuration du
pilote Qwen, le parent Qwen local et leurs SHA-256. `preflight.json` confirme
que ces fichiers n'ont pas changé, que le parent Qwen local se charge et que
les 471 exemples tiennent sous la limite de 768 tokens (maximum observé : 594).
Cette vérification ne mesure aucune qualité après entraînement.

`review-queue.jsonl` contient **les 5 135 segments avec leur audio**, y
compris les 205 sorties `edited` en échec. Les 127 paires Qwen silver retenues
pour validation/test apparaissent d'abord, puis les 344 de train. Les 1 058
cas `needs_audio`, 170 avertissements numériques et huit quarantaines ASR
sont signalés ; les motifs peuvent se recouper. `wispr-failed-chunks.jsonl`
isole les 205 requêtes Wispr en échec pour une reprise ciblée après correction
du service. Leur audio reste disponible pour une transcription humaine.

L'interface d'écoute locale est lancée sur
`http://127.0.0.1:62582/`. Elle permet de comparer le même extrait à Wispr
brut/édité, VoxoL brut et la proposition Luna, puis d'enregistrer séparément
un verbatim ASR et une cible fidèle Qwen. La validation exige une confirmation
explicite de l'écoute ; chaque sauvegarde met à jour `review-state.json` et
`human-reviewed.jsonl` sur le SSD. Les nouvelles lignes gardent
`approved: false` jusqu'aux contrôles de dataset et de benchmark. Le compteur
vivant est `human-review-summary.json` ; `handoff.json` décrit l'état au gel.

Si le serveur local s'arrête, reconnecter le SSD puis le relancer depuis la
racine du dépôt :

```sh
python3 Tools/training/serve_wispr_youtube_review.py \
  --handoff-root /Volumes/0_Oueillez/wispr-data/youtube-lot1-2026-09-24/prepared/training-handoff-20260925 \
  --port 62582
```

Pour la voie de promotion avec références humaines, distinguer les corrections
humaines réelles des simples acceptations d'une proposition. Le seuil de `Docs/models.yaml` exige
au moins **500 corrections humaines** et **150 exemples validation/test à
sources disjointes**, avec français et anglais dans chaque split. Les 471
paires silver existantes ne remplissent pas ce seuil. Aucun extrait non écouté,
aucune proposition Luna et aucun test Wispr silver ne devient une référence
humaine par la seule préparation. Les locuteurs ne sont pas identifiés, donc
la séparation par locuteur n'est pas encore établie.

Le 27 septembre 2026, l'utilisateur a déclaré « je valide tout les segments ».
Son accord global pour les **5 135 segments** est enregistré dans
`training-handoff-20260925/user-approval.json`, lié à l'empreinte de la file et
aux entrées figées. Le précontrôle et l'interface affichent cet accord.
Les textes restent de provenance Wispr/Luna ; cette déclaration ne documente
pas une écoute individuelle ou 5 135 corrections humaines. Les 205 erreurs
Wispr et les exclusions techniques restent traçables. Les paquets expérimentaux
ASR (4 770 segments) et Qwen (471 paires) sont approuvés par l'utilisateur pour
les essais ; la revue manuelle supplémentaire est facultative pour cette voie,
conformément à `Docs/dataset-policy.md`. Aucun entraînement n'est lancé par
l'enregistrement de l'accord.

## Contrôles et commandes pour les essais futurs

### Pilote ASR depuis le modèle retenu — 9 octobre 2026

Le candidat ASR d'octobre, entraîné depuis NVIDIA, a été converti et comparé
au modèle installé sur 384 extraits publics. Sur MediaSpeech FR, le WER est
de 32,92 % contre 20,23 % pour le modèle installé, avec six transcriptions
vides contre zéro. Il reste un candidat de recherche. Le rapport est sur le
SSD dans `VoxoL-Artifacts/Training/asr-october-qualification-20261009-c56e5698/RAPPORT.md`.

Pour le prochain pilote, `run_voxol_nemo_finetune.py` accepte
`--initial-delta <parent.delta.pt> --initial-delta-sha256 <sha256>`.
Le parent retenu est Wispr mass-v3, SHA-256
`863011a8bf30973c58322f03eaa8a3c04d17eaab47484ff5b85b70a1ad678d9a`.
Il faut garder le décodeur, le joint et BatchNorm gelés, sélectionner les
quatre dernières couches d'encodeur et utiliser un nouveau dossier
d'expérience. Cette initialisation conserve les poids appris et crée un
nouvel optimiseur ; elle ne se combine pas avec `--resume-checkpoint`.

Les deltas sauvegardés restent **cumulatifs par rapport à la base NVIDIA**,
comme l'exigent les exporteurs existants. Les empreintes et la recette du
parent sont contrôlées ; les tenseurs doivent correspondre exactement aux
paramètres sélectionnés, être FP32, de la bonne forme et finis.

Le premier lot de relecture contient 48 extraits FR sur le SSD : 32 train,
8 validation, 8 test, répartis sur 12 vidéos, sans vidéo traversant les
splits. Les propositions automatiques restent expérimentales. La séparation
des locuteurs entre vidéos n'est pas établie. Un pilote corrigé attend les
verbatims validés sur audio ; l'accord global historique pour les essais
silver reste distinct de ces corrections. Le replay historique conserve sa
provenance silver. Qwen v8 et l'ASR installé restent en place pendant le pilote.

Le lanceur GPU historique embarque un instantané de ses sources : une
préparation utilisant `--initial-delta` doit transférer le script actualisé
et son parent épinglé, plutôt que réutiliser ce lanceur inchangé. La recette
locale en préparation ne démarre ni ne finance un Pod.

### Essai local Whisper mis de côté — 9 octobre 2026

Un essai de comparaison locale avec Whisper a été réalisé pendant la préparation.
Le propriétaire a ensuite précisé le parcours demandé : joindre les fichiers
audio à ChatGPT dans le navigateur, récupérer ses propositions JSON et les
comparer. Les artefacts Whisper sont conservés sur SSD pour leur traçabilité ;
ce paquet est mis de côté et son lanceur par défaut est bloqué. Aucun entraînement
ou remplacement des modèles VoxoL installés n’a été effectué.

Le contrôle reproductible du dossier est :

```sh
python3 Tools/training/verify_wispr_youtube_handoff.py \
  --handoff-root /Volumes/0_Oueillez/wispr-data/youtube-lot1-2026-09-24/prepared/training-handoff-20260925
```

Le pilote Qwen *silver* est configuré dans `qwen-silver-pilot.yaml` : parent
Qwen 3.5 0.8B 4-bit installé, LoRA sur quatre couches, 80 itérations,
accumulation 8, taux `2e-5`, validation toutes les 20 itérations et artefacts
sur le SSD. Il s'agit d'un essai local de diagnostic, sans autorisation de
promotion. Commande prête pour un lancement distinct :

```sh
python3 Tools/training/run_mlx_lora_safely.py \
  --memory-gb 8 --cache-mb 512 --disable-compile \
  --config /Volumes/0_Oueillez/wispr-data/youtube-lot1-2026-09-24/prepared/training-handoff-20260925/qwen-silver-pilot.yaml
```

Le paquet ASR silver peut être envoyé au pipeline GPU existant, qui ajoute son
replay FLEURS et ses contrôles publics. Le lanceur local
`Scripts/launch-voxol-runpod-training.sh` démarre réellement une machine
facturable et transfère le paquet ; il n'a pas été exécuté. Pour son lancement,
il faudra le nom d'hôte/port/clé SSH du Pod, le prix horaire réel affiché par
le fournisseur, un budget et une durée plafonds. Pointer
`VOXOL_TEACHER_DATASET` sur `prepared/asr-silver.tar.gz` et
`VOXOL_REMOTE_WORK` sur un nouveau dossier persistant ; ne pas utiliser les
valeurs historiques par défaut du lanceur. La variante
`bash VoxoL_GPU_Train.sh --dry-run` a été vérifiée localement avec cette
archive et son empreinte ; elle n'installe ni ne lance rien. Aucun entraînement
GPU, entraînement Qwen ou remplacement de modèle installé n'a été fait.
