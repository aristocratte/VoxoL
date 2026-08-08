# Benchmark ASR public — 26 juillet 2026

Ce rapport mesure le port Core ML de Parakeet TDT 0.6B v3 utilisé par VoxoL. Il ne mesure pas le
polisher Qwen, car FLEURS et MediaSpeech fournissent des transcriptions ASR, pas une référence de
réécriture éditoriale.

## Protocole

Les deux corpus sont téléchargés depuis leur source officielle, vérifiés par SHA-256, convertis en
manifeste VoxoL puis figés avant l'inférence. Tous les clips passent dans le même binaire Release,
le même artefact Parakeet et le même normaliseur WER/CER. Le normaliseur met en minuscules, conserve
les lettres, chiffres et apostrophes, puis remplace les autres signes par des espaces.

| Corpus | Version vérifiée | Contenu évalué |
| --- | --- | --- |
| FLEURS `fr_fr` | révision `70bb2e84b976b7e960aa89f1c648e09c59f894dd` | split `test`, 676 clips |
| MediaSpeech français | OpenSLR SLR108, SHA-256 `edefa83d…f390` | corpus complet, 2 498 clips |

Les manifests figés ont respectivement les empreintes
`fd49ad483fa937fbd5006db4ddeb05ad31307b00263ce9f6883b36a0910ebcee` et
`5384bf42594c42b06840be98ffdfc6654ac6d132063964cf4158748e4c210478`.

## Résultats

| Corpus | WER macro | WER micro | CER micro | Exact match | p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| FLEURS français `test` | 7,02 % | 6,88 % | 2,70 % | 33,14 % | 123,9 ms | 152,9 ms | 182,3 ms |
| MediaSpeech français | 39,66 % | 39,82 % | 30,30 % | 0,56 % | non retenu | non retenu | non retenu |

Ces valeurs intègrent le correctif de centrage FFT décrit plus bas. La mesure MediaSpeech a été
exécutée pendant un autre téléchargement et ses latences ne sont donc pas publiables; ses métriques
de qualité restent déterministes. FLEURS ne contient aucune sortie vide. MediaSpeech contient
170 sorties vides. Ses 39 755 erreurs de mots se répartissent en 24 465 suppressions,
12 162 substitutions et 3 128 insertions. Les suppressions dominantes
indiquent une perte d'information acoustique; un polisher textuel ne peut pas reconstruire ces
mots de manière fiable.

Un contrôle sur des échantillons vides et non vides n'a pas trouvé de corrélation simple avec le
volume moyen. Le problème MediaSpeech ne se réduit donc pas à un seuil de gain trop faible. Il faut
encore séparer la faiblesse du modèle source d'une divergence propre au port Core ML.

## Interprétation

FLEURS confirme une très bonne qualité et une latence stable sur du français lu propre. MediaSpeech
révèle en revanche une faiblesse importante sur la parole issue de médias réels. Le papier
MediaSpeech de 2021 publie, avec son propre protocole, 16,83 % pour Azure, 17,59 % pour Wit,
19,15 % pour QuartzNet, 21,11 % pour Vosk, 23,85 % pour Google et 47,41 % pour DeepSpeech. Ces
valeurs donnent un ordre de grandeur historique, mais elles ne sont pas directement comparables à
VoxoL tant que leur normalisation exacte n'est pas reproduite dans notre scorer.

Il ne faut ni agréger FLEURS et MediaSpeech en un score moyen, ni entraîner sur leur partie utilisée
pour la mesure. FLEURS reste le gate de non-régression sur parole propre; MediaSpeech devient un
stress test verrouillé de robustesse média.

## Décision

La prochaine expérience doit exécuter le modèle Parakeet officiel et le port Core ML sur un
échantillon MediaSpeech stratifié comprenant les 171 sorties vides, des erreurs fortes et des clips
corrects. Si le modèle officiel réussit là où Core ML échoue, le port ou le front-end est prioritaire.
S'il échoue pareillement, il faut améliorer le modèle avec des données d'entraînement séparées,
du bruit et de la parole média, tout en gardant MediaSpeech entièrement hors entraînement.

## Diagnostic source contre Core ML

