# VoxoL — clôture du cycle d’optimisation

Le **27 septembre 2026**, ce cycle de recherche sur l’inférence est clos à la demande d’Aris. Les améliorations retenues restent dans les sources. Les variantes sans gain fiable ou sans parité sont écartées. Aucune nouvelle campagne, modification de poids ou expérimentation n’est prévue dans ce cycle.

Cette clôture concerne l’optimisation. La validation du produit avant publication reste distincte : elle comprend encore la qualité sur des enregistrements naturels, la dictée au microphone, l’insertion et le nouveau document Réunion.

## Ce qui est conservé

| Partie | Choix retenu | Conséquence |
| --- | --- | --- |
| Parakeet | Modèles de référence conservés ; réutilisation des sorties du décodeur pour une seule fenêtre, calcul vectorisé du meilleur token et raccourci exact pour certains biais | Moins de calcul et d’allocations dans les cas mesurés, avec parité des sorties et des preuves |
| Prévisualisation | Calculs de confiance et tentatives supplémentaires réservés au résultat final | Travail évité pendant la parole ; le résultat final garde ses contrôles |
| Fichiers longs | Audio temporaire mappé en lecture seule, fenêtres matérialisées à la demande, durée acceptée jusqu’à 2 h | La mémoire audio n’augmente plus comme une copie complète de toutes les fenêtres |
| Dictée Qwen | Préremplissage 512, cache réutilisable 64 Mio, cache de préfixe et fusion de l’adaptateur conservés | Configuration interactive inchangée ; décodage expérimental désactivé |
| Compte rendu Qwen | Préréglage partagé `meetingReport`, préremplissage 128, sans adaptateur de dictée | Réduction mémoire mesurée sur le compte rendu de référence ; les deux constructions du runtime Réunion utilisent ce préréglage |
| Décisions, actions et questions | Préfiltre partagé, résolution locale des cas explicites, cas ambigus laissés à Qwen | Les expressions comme « l’avatar en question » évitent des appels inutiles ; « je vais comprendre » ne devient pas une tâche et ne masque pas un engagement distinct |

Les variantes de fenêtres encodeur 20/25 s, nouveaux exports FP16/INT8, décodeur GPU/fusion et encodeurs parallèles restent fermées. Un résultat rapide avec des sorties divergentes ne suffit pas à les retenir.

## Gains effectivement mesurés

Ces chiffres viennent des campagnes du 24–25 septembre. Ils décrivent leurs entrées et leurs conditions ; ils ne sont pas des garanties pour tous les utilisateurs.

| Changement | Observation | Limite |
| --- | --- | --- |
| Sorties du décodeur réutilisées, une fenêtre | ASR médian sans cache : 156,32 → 147,56 ms ; avec cache : 61,73 → 51,94 ms | 384 observations sur six sources ; aucune divergence détectée. Ce temps exclut Qwen et l’insertion |
| Fenêtres audio à la demande | Pic mémoire −5,08 %, soit 22,07 Mio économisés | Fichier de 278,696 s ; texte et confiance identiques ; aucun gain de vitesse revendiqué |
| Audio mappé après cette optimisation | Pic mémoire −4,28 %, soit 18,19 Mio économisés | Comparaison distincte, deux passages par condition ; ne pas additionner les pourcentages ni généraliser la vitesse observée |
| Préremplissage du compte rendu 128 au lieu de 512 | Pic processus 4,29 → 3,28 Gio, soit −23,55 % ; pic MLX −24,27 % | Même sortie sur quatre passages A/B/B/A. Temps médian 17,735 → 18,180 s : compromis mémoire, pas accélération |
| Préfiltre du compte rendu de référence | 29 → 2 candidats, 27 → 0 cas non résolus et aucun appel Qwen de classification | Résultat limité à la fixture de diagnostic répétée |

Sur cette fixture de **2 h construite en répétant un audio réel**, la transcription a terminé en **143,86 s** avec un pic d’environ **395,5 Mio**. La transcription avec diarisation et attribution a terminé en **201,48 s** avec un pic d’environ **405,9 Mio**. Ce sont des mesures de capacité technique, issues d’un passage par route. Elles ne prouvent ni la qualité d’une réunion naturelle de deux heures ni le temps total du produit avec son nouveau compte rendu.

## Marges d’amélioration probables

Les appréciations suivantes sont des hypothèses fondées sur les mesures, pas des gains acquis. Aucun pourcentage supplémentaire n’est annoncé.

