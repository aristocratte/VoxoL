# VoxoL Text Quality v3 — baseline et incrément shadow

Date : 2026-09-03. Branche : `feat/text-quality-v3`.
Point de départ : `b27f0c97edf9e6c47be9790158692710f4f7f79d`.

## Sauvegarde du worktree reçu

Le worktree était déjà modifié. Aucun reset, clean ou checkout destructif n'a été exécuté.

- sauvegarde : `/Users/aris/Documents/Zphyr-backups/2026-09-03-text-quality-v3-b27f0c9` ;
- patch binaire suivi, SHA-256 :
  `8d4764c26f64ec98ec69a0e7bba5ae1627981c022351460177a743a31a5afc91` ;
- archive des fichiers non suivis, SHA-256 :
  `4565da458dd95dac947d1587ceb2a64eb31677102adb900608d7eeae23efcf69`.

Le baseline avant modification passait `./Scripts/verify.sh --fast` : 281 tests Swift, dont 3
ignorés faute de runtime embarqué, et 16 tests Python, sans échec.

## Modèles figés

- Qwen 3.5 0.8B 4-bit pristine, révision `2fc06364715b967f1860aea9cf38778875588b17`,
  poids `f5a0d9dd3efa73510542a8023d610ff26be2b4b020d181cfc4bedaa1fcc5dd9e` ;
- adapter local historique actif,
  `9df7372a3560ddd0f13cf48cf7126aab763eee3db097cdc9994b54c53cbe3185`, non reproductible et
  interdit comme parent d'entraînement ;
- Parakeet TDT 0.6B v3, révision `7c35754d166cca382ad1e53e68b01e7c575f3a1d` : joint
  `d83381f8a19ac296033554a7cfec355063b8f3225129cb8bed013c92f6ab141f`, encodeur
  `b4ccde8e539505854af887c0d21bbb1048197847ab7ae77533054ade8d9f0ad2`, décodeur
  `36cd656ebf1105ee5aa85d1e55c00f25669327aef8b39346333a19260ca78018`, tokenizer
  `bd321b096832a3f270bd3b2a88823957920f1a5c5ada71114a26ea729d0cbe91`.

La mesure diagnostique héritée reste 172 sorties acceptées sur 184, sans valeur de promotion : le
corpus ne contient que 92 sources indépendantes et ses cibles sont AI-labeled. Les latences produit
doivent être mesurées sur machine stable, hors compilation concurrente ; cet incrément ne les
réinterprète pas comme une promesse.

## Ce qui est implémenté

Les cinq flags sont lus depuis `UserDefaults` et valent `false` en leur absence :

```text
voxol.textQualityV3Shadow
voxol.editGateV3
voxol.codeDictationV1
voxol.qwenPatchMode
voxol.selectiveASRRescue
```

Parakeet transporte maintenant, par mot, offsets UTF-16, tokens, frames, marges minimale/moyenne,
activation du biais et proximité des frontières de chunks. La préparation déterministe et le
découpage ré-alignent ces preuves ; Apple Speech fournit explicitement une confiance inconnue.
`Scripts/calibrate-asr-word-risk.py` produit une calibration isotone à partir de mots réellement
revus (`minimum_margin` numérique et `correct` booléen dans un JSONL), mais aucune table inventée
n'est livrée. La table produite est chargée depuis `word-risk-calibration.json` à la racine du
modèle ASR lorsqu'elle existe ; sans elle, le risque calibré reste inconnu.

Le validateur v3 shadow analyse les faits canoniques, les invariants propositionnels et un script
d'éditions, puis restaure localement les clauses dangereuses. V2 et v3 reçoivent la même génération
Qwen ; v2 reste l'unique autorité sur le texte visible. Les métriques séparent copie, modèle non
prêt, timeout, erreur, rejet, récupération partielle et sortie utilisée. Le Pipeline Inspector peut
relier ASR, candidat Qwen, verdicts v2/v3, texte final et correction utilisateur avec le même UUID,
uniquement hors mode privé.

## Hors périmètre de cet incrément

Aucun LoRA n'est entraîné, aucune réparation phonétique n'est promue, aucun embedding n'est ajouté,
et aucun des flags expérimentaux n'est activé par défaut. Les phases ultérieures exigent un vrai jeu
d'or audio disjoint et leurs gates de promotion propres.

## Audit personnel et collecte Gemini par lots — 4 septembre 2026

L'inventaire personnel contient 149 sessions pour 43,53 minutes. Le run incrémental étudié ici
fige les 114 sessions les plus récentes, soit 31,87 minutes. Qwen est sollicité sur 113 cas, mais le
rejeu produit seulement 22 changements visibles : 76 copies, 15 sorties modèle, 6 récupérations
partielles, 16 rejets du validateur et un fast path. Ce résultat confirme que le problème observé
n'est pas une absence d'appel de Qwen : le modèle copie souvent l'entrée ou propose des éditions
qui perdent du contenu, des négations, des questions ou des termes protégés.

