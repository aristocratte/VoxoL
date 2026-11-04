# Correction du texte : campagne autonome du 7 septembre 2026

La campagne fournit un corpus synthétique figé, un lanceur reproductible et deux corrections ciblées du validateur. Sur les 48 phrases de contrôle, le résultat final atteint **39 références sur 48, contre 38 avant**. Les 10 témoins de préservation restent inchangés. Le gain est réel sur ce petit jeu, mais ne résout pas toutes les fautes grammaticales.

L'utilisateur a autorisé la création et l'évaluation de données par IA sans relecture personnelle. Les références sont donc utilisables pour cette campagne avec leur provenance synthétique explicite. Aucun exemple n'est présenté comme relu par un humain.

## Données et protocole

Le [corpus](../Data/corpus/text-quality-synthetic-v1/README.md) contient 96 paires, 68 marquées français et 28 anglais, toutes en mode `faithful`, profil `document`. Il couvre accords, conjugaison, orthographe, ambiguïtés, faits, négations, texte technique, autocorrections et mélange de langues. Il comporte 20 témoins à préserver.

Les 48 phrases de développement ont servi aux diagnostics et à la sélection. Les 48 phrases de contrôle ont été figées avant examen des prédictions. Les phrases et groupes sont distincts ; certaines structures grammaticales sont partagées. La version a été sélectionnée avant le contrôle, puis exécutée une fois avant/après sur celui-ci. Aucune référence ni correction de production n'a été ajustée après lecture des sorties de contrôle.

L'évaluation traverse le processeur utilisé par l'application, avec son modèle, ses limites de génération, sa validation et son repli déterministe. Le score utilise exclusivement `finalText`. Les sorties des candidats ne sont jamais substituées au texte effectivement retenu pour améliorer un score. Les échecs restent dans le dénominateur.

Deux scores sont conservés : égalité stricte et correspondance lexicale. Le second ignore casse, ponctuation et forme droite/courbe de l'apostrophe, mais conserve les accents. Une correspondance propre exige aussi l'absence de Markdown supplémentaire et l'égalité littérale des chiffres et fragments de code. Cette dernière vérification ne prouve pas la conservation du sens.

## Comparaisons de modèles et de consignes

Cinq modèles locaux déjà disponibles ont été examinés sur les 26 anciennes régressions. Les correspondances lexicales sont : modèle installé 15/26, LFM 16/26, Qwen3-1.7B 14/26, Granite 15/26 et Qwen3.5-2B 16/26. Parmi ces dernières, six contiennent des italiques non demandées : elles ne sont donc pas des correspondances propres. Ces exemples connus ne constituent pas un test indépendant.

Les candidats utiles ont ensuite été examinés sur le développement figé :

| Configuration | Références propres / 48 | Témoins modifiés / 10 | Appels échoués |
| --- | ---: | ---: | ---: |
| Qwen installé avec adaptateur, consigne actuelle | 34 | 0 | 1 |
| Même Qwen sans adaptateur | 38 | 0 | 1 |
| LFM2.5-1.2B sans adaptateur | 37 | 0 | 2 |
| Qwen avec adaptateur, consigne grammaticale expérimentale | 34 | 0 | 1 |
| Qwen sans adaptateur, consigne grammaticale expérimentale | 36 | 1 | 1 |
| LFM, consigne grammaticale expérimentale | 32 | 0 | 23 |

Le score supérieur du Qwen sans adaptateur ne suffit pas pour le sélectionner. Il a transformé « 3 commit » en « le commit 3 », ce que le validateur acceptait alors. Sur les anciennes régressions, il provoquait aussi davantage de rejets complets : 8 contre 2. La consigne grammaticale a changé à tort « tache sur le mur » en « tâche sur le mur ». Les sorties montrent donc des compromis, sans vainqueur assez fiable pour remplacer le modèle actif dans cette passe.

La consigne expérimentale reste accessible uniquement par configuration explicite (`--prompt-style grammar-v1`) pour reproduire les essais. La configuration par défaut, le modèle et l'adaptateur restent identiques. Aucun entraînement n'a été lancé : ce nouveau lot sert à l'évaluation, et l'utiliser aussi pour entraîner invaliderait cette mesure.

## Corrections retenues

