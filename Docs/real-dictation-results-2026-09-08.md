# Dictées réelles — résultats du 8 septembre 2026

La campagne exécutée sur le Mac conserve **Parakeet et le correcteur avec son
adaptateur actuel**. Aucun candidat ne démontre la réduction de 20 % des erreurs
finales visée. Les changements livrés corrigent le protocole de mesure ; ils ne
constituent pas un gain de précision dans l'application installée.

## Périmètre effectivement exécuté

- Checkout `codex/real-dictation-20260908`, base `b27f0c97edf9e6c47be9790158692710f4f7f79d`,
  avec les changements locaux préexistants conservés.
- 225 prises inventoriées dans le manifeste existant : **88 dictées de diagnostic**,
  **60 prises réservées**, 77 exclusions. Les 60 réservées n'ont reçu aucune inférence
  pendant cette campagne : aucun remplacement n'a franchi la sélection préliminaire.
- Diagnostic complémentaire : **40 extraits FLEURS**, 20 français et 20 anglais,
  sélectionnés par identifiant avant les résultats. Les transcriptions publiées
  constituent une référence distincte des labels personnels historiques.
- Trois moteurs exécutés sur les mêmes 128 fichiers : **384 transcriptions**, aucun
  fichier absent et aucun échec d'inférence. Langue automatique, sans vocabulaire
  tiré des réponses. Les variantes MLX utilisent une température nulle et leurs
  paramètres sont conservés dans chaque `run.json`.
- Deux variantes du correcteur exécutées sur les mêmes 88 sorties Parakeet,
  via `--through-processor` : **176 traitements du véritable processeur de texte**.
  Cela n'inclut pas une nouvelle capture micro ou une insertion dans une autre application.

