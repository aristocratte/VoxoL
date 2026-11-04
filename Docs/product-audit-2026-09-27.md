# VoxoL — audit produit et plan d’amélioration

Date de référence : 27 septembre 2026. Analyse du checkout courant, avec ses modifications en cours conservées. Ce document distingue les constats de code, les vérifications visuelles, les fonctionnalités annoncées par les concurrents et les hypothèses à tester.

## Résultat du lot

- [x] Lire les décisions récentes et examiner les parcours existants.
- [x] Identifier deux défauts de confiance : statistiques fictives avec un historique vide, et vérification de mise à jour échouée présentée comme réussie.
- [x] Comparer sept produits ou références à partir de leurs sources officielles, vérifiées le 27 septembre.
- [x] Examiner le rendu natif, les états vides, la recherche, la confidentialité et la récupération.
- [x] Implémenter les corrections de fiabilité et d’interface décrites en section 7 ; compiler l’application et exécuter les contrôles ciblés.
- [ ] Qualifier la dictée au microphone et les comptes rendus sur des réunions naturelles, puis la distribution sur un autre Mac. Ces critères de publication restent distincts du lot livré.

## Priorités retenues

1. **Confiance et récupération.** Ne jamais inventer une activité ; distinguer historique vide, désactivé et illisible ; ne pas écraser un historique illisible ; afficher les erreurs de mise à jour avec une possibilité de réessayer.
2. **Parcours quotidien.** Rendre la recherche accessible au clavier, préserver le retour d’action lors de copies successives et garder l’interface réactive quand l’historique augmente.
3. **Lisibilité et cohérence.** Conserver la direction ivoire, encre et cobalt ; améliorer les états vides et les informations de confidentialité avant d’ajouter des écrans.
4. **Qualification.** Séparer les preuves de compilation, les tests synthétiques, le rendu de l’interface et les essais réels microphone → transcription → insertion. Le cycle d’optimisation d’inférence clos le 27 septembre reste clos.

## 1. Verdict et choix produit

VoxoL a déjà un périmètre conséquent : dictée globale, traitement local, personnalisation, historique révisable, import, capture de réunions, attribution des voix et édition de comptes rendus. Le principal risque n’est plus le manque de fonctionnalités. C’est l’écart entre une interface qui paraît aboutie et des comportements encore fragiles quand un résultat manque, qu’un fichier est illisible ou qu’une opération échoue.

Le positionnement recommandé est **« une voix transformée en texte exploitable, sur son Mac, avec un résultat que l’on peut retrouver et vérifier »**. La dictée française et anglaise quotidienne constitue le premier parcours à réussir. Les réunions deviennent le deuxième parcours : un document éditable et ses sources, et non une accumulation de tableaux de bord. Il s’agit d’un choix proposé à partir du produit et des concurrents, pas d’une conclusion issue d’entretiens clients.

L’ordre de concentration est le suivant : fiabilité des résultats et des sauvegardes ; simplicité du premier résultat utile ; récupération, recherche et correction ; qualité réelle de la dictée ; qualité documentaire des réunions. Ajouter des intégrations, davantage de modèles ou des fonctions d’équipe avant ces fondations augmenterait la surface de maintenance sans prouver une meilleure expérience.