Le diagnostic a ensuite été exécuté sur 50 clips sélectionnés à partir des sorties Core ML :
20 sorties vides, 20 erreurs fortes et 10 contrôles sous 10 % de WER. Cette sélection est
volontairement biaisée vers les échecs et ne constitue donc pas un nouveau score global
MediaSpeech.

| Runtime | WER macro sur l'échantillon | WER micro | Sorties vides |
| --- | ---: | ---: | ---: |
| VoxoL Core ML | 73,79 % | 74,37 % | 20 |
| Parakeet Transformers officiel | 65,80 % | 66,23 % | 13 |

L'officiel améliore 17 clips, en laisse 23 identiques et en dégrade 10. Il récupère 7 des
20 sorties Core ML vides sans créer de nouvelle sortie vide, mais reste vide sur les 13 autres.
Sur les 20 erreurs fortes, le WER macro passe de 81,30 % à 69,76 %. Sur les 10 contrôles, Core ML
reste meilleur : 6,37 % contre 10,45 %.

Le verdict est mixte et suffisamment net pour ordonner le travail. Une divergence de portage existe
sur les cas difficiles et doit être corrigée en premier, car elle ne demande aucune donnée
d'entraînement. Le modèle officiel reste toutefois très insuffisant sur ce domaine; après la parité,
un fine-tuning ASR avec un corpus d'entraînement séparé de parole média/bruitée sera nécessaire.
MediaSpeech reste verrouillé comme test final.

## Audit du front-end et de l'encodeur

Le harnais de parité a révélé un défaut réel dans le STFT Swift : la fenêtre de Hann de 400
échantillons était écrite au centre du buffer FFT de 512 points, mais l'audio était lu 56
échantillons trop tôt. Chaque frame était donc décalée de 3,5 ms. Le correctif centre désormais
les deux côtés de la multiplication et un test impulsionnel verrouille ce comportement.

Sur sept sorties MediaSpeech vides que le modèle officiel récupère, le spectre de puissance Swift
correspond maintenant à la source avec un NRMSE moyen de `1,56e-7`. Le mode reproduisant aussi le
masque de dernière frame atteint un NRMSE moyen de `5,23e-6` sur les features et sept masques
identiques sur sept. L'encodeur Core ML reste pourtant à seulement `0,746` de similarité cosinus
moyenne et ne récupère que deux sorties sur sept. Le front-end n'est donc plus l'explication
principale; la quantification/conversion de l'encodeur et la faiblesse du modèle sur le domaine
média dominent.

Le masque de dernière frame a également été testé sur les corpus complets. Il obtient 7,01 % de
WER macro sur FLEURS, mais dégrade MediaSpeech de 39,66 % à 39,86 % et porte les sorties vides de
170 à 174. Cette variante reste disponible dans les outils de diagnostic, mais elle est rejetée
du chemin produit.

Le correctif FFT seul améliore MediaSpeech de 39,75 % à 39,66 % de WER macro, avec 391 clips
améliorés, 400 dégradés et 1 707 identiques. Il corrige une erreur mathématique et reste donc
intégré, mais son effet global presque neutre confirme que le prochain gain important doit venir
du checkpoint ou de son export.

## Tranche de fine-tuning

La chaîne reproductible est maintenant disponible dans `Docs/parakeet-finetuning.md`. Elle prépare
FLEURS `train/dev` français et anglais, épingle NeMo, produit des checkpoints `.nemo` et force leur
évaluation source sur FLEURS `test` et MediaSpeech avant toute conversion. FLEURS valide la
mécanique multilingue; il ne couvre pas le domaine média et ne suffira probablement pas à lui seul
à réduire fortement les 39,66 % de MediaSpeech.

## Reproduction

```sh
./Scripts/run-fleurs-fr-test-benchmark.sh
./Scripts/run-mediaspeech-fr-benchmark.sh
./Scripts/run-mediaspeech-source-diagnostic.sh
./Scripts/run-mediaspeech-recovered-parity.sh
./Scripts/prepare-parakeet-fleurs-finetune.sh --print-plan
```

Les archives, fichiers audio, prédictions et rapports restent sous
`~/Library/Caches/VoxoL/Benchmarks` et ne sont pas distribués avec l'application.
