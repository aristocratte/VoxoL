# VoxoL — mission pour GPT-6 Pro / Astra à distance

## Mission

Travaille sur `https://github.com/aristocratte/VoxoL` pour améliorer la précision des
dictées réelles, puis produire des changements vérifiés et prêts à intégrer. Commence
par mesurer la reconnaissance et la correction séparément, puis le texte final de
l'application. Termine les étapes réalisables sur ton environnement ; si certaines
mesures exigent le Mac ou des données absentes, livre les outils et les commandes
nécessaires, avec la liste exacte de ce qui reste à exécuter.

L'utilisateur autorise la préparation et le contrôle de datasets par IA sans lui
demander de tout relire. Garde leur provenance explicite. Les cas ambigus peuvent
être exclus, avec un motif ; aucun texte IA ne doit devenir une référence humaine
par changement de champ ou de nom de fichier.

La cible est une application de dictée macOS locale, utilisable sur Apple Silicon
avec une mémoire limitée. Les expérimentations Python sont des outils hors application.
Respecte les instructions du dépôt et préserve le travail existant. Une comparaison
de modèles n'autorise pas à ajouter un runtime cloud ou Python à l'application.

## 0. Vérifier ce que tu as réellement reçu

État observé le 8 septembre 2026 :

- GitHub `main` : `b27f0c97edf9e6c47be9790158692710f4f7f79d`.
- Le checkout local d'Aris est sur `feat/text-quality-v3`, au même commit, avec de
  nombreuses modifications et de nouveaux fichiers non commités.
- Cette branche locale n'apparaît pas dans les branches distantes vérifiées.
- **Un clone de GitHub seul ne contient donc pas les derniers travaux décrits ici.**
- Les enregistrements personnels, modèles et rapports détaillés sous `outputs/`
  ne sont pas fournis par Git. Les chemins du Mac et du SSD ne sont pas utilisables
  automatiquement depuis une machine distante.

À l'arrivée : relève commit, branche, modifications locales, OS, architecture,
accélérateur, mémoire, outils disponibles et données accessibles. Crée une branche
`codex/…` si tu dois implémenter des changements. Ne réinitialise pas un checkout sale.

Si les changements locaux n'ont pas été transférés, demande leur commit ou un patch
de code accompagné des nouveaux fichiers nécessaires. Un `git diff` seul omet les
fichiers non suivis. Fais préciser la base exacte avant de reconstruire un correctif
qui pourrait déjà exister. Continue entre-temps les tâches indépendantes sur les
outils portables et le protocole.

Le transfert de code doit exclure les poids, caches, secrets, enregistrements,
transcriptions personnelles et contexte d'applications. L'accès au dépôt distant
n'autorise pas à y publier les données personnelles. Si elles ne sont pas fournies
par un canal autorisé, prépare une exécution locale et utilise des données publiques
pour vérifier l'outillage ; ne présente pas ces dernières comme les dictées d'Aris.

### Travaux locaux récents à récupérer ou à prendre en compte

Les chemins suivants sont relatifs à la racine du dépôt ; plusieurs n'existent pas
encore sur GitHub au moment de ce passage de relais.

| Travail | Points d'entrée |
| --- | --- |
| Résultats du correcteur, références et limites | `Docs/text-quality-results-2026-09-07.md` |
| Corpus synthétique figé de 96 cas | `Data/corpus/text-quality-synthetic-v1/` |
| Benchmark du véritable processeur de texte | `Scripts/run-text-quality-benchmark.py`, `Scripts/score-text-quality-suite.py` |
| Capture, écoute et mesures de latence | `Docs/benchmarking.md` |
| Capture native et conversion ASR | `Packages/AudioCaptureKit/Sources/AudioCaptureSession.swift` |
| Collecte personnelle et traces du pipeline | `App/Services/DictationSessionCoordinator.swift` |
| Lecture des sessions et écoute de l'original | `Packages/AppCoreKit/Sources/TrainingReview.swift`, `App/Hub/TrainingStudioView.swift` |
| Traitement final, repli et commandes dictées | `App/Services/DictationTextProcessor.swift`, `Packages/TextProcessingKit/Sources/SpokenFormatting.swift` |
| Validation de fidélité | `Packages/FidelityKit/Sources/FidelityValidator.swift`, `SpanRepair.swift` |

Les fichiers de tests associés font partie du transfert. Ne copie pas seulement les
quelques fichiers cités si leurs dépendances ont également changé : vérifie la
compilation de l'état reçu.

