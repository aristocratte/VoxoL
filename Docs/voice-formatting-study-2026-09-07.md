# VoxoL : dictée naturelle, formatage et prochaine campagne de mesure

État du 7 septembre 2026. Recherche documentaire auprès des éditeurs et mesures locales sur le Mac de développement. Les fonctions de cette passe sont dans le projet et un build Release de développement ; aucune nouvelle release n'a été publiée pour ces changements.

Mise à jour : l'utilisateur a ensuite autorisé la création de données par IA sans relecture personnelle. Une [campagne autonome de correction](text-quality-results-2026-09-07.md) a été réalisée avec 96 paires synthétiques, comparaison de modèles et corrections ciblées du validateur. Les propositions de campagne ci-dessous décrivent l'état antérieur ; une relecture humaine n'est pas une condition pour utiliser le nouveau corpus synthétique d'évaluation.

## Le problème observé

Les deux captures personnelles `20260907-134549-e0bfda6b` et `20260907-134634-e2cd6e60` permettent de comparer le texte ASR et le texte livré. Beaucoup d'erreurs restent identiques entre les deux étapes ; la première capture contient même le passage de « un point » à « un. Point ». Cela démontre un défaut de résultat final, mais les anciennes métadonnées ne permettent pas d'attribuer chaque défaut à Qwen, à son validateur ou à une sortie de secours.

L'utilisateur a confirmé que « tapus » correspondait à « liste à puces ». Cette confirmation est conservée comme correction d'un terme, avec l'empreinte de l'audio, dans [user-confirmed-term.json](../outputs/spoken-formatting-2026-09-07/user-confirmed-term.json). Elle ne constitue pas une transcription humaine complète de l'enregistrement. Le programme n'applique pas un remplacement global de « tapus » : une correction contextuelle doit rester liée à son contexte et à l'audio.

Trois chantiers se distinguent : retrouver les mots entendus, interpréter les intentions de correction et de mise en forme, puis insérer le bon résultat dans l'application cible. Un score de reconnaissance brut ne suffit pas à évaluer les deux dernières étapes.

## Ce que proposent les outils comparables

| Outil | Fonctions décrites par son éditeur | Conséquence pour VoxoL |
| --- | --- | --- |
| Wispr Flow | Utilise le texte près du curseur et l'application pour adapter vocabulaire, style et format. Son Command Mode possède un raccourci distinct et nécessite un forfait payant. | Évaluer séparément dictée et commande, puis tester le même texte dans plusieurs destinations. Sources : [contexte](https://docs.wisprflow.ai/articles/4678293671-Context-Awareness), [Command Mode](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode). |
| Superwhisper | Super Mode exploite application, sélection et presse-papiers, et propose des transformations du texte sélectionné. Sa documentation reconnaît les limites des modèles locaux moins capables sur les demandes nuancées. | Mesurer l'apport réel du contexte, et le taux de corrections nuisibles, au lieu de seulement augmenter la taille du modèle. Source : [Super Mode](https://superwhisper.com/docs/modes/super). |
| Aqua Voice | Présente Avalon, le contexte d'écran et la correction/présentation selon l'application comme un produit intégré. Sa FAQ précise que l'audio est traité dans le cloud. | Comparer le résultat réellement inséré ; garder le fonctionnement local comme contrainte du produit VoxoL. Source : [FAQ Aqua Voice](https://aquavoice.com/info/faq). |

Cette table compare des fonctions documentées, pas des performances mesurées. Aucun nouveau test Wispr, Aqua ou Superwhisper n'a été exécuté dans cette passe. Leurs résultats sur notre corpus restent non mesurés. Les scores de leurs pages commerciales ou de leurs propres corpus ne sont pas un classement de notre usage.

## Modèles ASR à comparer ensuite

