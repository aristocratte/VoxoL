# Benchmarking

Tous les résultats sont des observations associées à un environnement, un commit et un schéma;
ils ne deviennent jamais des promesses produit sans corpus et protocole publiés.

## Réduction de l'attente après dictée — 7 septembre 2026

Le chemin natif prépare maintenant des corrections pendant la capture, puis ne réutilise que
les calculs correspondant exactement aux entrées finales. Aucun poids, prompt de correction,
seuil de fidélité, découpage texte de 45 mots ou budget final de 14 secondes n'est assoupli.
Le décodage spéculatif `promptLookupTokenCount` reste désactivé par défaut.

### Diagnostic de capture et précision — 7 septembre 2026

Dans la version installée 0.1.5, « Écouter » lit `audio.wav` : du PCM16 mono à 16 kHz,
sans compression avec perte. Le fichier est issu des échantillons Float32 déjà
convertis pour la reconnaissance, arrondis sur 16 bits. Il représente donc ce que
le moteur reçoit, à cet arrondi près, plutôt que le flux natif fourni par macOS.

L'audit de 24 prises récentes a mesuré un niveau RMS médian d'environ −45 dBFS.
Le micro sélectionné était celui du MacBook, à 44,1 kHz, avec un volume d'entrée
système de 32 %. Le caractère métallique signalé par l'utilisateur ne peut pas
être attribué au seul volume. Aucune écoute subjective par l'agent n'est revendiquée.

Les tests du véritable convertisseur de capture ont révélé un filtrage insuffisant
avec son réglage par défaut. Pour une sinusoïde de 10 kHz d'amplitude 0,02 à 48 kHz,
le résidu replié dans la sortie 16 kHz avait un RMS de 0,000454 ; après activation
explicite de la qualité `high`, il est de 0,000000094. La bande à 6 kHz est également
mieux conservée. Les tests à 44,1 et 48 kHz contrôlent durée, continuité, faible
amplitude, bande utile et rejet des fréquences supérieures à 8 kHz. Cela démontre
une amélioration du signal sur ces tests, pas encore une baisse du WER en conditions
réelles ni la résolution de tout le défaut perçu.

La collecte personnelle existante ajoute maintenant `captureTrace` à `meta.json` :
périphérique réellement utilisé, format d'entrée, format ASR, qualité de conversion,
traitement vocal actif, niveau maximal, écrêtage et échantillons perdus. Cette trace
reste soumise à l'activation existante de la collecte et à l'exclusion du mode privé.

Pour comparer une même prise native/ASR sans modifier l'application installée,
le build de développement accepte ce diagnostic explicitement demandé :

```sh
.build/DerivedData/Build/Products/Release/VoxoL.app/Contents/MacOS/VoxoL \
  --capture-probe 10 disabled \
  --output-directory /chemin/vers/un-nouveau-dossier
```

Le test dure 10 secondes, utilise le micro sélectionné dans VoxoL et écrit
`native.wav`, `asr.wav` et `capture.json`. Les deux WAV sont Float32 sans perte,
issus des mêmes callbacks de capture. « Natif » signifie avant les traitements
de VoxoL, tel que fourni par macOS, pas avant les traitements matériels du micro.
La rétention de ce diagnostic est limitée à 15 secondes. Un dossier déjà
existant est refusé avant l'ouverture du micro. Le test doit être lancé lorsque
l'utilisateur est prêt à prononcer sa phrase ; il n'a pas été remplacé par un
enregistrement de silence ou par des paroles synthétiques jouées dans le micro.

### Écoute de l'original — 8 septembre 2026

Une prise réelle de 10,3 secondes a été capturée simultanément en Float32 mono
44,1 kHz et après conversion en 16 kHz. Aucun bloc perdu n'a été signalé. L'utilisateur
entend davantage le défaut « low-bitrate » dans la deuxième version. Une conversion
indépendante de l'original vers 16 kHz donne une corrélation de 0,99675 avec la sortie
VoxoL, après ajustement du gain et exclusion des bords. C'est compatible avec une
différence liée principalement à la bande passante, sans établir une équivalence perceptive.

