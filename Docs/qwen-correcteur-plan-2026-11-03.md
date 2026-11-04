# Qwen correcteur — plan d'implémentation

> **Pour les agents :** sous-skill requise : `superpowers:subagent-driven-development` ou
> `superpowers:executing-plans`, tâche par tâche. Les étapes utilisent des cases `- [ ]`.
> Aucun commit, push ou installation de l'app sans demande explicite d'Aris.

**Objectif :** faire de Qwen3.5-0.8B un correcteur qui corrige les fautes réelles de la dictée et
recopie le texte quand il n'y a rien à corriger, sans dégrader la qualité ni la latence.

**Architecture :** trois étages, chacun mesuré avant le suivant. D'abord mesurer qui ajoute les
fautes (l'adaptateur hérité, le modèle de base ou le validateur). Ensuite appliquer les corrections
sans entraînement : retirer l'adaptateur s'il est en cause et resserrer le validateur sur les
erreurs mesurées. Enfin entraîner un nouvel adaptateur LoRA, en local, depuis le Qwen d'origine,
sur des corrections humaines, avec beaucoup d'exemples où la bonne réponse est de ne rien changer.

**Tech :** Swift 6.2 / MLX Swift (runtime), Python 3 + `mlx-lm` (entraînement), runner
`VoxoL --polisher-smoke`, `unittest`.

**Spec :** demande d'Aris du 3 novembre 2026, [dataset-policy.md](dataset-policy.md) (section
« Gate du prochain Qwen »), [models.yaml](models.yaml).

## Point de départ

- L'app charge `Models/polisher/voxol-adapter`, entraîné à imiter Wispr Flow (`ACTIVE_LOCAL_LEGACY_WISPR`,
  non reproductible). Sur le développement synthétique du 7 septembre : 34/48 avec l'adaptateur, 38/48 sans.
- Le validateur v2 décide seul du texte inséré ; v3 (`EditGate`, réparation par clause) ne tourne
  qu'en shadow.
- Aucune référence humaine n'existe : `human-v1` et les `review.json` des sessions sont étiquetés par IA.
- L'historique ne contient aucune dictée corrigée à la main : ses `revisions` sont une pile
  d'annulation qui garde le texte ASR brut, pas des corrections (vérifié le 3 novembre, 0 cas sur
  126 dictées reliées à une session). Une première lecture erronée avait pris ce texte brut pour
  des références humaines ; ces mesures sont invalides (`outputs/qwen-corrector/*/INVALID.md`).
- `~/Library/Application Support/VoxoL/Models` est absent du disque interne ; les poids sont
  probablement sur le SSD `0_Oueillez`.

## Contraintes globales

- Deux modèles seulement. Parent unique de tout entraînement : Qwen3.5-0.8B pristine
  `2fc06364715b967f1860aea9cf38778875588b17`, poids `f5a0d9dd3efa73510542a8023d610ff26be2b4b020d181cfc4bedaa1fcc5dd9e`.
- `voxol-adapter` (`9df7372a…`) est interdit comme parent d'entraînement.
- Seules les lignes `source: "human"` avec `approved: true` comptent dans les quotas. Un texte IA ne
  devient jamais une référence humaine.
- Gate d'entraînement : au moins 500 corrections humaines réelles, dont 150 en validation/test
  disjointes par session, français et anglais présents dans chaque split, gate
  `voxol-qwen-human-gate-v2` vérifié par `Scripts/build-qwen-human-gate.py --check`.
- Promotion : au moins 5 % de gain relatif sur le WER propre face au runtime actuel, 100 % des spans
  protégés conservés après le validateur, aucune hausse des mots inattendus, latence p95 dans
  l'enveloppe actuelle. Le candidat ne remplace jamais l'adaptateur installé automatiquement.
- « Sans dégrader » : 0/10 témoins de préservation modifiés, 0 différence littérale de chiffres ou
  de code, aucun cas du test scellé lu avant l'évaluation finale.
- Matériel : M4 16 Go. Entraînement local via `Tools/training/run_mlx_lora_safely.py --memory-gb 10`.
  Aucun GPU payant sans accord.