| Modèle | Intérêt du candidat | Mesure nécessaire sur le Mac M4 |
| --- | --- | --- |
| Parakeet TDT 0.6B v3 | Modèle de 600 millions de paramètres, 25 langues européennes, architecture de transcription rapide. [Fiche NVIDIA](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3). | Référence de départ : versions/poids précis, transcription brute et pipeline VoxoL complet. |
| Qwen3-ASR 0.6B, puis 1.7B si utile | Reconnaissance multilingue avec inférence hors ligne et en flux. C'est une famille ASR distincte du Qwen correcteur de texte déjà utilisé par VoxoL. [Fiche Qwen](https://huggingface.co/Qwen/Qwen3-ASR-0.6B). | Erreurs sur noms et vocabulaire métier, dictée FR/EN mélangée, mémoire et latence avec un runtime Apple Silicon réellement disponible. |
| Whisper large-v3-turbo | Autre architecture de reconnaissance multilingue, utile comme comparaison indépendante. [Fiche OpenAI](https://huggingface.co/openai/whisper-large-v3-turbo). | Mêmes fichiers audio, même protocole ; inclure silences et bruit pour mesurer aussi les insertions indésirables. |

Priorité proposée : garder Parakeet comme référence, comparer Qwen3-ASR 0.6B et Whisper turbo sur les mêmes captures avant de décider d'un remplacement. Les débits publiés sur GPU serveur et lots parallèles ne prédisent pas l'attente après relâchement du raccourci sur ce Mac. Aucun nouveau modèle n'a été téléchargé ou entraîné ici.

## Changements implémentés

- Commandes FR/EN de point final, interrogation, exclamation, ligne et paragraphe ; formulations impératives telles que « ajoute un point d'interrogation », ainsi que virgule, deux-points et point-virgule explicites.
- Parenthèses avec marqueur d'ouverture et de fermeture ; gras avec « début du gras … fin du gras » ou « mets le mot urgent en gras » lorsqu'un seul mot cible existe dans la dictée courante. Un mot répété ou absent reste inchangé.
- Petit vocabulaire explicite d'emojis : cœur, pouce levé, sourire et clin d'œil. Les noms inconnus restent littéraux.
- Introduction de liste à puces avec marqueurs d'éléments : « Crée une liste à puces. Première puce acheter du pain. Nouvelle puce envoyer le rapport. » Les mentions ordinaires de puces ne déclenchent plus cette conversion.
- Corrections factuelles successives résolues dans l'ordre, par exemple « lundi, non, mardi, pardon, mercredi ». Les connecteurs « enfin », « plutôt » et « actually » ne déclenchent plus une suppression arbitraire de mots. Les citations et le code sont exclus de cette correction.
- Le collage propose texte brut, RTF et HTML échappé pour le gras. Les éditeurs de code identifiés et le profil développeur conservent le Markdown. Les contrôles qui acceptent seulement du texte brut reçoivent le texte lisible.
- Les nouvelles captures de diagnostic, uniquement quand la collecte existante est activée et le mode privé désactivé, enregistrent préparation, candidat Qwen, route, résultat de validation et profil. Les fichiers proposés pour relecture sont déclarés non revus par un humain.
- Les statistiques du runner incluent désormais les durées arrondies à zéro milliseconde. Les supprimer faussait les moyennes dès que certains cas évitaient Qwen.

Exemples de résultat :

| Dictée | Résultat |
| --- | --- |
| Tu viens demain point d'interrogation | Tu viens demain ? |
| Le rendez-vous ouvre la parenthèse mardi matin ferme la parenthèse est confirmé | Le rendez-vous (mardi matin) est confirmé |
| Le rapport est urgent. Mets le mot urgent en gras. | Le rapport est **urgent**. |
| Bonjour nouveau paragraphe merci | Deux paragraphes, « Bonjour » puis « Merci » |

Limites de cette première passe : les commandes reconnues utilisent une sortie déterministe, car le découpage actuel destiné à Qwen peut aplatir les retours à la ligne. Une longue dictée contenant ces commandes ne bénéficie donc pas encore de toute la correction grammaticale Qwen. Les commandes agissent sur la dictée en cours ; modifier un document ou une sélection déjà présents reste un chantier distinct. Les formulations libres, les listes sans séparateurs explicites et les remplacements de propositions complètes ne sont pas couverts de façon générale.

## Vérification et portée des chiffres

Le corpus [spoken-formatting-v1.json](../Tests/Performance/Fixtures/spoken-formatting-v1.json) contient 30 exemples synthétiques écrits pour ce comportement : 15 commandes de formatage et 15 cas de correction ou de préservation. Il est rejoué avec le même modèle/configuration de correcteur, d'abord dans le binaire de la release 0.1.5, puis dans le build courant, via le processeur de production.

| Mesure | Avant | Après |
| --- | ---: | ---: |
| Texte final strictement égal à l'attendu | 8/30 | 26/30 |
| Commandes de formatage strictement réussies | 0/15 | 15/15 |
| Préparation déterministe égale aux 30 attendus | 11/30 | 30/30 |

Les quatre écarts restants du texte final sont l'ajout d'un point ou la normalisation d'une apostrophe dans les exemples où Qwen reste utilisé. Ce score ne mesure ni l'ASR, ni une performance sur des dictées nouvelles, ni une supériorité sur un concurrent. Le temps mesuré par ce runner exclut reconnaissance audio et insertion ; un « 0 ms » signifie une durée sous la résolution de cette mesure, pas une dictée instantanée.

Les vérifications du dépôt passent : politique, génération des notebooks/lanceurs, formatage, 334 tests Swift et 56 tests Python. Neuf autres exemples ciblés vérifient notamment les excuses, les commandes citées et les listes à puces. Le collage RTF est testé dans un NSTextView natif et ses attributs gras sont contrôlés ; un [rendu natif](../outputs/spoken-formatting-2026-09-07/native-paste.png) a été inspecté. L'interopérabilité du collage dans Notes, Word, Notion et les différents navigateurs reste à vérifier application par application.

Les 26 cas préexistants des suites de grammaire, de français réel et de dictée longue ont également été rejoués avant/après : **26 sorties finales identiques**, avec 5/26 correspondances strictes aux anciens attendus de chaque côté. Ce faible nombre ne se résume pas à une ponctuation différente : « Les rapport sont prêts », « Le calandrier et pret » et « The reports is ready » montrent que la correction grammaticale reste insuffisante. Le formatage ajouté ne résout pas ce problème à lui seul.

Une comparaison supplémentaire sans l’adaptateur installé passe de 5/26 à 6/26 correspondances strictes, mais les rejets complets du validateur passent de **2/26 à 8/26**. Elle corrige « Les rapports sont prêts. », tout en dégradant d’autres résultats. Le modèle et l’adaptateur actifs ont donc été conservés. Ce résultat justifie un audit du correcteur et des motifs de rejet ; il ne justifie pas de désactiver les protections de fidélité.

Les rapports et les journaux reproductibles se trouvent dans [outputs/spoken-formatting-2026-09-07](../outputs/spoken-formatting-2026-09-07).

## Suite recommandée et critères de décision

1. **Constituer un vrai jeu de dictées naturelles relues.** Partir des erreurs personnelles existantes, avec audio, verbatim entendu, texte souhaité, intention de correction/formatage et application cible. Conserver l'empreinte audio et distinguer les propositions machine de la validation humaine. Le terme confirmé « liste à puces » est le premier diagnostic ciblé de cette passe.
2. **Mesurer chaque étage sur les mêmes enregistrements.** ASR brut, préparation, candidat Qwen, sortie validée, texte effectivement inséré. Mesurer WER/CER, conservation des noms/chiffres/négations, corrections nuisibles, commandes réussies et temps de retouche humaine. Ajouter l'attente après relâchement jusqu'à insertion (médiane et p95), ainsi que mémoire, démarrage à froid et silence/bruit.
3. **Tester le contexte et les autres ASR avec des comparaisons appariées.** Séparer l'effet du dictionnaire, du texte voisin et du moteur. Répartir les sessions et variantes d'un même audio dans un seul groupe pour éviter les fuites entre entraînement et évaluation. Garder aussi les échecs dans les scores.
4. **Apporter l'audio aux corrections incertaines.** Pour un mot comme « tapus », étudier une deuxième hypothèse acoustique ou un réexamen local ciblé, puis utiliser le contexte pour départager. Augmenter la liberté de Qwen sans information sonore peut produire une phrase plausible mais fausse.
5. **Entraîner seulement après ces mesures.** Les corpus générés ou historiques ne deviennent pas des références humaines par renommage. Maintenir les seuils existants avant promotion : 500 corrections humaines déclarées et 150 exemples de test distincts. Un premier test de formatage réussi ne remplit pas ces conditions.

## Stockage effectué

Le SSD utilisé est `/Volumes/0_Oueillez`, UUID `BBD52EFA-5A69-3470-A3BE-E8609E5A267A`. Destination : `VoxoL-Storage/2026-09-07`.

| Ensemble | Octets de fichiers transférés | Organisation |
| --- | ---: | --- |
| Benchmarks et modèles expérimentaux | 5 766 434 764 | Dossier SSD ; lien symbolique conservé à l'ancien emplacement local |
| Ancien `.build/ReleaseBuild` | 1 647 695 672 | Archive TAR vérifiée |
| Build de publication 0.1.5 | 2 380 741 843 | Archive TAR vérifiée |
| Total | **9 794 872 279** | **9,79 Go de fichiers déplacés** |

Chaque fichier ordinaire a été vérifié par SHA-256, ainsi que les cibles des liens des archives. Une nouvelle vérification de la source a précédé sa suppression. Les fichiers AppleDouble ajoutés par macOS sur ExFAT ont été identifiés séparément. Le [rapport de transfert](../outputs/spoken-formatting-2026-09-07/storage-report.json) et les manifestes présents sur le SSD permettent de retrouver les données.

Ce total décrit les fichiers déplacés, pas le gain net d'espace physique APFS après création du nouveau build. Les modèles actifs de dictée, les sources du projet et la capture personnelle active restent sur le Mac. Les benchmarks déplacés demandent le SSD monté ; le fonctionnement normal de la dictée continue à utiliser ses modèles internes.