| Marge | Pourquoi elle semble utile | Décision simple |
| --- | --- | --- |
| **Compte rendu : potentiel notable sur le temps de rédaction** | Dans la trace de référence, la génération des tokens prend environ 11 s, contre 4–5 s pour le prompt. Le nouveau document produit davantage de contenu | À mesurer sur le nouveau format. Réutiliser les sections déjà valides et éviter les régénérations inutiles sont des pistes ; réduire le contenu ne convient que si le document reste suffisamment complet |
| **Dictée : potentiel sur la régularité** | Des premières requêtes et des cas lents dépassent encore l’objectif malgré de bons résultats chauds | Examiner le chargement, les caches et l’attente en fin de parole sur microphone réel. La cible de moins d’une seconde reste à démontrer de bout en bout |
| **Import long : potentiel sur les erreurs coûteuses** | La mémoire est déjà bornée, mais les essais de 2 h n’ont pas déclenché le pire cas de nouvelle tentative ASR | Mesurer une reprise réelle avant de changer la politique. Préserver la récupération et l’intégralité du texte |
| **Qualité FR/EN : bénéfice probable, ampleur inconnue** | Les diagnostics répétés ne représentent pas les accents, noms, bruits et conversations naturelles | Qualifier des exemples humains indépendants avant de décider d’un entraînement ou d’un changement de modèle |
| **Nouveaux exports et micro-optimisations : faible priorité** | Plusieurs variantes ont échoué à la parité ou n’ont pas donné de gain reproductible | Ne pas rouvrir ces pistes sans un défaut observé et une nouvelle hypothèse précise |

Ces marges sont réservées à un éventuel nouveau cycle décidé séparément. Elles ne constituent pas une liste de travaux à poursuivre automatiquement après cette clôture.

## Portée de la vérification finale

Les résultats et empreintes de ce lot sont consignés dans le [reçu de clôture](../outputs/inference-closure-20260927/summary.json). Les tests ciblés couvrent le décodeur, les configurations Qwen, les fichiers longs, la sélection des sources et les garde-fous des décisions/actions/questions. Le contrôle local du compte rendu utilise le modèle présent et les fonctions Swift de sélection et de validation.

Le lot compte **139 tests ciblés réussis** : 76 ParakeetCore, 24 QwenPolisher et 39 SpeakerKit/MeetingMedia. L’outil d’inférence est compilé en Release. Le contrôle final du modèle porte sur **4 639 fragments**, dont **58 passages sélectionnés** et **2 candidats DAQ résolus localement**. Il a produit deux paragraphes de 1 148 caractères au total en **25,48 s**, avec un pic processus d’environ **3,28 Gio**. Un seul passage, avec un prompt différent de la comparaison du 25 septembre : aucune nouvelle accélération n’en est déduite.

Le modèle a d’abord écrit des références `E2` plutôt que l’entier `2`. Cette représentation équivalente était rejetée. Le parseur accepte désormais les étiquettes canoniques `E` + entier et applique ensuite les mêmes limites, contrôles de sources, de nombres et de décisions. La **même sortie**, conservée sans régénération, passe la validation corrigée. Les références inconnues, dupliquées, négatives ou malformées restent rejetées. Cette validation mécanique n’établit pas à elle seule la vérité de chaque reformulation.

**Évolution parallèle du produit.** Le chat « Optimiser mode réunion VoxoL » met en place un document thématique et un éditeur. Son format utilise des budgets de prompt et de sortie différents du compte rendu court de référence. Le préréglage mémoire 128 y est conservé, mais les durées, le nombre d’appels et la couverture du compte rendu court ne qualifient pas cette nouvelle rédaction. Le contrôle local de référence reste un contrôle du modèle et du parseur, pas une validation de la nouvelle interface.

Le contrôle global `Scripts/verify.sh --fast` s’arrête sur des artefacts de modèles historiques détectés par la règle du dépôt, avant ses étapes de formatage et de tests. Le détail est conservé dans le reçu. Les vérifications ciblées ne remplacent pas ce contrôle global.

Les jalons de publication **A/B/C restent non qualifiés**. La clôture ne déclare pas la cible interactive atteinte, ne qualifie pas la réécriture sur un corpus humain et ne remplace pas les essais de l’application. La cible d’une seconde ne s’applique pas aux fichiers importés, conformément à la décision utilisateur.

## Sources

- [Sorties du décodeur et parité](../outputs/inference-opt-20260924-output-backings-single-chunk-final8/summary.json).
- [Fenêtres à la demande](../outputs/inference-opt-20260925-lazy-segmentation-long-file/summary.json) et [audio mappé](../outputs/inference-opt-20260925-mapped-pcm-long-file/summary.json).
- [Transcription de 2 h](../outputs/inference-opt-20260925-long-import-2h/summary.json) et [diarisation de 2 h](../outputs/inference-opt-20260925-long-meeting-2h/summary.json).
- [Compte rendu de référence, filtrage et comparaison mémoire](../outputs/inference-opt-20260925-long-report-2h/summary.json).
- [Plan produit et historique](../outputs/end-to-end-research-2026-09-17/PLAN.md) et [refonte Réunion](meetings/refonte-produit-2026-09-27.md).