Parakeet produit exactement la même transcription brute pour les deux fichiers,
y compris « liste à puce » au singulier. Le texte proposé à lire n'a pas été transformé
en référence certifiée : cette comparaison est un diagnostic sur une prise, pas un
benchmark de précision. Le chargement de l'original reconvertit lui aussi vers les
16 kHz mono attendus par [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).

Le build de développement conserve maintenant un `native.wav` Float32 sans perte
en plus de `audio.wav` lorsque la collecte personnelle est active au début de la
prise et que le mode privé est désactivé. L'écriture reste soumise aux mêmes réglages
en fin de dictée. La rétention est bornée à la durée ASR (180 secondes au maximum)
et à 64 Mio d'échantillons natifs au total ; une copie tronquée n'est jamais proposée
comme original complet. Les entrées non prises en charge continuent à fonctionner
pour l'ASR sans conserver de copie native.

« Écouter » utilise cette copie complète si elle existe et revient à `audio.wav`
pour les anciennes prises ou si la copie ne peut pas être lue. Une infobulle précise
la source. La durée du lecteur vient du fichier lu. Le chemin `audioURL` des jeux
d'évaluation reste celui de `audio.wav` : les benchmarks existants ne changent pas
silencieusement de signal. `meta.json` version 4 contient les formats, le lien entre
les deux captures et leurs SHA-256. Aucun gain d'écoute n'est appliqué aux fichiers.

Le plafond existant de 500 Mo comprend les deux fichiers. Les écritures sont
sérialisées et calculent le volume complet avant de commencer ; si l'original
ne tient plus, seule la prise ASR est conservée. Aucun ancien enregistrement n'est
effacé. Le surcoût typique de l'original mono 44,1 kHz est d'environ 10,6 Mo/minute.
L'application installée n'a pas été remplacée et aucun gain de précision n'est
attribué à cette amélioration de l'écoute.