Le fonctionnement local est important mais **n’est pas une exclusivité** : Superwhisper, VoiceInk et MacWhisper proposent aussi des traitements locaux. La différenciation doit se démontrer dans les parcours, la fidélité et les ressources utilisées, pas seulement dans une promesse de confidentialité. Sources : [Superwhisper — modes](https://superwhisper.com/docs/modes/modes), [VoiceInk](https://tryvoiceink.com/), [MacWhisper](https://www.macwhisper.com/).

## 2. Méthode et niveau de preuve

L’analyse s’appuie sur les sources du checkout courant, les décisions documentées dans le dépôt, le bilan local d’optimisation du 27 septembre et les pages officielles des concurrents consultées pour cette tâche. Le code actuel prime sur les anciens résumés. Le checkout contient déjà une refonte importante de la bibliothèque et des réunions : ces apports antérieurs ne sont pas attribués à cet audit.

Les concurrents ont fait l’objet d’une **analyse documentaire**, pas d’un essai de leurs applications sur les mêmes enregistrements. Leurs promesses d’exactitude, de vitesse et d’autonomie ne sont donc pas des mesures comparatives. Les prix ci-dessous sont ceux affichés lors de la consultation, dans leur devise d’origine, sans conversion ni hypothèse sur les taxes.

Les preuves sont séparées : un constat de code montre une possibilité ou une règle ; un test démontre un cas contrôlé ; une capture native montre un état rendu ; une dictée réelle vérifie le microphone, le modèle et l’insertion ensemble. Une capture sur données fictives ne prouve ni l’absence d’erreur de transcription ni la qualité éditoriale d’une réunion réelle. Les résultats effectifs de ce chantier sont consignés en fin de document.

## 3. Analyse des concurrents

### Comparaison utile à la décision

| Produit | Parcours à étudier | Local / cloud | Repère de prix public | Conséquence pour VoxoL |
|---|---|---|---|---|
| Wispr Flow | Dictée directement dans l’application cible, personnalisation, réunions | Transcription cloud ; contrôles distincts de conservation et d’entraînement | Pro 15 USD/mois, ou 12 USD/mois avec paiement annuel | Réduire les corrections et les interruptions du geste quotidien |
| Superwhisper | Modes adaptés à l’application, transcription et transformation configurables | Choix local ou cloud selon le mode et les modèles | 8,49 USD/mois, 84,99 USD/an, 249,99 USD à vie | Offrir de bons réglages par défaut sans imposer un atelier de configuration |
| VoiceInk | Dictée Mac, vocabulaire et remplacements, réécriture | Transcription locale ; amélioration cloud facultative | Achat unique : 25 USD pour un Mac, 39 USD pour deux, 49 USD pour trois | La dictée locale abordable existe déjà ; la confiance doit être visible |
| MacWhisper | Import, lecture, correction et export de transcriptions | Modèles locaux ; services et modèles cloud également proposés | Gratuit ; Pro 64 EUR par licence, achat unique | Faire aboutir le parcours fichier → texte révisé → document exporté |
| Granola | Notes de réunion, recherche, exploitation et partage | Capture sur l’appareil, traitement par services distants | Basic gratuit ; Business 14 USD/utilisateur/mois | Centrer les réunions sur le document et le contexte retrouvé |
| Willow | Dictée et génération depuis une intention avec Scribe | Offre de dictée assistée et contrôles de confidentialité ; pas de preuve d’un moteur hors ligne dans les pages étudiées | Pro 15 USD/mois ou 12 USD/mois annuel | Séparer clairement transcription fidèle et réécriture intentionnelle |
| Dictée macOS | Déclenchement au clavier, texte dans le champ actif | Traitement local selon la configuration et les langues, à vérifier dans Réglages | Fonction intégrée à macOS | Justifier toute installation et tout réglage supplémentaires |

Sources tarifaires et fonctionnelles : [Wispr](https://wisprflow.ai/pricing), [Superwhisper](https://superwhisper.com/docs/billing/plans), [VoiceInk](https://tryvoiceink.com/), [MacWhisper](https://www.macwhisper.com/), [Granola](https://www.granola.ai/pricing), [Willow](https://willowvoice.com/pricing), [Apple](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac). Les conditions commerciales peuvent évoluer ; cette comparaison ne fixe pas un prix de vente pour VoxoL.

### Wispr Flow : le résultat dans le contexte de travail

L’offre rassemble dictée dans les applications, dictionnaire, snippets, personnalisation et Notetaker. La dictée est annoncée sur Mac, Windows, iOS et Android ; le Notetaker sur Mac et Windows. Les fonctions de réunion incluent l’identification des intervenants, les questions sur les notes et l’accès par MCP. Cela rend obsolète une comparaison qui présenterait Flow comme une simple boîte de transcription. [Produit et offre](https://wisprflow.ai/pricing).

Le point de confidentialité important est précis : la transcription reste dans le cloud, même quand l’entraînement est désactivé. Conservation, contexte et participation à l’amélioration des modèles sont des décisions distinctes. [Contrôles de données, mise à jour du 18 août 2026](https://wisprflow.ai/data-controls).

**À retenir pour VoxoL :** le premier écran doit préparer un résultat utilisable dans l’application cible, et chaque échec doit offrir une récupération compréhensible. Le retour manuel par presse-papiers a plus de valeur qu’une nouvelle carte statistique lorsqu’une insertion échoue. À ne pas copier automatiquement : les fonctions de collaboration ou de synchronisation qui contrediraient le périmètre local choisi.

### Superwhisper : puissance configurable, coût de compréhension

Un mode associe reconnaissance vocale et, éventuellement, un modèle de texte. Les choix de langue, de modèle et de traitement local ou distant ne sont pas tous équivalents. La documentation décrit aussi l’activation selon l’application ou le site, sans retour automatique au mode précédent. Les transcriptions séparées par intervenants apparaissent dans les segments de l’historique et ne passent pas automatiquement par le traitement de texte du même mode. [Fonctionnement des modes](https://superwhisper.com/docs/modes/modes) et [changement de mode](https://superwhisper.com/docs/modes/switching-modes).

**À retenir :** la personnalisation par application est utile seulement si l’utilisateur comprend quel comportement est actif et pourquoi. VoxoL dispose déjà de profils : améliorer leur visibilité et leur prévisibilité avant d’ajouter une nouvelle abstraction « workflow ». Trois intentions lisibles — restituer fidèlement, conserver le brut, réécrire explicitement — sont préférables à une collection de paramètres exposés dès le départ. La supériorité de qualité ou de latence entre les deux applications reste à mesurer.

### VoiceInk : une concurrence directe sur la simplicité et le local

VoiceInk annonce une transcription locale sur Mac, un vocabulaire personnalisé, des remplacements, une réécriture et des modes ; l’amélioration cloud reste une option distincte. Le code est publié. L’achat unique rend difficile de vendre VoxoL uniquement sur l’absence d’abonnement. [Présentation, fonctionnalités et licences](https://tryvoiceink.com/).

**À retenir :** « local » doit être accompagné d’une expérience immédiatement praticable : modèles prêts, raccourci visible, états explicites et historique fiable. Le projet doit pouvoir expliquer ce que conserve le mode privé sans demander de comprendre les mécanismes internes. Le prix de VoiceInk est un repère concurrentiel, pas une preuve qu’un prix identique conviendrait à VoxoL : le support, les mises à jour et la valeur du mode Réunion restent à évaluer.

### MacWhisper : terminer le travail commencé dans un fichier

Le produit met en avant import par glisser-déposer, transcription locale, capture des appels sans bot, distinction des intervenants, édition, recherche, traitement par lots et exports. Il propose également des connexions à des modèles locaux ou distants pour enrichir les transcriptions. Le qualificatif « local » doit donc être appliqué au parcours choisi et non à toutes les configurations possibles. [Fonctionnalités et tarif](https://www.macwhisper.com/).

**À retenir :** conserver l’origine du média, rouvrir un résultat, corriger un nom, retrouver un passage et exporter proprement sont des fonctionnalités produit centrales. Les performances sur un fichier long ne suffisent pas si son résultat disparaît après un problème de sauvegarde. Ne pas reproduire tout le traitement par lots avant de qualifier la reprise et la récupération d’un import unique. Les nouveaux travaux de VoxoL sur les références audio et l’édition riche vont déjà dans cette direction.

### Granola : la réunion comme document et mémoire de travail

L’offre inclut notes de réunion, modèles de notes, recherche, intégrations et accès aux données par MCP/API selon le plan. Le parcours valorise le résultat consultable au-delà du moment de capture. [Offre actuelle](https://www.granola.ai/pricing).

Granola indique démarrage manuel, capture micro et audio du système sans bot, traitement via des fournisseurs et stockage des transcriptions et notes. Sur ordinateur, il n’enregistre pas l’audio des réunions ; sur mobile, un cache audio temporaire sert à la transcription. Les notes sont privées jusqu’au partage. Ce modèle n’est pas celui d’un traitement entièrement hors ligne. [Sécurité](https://www.granola.ai/security).

**À retenir :** une réunion réussie aboutit à un compte rendu lisible, corrigeable et relié à ses sources. VoxoL peut conserver une valeur distincte dans la vérification locale des passages, sous réserve de fidélité effective. L’existence d’un lien vers un extrait ne prouve pas que la phrase générée est justifiée par cet extrait. La relecture humaine doit rester distincte de la génération automatique.

### Willow : distinguer dire un texte et demander un texte

Willow sépare dictée et Scribe, qui produit du texte à partir d’une intention. L’offre gratuite annonce un modèle de dictée moins performant avec personnalisation limitée ; l’offre Pro met en avant mémoire de style, modèle supérieur et davantage de possibilités de dictée. Ces comparaisons de qualité sont des formulations de l’éditeur. [Offre et différences de plans](https://willowvoice.com/pricing).

**À retenir :** VoxoL doit annoncer clairement lorsqu’il reformule. Une personne qui dicte un chiffre, une négation ou un nom propre n’a pas implicitement demandé une réinterprétation. Le couple texte brut / résultat modifié, déjà disponible, mérite une place accessible dans le parcours de correction. Il ne faut pas présenter le nombre de modifications automatiques comme le nombre de corrections validées.

### Dictée macOS : le coût de changement à battre

Apple permet de dicter dans un champ texte, de personnaliser le raccourci, de choisir le microphone et les langues, et d’utiliser une ponctuation automatique dans les langues compatibles. Sur Apple Silicon, clavier et dictée peuvent être utilisés ensemble. Apple demande de vérifier dans les réglages si les entrées de la configuration choisie sont traitées sur l’appareil ; il serait faux d’en faire une garantie universelle. [Guide officiel](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac).

**À retenir :** l’installation, le téléchargement des modèles et les permissions de VoxoL sont un coût d’entrée. Le produit doit démontrer rapidement la différence par un résultat fidèle, une correction récupérable et une meilleure continuité de travail. Une interface plus décorative ne suffit pas à justifier ce coût.

## 4. Audit critique de VoxoL

Cette section décrit le diagnostic initial. La section 7 distingue les corrections livrées de ce qui reste à qualifier ; les défauts corrigés ci-dessous ne sont donc pas présentés comme l’état final du code.

### Design et hiérarchie

La palette ivoire/encre/cobalt, la typographie Outfit et le grain constituent une direction cohérente dans les sources. La navigation distingue accueil, statistiques, réunions, bibliothèque et réglages. Il faut préserver cette identité et les refontes récentes. Une nouvelle direction artistique globale serait coûteuse et ne résoudrait aucun des défauts de fiabilité identifiés.

Le danger vient de la priorité donnée à la démonstration visuelle : les valeurs de maquette apparaissent même lorsque l’historique est vide. Le tableau de bord peut ainsi annoncer une activité inexistante au premier lancement ou après une erreur. Ce n’est pas seulement un problème de libellé : la représentation du produit devient trompeuse. Les valeurs initiales doivent être nulles, les exemples explicitement demandés et identifiés, et les états vides utiles.

La couleur secondaire actuelle `#77736A` a un contraste calculé d’environ **4,18:1 sur `#F4F1E8`** et **3,96:1 sur `#EEEBE2`**. Cela justifie un assombrissement limité du jeton secondaire, sans changer la marque. Le repère retenu pour les petits textes opaques est 4,5:1, issu des [critères de contraste W3C](https://www.w3.org/TR/WCAG22/#contrast-minimum). Ce calcul ne constitue pas une certification d’accessibilité : opacité, superpositions, sélection, focus et rendu des contrôles nécessitent des vérifications distinctes.

L’interface impose actuellement le thème clair dans le Hub et l’onboarding malgré des couleurs adaptatives. Ne pas promettre un mode sombre abouti en supprimant une ligne : les illustrations, ombres, éditeurs natifs et états sélectionnés doivent être examinés ensemble. La fenêtre minimale actuelle de 1 100 × 720 impose aussi une recette sur les petits écrans et les dispositions réduites.

### Onboarding et première dictée

Le parcours comporte six étapes : accueil, capacités, autorisations, modèles, essai, disponibilité. L’essai est relié au pipeline réel dans le code actuel ; il ne faut donc pas le remplacer par une animation illustrative. Les priorités sont de comprendre l’autorisation demandée, reprendre un téléchargement, voir pourquoi l’application n’est pas prête et obtenir un premier résultat sans chercher dans les réglages.

Les états de disponibilité doivent distinguer absence de modèle, autorisation manquante et erreur de la dernière dictée. Une insertion échouée ne doit pas renvoyer systématiquement vers l’installation. `EditorialRuntimePresentation` distingue déjà plusieurs de ces situations : cette amélioration existante doit être conservée.

La métrique pertinente est le **temps entre lancement et premier texte utile**, avec causes d’abandon, et non le nombre d’étapes parcourues. Il manque une recette de bout en bout sur une nouvelle session macOS avec permissions réelles ; aucune durée d’activation n’est annoncée comme mesurée ici.

### Historique, récupération et confiance

Trois problèmes sont directement identifiés dans les sources :

1. Un échec de lecture vide l’état affiché ; une sauvegarde suivante peut alors remplacer l’archive originale. Une écriture doit être interdite tant que l’archive n’a pas été correctement lue ou son absence confirmée.
2. Un historique vide, un historique désactivé et un échec de chargement reçoivent presque le même message. L’utilisateur ne sait pas si ses résultats sont perdus, volontairement non conservés ou seulement indisponibles.
3. Les notifications temporaires reposent sur une valeur d’énumération et des tâches de fermeture indépendantes. Deux copies identiques peuvent ne pas relancer le retour visuel ; une ancienne tâche peut fermer la notification suivante.

La solution retenue combine archive protégée, maintien des résultats en mémoire, avertissement persistant et bouton de reprise. Lors d’une reprise réussie, les résultats en attente doivent être fusionnés par identifiant avec les résultats présents sur disque, puis enregistrés. Les erreurs de stockage ne doivent pas se limiter à un message de quelques secondes.

Le mode privé et la désactivation de l’historique bloquent la conservation des nouvelles dictées ; ils n’effacent pas automatiquement les résultats antérieurs. Cette différence doit être annoncée. L’effacement et la rétention automatique constituent des décisions distinctes, à concevoir sans suppression implicite de données.

### Recherche, clavier et performance de l’interface

La recherche de l’accueil parcourt et regroupe les résultats dans une propriété calculée de la vue. Les changements d’état du runtime peuvent donc refaire ce travail sans modification de la requête. Une mise en cache dérivée de la requête, des résultats et de la langue réduit ces recalculs. La saisie doit rester immédiate ; seule l’application du filtre peut être légèrement différée.

La pile de lignes d’un même jour est construite avec un `VStack` à l’intérieur d’une pile paresseuse. Un historique fortement concentré sur une journée doit être testé : la paresse du conteneur extérieur ne garantit pas celle des lignes internes. Les identifiants UUID existants sont un bon point et doivent être conservés.

Ajouter l’accès par **⌘F**, un focus visible et une sortie par Échap rend la recherche praticable au clavier. La validation doit inclure requêtes accentuées, espaces seuls, aucun résultat, données ajoutées pendant une recherche et navigation hors de la page. Le coût doit être mesuré sur la construction et l’interaction de l’interface ; une amélioration de code n’autorise pas à annoncer un gain de batterie ou de fluidité globale.

### Réunions, personnalisation et fonctionnalités

La bibliothèque possède déjà dictionnaire, snippets, profils et révision d’exemples. Le nouvel espace Réunion comporte capture, import, calendrier, historique, document, sources et export. La priorité est leur cohérence : une correction validée doit rester une correction humaine, un brouillon doit rester identifié comme brouillon, et un média absent ne doit pas rendre le document inaccessible.

Le document [Refonte Réunion du 27 septembre](meetings/refonte-produit-2026-09-27.md) détaille déjà la direction éditoriale. Ce chantier la complète ; il ne lance pas une refonte concurrente. Les prochaines recettes doivent couvrir annulation/rétablissement, édition pendant sauvegarde, fermeture et réouverture, média déplacé, export éditable, régénération conservant les corrections humaines et reprise après échec d’une seule étape.

La recherche globale dans plusieurs réunions et les actions interapplications peuvent attendre. Une réponse convaincante mais non justifiée par la réunion serait plus dommageable qu’une fonctionnalité manquante. Les notes personnelles, données du calendrier et paroles prononcées doivent rester distinguées.

### Mise à jour, aide et distribution

Le service de mise à jour avale les erreurs réseau, tandis que les vues considèrent une tentative terminée comme une vérification réussie. Une réponse HTTP d’erreur dont le JSON n’est pas une liste peut aussi être interprétée comme l’absence de nouvelle version. L’état « À jour » doit être réservé à un succès réel.

La vérification et l’installation sont deux actions différentes : le premier clic doit vérifier, puis une version découverte doit être proposée explicitement. L’état doit être partagé entre réglages et barre latérale, avec requêtes simultanées regroupées, attente réseau bornée et version connue conservée après une erreur de rafraîchissement.

Le rapport de bug sans transcription constitue une bonne direction. Il faut toutefois continuer à vérifier le contenu réellement exporté. Une compilation locale ne prouve ni signature de distribution, ni notarisation, ni installation et mise à jour sur un autre Mac.

## 5. Performances : ce qui est établi et ce qui manque

Le [bilan d’optimisation d’inférence](inference-optimization-closure-2026-09-27.md) clôt le cycle précédent. Il consigne des mesures ciblées, notamment le passage du préremplissage des comptes rendus de 512 à 128 tokens : pic du processus de 4,29 à 3,28 Gio, avec temps de 17,735 à 18,180 secondes sur un petit essai A/B/B/A à sortie identique. C’est un compromis mémoire/temps, pas une accélération générale de la dictée.

Le même bilan distingue les essais longs construits avec un audio répété, les tests unitaires et les recettes naturelles qui manquent encore. Ces résultats ne sont pas additionnés et ne sont pas extrapolés au nouveau format documentaire. Aucun poids de modèle ni paramètre d’inférence n’est modifié par ce lot d’audit.

Pour suivre la performance produit, mesurer séparément : démarrage à froid et à chaud ; relâchement du raccourci → texte utilisable ; première information utile d’un import ; mémoire maximale ; coût au repos ; reprise après échec. Publier médiane et p95 avec machine, build, langue, durée, modèle et nombre d’observations. Les tâches de compilation de ce chantier ne constituent pas une mesure de consommation de l’application au repos.

Les objectifs suivants sont **des critères proposés**, pas des performances déjà obtenues : aucun historique remplacé après échec de lecture ; aucun succès réseau affiché sur une erreur ; aucun résultat validé sans geste humain ; recherche disponible au clavier ; aucune omission silencieuse d’un résultat ou d’une étape de traitement.

## 6. Feuille de route et critères de sortie

| Priorité | Amélioration | Critère concret | Décision de ce chantier |
|---|---|---|---|
| P0 | Protection de l’historique | Archive corrompue ou future conservée octet pour octet après nouvelle dictée | Implémentation et tests de récupération |
| P0 | Reprise et visibilité des erreurs | Résultats en attente conservés, fusionnés au retry ; erreur persistante | Implémentation du magasin et de l’accueil |
| P0 | Statistiques honnêtes | Historique vide = zéro ; pas de maquette présentée comme activité | Correction de l’accueil et des statistiques |
| P0 | État de mise à jour véridique | Erreur HTTP/réseau ≠ « À jour » ; installation distincte | État partagé et tests du protocole |
| P1 | Retours d’action successifs | Copier deux fois réaffiche le retour ; ancienne tâche sans effet sur la suivante | Identité de notification et annulation |
| P1 | Recherche utilisable au clavier | ⌘F, focus, Échap ; accents et absence de résultat | Implémentation puis recette native |
| P1 | Lecture confortable | Jeton secondaire suffisamment contrasté sur les fonds de base | Ajustement limité et comparaison du rendu |
| P1 | Historique dense | Filtrage hors des redraws sans changement de données ; lignes paresseuses | Correction ciblée, sans promesse de débit non mesuré |
| P1 | Dictée réellement qualifiée | Micro → modèle → insertion et récupération, FR/EN, noms/chiffres/négations | Recette naturelle requise, distincte de ce lot UI/stockage |
| P1 | Réunion documentaire fiable | Corriger, rouvrir, retrouver la source et exporter sans perte | Poursuivre la recette du chantier Réunion existant |
| P2 | Fenêtres réduites, VoiceOver et thème sombre | Parcours complets testés, sans contenu inaccessible | Qualification dédiée après stabilisation |
| P2 | Rétention et sauvegarde utilisateur | Options explicites et réversibles avant toute suppression | Concevoir ; aucune suppression automatique ajoutée |
| P2 | Distribution | Signature, notarisation, mise à jour réelle sur Mac distinct | Ne pas confondre avec la compilation locale |
| P3 | Équipe, synchronisation, intégrations supplémentaires | Besoin utilisateur démontré et politique locale compatible | Différer plutôt que multiplier les surfaces |

### Indicateurs à suivre

Retenir peu d’indicateurs, calculés localement lorsque possible : proportion de dictées insérées sans intervention ; proportion nécessitant une correction humaine ; temps p50/p95 jusqu’au résultat utilisable ; résultats non sauvegardés et récupérations réussies ; temps nécessaire pour retrouver puis exporter une réunion. Le nombre de mots transformés par le modèle mesure de l’activité, pas une qualité vérifiée.

Le « temps gagné » affiché à partir d’une vitesse de frappe de référence doit porter la mention **estimation** et sa base de calcul. Il ne tient pas compte de tout le temps de vérification, de correction ou des habitudes individuelles. Une heatmap ou un compteur d’usage peut aider à comprendre l’activité, mais ne doit pas remplacer l’accès au texte ni devenir un objectif produit.

## 7. Implémentation et vérification

### Ce qui est livré dans le code

| Problème | Comportement livré | Sources principales |
|---|---|---|
| Archive illisible ou issue d’une version future | Les écritures sont bloquées ; les octets existants restent intacts. Les nouveaux résultats restent disponibles en mémoire. Une reprise fusionne les résultats en attente avant de sauvegarder | `TranscriptHistory.swift`, `TranscriptStore.swift` |
| Arrivée d’une dictée avant la lecture initiale | Aucun remplacement de l’historique non lu ; chargement, fusion puis sauvegarde des résultats | `TranscriptStore.swift` |
| Erreur de sauvegarde sans issue utilisable | Avertissement persistant, accès depuis la barre latérale, reprise et export JSON séparé. Une fermeture normale est refusée tant que des modifications ne sont ni sauvegardées ni protégées par cet export | `TranscriptStore.swift`, `AppDelegate.swift`, `HubView.swift` |
| Copie de secours pointant vers l’archive originale | Destination originale, lien symbolique et variante de casse refusés ; exporter ne débloque pas les écritures dans l’archive illisible | `TranscriptHistory.swift`, `TranscriptFileStoreTests.swift` |
| Statistiques inventées dans un historique vide | Compteurs nuls, aucune catégorie « Autres : 100 % », pas de barre positive ni de remplissage de jauge à zéro. Le temps gagné est explicitement estimé ; les modifications de texte ne sont plus qualifiées de corrections validées | `SignalEditorialScreens.swift` |
| Recherche coûteuse ou difficile au clavier | Résultats filtrés conservés hors des recalculs de rendu, délai de 120 ms lors de la saisie, lignes paresseuses, ⌘F et Échap ; l’historique est rapproché de son en-tête | `SignalEditorialScreens.swift` |
| Mode privé confondu avec disparition des résultats | Messages distincts pour mode privé, historique désactivé, chargement et erreur ; les anciens résultats ne sont pas effacés par ces réglages | `SignalEditorialScreens.swift` |
| Copies successives sans retour fiable | Chaque notification possède une identité ; une nouvelle action annule la fermeture temporisée de la précédente | `TranscriptStore.swift`, `HubView.swift` |
| Échec réseau présenté comme « À jour » | État partagé entre réglages et barre latérale ; validation du statut HTTP et du JSON ; nouvelle tentative possible ; une version déjà découverte reste connue après un échec | `UpdateCheck.swift`, `UpdateNotifier.swift` |
| Vérification déclenchant immédiatement l’installation | Vérifier et installer sont deux actions distinctes dans les réglages | `SignalEditorialScreens.swift` |
| Petits textes insuffisamment contrastés | Jeton secondaire clair passé de `#77736A` à `#69655D`, sans changement de palette globale | `VoxoLTheme.swift` |
| Traductions absentes dans les métadonnées extraites | Chaînes des nouvelles erreurs et du mode Réunion ajoutées au catalogue français ; aucune chaîne extraite manquante lors du contrôle final | `fr.lproj/Localizable.strings` |

Le contraste calculé du nouveau texte secondaire est **5,14:1 sur l’ivoire**, **5,71:1 sur la surface principale** et **4,87:1 sur le fond de sélection**, contre 4,18, 4,65 et 3,96 auparavant. Ce calcul s’applique aux couleurs opaques de base ; les contrôles en surimpression et l’accessibilité complète restent à vérifier.

### Vérifications techniques

| Contrôle | Résultat | Portée |
|---|---|---|
| `swift test --filter AppCoreKitTests` | **51 tests réussis, aucun échec** | Archive, récupération, export séparé, versions de texte, mise à jour et autres tests de ce module |
| `verify-transcript-recovery.swift`, compilé avec le vrai magasin de l’application | **18 contrôles réussis** | Fichiers temporaires : corruption, fusion, capture avant chargement, export, protection des nouvelles modifications, notifications |
| `xcodebuild`, schéma VoxoL, Debug, arm64 | **Compilation réussie** | Application complète, sans signature ni installation dans `/Applications` |
| `swift-format lint --strict`, fichiers Swift concernés | **Réussi** | Formatage ciblé ; aucun formatage massif du dépôt |
| `Scripts/check-localization.sh .build/ProductAudit` | **Réussi** | Couverture de toutes les chaînes extraites ; pas une preuve de qualité linguistique de chaque parcours |
| `git diff --check`, périmètre concerné | **Réussi** | Absence d’erreurs d’espacement dans les différences suivies |
| `Scripts/verify.sh --fast` | **Non réussi : arrêt au contrôle de politique du dépôt** | Des artefacts de modèles antérieurs, déjà ignorés par Git dans `outputs/`, sont néanmoins détectés par le script. Le lot ne les supprime pas et ne relâche pas cette règle |

Les journaux, empreintes des sources et captures sont regroupés dans le [reçu de vérification](../outputs/product-audit-20260927/summary.json). Le test global arrêté ne vaut pas exécution de toutes ses étapes : les contrôles ciblés ci-dessus sont des exécutions séparées. Les avertissements antérieurs des dépendances ne sont pas transformés en erreurs du lot.

### Parcours et preuves visuelles

Le mode Debug `--product-audit-preview` rend les vues de l’application avec des magasins vides ou des exemples explicitement fictifs. Il n’active pas la capture et ne charge pas l’historique personnel ni les modèles. Les captures sont des rendus AppKit/SwiftUI ; les raccourcis sont envoyés comme événements natifs. Les mentions « Configuration requise » sont attendues dans cet environnement isolé.

| Étape | État et résultat observé | Capture |
|---|---|---|
| 1. Accueil vide | Compteurs nuls, message de première dictée et historique rapproché de son en-tête | [Accueil](../outputs/product-audit-20260927/final-today.png) |
| 2. Statistiques vides | Absence de fausse application et de fausse activité ; temps présenté comme estimation | [Statistiques](../outputs/product-audit-20260927/final-insights.png) |
| 3. Bibliothèque vide | Dictionnaire vide explicite et action d’ajout visible | [Bibliothèque](../outputs/product-audit-20260927/final-library.png) |
| 4. Réglages | Navigation et textes français lisibles ; thème clair conservé | [Réglages](../outputs/product-audit-20260927/final-settings.png) |
| 5. Mode privé | Nouvelles dictées non conservées, sans annoncer l’effacement de l’historique existant | [Mode privé](../outputs/product-audit-20260927/final-private.png) |
| 6. Historique désactivé | Message distinct du mode privé et d’une erreur | [Historique désactivé](../outputs/product-audit-20260927/final-history-paused.png) |
| 7. Erreur de lecture | Avertissement persistant, accès latéral et bouton de reprise | [Erreur](../outputs/product-audit-20260927/final-history-error.png) |
| 8. Erreur avec résultats disponibles | Les textes restent visibles ; reprise et export de secours accessibles ensemble | [Récupération](../outputs/product-audit-20260927/final-recovery.png) |
| 9. Recherche sans accent | ⌘F donne le focus ; « cafe » retrouve uniquement l’exemple contenant « café » | [Recherche](../outputs/product-audit-20260927/final-search-cafe.png) |
| 10. Recherche sans résultat | La requête reste modifiable et le message d’absence de résultat est explicite | [Aucun résultat](../outputs/product-audit-20260927/final-search-no-match.png) |
| 11. Sortie du filtre | Échap efface la requête et les trois exemples réapparaissent | [Après Échap](../outputs/product-audit-20260927/final-search-escape.png) |
| 12. Fenêtre de 1 100 × 720 points | Accueil et contrôles accessibles ; les textes longs reviennent à la ligne | [Petite fenêtre](../outputs/product-audit-20260927/final-today-small.png) |
| 13. Réunion fictive | Document, sommaire, état à relire et commandes d’édition visibles. Rendu uniquement : l’édition et l’export complets ne sont pas qualifiés par cette capture | [Réunion](../outputs/product-audit-20260927/final-meeting.png) |
| 14. Statistiques avec exemples | Le cas positif reste calculé à partir des trois dictées fictives, distinct du cas vide | [Statistiques avec données](../outputs/product-audit-20260927/final-insights-populated.png) |

**Avant / après — accueil.** Le premier rendu affichait 20 837 mots et 148 mots/min alors qu’aucun résultat n’était chargé. Le rendu final réserve ces chiffres aux données disponibles et remonte l’historique.

![Accueil : avant à gauche, après à droite, même taille de fenêtre](../outputs/product-audit-20260927/comparison-today.png)

**Avant / après — statistiques.** Les valeurs, applications et rythmes fictifs ont disparu. Les représentations graphiques respectent désormais elles aussi le cas zéro.

![Statistiques : avant à gauche, après à droite](../outputs/product-audit-20260927/comparison-insights.png)

**Après — récupération.** L’erreur ne fait plus disparaître les résultats disponibles ; l’export séparé fournit une issue lorsque la sauvegarde principale reste impossible.

![Résultats conservés et actions de récupération](../outputs/product-audit-20260927/final-recovery.png)

### Limites et prochain travail utile

L’analyse concurrentielle reste documentaire : les sept références n’ont pas été testées sur un même corpus. Les captures ne qualifient pas le microphone, l’insertion dans des applications tierces, la fiabilité d’une vraie longue réunion ni la fidélité du document produit. L’amélioration structurelle de la recherche ne suffit pas à annoncer une réduction mesurée de latence, de consommation ou de mémoire. Aucun nouveau poids de modèle ni réglage d’inférence n’a été introduit.

La copie de secours protège les modifications exportées lors d’une fermeture normale ; elle ne garantit pas la survie de modifications encore uniquement en mémoire après un arrêt forcé. La restauration de l’archive JSON reste manuelle, et les courses avec un autre processus modifiant le même fichier ne sont pas qualifiées par les tests de ce lot. Le contour de focus du champ de recherche et l’homogénéité tutoiement/vouvoiement entre Hub et Réunion méritent encore une passe de finition. Le mode sombre, VoiceOver et les dispositions plus petites que la fenêtre minimale n’ont pas fait l’objet d’une recette complète.

**Prochaine priorité :** réaliser une recette humaine courte mais représentative, en français et en anglais, depuis une nouvelle installation jusqu’à l’insertion, la récupération et l’export d’une réunion. Mesurer les erreurs réelles et le temps de correction avant de choisir un nouveau chantier d’inférence. Le rapport et les corrections de ce lot sont livrés ; les jalons de publication restent non qualifiés.