Le premier transport multi-fichiers a produit des associations audio/ID incorrectes, malgré la
présence de tous les IDs attendus. Ses 61 résultats et le débit annoncé de 3,55 secondes par élément
sont invalidés ; une copie privée `gemini-predictions.tainted-batch-v1.jsonl` reste disponible pour
l'audit. Deux anciennes réponses demandant de joindre un audio ont également été écartées puis régénérées.

Le transport corrigé utilise quatre fichiers par défaut, une ouverture séquentielle des pièces
jointes et un appariement bijectif avec les transcriptions Parakeet. Chaque paire doit avoir une
similarité d'au moins 0,60 et une marge de 0,10 sur les autres audios ; un lot ambigu ou incomplet est
divisé récursivement. Les IDs déclarés et réattribués, les scores et le SHA-256 de l'audio sont
conservés. Sans références d'alignement, chaque audio est envoyé dans un message distinct du même
chat. Les erreurs persistantes sont consignées dans `.failures.jsonl` et ne bloquent plus les
fichiers suivants ; `--retry-failures` permet de les retenter explicitement.

Cet appariement est heuristique et dépend de Parakeet : il sert à la collecte silver, pas à un
classement indépendant de Gemini. L'application gérait Flash 3.8 lors de l'inspection du
4 septembre ; le raisonnement étendu était encore actif et a été désactivé. Le pont échoue désormais
explicitement si cette désactivation ne réussit pas. L'ancien nom 3.7 n'identifie donc pas de façon
fiable le modèle servi. Gemini reste hors du runtime produit.

Lors de la première passe, Gemini, Wispr et Parakeet ont été comparés élément par élément. Trente-huit références ont
pu être corrigées par contexte avec trois couches séparées (`verbatim`, `faithful`, `rewrite`) et
appliquées aux sessions ; elles portent toutes le niveau `agent-context-adjudicated` et
`human_reviewed: false`. Les 76 divergences restantes restent en quarantaine. Le benchmark filtré
se trouve sous
`~/Library/Application Support/VoxoL/PersonalBenchmark/head-to-head/20260903-new114-v3-audit/adjudicated-benchmarks/c02cbc99e8b6`.
Ce répertoire est un résultat historique antérieur à la réparation des associations Gemini.
Il ne doit plus être utilisé comme comparaison courante. Les cibles restent silver, jamais un gate
de promotion. La version `agent-context-decisions-v2-20260904.jsonl` corrige douze réécritures qui
avaient perdu des détails, renforcé une modalité ou traduit des termes anglais.

Une corruption indépendante a aussi été reproduite sur une dictée comportant plus de dix spans
protégés : `VOXOLP1` était restauré avant `VOXOLP10`, ce qui transformait ce dernier en texte comme
`pas0`. Les placeholders sont désormais restaurés par longueur décroissante. Le rejeu des 114 cas
ne contient plus aucun fragment `pas` suivi d'un chiffre et ne transforme aucune question finale en
affirmation.

Le benchmark public ServiceNow FR/EN a enfin été ajouté pour mesurer les vrais changements de
langue. Le run local atteint 9,79 % de WER micro sur 486 clips ; le détail et la comparaison avec les
résultats publiés sont dans `Docs/servicenow-code-switch-results-2026-09-03.md`.

Le prochain entraînement massif Qwen reste volontairement bloqué sur
`voxol-qwen-human-gate-v2` : les références silver produites ici ne doivent pas être transformées
en faux gold. La campagne pourra être préparée lorsque le SSD externe contenant les données sera
remonté, puis exécutée sur RunPod après une vraie revue humaine du volume requis.

Le rejeu Qwen historique limité aux 38 premières cibles `rewrite` contextuellement tranchées montre la faiblesse de
l'adapter actuel : 38 appels demandés, 24 copies à l'identique, 8 sorties modèle, 2 récupérations
partielles et 4 rejets. Dix textes changent visiblement, mais aucun ne réduit de plus d'un point la
distance lexicale à la cible et aucun n'est un exact match. Cette mesure reste silver, mais elle est
cohérente avec le comportement produit observé et justifie un nouvel entraînement plutôt qu'un
assouplissement du validateur. Les distances aux cibles doivent être recalculées après toute révision
des références ; les copies et sorties du modèle restent observables indépendamment des cibles.

## Vérification finale

### État consolidé après réparation Gemini — 4 septembre 2026

La collecte contient maintenant **113 transcriptions sur 114**, toutes associées au SHA-256 exact
de leur audio, sans réponse de type « veuillez joindre un fichier ». Répartition : 51 captures
individuelles historiques, 60 captures par lots alignés v3 et 2 captures individuelles en session.
L'enregistrement de 1,207 seconde `20260903-002142-4eed2c85` reste explicitement en échec après trois
tentatives ; aucune transcription Gemini n'est inventée pour compléter le compteur.

La troisième passe applique **78 références silver** : 62 adjudications contextuelles (dont
24 nouvelles) et 16 accords entre enseignants. Huit éléments nécessitent encore une revue de
contexte et 28 restent en quarantaine. Aucune référence n'est déclarée relue humainement ; le
`verbatim` proposé reste lui aussi une référence textuelle inférée, pas une écoute certifiée.