## 1. Partir des résultats établis, sans les généraliser

Le runtime déclaré utilise Parakeet TDT 0.6B v3 pour la reconnaissance et Qwen3.5
0.8B 4-bit pour le nettoyage, avec un adaptateur historique. Lis le registre
`Models/manifests/runtime-models.json` et `Docs/models.yaml` pour les révisions exactes.

Les derniers résultats locaux sont les suivants ; ils devront être reproduits si
tu disposes des sources, modèles et données correspondants :

- Sur 48 phrases synthétiques de contrôle, la correspondance lexicale propre du texte
  final passe de **38 à 39**. Le gain vient d'une correction du validateur. Ce n'est
  pas un taux général de réussite des dictées.
- Un contrôle supplémentaire empêche de transformer « 3 commits » en « commit 3 ».
  Les accords modaux sûrs, comme « tu doit → tu dois », peuvent être acceptés.
- Les cinq modèles déjà comparés étaient des **correcteurs de texte**, pas cinq
  moteurs de reconnaissance. Aucun remplacement du modèle actif n'a été retenu.
- Sur le développement synthétique, Qwen sans adaptateur obtient 38/48 contre 34/48
  avec l'adaptateur, mais présente aussi des régressions. Ce résultat motive un
  comparatif propre ; il ne justifie pas de désactiver l'adaptateur par défaut.
- La conversion audio utilise maintenant explicitement la qualité élevée. Une prise
  réelle conserve un son moins riche à 16 kHz qu'en natif à 44,1 kHz, mais Parakeet
  produit exactement le même texte sur les deux versions de cette prise.
- La collecte opt-in peut maintenant conserver un original Float32 pour l'écoute.
  `audio.wav` reste le signal ASR canonique ; le nouveau `native.wav` est séparé,
  identifié dans `meta.json` v4 et inclus dans le plafond de stockage existant.
- L'anticipation pendant la capture a réduit l'attente finale sur quelques rejeux
  longs. Cela ne démontre ni un gain général de débit ni une réduction d'énergie.
- Dernière vérification locale : 347 tests Swift comptabilisés, dont 3 ignorés,
  zéro échec ; 63 tests Python ; build Release réussi. Ce résultat n'est pas celui
  d'un clone distant n'ayant pas reçu les modifications.
- L'application installée était encore en 0.1.5 ; les derniers travaux n'y ont pas
  été installés ni publiés. Ne confonds pas version installée et build expérimental.

Le contrôle synthétique de 48 cas a déjà été consulté : il devient un jeu de
régression. Il ne peut plus être présenté comme un nouveau contrôle indépendant.

## 2. Premier livrable : benchmark audio personnel reproductible

Vise d'abord environ **150 dictées distinctes** : 100 pour le diagnostic et la
sélection, 50 pour un contrôle final réservé. Adapte ces nombres au volume réellement
disponible et rapporte les effectifs exacts. N'invente pas de données manquantes.

Couvre français, anglais et mélange de langues, termes de projets, noms propres,
nombres, négations, hésitations, autocorrections, listes, code et dictées longues.
Échantillonne aussi des dictées faciles et déjà correctes ; un corpus exclusivement
composé d'échecs donnerait une image trompeuse du produit.

Chaque entrée doit relier sans ambiguïté :

- identifiant, groupe source/session, chemin audio relatif, SHA-256 et durée ;
- format audio effectivement évalué, et éventuel original distinct ;
- langue et catégories utiles ;
- verbatim de référence et texte fidèle attendu, dans deux champs séparés ;
- provenance de chaque référence, modèle/révision/consigne ayant servi à la produire,
  décision d'acceptation ou d'exclusion et contrôles appliqués ;
- split figé et version du manifeste.

Recoupe les références IA avec des systèmes indépendants quand c'est possible.
L'accord de plusieurs modèles reste une référence IA, pas une vérité humaine.
Évite de fabriquer la référence à partir de la sortie du candidat que tu veux classer.
Si le candidat a participé à l'adjudication, signale ce biais et utilise une référence
indépendante ou un contrôle public pour corroborer la comparaison.

Contrôle les doublons exacts et proches. Une même prise, ses sous-extraits et ses
variantes fidèle/réécriture restent dans le même groupe. Gèle les références avant
de comparer les candidats. Ne montre pas les résultats du contrôle final pendant
les itérations de sélection.