- Les dictées privées, suites et prédictions restent hors Git, sous `outputs/qwen-corrector/`
  (ignoré). Les scripts n'impriment aucun texte dicté.

## Décisions qui te reviennent

- **D1, après la tâche 3** : retirer l'adaptateur hérité et/ou activer la porte v3, chiffres en main.
- **D2, après la tâche 4** : faire 500 relectures dans la Relecture de l'app (aucune correction
  humaine n'existe encore) pour atteindre le gate, ou s'arrêter aux corrections sans entraînement.
- **D3, après la tâche 8** : installer ou non le nouvel adaptateur dans l'app.

## Points de vigilance

1. **Texte déjà correct** : Qwen doit le rendre intact. C'est le cœur du problème. Testé dans les tâches 1, 3 et 6.
2. **Mélange français/anglais** : « je push sur main » ne doit pas devenir « je pousse sur la branche principale ». Testé dans les tâches 1 et 2.
3. **Nombres et identifiants** (`B450`, `3 commits`) inchangés. Testé dans la tâche 4 via le validateur.
4. **Homophones qui changent le sens** (« tache » / « tâche ») : refusés sans preuve. Testé dans la tâche 4.
5. **Dictées longues découpées en morceaux** (plus de 70 mots) : le score agrège les morceaux sans les
   compter deux fois. Testé dans la tâche 1.

---

### Tâche 0 : préparer la mesure

Pas de code.

- [ ] Monter `0_Oueillez`, puis localiser la racine du modèle Qwen et `voxol-adapter`.
- [ ] Vérifier les empreintes : `shasum -a 256 <modèle>/model.safetensors` doit donner
  `f5a0d9dd…` et `<adaptateur>/adapters.safetensors` doit donner `9df7372a…`. Sinon, arrêter.
- [ ] Construire l'app Debug et noter le chemin de l'exécutable.

Prêt quand les deux empreintes correspondent et que
`VoxoL --polisher-smoke --model <M> --text "test"` répond.

### Tâche 1 : score des fautes ajoutées et corrigées

**Fichiers :**
- Créer : `Scripts/score-edit-attribution.py`
- Créer : `Scripts/test_score_edit_attribution.py`

**Interfaces :**
- Produit : `attribute_edits(source: str, output: str, reference: str) -> EditCounts`, avec
  `EditCounts(fixed: int, broken: int, spurious: int, verdict: str)` et `verdict` parmi
  `helpful`, `harmful`, `unchanged`, `mixed`.