Les artefacts courants sont privés, sous
`~/Library/Application Support/VoxoL/PersonalBenchmark/` :

- `head-to-head/20260903-new114-v3-audit/adjudication-aligned-v3/` : décisions et statut ;
- `head-to-head/20260903-new114-v3-audit/adjudicated-benchmarks/f5638df872a2/` : comparaison
  recalculée sur les 78 références (manifest gelé `1d6f2307ee8074ddc44552ccc7d7181a9517f415842a5293811085028899d6a3`) ;
- `audits/20260904-aligned-v3-final/` : audit Qwen et file de relecture actualisés.

La comparaison privée reste dépendante des enseignants, dont Parakeet pour l'alignement Gemini :
elle ne constitue pas un classement public indépendant. Le WER final mesure une distance à des
cibles nettoyées et ne doit pas être interprété comme le taux d'erreur de transcription verbatim.

L'audit réutilise les sorties Qwen déjà enregistrées, sans nouvelle mesure de latence. Sur les
78 cibles `rewrite` silver actuelles, la distance lexicale normalisée est neutre dans 77 cas,
dégradée dans un cas et améliorée dans aucun cas (seuil de variation : 0,01) ; sept sorties
correspondent exactement à la cible après normalisation. Cela décrit la proximité textuelle,
pas une validation sémantique humaine. Sur les 114 sorties, 21 utilisent Qwen entièrement ou en
partie ; le compteur de 22 différences littérales inclut aussi des modifications déterministes.

Le pont ne réactive plus l'application initiale à chaque boucle lorsque Gemini n'est pas actif.
Le correctif est compilé et signé ; une absence absolue de flash au premier plan n'est pas garantie
par cette automatisation Accessibility. Le modèle Flash est géré par l'application, donc non figé.

Vérification de cette continuation : 32 tests Python dans `Scripts`, 11 dans `Tools/benchmarks`,
15 dans `stt-factory`, tous réussis ; pont reconstruit et signature stricte validée. Aucun code Swift
du runtime VoxoL n'a changé pendant cette réparation ; les vérifications complètes ci-dessous
proviennent de la passe précédente. Le SSD `/Volumes/0_Oueillez` est toujours absent, aucun
entraînement RunPod ni changement de modèle produit n'a été lancé.

### Vérifications de la passe runtime précédente

- `./Scripts/verify.sh --fast` : 299 tests Swift exécutés, 3 ignorés, 0 échec ; 33 tests Python,
  0 échec.
- `./Scripts/verify.sh` : mêmes tests, build Debug signé, localisations, signature et smoke checks
  validés.
- `stt-factory` : 15 tests Python, reconstruction et signature de
  `dist/Gemini Transcriber.app`, 0 échec.
- audit du corpus régénéré à l'identique :
  `d71bfd1b06ec03cf0a7445dd41c784be69cbd834343237fedef19615eae986f0`.

## Continuation du 6 septembre 2026

L'inventaire atteint 165 sessions. Les 16 nouvelles captures (6,15 minutes) ont été relues
localement, sans réveiller Gemini ni relancer les modèles : dix références contextuelles
supplémentaires sont appliquées et six cas ambigus restent en quarantaine. Les deux lots récents
contiennent donc 88 références silver acceptées sur 130 audios ; cela n'est ni un score qualité
ni un nombre de validations humaines. Les autres sessions ne sont pas réévaluées dans ce total.

Les données de cette passe sont conservées sous
`~/Library/Application Support/VoxoL/PersonalBenchmark/head-to-head/20260906-new16-context-review/` :
snapshot des textes avant application, décisions, six motifs précis de relecture dans
`RELECTURE.md`, et notebook de contrôle `provenance-check.ipynb`. Les hashes des anciens artefacts
du lot de 114 sont inchangés. Aucune nouvelle mesure Qwen, Gemini ou de code-switch n'est revendiquée.

Le raccord préparation/entraînement a été corrigé : la préparation écrivait encore un gate v1
alors que le lanceur exigeait v2. Les deux passent désormais par `build-qwen-human-gate.py`, avec
contrôle de provenance humaine, déduplication des entrées, séparation des splits et vérification
des hashes des sept fichiers d'entrée. Le détail du contrat est dans `Docs/dataset-policy.md`.
Un ancien statut `not-trained` ne bloque plus indéfiniment une reprise devenue admissible.

Vérification : 299 tests Swift, dont 3 ignorés, lors de `verify.sh --fast` ; après le dernier
ajout Python, 40 tests Scripts et 11 tests benchmarks réussissent. Les deux scripts shell passent
`bash -n` et le diff passe les contrôles d'espaces. Le gate positif est testé sur des fixtures,
pas sur la campagne externe absente. Aucun entraînement, téléchargement de modèle ou changement
d'adapter n'a été effectué ; `/Volumes/0_Oueillez` reste non monté.