Complète ce diagnostic personnel par un petit contrôle public avec des transcriptions
documentées, par exemple FLEURS FR/EN ou MediaSpeech FR, en vérifiant les sources et
licences. Rapporte les résultats personnels et publics séparément.

### Outillage à réutiliser et à vérifier

- `Scripts/build-personal-benchmark.py`
- `Scripts/run-personal-transcriber-head-to-head.py`
- `Tools/benchmarks/run_mlx_asr_challenger.py`
- `Tools/benchmarks/score_asr_challengers.py`
- `Tools/benchmarks/adjudicate_transcriber_predictions.py`
- `Tools/benchmarks/compare_transcriber_reports.py`
- `Tools/asr-benchmark-cli/Sources/main.swift`
- `Scripts/prepare-fleurs-test-benchmark.py`, `Scripts/prepare-mediaspeech-fr-benchmark.py`

Ne suppose pas que leurs anciens contrats conviennent à cette campagne. Certains
scoreurs attendent un teacher Wispr ; certains scripts sont liés au SSD du Mac ;
le runner MLX reprend actuellement des résultats par ID. La nouvelle campagne doit
identifier un résultat par **audio + modèle/révision + paramètres + version du runner**.
Une reprise ne doit jamais réutiliser silencieusement une ancienne prédiction.

Ajoute des tests utiles : association audio/ID incorrecte, référence changée,
chevauchement de splits, doublon, résultat absent, échec d'inférence et reprise avec
une configuration différente. Une comparaison incomplète doit être signalée ; les
échecs restent comptés, pas supprimés du dénominateur.

## 3. Comparer la reconnaissance avant de changer le produit

Compare d'abord trois candidats hors application :

1. Parakeet actuellement utilisé, avec sa configuration de production.
2. Qwen3-ASR 0.6B ; considérer 1.7B seulement si la première passe le justifie.
3. Whisper large-v3-turbo.

