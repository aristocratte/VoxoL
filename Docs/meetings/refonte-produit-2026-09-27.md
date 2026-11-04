# VoxoL — Repenser le mode Réunion autour du document

Proposition du 27 septembre 2026, fondée sur le code local et la demande d’Aris. Ce document décrit la refonte à réaliser ; il ne constitue ni une implémentation ni une qualification du produit actuel.

## 1. Le résultat attendu

Ouvrir une réunion doit donner accès à un **vrai compte rendu que l’on peut lire, corriger et transmettre** : comprendre pourquoi la réunion a eu lieu, ce qui a été discuté, les raisons des choix et les suites effectivement convenues. Le document doit tenir debout sans obliger son lecteur à consulter la transcription.

La structure suit les sujets de la conversation. Une réunion technique, un entretien client et une réunion de suivi peuvent partager la même interface tout en produisant des documents très différents. Les paragraphes portent le raisonnement ; les listes servent les énumérations et les tâches ; les mises en valeur aident à repérer l’essentiel.

Le positionnement proposé : **un espace de réunion local, centré sur la qualité rédactionnelle, avec un accès simple aux échanges qui justifient le compte rendu**.

## 2. Diagnostic de l’existant

| Ce qui existe dans le code | Limite pour le résultat demandé | Conséquence pour la refonte |
|---|---|---|
| Accueil, historique, recherche, agenda EventKit, capture micro/son du Mac, import audio/vidéo | Le parcours rassemble déjà les fonctions principales, mais l’agenda reprend essentiellement le titre lors du démarrage | Conserver ces capacités et construire une relation durable événement → réunion → document |
| Brouillon Markdown avec rubriques prédéfinies | Le modèle de départ reste « Synthèse / Décisions et suites / Points à clarifier » | Produire un plan propre à chaque réunion ; supprimer les sections sans contenu |
| Rédaction Qwen locale en prose | Consigne de 1 à 3 paragraphes chronologiques, sans titres, listes ni Markdown | Définir un contrat de document avec sections thématiques et contenu structuré |
| Sélection globale de passages pour la prose | Maximum de 5 200 caractères et 64 fragments, puis 512 tokens de sortie, quelle que soit la richesse de la réunion | Dimensionner la rédaction selon les sujets et vérifier leur couverture ; ce plafond peut écarter du contexte utile |
| Lecture ligne par ligne et édition par `TextField` / `TextEditor` | On édite du Markdown ; ce n’est pas une expérience de traitement de texte | Introduire une vraie édition riche dans la page |
| Exports Word et Markdown | Word gère des titres et quelques styles ; les puces sont des caractères, sans couverture complète de la mise en forme | Unifier document, édition et exports autour du même contenu sémantique |
| Transcription horodatée et empreinte des sources | Les références existent, mais le document ne dispose pas d’un lecteur audio relié durablement à son fichier dans son modèle actuel | Ajouter une référence locale au média et une navigation précise vers les sources |

Ce constat porte sur les sources présentes. Les parcours de capture réels et la qualité de comptes rendus longs ne sont pas revalidés par cet audit.