1. **Accord d'un verbe modal avec son sujet.** Le validateur autorise maintenant une liste bornée de corrections de présent, à la même position et avec le même sujet : « tu peut → tu peux », « tu doit → tu dois », « elle peux → elle peut ». La substitution « dois → peux » reste refusée. Il s'agit d'accepter une correction proposée par le modèle, pas d'inventer une reformulation.
2. **Rattachement local d'un nombre.** Un nom voisin ne peut plus traverser son nombre protégé pour transformer une quantité en identifiant, ou l'inverse : « 3 commits → commit 3 » et « ticket 7 → 7 tickets » sont refusés. Le pluriel « 3 commit → 3 commits » reste accepté. La réparation par phrase conserve une bonne correction ailleurs tout en restaurant la phrase fautive.

Ce contrôle numérique est local. Il ne garantit pas l'équivalence de propositions complexes, les relations entre plusieurs noms ou tous les déplacements de nombres. Les nouveaux tests encadrent précisément la correction et ses contre-exemples.

## Résultat de la version sélectionnée

| Mesure du texte final | Avant | Après |
| --- | ---: | ---: |
| Développement : référence propre | 34/48 | 35/48 |
| Développement : référence stricte | 30/48 | 31/48 |
| Contrôle : référence propre | 38/48 | 39/48 |
| Contrôle : référence stricte | 34/48 | 35/48 |
| Contrôle : témoins modifiés | 0/10 | 0/10 |
| Contrôle : différence littérale de chiffres/code | 0/48 | 0/48 |
| Contrôle : appels échoués, avec repli conservé | 1/48 | 1/48 |

Sur le contrôle, tous les candidats générés sont identiques entre avant et après. Le seul changement de résultat final est l'acceptation correcte de « Tu dois confirmer ta présence. », auparavant remplacée par le repli « Tu doit confirmer ta présence. ». Le gain vient donc bien du validateur. Le défaut de rattachement numérique est vérifié par les tests ciblés, sans prétendre qu'il s'est produit dans cette comparaison de contrôle.

La médiane mesurée sur le contrôle passe de 136,5 à 226,5 ms. La différence se situe dans la génération ; la médiane du reste du processeur est arrondie à 0 ms dans les deux exécutions. L'application installée était active, avec une charge CPU observée, pendant cette fenêtre de travail. Les conditions ne permettent pas d'attribuer cette variation au changement ni de revendiquer une amélioration de vitesse. Ce runner exclut aussi l'ASR et l'insertion finale.

Les erreurs restantes comprennent des accords incomplets, des homophones et des fautes copiées par Qwen. Le corpus étant synthétique, court et créé par la même IA que les changements, ces scores ne mesurent pas une qualité générale de dictée. Les 48 phrases de contrôle sont désormais connues : elles peuvent servir aux régressions, mais une prochaine sélection demandera un autre contrôle figé.

## Vérification et artefacts

- `Scripts/verify.sh --fast` passe : politique du dépôt, notebooks/lanceurs, formatage, **338 tests Swift et 63 tests Python**.
- Le build Release de développement réussit.
- Les **26 anciennes régressions et les 30 cas de formatage** produisent exactement les mêmes sorties finales qu'avant cette correction.
- Le lanceur vérifie les empreintes du corpus et enregistre celles de l'exécutable, des poids et de l'adaptateur. Le scoreur refuse les cas manquants, dupliqués, les références modifiées et les durées invalides.

Entrées utiles : [lanceur](../Scripts/run-text-quality-benchmark.py), [scoreur](../Scripts/score-text-quality-suite.py), [sélection figée](../outputs/text-quality-autonomous-2026-09-07/selection-before-holdout.json), [contrôle avant](../outputs/text-quality-autonomous-2026-09-07/baseline-holdout/score.json), [contrôle après](../outputs/text-quality-autonomous-2026-09-07/patched-holdout/score.json), [ensemble des résultats](../outputs/text-quality-autonomous-2026-09-07/summary.json).

Le binaire de référence est conservé sur le SSD dans `VoxoL-Storage/2026-09-07/text-quality-autonomous/baseline.app`, avec vérification SHA-256 de tous les fichiers. Les petits corpus et scripts restent dans le dépôt. L'application installée n'a pas été remplacée et aucune nouvelle version n'a été publiée pour cette campagne.