- Produit : `score_report(report: dict) -> dict`. Lit un rapport `--polisher-smoke --through-processor`
  et score séparément `candidate`, `finalText` et `v3Text` (s'il est présent) contre `expected`, avec
  `normalized` comme source. Agrège par cas et au total.
- CLI : `--report <rapport.json> --output <score.json>`.

Algorithme : tokens via `tokens()` de `score-text-quality-suite.py` (casse et ponctuation ignorées,
accents gardés). On aligne chaque texte sur la référence avec `difflib.SequenceMatcher` ; R(x) est
l'ensemble des positions de la référence retrouvées dans x. Alors `fixed = |R(out) − R(src)|`,
`broken = |R(src) − R(out)|` et `spurious = max(0, mots non alignés de out − mots non alignés de src)`.

- [ ] **Tests à écrire d'abord :**
  - `test_identity_is_unchanged` : source = sortie = référence, donc `(0, 0, 0, "unchanged")`.
  - `test_counts_real_fix` : « Les document sont complet » → « Les documents sont complets. »
    donne `fixed == 2`, `broken == 0`, `helpful`.
  - `test_counts_introduced_error` : « tache sur le mur » → « tâche sur le mur » (référence
    identique à la source) donne `broken == 1`, `harmful`.
  - `test_case_and_punctuation_ignored` : « bonjour » → « Bonjour. » donne `unchanged`.
  - `test_code_switch_translation_is_harmful` : « je push sur main » → « je pousse sur la branche
    principale » donne `broken == 2`, `harmful`.
  - `test_report_scores_each_stage_separately` : un rapport à deux cas produit des totaux distincts
    pour `candidate` et `finalText`.
  - `test_long_multi_sentence_case_counts_once` : un cas de 120 mots, avec une faute corrigée et
    une faute ajoutée dans deux phrases différentes, donne `fixed == 1`, `broken == 1`, `mixed`.
  - `test_never_prints_text` : la CLI n'écrit aucun mot des cas sur stdout.
- [ ] Lancer `python3 -m unittest Scripts/test_score_edit_attribution.py` : échec attendu (module absent).
- [ ] Implémenter, puis relancer : tout passe.

### Tâche 2 : suite humaine à partir de tes corrections

**Fichiers :**
- Créer : `Scripts/build-human-revision-suite.py`
- Créer : `Scripts/test_build_human_revision_suite.py`

**Interfaces :**
- Consomme : `~/Library/Application Support/VoxoL/transcripts.json` et
  `PersonalBenchmark/sessions/*/meta.json`.
- Produit : `outputs/qwen-corrector/human-revision-suite/{train,validation,test}.json` au format
  `{"purpose", "cases": [{"id", "language", "transcript", "expected", "mode": "faithful",
  "profile": "document", "source": "human", "approved": bool, "split", "sessionID"}]}`, plus
  `manifest.json` (SHA-256 de chaque fichier, comptes par split et langue, exclusions avec motif).
- Produit : `link_revisions(history, sessions) -> list[Link]`, `split_for(session_id: str) -> str`
  (SHA-256 du nom de session : 70 % train, 15 % validation, 15 % test) et
  `guess_language(text) -> "fr" | "en" | None`.

Règles : lien par texte final normalisé (NFC, espaces). `transcript` = `rawText` de la session ;
`expected` = dernière révision. Les cas sont exclus avec motif dans quatre situations : révision
identique au texte final, ratio d'édition final→révision supérieur à 0,5 (`probable-rewrite`),
langue indéterminée, texte vide. `approved: true` seulement si on passe `--owner-confirmed`, ce que
tu fais après avoir confirmé que ces révisions sont bien les tiennes.

- [ ] **Tests à écrire d'abord :** `test_links_by_normalized_final_text`,
  `test_excludes_identical_and_rewrite_with_reason`, `test_split_is_deterministic_per_session`
  (même session, même split, sur deux exécutions), `test_code_switch_sentence_is_french`
  (« je push sur main demain » donne `fr`), `test_approved_requires_owner_flag`,
  `test_output_refuses_tracked_path` (refuse d'écrire hors de `outputs/`).
- [ ] Lancer la suite de tests : échec attendu. Implémenter, puis relancer : tout passe.
- [ ] Lancer le script sur les vraies données ; le manifeste doit annoncer environ 126 liens, avant exclusions.

### Tâche 3 : mesure de référence

**Fichiers :**
- Modifier : `App/Services/PolisherSmokeRunner.swift`, structure `PolisherEvaluationResult` (~ligne 1069).

**Interfaces :**
- Produit : champ `v3Text: String?` dans chaque résultat du rapport, rempli à partir de
  `v3ShadowDecision?.text` après restauration des placeholders.
- Consomme : la CLI de la tâche 1, les suites de la tâche 2.

- [ ] Ajouter `v3Text`, puis vérifier avec `swift test --filter QwenPolisherTests` et le build Debug.
- [ ] Lancer trois configurations, chacune sur deux suites : le développement synthétique
  (`Data/corpus/text-quality-synthetic-v1/development.json`) et la validation humaine.
  - **C1 production** : `VoxoL --polisher-smoke --model <M> --suite <S> --through-processor`
  - **C2 sans adaptateur** : la même commande avec `--without-adapter`
  - **C3 porte v3** : `v3Text` de C2, rien à relancer

  Les sorties vont dans `outputs/qwen-corrector/baseline/<config>/<suite>/`. Le test humain et le
  contrôle synthétique (`holdout`) restent scellés.
- [ ] Scorer chaque rapport avec la tâche 1, puis écrire `outputs/qwen-corrector/baseline/summary.json`.
  Pour chaque configuration et chaque étape (candidat, final, v3) : cas utiles/nuisibles, mots
  corrigés/cassés, témoins modifiés, latence p50/p95.

Règle proposée pour D1 : on retire l'adaptateur si C2 casse moins de mots que C1 sur le texte
final, corrige au moins 90 % de ce que corrige C1, et laisse 0/10 témoin modifié. On active v3 si
C3 casse moins de mots que C2 sans en corriger moins de 90 %.

### Tâche 4 : corrections sans entraînement

Seulement ce que D1 approuve.

**Fichiers :**
- Modifier : `App/Services/DictationSessionCoordinator.swift:384` →
  `DictationTextProcessor(modelRoot: modelRoot, useInstalledAdapter: false)`
- Modifier, si v3 est approuvé : `App/Services/DictationTextProcessor.swift`, méthode `polish()`.
  Quand `preparation.featureFlags.editGateV3` est vrai, le texte retourné vient de la décision v3 et
  non de v2. On passe `voxol.editGateV3` à `true` dans `App/Services/DefaultSettings.swift:33`.
- Modifier : `Packages/FidelityKit/Sources/FidelityValidator.swift` (ou `EditGate.swift` si v3),
  pour chaque catégorie qui cause au moins 3 mots cassés dans la validation de la tâche 3.
- Test : `Tests/Unit/FidelityKitTests/FidelityValidatorTests.swift` (ou `FidelityValidatorV3Tests.swift`).

- [ ] Pour chaque catégorie retenue, écrire un test d'abord, avec une phrase synthétique de même
  structure (jamais la dictée privée). Il doit refuser la modification nuisible et accepter la
  correction légitime voisine. Toujours présents : `test_rejects_meaning_changing_homophone`
  (« tache » → « tâche » refusé sans contexte), `test_keeps_alphanumeric_identifier` (`B450`
  intact), `test_quantity_noun_attachment` (« 3 commits » ne devient pas « commit 3 »).
- [ ] `swift test --filter FidelityKitTests` : échec attendu, puis correction, puis tout passe.
- [ ] Relancer la tâche 3 sur la configuration retenue. Le texte final doit casser moins de mots,
  sans baisse de plus de 10 % des corrections, avec 0/10 témoin et 0 différence de chiffres.
- [ ] `./Scripts/verify.sh --fast`, puis noter les échecs préexistants dans `outputs/` séparément.

### Tâche 5 : atteindre 500 corrections humaines

Seulement si D2 = oui. C'est du travail humain, pas du code.

- [ ] Relire les sessions dans Bibliothèque → Relecture : chaque validation doit produire une ligne
  `source: "human"`, `approved: true`. Viser au moins 75 corrections en anglais.
- [ ] Relancer la tâche 2 avec `--owner-confirmed`, puis vérifier dans le manifeste : au moins 500
  lignes approuvées, au moins 150 en validation+test, FR et EN dans chaque split.

### Tâche 6 : jeu d'entraînement

On réutilise la chaîne de l'ancienne campagne (`Scripts/prepare-voxol-qwen-mass-campaign.sh`,
lignes 82 à 94). Seule la conversion d'entrée est nouvelle. Les invites restent produites par le
Swift de production (`DatasetBuilder` → `PolishingPromptBuilder`, `voxol-cleanup-v8`), jamais
recopiées en Python.

**Fichiers :**
- Créer : `Tools/training/build_corrector_source.py`
- Créer : `Tools/training/test_build_corrector_source.py`

**Interfaces :**
- Consomme : les splits de la tâche 2, cas `approved: true` seulement.
- Produit : `outputs/qwen-corrector/dataset/candidate-source.jsonl`, au schéma
  `CleanupDatasetExample` des lignes de `Data/corpus/human-v1.jsonl` : `id`, `language`,
  `profile: "document"`, `app_category`, `before_cursor: ""`, `after_cursor: ""`, `dictionary: []`,
  `protected_tokens: []`, `raw_transcript`, `target_text`, `operations`, `source: "human"`,
  `approved: true`, `split`, `split_group` = `sessionID`.
- Composition : les exemples d'identité (brut = cible après normalisation) doivent représenter au
  moins 30 % du train. Si ce n'est pas le cas, le script échoue avec le manque chiffré ; on ne
  complète jamais avec du synthétique.

- [ ] **Tests à écrire d'abord :** `test_schema_matches_human_v1_rows`,
  `test_identity_share_below_30_percent_fails_with_count`, `test_split_group_is_session`,
  `test_rejects_unapproved_rows`.
- [ ] Implémenter, puis `python3 -m unittest Tools/training/test_build_corrector_source.py` : tout passe.
- [ ] Chaîne existante, avec `B=.build/arm64-apple-macosx/release/voxol-dataset-builder` (après
  `swift build -c release --product voxol-dataset-builder`) et `D=outputs/qwen-corrector/dataset` :
  - `python3 Tools/training/merge_qwen_sources.py --input $D/candidate-source.jsonl --output-root $D/source`
  - `$B --prepare-source $D/source/source.jsonl --output $D/prepared-source.jsonl`
  - `$B --input $D/source/source.jsonl --output $D/mlx-data`
- [ ] Lire `rejected_ids` dans `$D/mlx-data/summary.json` : ce sont les corrections humaines que
  le validateur refuserait. Chacune devient un cas de test candidat pour la tâche 4.
- [ ] `python3 Scripts/build-qwen-human-gate.py --root $D`, puis `--check --root $D` : éligible.

### Tâche 7 : entraînement local

**Fichiers :**
- Créer : `Tools/training/qwen-corrector-lora.yaml`, dérivé de `qwen-lora.yaml` avec la recette
  des candidats propres du 21 août (`num_layers: 4`, `rank: 4`, `scale: 8`, `learning_rate: 2.0e-5`).
  `model` : chemin local du pristine `2fc0636…` (jamais `voxol-adapter`). `data` :
  `outputs/qwen-corrector/dataset/mlx-data`. `adapter_path` :
  `outputs/qwen-corrector/runs/<horodatage>/adapter`. Puis `batch_size: 4`,
  `grad_accumulation_steps: 1`, `iters` = ⌈2 × train / 4⌉ (deux passes, train lu dans
  `summary.json`), `save_every` = ⌈iters / 8⌉, `mask_prompt: true`, `seed: 1729`.

- [ ] Précondition : `python3 Scripts/build-qwen-human-gate.py --check --root outputs/qwen-corrector/dataset`
  réussit. `run_mlx_lora_safely.py` ne vérifie pas le gate, et l'ancien
  `train-voxol-qwen-mass-campaign.sh` est câblé sur la campagne Wispr : il n'est pas réutilisé.
- [ ] Lancer `python3 Tools/training/run_mlx_lora_safely.py --memory-gb 10 --config Tools/training/qwen-corrector-lora.yaml`
  (les arguments restants sont transmis à `mlx_lm.lora` ; `mlx-lm` 0.31.1 est installé).
- [ ] `python3 Tools/training/select_qwen_checkpoint.py --run-root <run> --model <pristine> --dataset <dataset> --references <evaluation-reference.jsonl> --output <run>/selection.json`.
  La sélection se fait sur la validation uniquement.
- [ ] Rapport de la tâche 3 sur la validation humaine avec `--adapter <checkpoint choisi>`, puis
  score de la tâche 1. Le checkpoint doit casser moins de mots que la configuration retenue en
  tâche 4 ; sinon, arrêter et revoir la composition du train plutôt que d'allonger l'entraînement.

### Tâche 8 : évaluation finale et promotion

- [ ] Ouvrir une seule fois le test humain et le contrôle synthétique (`holdout`). Lancer la
  configuration retenue en tâche 4 et le candidat, puis scorer.
- [ ] Écrire `outputs/qwen-corrector/promotion.json`. Chaque critère des contraintes globales doit
  y figurer avec sa valeur mesurée et un booléen, plus les SHA-256 du dataset, de la recette et de
  l'adaptateur.
- [ ] Si tous les critères passent, préparer l'ADR `Docs/decisions/0012-qwen-corrector-adapter.md` et
  l'entrée dans `Docs/models.yaml`, puis demander D3. L'installation dans `Models/polisher/` se fait
  seulement après un oui.