La prochaine mesure de précision doit partir des dictées audio réelles : conserver
l'audio et son empreinte, produire des références IA explicitement déclarées comme
telles, isoler un contrôle non consulté, puis comparer reconnaissance brute et texte
final. Les essais précédents comparaient des correcteurs de texte. Une comparaison
acoustique peut ensuite opposer Parakeet à Qwen3-ASR et Whisper, dont les runtimes
Apple Silicon sont documentés par [MLX Audio](https://github.com/Blaizzy/mlx-audio#speech-to-text-stt).
Ces moteurs ne sont pas classés par les scores du corpus synthétique de texte.
Une version ne doit être retenue qu'avec moins d'erreurs sur le contrôle, sans
augmentation des erreurs de faits ni dégradation inacceptable du délai d'insertion.

### Architecture et périmètre

`voxol.prefetchEnabled` est activé par défaut pour Parakeet en langue automatique avec les
aperçus activés. Il n'est pas démarré en économie d'énergie ou sous pression thermique sérieuse
ou critique. Les aperçus acoustiques utilisent le préfixe capturé, limité aux 180 secondes que
le buffer de capture peut retenir, plutôt qu'une simple fenêtre finale de 20 secondes. Leur
cadence passe à quatre secondes après les vingt premières secondes.

Le correcteur prépare les blocs complets, en laissant le dernier bloc ouvert. Le contexte de
chaque bloc est construit avec les mêmes résultats validés que dans le traitement final. La
réutilisation exige un UUID de dictée explicite, les octets UTF-8 exacts du système et du message
utilisateur, et le même plafond de tokens. Même une différence Unicode canoniquement équivalente
invalide la clé. Toute sortie récupérée repasse dans les validateurs finaux et la restauration
des placeholders. Les annulations et timeouts ne sont pas mis en cache. Une sortie réellement
terminée mais vide ou tronquée peut être conservée comme **échec**, jamais comme réussite : son
statut et son repli restent identiques, sans répéter la génération à chaque aperçu.

Un second cache conserve les sorties de l'encodeur Parakeet uniquement pour les **mêmes octets
audio** et la même normalisation, dans le même runtime et la même dictée. Les fenêtres complètes
sont gardées par une politique LRU ; une fenêtre finale modifiée est recalculée. Le décodeur TDT,
les biais de vocabulaire, les marges et l'assemblage des overlaps sont toujours recalculés : un
nouveau vocabulaire final ne peut donc pas être ignoré à cause d'un ancien décodage.

Les budgets sont de 96 entrées / 1 Mio de données comptabilisées pour Qwen et de 16 entrées /
32 Mio pour les entrées et sorties de l'encodeur. Ce ne sont pas des plafonds de RAM totale de
l'application. Les caches ne créent aucun fichier audio ni historique ; ils sont vidés à la fin,
à l'annulation ou au remplacement de la session. Les fins de sessions périmées ne peuvent pas
effacer les données d'une nouvelle session. Les tâches annulées sont rejointes avant la finale.

### Interpréter les mesures

Deux protocoles sont distincts. `--prefetch-replay` dévoile progressivement un **texte connu** :
il mesure le potentiel avec des préfixes stables, pas la latence d'un ASR réel. `--audio-replay`
avec `--replay-real-time` ne fournit au moteur que l'audio disponible à chaque instant. Ce second
protocole compare un contrôle initial, le traitement anticipé, puis un contrôle frais après
vidage des caches, dans le même processus préchauffé. Les rapports vérifient les empreintes du
texte ASR et du texte final, séparent ASR, attente du producteur, correction résiduelle, réutilisations
et échecs. Le temps mesuré s'arrête au **texte prêt**, pas à son insertion dans une autre application.

Il s'agit de déplacer du travail pendant la parole et d'éviter les recalculs, pas de multiplier
magiquement la vitesse intrinsèque des modèles. Le coût cumulé des aperçus reste rapporté ;
l'énergie et l'autonomie ne sont pas mesurées. Un fichier importé, disponible d'un seul coup,
ne bénéficie pas de temps de parole masqué. Les cibles diagnostiques AI-labeled restent non humaines,
même si leurs identifiants commencent par `human-` ; aucun classement commercial n'en découle.

### Résultats sur le build natif final

Le binaire Release évalué porte le SHA-256
`180359a5a51e3e3ccd53b3e9c50a5e80076c186a62dbecfb087d3e3cda687947`.
Les chronométrages suivants vont de l'arrêt du rejeu au **texte prêt**, avec des modèles chauds.
Ils incluent Parakeet, l'attente éventuelle du producteur annulé et la correction restante.
Le contrôle frais est exécuté après vidage des caches de session ; il montre aussi la variabilité
de charge de ce Mac, qui n'était pas réservé aux benchmarks.

| Enregistrement / contrat | Contrôle initial | Avec anticipation | Contrôle frais | Parité et échecs |
| --- | ---: | ---: | ---: | --- |
| 84,56 s, 140 mots, fidèle | 3 151 ms | **766 ms** | 2 639 ms | ASR et texte final identiques dans les trois passes ; aucun échec |
| 180 s, 438 mots, fidèle | 7 362 ms | **1 475 ms** | 8 719 ms | ASR et texte final identiques dans les trois passes ; aucun échec |
| Même audio de 180 s, confirmation indépendante du premier run | 8 145 ms | **1 599 ms** | 9 123 ms | ASR et texte final identiques dans les trois passes ; aucun échec |
| 133,93 s, 278 mots, réécriture | 6 283 ms | **1 891 ms** | 14 957 ms | Mêmes textes, mais `generationFailed` déjà présent dans les trois passes : pas un succès qualité |

Les preuves sont `confirmation-audio85-faithful.json`, `encoder-audio180-faithful.json` et
`encoder-audio134-rewrite.json` dans le dossier de session. Ce sont trois enregistrements,
pas un benchmark représentatif de tous les locuteurs, accents, contextes ou applications.
Le rejeu de confirmation est `confirmation-audio180-faithful.json` ; les commandes, empreintes
audio, dates et empreinte du binaire inchangé sont dans `confirmation-manifest.json`. Le même
enregistrement répété n'est pas compté comme une quatrième source indépendante.

Dans le cas de 180 secondes, 13 des 15 appels de correction finaux réutilisent un résultat
calculé pendant la capture ; il ne reste que deux appels et 63 tokens à produire après l'arrêt,
au lieu de 15 appels et 645 tokens. Neuf fenêtres d'encodeur sont réutilisées. Le coût cumulé
des aperçus reste visible : 11,01 s d'ASR et 13,03 s de correction pendant les 180 s de parole.
Sur 84,56 s, le coût anticipé cumulé est de 3,05 s d'ASR et 4,20 s de correction. Ces sommes
mesurent du temps de calcul, pas de l'énergie ni une consommation électrique.

**Simulation textuelle séparée :** les 14 cas longs couvrent sept entrées françaises distinctes,
testées sous les deux contrats, de 136 à 661 mots. Avec des préfixes textuels connus et stables,
les 14 candidats et 14 textes finaux sont inchangés. La médiane résiduelle passe de 3 242,5 à
936 ms, et le maximum de 11 448 à 1 612 ms. Deux cas conservent des échecs partiels préexistants.
Pour l'entrée de 661 mots : 8 485 → 1 128 ms en fidèle ; 11 448 → 1 612 ms en réécriture.
Ce protocole ne mesure ni l'ASR ni la stabilité acoustique et ne doit pas servir de promesse produit.

**Expériences non promues :** les graphes de génération groupant quatre ou huit tokens ont
augmenté la latence ou atteint les budgets ; la vérification anticipée d'une copie de l'entrée
a trop peu de succès pour amortir son coût ; les variantes de blocs de 30/90 mots et les lots
de plusieurs corrections ont modifié les sorties. Le lookup de 16 tokens a réduit une mesure
de deux longs cas à 6,53/7,51 s, mais change un texte final sur les deux. Ces essais restent dans
`rejected-experiments-source/` et les rapports `experiment-summary.json`, `v2-summary.json`,
`batchgrid-summary.json`, pas dans la configuration de production. Les baselines variaient
fortement entre passes : ne pas leur attribuer des ratios précis sans essais complémentaires.

Validation : 327 tests Swift (trois ignorés, zéro échec), 56 tests Python, vérifications de
format/politique, et compilation Release réussie. L'application installée dans `/Applications`
n'a pas été remplacée. Aucun poids ni adaptateur n'a changé ; aucun entraînement ni appel distant
de reconnaissance n'a été lancé. La capture physique et l'insertion inter-applications n'ont
pas été rejouées : le gain d'attente utilisateur complet reste à mesurer dans ce dernier parcours.

### Reproduction locale

```sh
BIN=.build/ReleaseBuild/Build/Products/Release/VoxoL.app/Contents/MacOS/VoxoL
MODEL="$HOME/Library/Application Support/VoxoL/Models/polisher/2fc06364715b967f1860aea9cf38778875588b17"
ASR="$HOME/Library/Application Support/VoxoL/Models/asr/7c35754d166cca382ad1e53e68b01e7c575f3a1d"
"$BIN" --polisher-smoke --model "$MODEL" --asr-model "$ASR" \
  --audio-replay /chemin/vers/enregistrement.wav --replay-real-time --replay-seconds 180
```

Ajouter `--rewrite` pour le contrat réécriture. Un exit code 1 peut signaler un échec de modèle
déjà présent dans les contrôles : comparer aussi les statuts et les textes, sans effacer ces cas.
Les simulations textuelles se lancent avec `--suite ... --through-processor --prefetch-replay`.
Les scripts expérimentaux rejetés et les résultats de toutes les variantes restent sous
`/Users/aris/Documents/Zphyr-backups/long-latency-20260907-005056/`, séparés des poids et du dépôt.

## Investigation d'inférence M4 / 16 Go — session du 6 septembre 2026

Les changements retenus concernent l'allocation mémoire et l'annulation, pas les poids :

- Le pool de buffers recyclables MLX est limité à **64 Mio** par défaut. Ce n'est ni un plafond
  de RAM totale, ni une réduction du KV cache, ni une éviction des poids ou états récurrents.
  `maximumBufferCacheBytes: nil` laisse la politique MLX inchangée dans un nouveau processus.
- Une annulation Parakeet se propage aux étapes GCD et au décodeur. Les producteurs mel/encodeur
  et les décodeurs sont tous rejoints avant de réutiliser les buffers pour une dictée finale.
  Une prédiction Core ML déjà en cours n'est pas interrompue de force.
- Le runtime Qwen conserve et rejoint la tâche productrice MLX, y compris après timeout.
  Le plafond de sortie est vérifié via le nombre effectif de jetons : la version MLX épinglée
  peut annoncer `.cancelled`, plutôt que `.length`, au plafond. Une réponse tronquée est rejetée.

**Mesures locales, Release, modèles préchauffés :** sur les mêmes 182 cas diagnostiques,
le runtime corrigé avec pool MLX par défaut puis avec pool de 64 Mio produit **182/182 sorties
brutes identiques et 182/182 textes finaux identiques**, y compris les cinq échecs au plafond.
La médiane reste à 423,5 ms ; la moyenne observée est de 718,5 puis 665,3 ms, le p95 de
2 150 puis 1 726 ms. Le pic d'empreinte du processus de test Qwen (`/usr/bin/time -l`) passe
de 9 507 653 360 à 1 441 515 008 octets. Le cache réutilisable final passe de 8 737 557 412
à 67 540 496 octets. L'allocation active reste autour de 620 Mo : il s'agit de buffers conservés,
pas d'une fuite démontrée. Ces nombres ne mesurent pas la RAM de l'application complète avec ASR.

Le microbenchmark d'annulation utilise deux enregistrements locaux et des sous-extraits :
20 mesures par variante, dont huit aperçus de 20 secondes annulés avant une finale de 2,51 s.
La latence annulation-vers-finale moyenne passe de 245,2 à 167,7 ms ; les 20 empreintes de texte
et de jetons sont identiques. Ce n'est pas une mesure microphone-vers-insertion ni un score WER.

**Expérience conservée désactivée :** `promptLookupTokenCount` reste `nil` en production.
`PromptLookupDecoder.swift` propose des tokens issus de la transcription, les vérifie par Qwen,
et restaure/rejoue l'état hybride complet lorsqu'un suffixe est rejeté. Il n'ajoute aucun modèle.
Le lot de 16 tokens réduit la médiane diagnostique de 412,5 à 193 ms, mais change 22 sorties
brutes et 10 finales sur 182 par rapport au binaire initial, dont les cas de troncature corrigés.
Les autres divergences ne sont pas expliquées suffisamment pour une promotion : ni garantie
de parité numérique, ni promesse de qualité inchangée. Ne pas promouvoir à partir du seul gain.
Face au contrôle qui inclut déjà le correctif de troncature, il reste 17 différences brutes
et neuf finales : ces divergences ne peuvent donc pas toutes être attribuées au correctif.

Le build final passe aussi les neuf cas synthétiques FR/EN de régression : deux timeouts sont
déclenchés intentionnellement, puis les appels suivants réussissent. Le contrôle sans plafond
et la configuration par défaut produisent les mêmes sorties. Dans le chemin de traitement
complet du texte, les 24 cas pilotes ont également des sorties identiques avant/après ; la
médiane est de 188,5 puis 190,5 ms, mais les deux entrées de 661 mots prennent encore environ
8,6–9 secondes. Ne pas présenter le gain mémoire comme une résolution de cette latence longue.
La vérification finale exécute 310 tests Swift (trois ignorés, zéro échec), 56 tests Python,
et une compilation Release réussie. L'application installée n'a pas été remplacée.

L'ablation de l'adaptateur installé sur les 12 cas synthétiques n'améliore pas l'exact match
(5/12 dans les deux essais) et introduit des réécritures rejetées. L'adaptateur est conservé.
Les exemples AI-labeled, même lorsqu'un identifiant commence par `human-`, ne sont pas du gold
humain et n'autorisent pas un classement face à Wispr, Gemini ou un autre ASR.

### Reproduire les contrôles d'inférence

Utiliser un build Release, sans compilation ni autre benchmark en parallèle. Le binaire installé
n'est pas remplacé par ces commandes. Les suites diagnostiques et leurs textes doivent rester locaux.

```sh
BIN=.build/ReleaseBuild/Build/Products/Release/VoxoL.app/Contents/MacOS/VoxoL
MODEL="$HOME/Library/Application Support/VoxoL/Models/polisher/2fc06364715b967f1860aea9cf38778875588b17"
SUITE=Tests/Performance/Fixtures/polisher-inference-regression-v1.json

# Deux processus distincts : contrôle puis plafond de buffers, sans décodage expérimental.
/usr/bin/time -l "$BIN" --polisher-smoke --model "$MODEL" --suite "$SUITE" \
  --mlx-cache-mb unlimited > .build/polisher-unlimited.json
/usr/bin/time -l "$BIN" --polisher-smoke --model "$MODEL" --suite "$SUITE" \
  --mlx-cache-mb 64 > .build/polisher-cache64.json
python3 Scripts/compare-polisher-runs.py \
  .build/polisher-unlimited.json .build/polisher-cache64.json

# Recherche uniquement : 0 = greedy direct, 1..16 = vérification par blocs.
"$BIN" --polisher-smoke --model "$MODEL" --suite "$SUITE" \
  --prompt-lookup-tokens 16 > .build/polisher-lookup16.json
```

Le comparateur aligne les identifiants, refuse les doublons/ensembles différents et sépare
différences brutes, finales, échecs, et latences de tous les cas / des cas terminés des deux côtés.
Il ne publie pas le texte dicté. Sa médiane est la moyenne des deux valeurs centrales et son p95
utilise le rang supérieur ; les anciens JSON natifs emploient un index arrondi, d'où de légères
différences possibles. Les deux cas `timeout` de la nouvelle fixture doivent échouer, puis les
cas `after-timeout` doivent réussir. Un exit code nul du smoke runner indique une suite exécutée,
pas une qualité validée. `--through-processor` applique aussi les paramètres expérimentaux,
et conserve les timeouts/découpages/flags de diagnostic de ce chemin. `--without-adapter` est
une ablation explicite et ne supprime aucun fichier ; incompatible avec `--adapter`.

Les preuves de cette session sont dans le dossier local indiqué par
`.build/inference-session-path.txt` : source initiale, binaire initial, logs et JSON de chaque run.
La copie du binaire initial est indispensable pour ne pas confondre nos changements avec les
nombreuses modifications déjà présentes dans le worktree au début de l'investigation.

La collecte privée Gemini par lots réattribue les réponses à l'aide de Parakeet. Ce contrôle est
utile pour préparer des données silver, mais introduit une dépendance au système évalué : ces
résultats ne constituent pas un classement indépendant. Les lots non alignés historiques sont
invalidés. Le benchmark public ServiceNow reste distinct de cette collecte personnelle.

Les rapports du head-to-head sont recalculés lorsque le hash du manifeste ou des prédictions change,
afin qu'une réparation de données ne conserve pas un ancien score en cache.

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

Chaque cas de suite peut porter `mode` (`faithful` ou `rewrite`) et `profile`, afin que la cible
soit jugée sous le contrat qui l'a produite. Le corpus diagnostique AI-labeled se convertit en suite
avec `Scripts/build-polisher-suite-from-corpus.py` (182 lignes FR/EN sur 184 le 2026-09-03). Deux
chemins existent :

- sans option, la suite appelle le runtime Qwen directement et rapporte les jetons et le cache de
  préfixe — c'est la mesure du modèle et du validateur ;
- avec `--through-processor`, elle passe par `DictationTextProcessor` — timeouts de production et
  découpage des longues dictées en tranches de phrases — c'est la mesure de ce que l'utilisateur
  obtient. Les compteurs de jetons y valent zéro.

Une mesure ne vaut que seule sur la machine : une compilation en parallèle décale les latences et
fait expirer les cas longs. Les rejets `reorderedProtectedToken` du 2026-09-03 (14/184) étaient un
défaut du validateur, pas du modèle : l'ordre des jetons est désormais jugé sur leur position dans
le prompt.

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

### Comparatif Parakeet, Gemini et Wispr Flow

Le runner personnel rejoue exactement les mêmes WAV et la même référence gelée dans les trois
systèmes. Il reprend les prédictions existantes, collecte Gemini en paires verbatim/mise en forme,
convertit Gemini et Wispr vers le schéma commun puis score les sorties brutes et finales avec le
même normaliseur :

```sh
python3 Scripts/run-personal-transcriber-head-to-head.py \
  --systems parakeet,gemini,wispr \
  --adjudicate --apply-adjudication
```

L'adjudication choisit automatiquement une référence silver lorsque Gemini et Wispr convergent et
que les noms techniques, nombres, commandes et négations restent cohérents. Les divergences
critiques sont placées en quarantaine; une décision contextuelle optionnelle reste étiquetée
`agent-context-adjudicated`, jamais `human-reviewed`. `--apply-adjudication` écrit `verbatim.txt`,
`corrected.txt` et `review.json` dans chaque session acceptée afin que le Training Studio et le run
suivant reprennent exactement la même décision.

Seul `--references-reviewed`, après contrôle humain de chaque référence, peut produire un
`candidate-gate`; une référence d'ensemble produit toujours un `silver-diagnostic`. Gemini passe
exclusivement par Gemini.app connecté, sans clé API. Le transport par défaut `batch-app` joint huit
audios portant leur ID dans une seule discussion temporaire et récupère autant de paires
verbatim/mise en forme, ce qui évite une activation et une discussion par fichier. Si la réponse ne
couvre pas exactement tous les IDs, le lot est divisé; les éléments déjà enregistrés sont repris
sans nouvel envoi. Le transport historique reste disponible avec `--gemini-transport app`.

La retranscription verbatim Gemini reste la prédiction silver utilisée pour l'adjudication. Sa mise
en forme est conservée comme `polishedCandidate` et ne devient jamais automatiquement une
référence. Une reprise dont le cache couvre déjà tous les IDs ne lance pas Gemini.app. Le corpus
personnel utilise `--language auto` par défaut afin de ne pas pénaliser les passages anglais; un
choix explicite reste disponible pour un corpus réellement monolingue. Une interruption est sans
perte, car le runner et les collecteurs reprennent au niveau prédiction ou segment.

Les sorties se trouvent sous
`~/Library/Application Support/VoxoL/PersonalBenchmark/head-to-head/<run>` avec le manifeste figé,
les prédictions, les rapports par système, `comparison.json`, `comparison.md` et
`run-metadata.json`. Avec `--apply-adjudication`, le runner produit aussi un benchmark limité aux
références acceptées sous `adjudicated-benchmarks/<empreinte-du-manifeste>/comparison.md`; ce rapport
versionné reste un diagnostic silver. Une
sortie VoxoL, Gemini ou Wispr ne peut jamais promouvoir un modèle contre sa propre référence : le
gate final exige toujours du texte humain indépendant.

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

## Code-switch français/anglais

Le benchmark public ServiceNow `asr_codeswitched` complète les corpus monolingues avec 486 clips
FR/EN : 298 en français international/anglais et 188 en français canadien/anglais. Le préparateur
épingle la révision du dataset, vérifie taille et SHA-256 des deux Parquet, convertit chaque audio en
WAV PCM mono 16 kHz, puis fige le manifeste. Les sources sont synthétiques et le dataset ne déclare
pas de licence dans sa carte épinglée : le cache reste donc local et n'est jamais redistribué.

```sh
VOXOL_SERVICENOW_RUN_ID=voxol-local-YYYYMMDD-v1 \
  ./Scripts/run-servicenow-code-switch-benchmark.sh
```

Le rapport calcule le WER global micro/macro avec un miroir déterministe du chemin
`normalize_text(..., "en/fr")` d'AU-Harness, puis ajoute ses propres tranches par français/anglais,
configuration, indice de mélange et nombre de changements de langue. Les insertions restent dans le
WER global mais ne sont pas attribuées à une langue. Seul le WER global est comparé au graphique
ServiceNow publié; les tranches VoxoL restent diagnostiques. Les scores sémantiques SWER/AER du
harnais officiel sont explicitement exclus parce qu'ils exigent un juge externe.

Sources du protocole : carte et données `ServiceNow-AI/asr_codeswitched`, article ServiceNow du
9 juin 2026 et dépôt `ServiceNow/AU-Harness`.

Le run local du 3 septembre 2026 et son diagnostic sont conservés dans
`Docs/servicenow-code-switch-results-2026-09-03.md`.

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

### Campagne locale de précision du 8 septembre 2026

Les résultats ASR et texte final sont documentés dans
[real-dictation-results-2026-09-08.md](real-dictation-results-2026-09-08.md).
`Scripts/run-dictation-campaign.py` utilise désormais `infer-parakeet` avec un
manifeste audio seul : `schemaVersion: 1`, `sourceManifestSHA256`, puis des `items`
contenant uniquement `id`, `audioPath` et `audioSHA256`. Cette commande vérifie les
fichiers avant et après l'inférence sans fabriquer une approbation de référence.
Les commandes `freeze` et `score` historiques conservent leur contrat de références
relues. Le scoreur de campagne mesure `raw`, `normalized` et `final` ; les propositions
`candidate` avec jetons de protection restent des traces de diagnostic non scorées.