Les références personnelles sont des **labels IA historiques**, dont la lignée
peut inclure Parakeet. Elles restent diagnostiques et ne permettent pas de conclure
à une supériorité indépendante sur toutes les dictées. Le contrôle public reste
petit et porte sur de la parole lue. [FLEURS est publié sous CC BY 4.0](https://huggingface.co/datasets/google/fleurs).

## Reconnaissance brute

Le WER lexical mesure substitutions, suppressions et insertions divisées par le
nombre de mots de référence. NFC, casse et apostrophes sont harmonisés ; accents,
nombres et négations restent significatifs. Un nombre écrit en lettres n'est pas
automatiquement considéré comme identique à ses chiffres. **Plus bas est meilleur.**

| Moteur | 88 dictées, labels IA | 40 extraits publics | Médiane d'inférence sur les dictées |
| --- | ---: | ---: | ---: |
| Parakeet TDT 0.6B v3, Core ML | **161 / 2 987 = 5,39 %** | **65 / 970 = 6,70 %** | **131 ms** |
| Qwen3-ASR 0.6B, MLX 8 bits | 387 / 2 987 = 12,96 % | 67 / 970 = 6,91 % | 715 ms |
| Whisper large-v3-turbo, MLX FP16 | 344 / 2 987 = 11,52 % | 71 / 970 = 7,32 % | 2 825 ms |

Sur le public : Parakeet obtient 7,14 % en français et 6,10 % en anglais ; Qwen
8,04 % et 5,37 % ; Whisper 8,21 % et 6,10 %. Les deux mots d'écart entre Parakeet
et Qwen sur l'ensemble public ne constituent pas une victoire statistique robuste.
Le remplacement global de Parakeet n'est pas justifié par ces résultats.

Les médianes excluent le chargement du modèle mais restent des temps de rejeu de
composants. Elles ne mesurent ni le délai complet après relâchement du raccourci,
ni une intégration native des concurrents Python. Les mesures RSS/Core ML et les
pics d'allocation MLX ont des périmètres différents : aucun respect du budget total
de mémoire de l'application n'est déduit de leur comparaison.

Révisions MLX réellement testées :

- [Qwen3-ASR-0.6B-8bit](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit),
  `89e96d92ba34aca20b3e29fb10cc284097d1219f`.
- [Whisper Turbo FP16](https://huggingface.co/mlx-community/whisper-large-v3-turbo-asr-fp16),
  `624c19c9af5603fa73b83bce14d4aeea96156d18`.

Les empreintes de tous les fichiers de poids, du binaire natif, du runner, du
contrat, des paramètres et des références accompagnent les sorties.

## Texte final et diagnostic des références

| Configuration fidèle | Écarts lexicaux aux cibles historiques | Sorties finales modifiées lexicalement après normalisation | Cas avec échec de génération signalé |
| --- | ---: | ---: | ---: |
| Correcteur avec adaptateur | 996 / 2 566 = 38,82 % | 0 / 88 | 4 |
| Même Qwen sans adaptateur | 996 / 2 566 = 38,82 % | 0 / 88 | 9 |

Les deux variantes ont 77 chaînes finales strictement identiques sur 88 ; les
différences restantes concernent la ponctuation ou la casse. Les échecs restent
comptés avec le texte de repli effectivement retenu. Le correcteur avec adaptateur
présente 3 décisions `validatorRejected`, contre 39 sans adaptateur ; ces décisions
sont distinctes des échecs de génération, qui peuvent être partiellement récupérés.

L'inspection des propositions rejetées sans adaptateur confirme notamment des
préambules ajoutés, une réponse à une question dictée, un changement de temps et
une négation supprimée. Desserrer globalement la validation pour accepter davantage
de sorties n'est donc pas une correction justifiée.

Le score final de 38,82 % **n'est pas un taux établi de mauvaise transcription** :
61 des 88 références dites fidèles diffèrent lexicalement de leur verbatim, et
46 dépassent 20 % de modifications. Leurs écarts cumulés au verbatim représentent
31,34 %. Certaines réécritures peuvent être souhaitables, mais ce mélange de
contrats ne permet pas d'établir un score propre de correction fidèle.

Conséquence : pas d'entraînement sur ces cibles en l'état et pas de désactivation
de l'adaptateur. Le problème à traiter ensuite est la production de cibles de
correction fidèles, distinctes des cibles de réécriture, avec provenance IA explicite.
L'absence de relecture humaine n'est pas le blocage ; la cohérence des références
et leur indépendance le sont. Les 60 prises réservées restent disponibles pour
évaluer une modification future qui aurait d'abord apporté un gain sur le diagnostic.

## Correctifs livrés et vérification

1. **Inférence native sans référence** : `infer-parakeet` reçoit seulement les
   identifiants, chemins audio et SHA-256. Le runner n'invente plus `reviewed: true`
   pour lancer des données IA. Le gate historique des benchmarks relus reste
   inchangé. Les fichiers sont vérifiés avant et après l'inférence.
2. **Score des sorties restaurées** : le scoreur refuse le stade `candidate`, qui
   peut contenir des jetons `VOXOLP…` non restaurés. Ces textes restent consultables
   pour comprendre les décisions ; les scores portent sur le brut, le normalisé
   et le final. Les anciens rapports `candidate-report.json` ne doivent pas servir
   à classer les modèles.
3. **Runner MLX** : plafond de cache de 64 Mio ; nombre de jetons générés et atteinte
   du plafond enregistrés pour Qwen ; langue détectée lue depuis le champ réel
   `language`. Whisper ne fournit pas de nombre de jetons dans cette API : ce champ
   reste inconnu. Le plafond de cache ne limite pas la mémoire totale du modèle.

`./Scripts/verify.sh --fast` passe : **352 tests Swift comptabilisés, dont 3 ignorés,
zéro échec ; 54 + 38 = 92 tests Python réussis**. Les nouveaux tests couvrent les
empreintes audio, doublons, chemins hors racine, liens symboliques, séparation avec
le gate humain et refus de scorer un candidat non restauré. La CLI native a été
compilée puis exécutée sur les 128 fichiers. `git diff --check` passe.

Aucune publication, aucun transfert d'audio personnel et aucune installation de
nouvelle version. L'application installée est toujours en **0.1.5**. Le gain cible
de 20 % n'est pas atteint ; aucun gain de précision utilisateur n'est revendiqué
pour ces corrections de benchmark.

## Reproduction et preuves locales

Les fichiers privés restent dans les emplacements ignorés par Git :

- `~/Library/Application Support/VoxoL/PersonalBenchmark/campaigns/precision-20260908-v1/manifest.json`
  — SHA-256 de contenu `1d33aec0c632471fbcfeb1a787159659c047975a6848fd23f46d5f3992411b29`.
- `.build/precision-fleurs-v1/manifest.json`
  — `bd64d807f8925b5ccd73f9c5d444f797e538bdcab45f0d948eb8894b8b598678`.
- `outputs/self-quality-2026-09-08/` : rapports comparatifs personnels/publics,
  comparaison du processeur, `summary.json`, audit des références, traces détaillées
  par prise et journal `verify-fast.log`. Les traces détaillées contiennent du texte
  personnel et ne doivent pas être ajoutées à Git.

Les commandes sont conservées dans `reproduce.sh`. Utiliser un nouveau répertoire
de résultats : les runners refusent l'écrasement et la reprise par simple identifiant.
`collect-results.py` reconstruit la synthèse depuis les résultats existants.