Les références produit utiles sont la prise de notes reliée au calendrier et les citations consultables de [Notion AI Meeting Notes](https://www.notion.com/help/ai-meeting-notes), ainsi que les repères horodatés et la recherche dans les réunions de [tl;dv](https://tldv.io/timestamp-google-meet-calls/). La proposition ci-dessous adapte ces principes au fonctionnement local de VoxoL ; elle ne prétend pas être un audit exhaustif de ces produits.

## 3. Les trois écrans à concevoir

### A. L’accueil : préparer et retrouver

Une page calme avec deux zones : **À venir** et **Vos réunions**. Actions principales constantes : « Enregistrer » et « Importer ».

- Agenda en bandeau de semaine avec liste du jour sélectionné, calendrier source et accès au lien d’appel. Une réunion spontanée reste accessible sans connecter de calendrier.
- Association explicite d’un enregistrement ou d’un import à un événement. Conserver la date de réunion séparément de la date d’import et de génération ; permettre de la corriger.
- Historique sous forme de lignes lisibles : titre, date, durée, extrait court et état réel. Filtres sobres par période et état ; recherche dans le titre et le contenu. Favoris et projets pourront suivre.
- Distinguer « Prévue », « Enregistrement », « En traitement », « À relire », « Relue » et « Erreur ». « Relue » résulte d’une action humaine. Un événement passé ne devient pas automatiquement une réunion enregistrée.
- Connexion aux calendriers macOS existants en première version, sélection des calendriers affichés et état clair si l’accès est retiré. Google/Microsoft en connexion directe restent une extension ultérieure.

### B. Pendant la réunion : capturer sans distraire

Une vue compacte : titre, durée, source audio, niveau sonore, pause/reprise et arrêt. Vérifier que les deux sources sont actives pour un appel micro + son du Mac et signaler une interruption réelle. Les autorisations se demandent au moment où elles deviennent nécessaires.

Prévoir un espace facultatif de notes personnelles et un bouton **« Marquer ce moment »** : un repère temporel utile à retrouver ensuite. Les notes restent identifiées comme des ajouts de l’utilisateur ; elles ne deviennent pas des propos attribués aux participants.

Après l’arrêt, la page de réunion s’ouvre avec un état explicite : préparation de l’audio, transcription, attribution des voix, rédaction. Afficher les résultats déjà disponibles et permettre de revenir à l’historique. Une erreur de rédaction conserve l’audio et la transcription et propose de réessayer seulement cette étape.

Conserver le traitement audio seul des vidéos importées. Présenter honnêtement les limites du parcours choisi : l’interface de capture annonce actuellement une heure ; les travaux d’import long ne suffisent pas à qualifier une capture physique de deux heures.

### C. Le détail : un document au centre

```text
← Réunions       Revue du lancement mobile         Enregistré   Exporter
                 27 septembre · 42 min · 4 personnes

Sommaire                Compte rendu                         Sources [fermer]
                        Pourquoi cette réunion               Passage sélectionné
Contexte                Un texte de contexte rédigé…          Alice · 12:34
Parcours d’inscription                                        « … »
Périmètre retenu        Parcours d’inscription
Préparation du test     Paragraphes, sous-titres…              Lire l’extrait
                                                             Chercher dans les échanges
                        Une conclusion mise en évidence.

                        Prochaines étapes, si pertinentes
```

Schéma de disposition, avec contenu fictif. Le volet Sources est fermé par défaut. Sur une fenêtre étroite, le sommaire devient un menu et les sources un panneau temporaire.

- En-tête compact : titre éditable, informations de réunion, état de sauvegarde, versions et export. Les réglages de génération restent dans un menu secondaire.
- Sommaire construit depuis les titres réels du document ; clic pour rejoindre une section.
- Lecture et édition dans la même page. Sélectionner un passage fait apparaître les commandes de mise en forme ; cliquer dans le texte permet d’écrire directement.
- Une référence discrète ouvre le passage de transcription correspondant dans le volet latéral, sans perdre la position de lecture. Lecture audio si le fichier est disponible ; possibilité de le relier à nouveau s’il a été déplacé.
- Transcription complète et intervenants restent accessibles. Les personnes invitées au calendrier ne sont pas automatiquement considérées comme des voix identifiées.

Direction visuelle : reprendre les couleurs de VoxoL, une surface de document sobre, une largeur de lecture confortable, des titres nets et des espaces généreux. Éviter de transformer chaque paragraphe en carte. Un accent discret pour les commandes ; un surlignage doux pour les passages importants.

Animations courtes, environ 150–250 ms comme point de départ à ajuster : ouverture d’un volet, changement de réunion et transition entre étapes. Ne pas déplacer le texte sous le curseur pendant l’édition. Les blocs générés apparaissent une fois cohérents ; les pourcentages proviennent d’une progression mesurée. Respecter la réduction des animations, la navigation clavier, VoiceOver et les thèmes clair/sombre.

## 4. Le contrat rédactionnel du compte rendu

### Un plan qui dépend réellement de la réunion

Commencer par un bref contexte lorsque les sources le permettent : sujet, objectif et enjeu. Organiser ensuite les échanges par thèmes, en conservant la chronologie à l’intérieur d’un thème lorsqu’elle explique un changement d’avis. La longueur dépend du contenu utile ; une réunion courte peut tenir en quelques paragraphes sans sous-sections.

Exemples de plans possibles, uniquement si ces sujets sont présents :

| Réunion | Titres possibles |
|---|---|
| Revue produit | Frictions à l’inscription → Périmètre de la prochaine version → Organisation du test |
| Discussion technique | Problème de latence → Options comparées → Choix retenu et compromis → Déploiement |
| Entretien client | Situation actuelle → Difficultés rencontrées → Besoins exprimés → Suite de l’échange |

L’utilisateur peut orienter le résultat : automatique, suivi de projet, entretien, revue technique, puis format personnalisé dans un second temps. Ces profils donnent une intention éditoriale ; ils n’imposent pas des cases vides. Le mode par défaut produit un compte rendu ; « Synthèse courte » devient une variante explicite.

### Rédaction et mise en forme

- Des phrases complètes qui relient les faits, les arguments, les arbitrages et leurs conséquences explicites.
- Des titres informatifs : « Un pilote limité avant le déploiement » est plus utile que « Points évoqués » lorsque la conversation le justifie.
- **Gras** pour une décision, un résultat ou un terme central ; *italique* pour une nuance ou une citation courte ; surlignage parcimonieux pour ce qui mérite une attention immédiate. Les parenthèses précisent une information présente dans les sources.
- Listes pour plusieurs éléments parallèles ; cases à cocher pour des engagements concrets. Un tableau peut servir une comparaison explicite, dans une version ultérieure de l’éditeur.
- Ni rubrique vide ni texte de remplissage dans un compte rendu généré. En cas de source insuffisante, signaler ce qui manque sans inventer l’objectif de la réunion.

Exemple fictif de ton attendu :

> L’équipe a examiné les abandons observés lors de l’inscription et discuté de deux pistes de simplification. La suppression immédiate d’une étape a été écartée, car ses conséquences sur la vérification des comptes restent à préciser. **Un test sur un groupe restreint a été retenu** pour comparer les parcours avant de généraliser la modification.
>
> Camille préparera le protocole de test. *Aucune date de déploiement général n’a été arrêtée.*

Ce texte ne serait acceptable que si les échanges étayent chacune de ces affirmations. Une référence valide ne prouve pas à elle seule que le paragraphe est fidèle. Préserver les désaccords et distinguer une idée proposée, une décision prise et une action promise. Ne jamais déduire un responsable ou une échéance du seul contexte.

## 5. Fonctionnalités et priorités

### P0 — Le socle de la refonte

| Fonction | Comportement attendu |
|---|---|
| Document dynamique | Contexte, thèmes adaptés, paragraphes suivis, mise en valeur utile, aucune rubrique artificielle |
| Éditeur riche | Titres, gras, italique, surlignage, liens, listes, cases à cocher, insertion/suppression de sections, copier-coller et annuler/rétablir |
| Sauvegarde et versions | Sauvegarde automatique avec état réel ; restauration d’une version ; conservation des corrections humaines |
| Régénération contrôlée | Nouveau brouillon comparé à la version existante ; acceptation explicite des changements ; jamais d’écrasement silencieux |
| Sources | Liens vers la transcription horodatée ; accès audio si conservé ; distinction entre texte généré et ajout personnel |
| Exports | DOCX éditable, PDF propre et Markdown ; export de la version éditée, avec option d’inclure les références |
| Accueil et agenda | Historique lisible, filtre/recherche, agenda utile et liaison persistante à l’événement |
| Capture et reprise | Micro ou micro + son du Mac, import audio/vidéo, erreurs récupérables et états fidèles |

Le PDF conserve la présentation ; Word conserve une structure éditable. Le Markdown préserve le contenu et les styles qu’il peut représenter : annoncer une éventuelle perte de surlignage. Tester l’ouverture dans les applications cibles, pas seulement la création du fichier.

### P1 — Les fonctions qui rendent le mode utile chaque semaine

1. **Réécriture d’un passage sélectionné** : raccourcir, clarifier, développer à partir des sources. Montrer la proposition avant remplacement ; préserver les faits.
2. **Notes et marqueurs pendant la capture**, reliés à leur moment dans l’enregistrement.
3. **Suivi des actions** : responsable et échéance uniquement lorsqu’ils sont connus, statut modifiable, lien vers le passage d’origine. Une action complétée par l’utilisateur reste une information ajoutée après la réunion.
4. **Profils de compte rendu** : préférence de longueur, style et langue ; un changement crée une nouvelle version.
5. **Classement par projet et favoris**, avec recherche dans les comptes rendus et transcriptions.
6. **Préparer le suivi** : brouillon de message récapitulatif ou ordre du jour suivant, à copier/exporter. Aucune diffusion automatique.

### P2 — Trois pistes de différenciation à explorer

- **La continuité entre réunions.** Sur une série explicitement reliée, montrer ce qui a changé : choix confirmé, reporté ou abandonné, sujet resté ouvert, engagement repris. Chaque comparaison renvoie aux deux réunions concernées. Dépend du classement, des sources et d’un suivi des actions fiable.
- **La relecture ciblée.** Signaler un montant ambigu, une attribution de voix incertaine ou une contradiction, puis ouvrir l’extrait pertinent. Préférer une explication concrète à un pourcentage de confiance arbitraire.
- **Plusieurs documents issus d’une même réunion.** Compte rendu complet, synthèse de direction, note technique ou brief de suivi, conservés séparément avec leurs sources. Les instructions peuvent varier sans altérer le document principal.

Le fonctionnement local est un axe de différenciation à conserver dès P0. La synchronisation cloud, la coédition en temps réel, un bot qui rejoint les appels et les intégrations CRM ne sont pas nécessaires pour réussir cette première refonte.

## 6. Les changements techniques nécessaires

### Un modèle de document commun

Faire évoluer le stockage Markdown vers un document versionné : blocs de titres, paragraphes, listes, citations et actions, avec identifiants stables ; styles à l’intérieur du texte ; références vers les passages sources. Conserver séparément la transcription originale, les corrections, les notes personnelles et les révisions du compte rendu.

L’interface, les exports et les commandes de réécriture utilisent ce modèle commun. Les mises en forme ne doivent pas dépendre de chaînes Markdown découpées ligne par ligne. Migrer les brouillons existants sans perte ; conserver leur original et un chemin de retour. Une modification humaine substantielle doit marquer le lien de source comme à revérifier, pas conserver abusivement une apparence de validation.

Garder l’enveloppe SwiftUI native. Réaliser un prototype limité de l’éditeur riche pour vérifier les vrais points difficiles : sélection, listes, raccourcis, annulation, collage, accessibilité et pont vers le modèle de document. Choisir le composant après ce test ; éviter de développer un traitement de texte complet avant d’avoir vérifié ces interactions.

### Une rédaction qui couvre les sujets et respecte les ressources

Le pipeline cible : transcription complète → index des passages et faits → carte des thèmes → plan du document → rédaction structurée → contrôles → nouveau brouillon.

- Parcourir toute la transcription pour identifier les thèmes, leurs passages et les changements de position. La sélection des décisions/actions/questions actuelle ne couvre pas à elle seule le contexte et les arguments.
- Sur une réunion courte, regrouper les opérations compatibles dans un appel. Sur une réunion longue, préparer un index réutilisable et rédiger à partir des sources pertinentes pour chaque thème, avec un budget global explicite.
- Distinguer le contexte provenant du calendrier, les notes personnelles et les faits prononcés. L’ordre du jour prévu ne prouve pas qu’un sujet a été discuté.
- Demander au modèle du contenu structuré ; laisser au rendu les règles typographiques. Valider les références, les noms/chiffres/dates, la complétude de la sortie et les incohérences repérables. Compléter par une évaluation humaine de la fidélité.
- Mettre en cache les étapes valides et reprendre une section échouée. Les états partiels restent visibles comme partiels ; un assemblage d’extraits de secours ne doit pas être présenté comme un compte rendu abouti.

Ne pas réintroduire un appel de prose par tranche temporelle arbitraire. Le diagnostic local du 25 septembre avait rejeté cette approche : 45 appels envisagés sur une fixture répétée de deux heures, avec échec de budget de sortie dès le deuxième appel. Le travail par thèmes doit donc être borné et mesuré, tout en conservant une couverture explicite de la réunion.

L’optimisation de préremplissage précédente avait réduit le pic mémoire du processus d’environ 23,6 %, avec un temps mural environ 2,5 % plus élevé sur son petit essai. C’est une preuve ciblée de consommation mémoire, pas de qualité rédactionnelle ni d’accélération générale. Les libellés du générateur ont évolué dans le code actuel : vérifier le modèle réellement chargé avant toute nouvelle comparaison.

Mesurer désormais le temps jusqu’au premier contenu utile, le temps jusqu’au document complet, la mémoire maximale, les erreurs/reprises et les omissions. Définir un budget de longueur selon la richesse de la réunion. Aucun objectif de latence précis ne peut être promis à partir des mesures existantes.

### Médias et calendrier

Ajouter une référence persistante au fichier audio, avec conservation choisie par l’utilisateur, disponibilité vérifiable et possibilité de relocalisation. Conserver le compte rendu si l’audio est absent. Lorsqu’une vidéo sert de source, proposer de garder uniquement son audio pour la relecture, sans supprimer la vidéo originale.

Pour le calendrier, conserver l’événement associé et son occurrence, le fuseau horaire et les informations de contexte pertinentes. Gérer événement déplacé, supprimé et récurrent sans dupliquer les réunions ni modifier leurs sources a posteriori.

## 7. Ordre de réalisation et critères de sortie

| Lot | Livrable | Ce qui permet de passer au suivant |
|---|---|---|
| 1. Référence éditoriale | Quelques comptes rendus représentatifs et maquettes accueil/détail | Accord sur ce qu’est un bon document : contenu, structure, densité et sources |
| 2. Document et éditeur | Modèle versionné, migration, page éditable, sources, sauvegarde, exports | Éditer, fermer, rouvrir et exporter préserve contenu et mise en forme ; aucune perte des anciens brouillons |
| 3. Rédaction dynamique | Plan thématique, contenu contextualisé, budgets adaptés et reprise | Les différents types de réunions produisent des documents cohérents et distincts, fidèles aux échanges |
| 4. Parcours complet | Agenda/historique, capture, traitement, relecture et états finalisés | Parcours validé avec capture réelle présentielle, appel et import vidéo ; interruptions récupérables |
| 5. Différenciation | Réécriture ciblée, actions puis continuité entre réunions | Ajout progressif après validation du socle, sans régression de fidélité ni de sauvegarde |

La définition éditoriale précède l’optimisation : elle donne un résultat à préserver lorsqu’on cherche ensuite à réduire le coût de Qwen. Les lots 2 à 4 composent la première version complète.

Pour la recette, constituer un petit lot de réunions réelles autorisées, de types et de durées différents, en français et en anglais. Ajouter des cas contrôlés de négation, contradiction, absence de décision, nom incertain et correction tardive. Les fixtures synthétiques servent aux tests techniques ; les appréciations éditoriales portent aussi sur des réunions naturelles.

Critères impératifs :

- Un lecteur extérieur comprend le contexte, les sujets et les suites sans ouvrir la transcription ; les thèmes importants repérés lors de la relecture humaine sont couverts.
- Aucun responsable, chiffre, engagement ou arbitrage inventé dans le lot de recette. Les propositions non tranchées restent ouvertes.
- Les sections sont adaptées au contenu, sans rubrique vide, répétition mécanique ou surlignage omniprésent.
- Édition clavier/souris, annulation, sauvegarde, restauration et régénération conservent les corrections ; une fermeture inattendue ne doit pas effacer la dernière version enregistrée.
- Sources consultables et références cohérentes ; fichier manquant et transcription modifiée sont gérés explicitement.
- DOCX et PDF inspectés visuellement, notamment titres isolés en fin de page, listes, caractères accentués, liens et surlignage. Le DOCX reste éditable.
- Captures et imports réels vérifiés séparément du build et des tests unitaires ; latence et mémoire mesurées sur le même matériel et le même modèle.

## 8. Sources de l’audit

- [Écran Réunions](../../App/Hub/NativeMeetingsView.swift) : accueil, navigation, édition et rendu.
- [Génération locale](../../App/Services/MeetingsStore.swift) : `generateReportDraft`, `reportNarrativeInstruction` et budgets de sortie.
- [Sélection des passages](../../Packages/SpeakerKit/Sources/MeetingReportNarrative.swift) : `boundedEvidence`.
- [Brouillon et rendu](../../Packages/SpeakerKit/Sources/MeetingReport.swift), [export Word](../../Packages/SpeakerKit/Sources/MeetingWordDocument.swift), [transcription](../../Packages/SpeakerKit/Sources/SpeakerTranscript.swift).
- [Calendrier](../../App/Services/MeetingCalendarStore.swift), [capture et états](../../App/Hub/MeetingSessionViews.swift).
- [Diagnostic du reporting long du 25 septembre](../../outputs/inference-opt-20260925-long-report-2h/summary.json) : résultats techniques et limites de preuve.
- [État antérieur du parcours](workspace-2026-09-24.md) : contexte historique, à distinguer des sources actuelles.

Les liens relatifs de cette section sont destinés à rester utilisables dans le dépôt. Aucun changement de code, installation ou publication n’accompagne ce plan.