Sources de départ à vérifier au moment de l'exécution :
[Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B),
[Whisper Turbo](https://huggingface.co/openai/whisper-large-v3-turbo),
[MLX Audio](https://github.com/Blaizzy/mlx-audio).

Utilise les mêmes prises, le même périmètre et des paramètres figés. Un système ne
doit pas recevoir la langue de référence ou le vocabulaire attendu si les autres
doivent les deviner. Commence sans vocabulaire propre aux réponses ; compare ensuite
les aides contextuelles réellement disponibles à la dictée, dans une expérience séparée.

Mesure le WER brut avec sa normalisation documentée, les insertions/suppressions,
les erreurs sur faits critiques et les échecs. Conserve les transcriptions brutes.
Ne normalise pas au point d'effacer les accents, nombres, négations ou différences
qui constituent précisément les erreurs à détecter.

Mesure séparément chargement à froid, inférence à chaud, mémoire et délai de fin de
dictée. Les temps Linux/GPU distant ne prédisent pas ceux d'un Mac Apple Silicon.
Un résultat PyTorch ou MLX Python ne valide pas une intégration Core ML/MLX Swift.

Le livrable est un tableau accompagné des différences par exemple, puis une décision
argumentée : conserver le moteur, améliorer son décodage/contextualisation, ou proposer
un remplacement. Ne charge pas trois moteurs dans le produit pour éviter de choisir.

## 4. Améliorer le texte final selon les erreurs observées

Sur les mêmes dictées, conserve et compare les étapes suivantes : reconnaissance
brute, normalisation, proposition de Qwen, décision du validateur, repli éventuel et
texte final réellement retenu. Une bonne proposition rejetée ne compte pas comme un
bon résultat produit.

Classe les défauts pour prioriser les changements :

- mot mal reconnu malgré un audio exploitable ;
- faute correctement reconnue mais non corrigée ;
- bonne correction rejetée par la fidélité ;
- mauvaise reformulation acceptée ;
- problème de segmentation, commande dictée, troncature ou timeout.

Compare le correcteur actuel avec le même Qwen pristine sans adaptateur sur ce
diagnostic réel. Conserve les paramètres des anciennes expériences pour comprendre
les différences. Ne multiplie pas les variantes sans hypothèse issue d'erreurs précises.

Implémente les corrections à fort impact et vérifie leurs contre-exemples. Une règle
d'accord ne doit pas autoriser un changement de temps, de sujet, de modalité ou de
négation. Une protection littérale de nombres ne suffit pas à préserver leur rôle.
Le vocabulaire contextuel doit venir du contexte autorisé et des termes confirmés,
pas d'une liste de bonnes réponses extraite du benchmark.

Les modes fidèle, réécriture et code ont des contrats distincts. Évalue le fidèle
en premier. Ne mélange pas leurs cibles pour gonfler le dataset ou ses scores.

## 5. Entraînement ciblé, seulement après ce diagnostic

Si les erreurs restantes sont répétitives et apprenables, prépare un adaptateur
de correction depuis le Qwen pristine, avec des paires issues de vrais échecs ASR
et des références IA contrôlées. Le lot d'entraînement est distinct du développement
et du contrôle final. Ne pars pas de l'adaptateur historique à la lignée non reproductible.

Le dépôt contient des contraintes humaines historiques dans `Docs/dataset-policy.md`
et `Scripts/build-qwen-human-gate.py`. L'instruction actuelle de l'utilisateur autorise
le travail sur des références IA sans relecture personnelle. Réconcilie explicitement
ce nouveau protocole avec les scripts : ajoute un mode/campagne IA clairement nommé
et ses contrôles, sans prétendre satisfaire le gate humain ni modifier sa définition.
Ne renseigne jamais `--references-reviewed`, `source=human` ou une approbation humaine
pour faire passer des références IA. Préserve les garanties de provenance et d'absence
de fuite ; mets la documentation et les tests en cohérence.

Livre le manifeste, la recette, les hyperparamètres, le budget calculé et l'évaluation
avant/après. Utilise seulement les ressources déjà autorisées. Si une dépense cloud
ou un transfert de données personnelles est nécessaire, prépare le lancement puis
demande l'autorisation portant sur ces éléments concrets.

## 6. Critères de sélection et de livraison

Fixe la métrique principale avant de lire les résultats du contrôle : pour le mode
fidèle, taux d'erreurs lexicales du texte final contre la référence fidèle, avec les
erreurs de formatage et de faits rapportées séparément. Le WER brut reste une mesure
du moteur, pas un substitut à la qualité finale.

L'objectif de campagne est **20 % de réduction relative des erreurs finales**. Exemple :
10 % d'erreurs devenant 8 %. C'est une cible, pas un résultat promis ou une raison
de modifier le dénominateur. Rapporte les effectifs, incertitudes et catégories faibles ;
si le petit contrôle ne permet pas de conclure, dis-le et prévois son extension.

La sélection exige également :

- pas de nouvelles altérations de faits critiques observées dans le contrôle ;
- pas de régression sur les témoins déjà corrects, commandes et cas de fidélité ;
- échecs, troncatures et replis inclus dans les résultats ;
- un budget mémoire compatible avec le Mac cible, à confirmer sur la machine ;
- un délai après dictée comparable, avec un budget fixé sur la baseline avant sélection.

Un candidat inférieur reste un résultat d'expérience et ne remplace pas le runtime.
Un nouveau moteur produit exige une proposition d'intégration native et de coût,
distincte de sa victoire éventuelle dans un script de benchmark.

Sur macOS avec les outils requis, exécute `./Scripts/verify.sh --fast`, puis les
vérifications ciblées et le build approprié aux changements. Sur Linux, exécute les
tests portables et configure/sollicite la validation macOS nécessaire. Ne marque pas
les tests SwiftUI, AVFoundation, Core ML, MLX Swift ou l'insertion inter-apps comme
réussis parce que des tests Python passent.

Prépare des changements cohérents et faciles à relire, avec les commandes de
reproduction et un rapport qui distingue **mesuré / inféré / non vérifié**. Prépare
la version candidate ; ne publie pas de release, ne fusionne pas dans `main` et ne
remplace pas l'application installée d'Aris sans l'autorisation correspondante.

## Résultat attendu de ta mission

1. Un état des lieux précis du checkout et des ressources accessibles.
2. Un corpus/manifeste figé ou un outil prêt à le construire localement, sans données
   privées dans Git.
3. Un runner et un scoreur reproductibles avec des tests de leurs modes d'échec.
4. Une comparaison ASR puis texte final, dans les limites des ressources disponibles.
5. Les corrections justifiées par cette comparaison, avec tests et bilan avant/après.
6. Si pertinent, une recette d'adaptation propre et son protocole d'évaluation.
7. Un passage de relais court indiquant les commandes restantes sur le Mac, les
   artefacts attendus et les décisions qui exigent encore une mesure ou une autorisation.

Commence par les étapes 0 et 2. Avance sur l'implémentation utile ; ne termine pas
par un nouveau plan générique si tu peux déjà produire le benchmark et ses outils.
