# VoxoL — direction « Signal éditorial »

Statut : direction visuelle approuvée le 2 août 2026. Le concept de logo A · Seuil est recommandé et utilisé dans les maquettes, mais reste à valider comme marque finale.

Ce package fixe la direction avant l’intégration SwiftUI. Il ne modifie pas encore les écrans de production ni les contrats du preflight existant.

## Intention

VoxoL doit donner l’impression d’un outil local, précis et calme. L’interface est claire et presque éditoriale ; le signal dither apporte la part vivante sans devenir un décor permanent. Le motif raconte toujours la même transformation : une voix diffuse devient un texte net.

La référence à Wispr Flow reste structurelle — accès rapide à la dictée et lecture immédiate de l’état — sans reprendre son langage visuel, son catalogue de pages ou ses cartes promotionnelles.

## Marque

- Nom produit conservé : `VoxoL` dans les textes système.
- Wordmark proposé : `voxol` en Outfit 700, pour une présence plus calme et compacte.
- Logo recommandé : **A · Seuil**. Les points représentent le signal brut ; le croissant plein représente la forme résolue.
- Icône macOS : marque noire sur porcelaine, avec une petite traversée cobalt/corail réservée à l’icône couleur.
- Barre des menus et petits contextes : version monochrome, sans dither animé.

Les alternatives B · Portail et C · Grain restent dans le board pour comparer le territoire, pas pour former une famille de logos simultanée.

## Palette

| Rôle | Valeur | Usage |
| --- | --- | --- |
| Ivoire | `#F4F1E8` | fond principal et chrome |
| Porcelaine | `#FFFDF8` | surfaces actives |
| Surface sourde | `#EEEBE2` | contrôles secondaires |
| Encre | `#171713` | texte et actions primaires |
| Gris éditorial | `#77736A` | texte secondaire |
| Cobalt | `#2449F8` | focus, signal et sélection |
| Corail | `#FF7048` | voix, chaleur et état d’écoute |
| Sauge | `#2E6B51` | état prêt ou autorisé |

Le cobalt et le corail apparaissent surtout dans le signal. Une surface entière ne devient colorée que pour un état exceptionnel et court.

## Typographie et formes

- Outfit variable, incluse localement dans le prototype : 400 pour lire, 500 pour agir, 600 à 700 pour orienter.
- Échelle : 12, 14, 16, 18, 20, 24, 30, 36, 48, 60 et 72 px dans le prototype ; l’intégration SwiftUI devra mapper ces valeurs vers des tokens sémantiques.
- Interlignage généreux, titres serrés, chiffres tabulaires pour les durées et statistiques.
- Rayons emboîtés : 24 px pour un conteneur extérieur, 16 px pour une surface située à 8 px à l’intérieur, 12 ou 8 px pour les contrôles.
- Ombres courtes et diffuses ; les bordures restent optiques et très faibles.

## Architecture de l’application

La navigation principale contient six destinations :

1. **Aujourd’hui** — statut du système, raccourci, dernière dictée et lecture hebdomadaire légère.
2. **Dictée** — langue, état d’écoute, aperçu entendu/prêt et réglages immédiats.
3. **Insights** — vitesse, volume, régularité, temps récupéré et répartition par app, calculés localement.
4. **Réunions** — destination visible avec un badge « Bientôt » et un aperçu honnête du futur résultat.
5. **Bibliothèque** — dictées conservées, favoris et futures réunions, si l’historique local est activé.
6. **Réglages** — raccourci, audio, langues, moteurs et confidentialité locale.

Il n’y a ni profil, ni compte, ni espace équipe. Le bloc « Tout fonctionne » dans la barre latérale remplace ces signaux SaaS par l’état réel des moteurs et permissions.

## Écrans directeurs

### Aujourd’hui

Le raccourci et l’état prêt sont la première information. La dernière transcription occupe ensuite la place utile ; les statistiques restent secondaires et compactes.

### Dictée

L’état d’écoute devient un moment plein écran dans le contenu, avec une capsule stable et un signal vivant. La comparaison « Entendu → Prêt à insérer » explique la valeur du nettoyage sans masquer ce qui a changé.

### Insights

La première vue répond immédiatement à quatre questions : combien de temps a été récupéré, combien de mots ont été dictés, à quelle vitesse et dans quelles apps. Les périodes 7 jours, 30 jours et Tout restent accessibles en haut. Les métriques décrivent l’usage sans streak culpabilisant, score opaque ou comparaison sociale.

### Réunions

L’écran prépare l’architecture future autour de quatre vues : Résumé, Décisions, Actions et Transcription. Tant que la capture n’existe pas, aucun bouton ne prétend démarrer une vraie réunion ; l’aperçu est explicitement présenté comme un exemple non enregistré.

### Preflight

Le preflight est la première démonstration du produit, pas une suite de formulaires. Il suit cinq actes qui tiennent chacun sans défilement :

1. **La transformation** montre immédiatement trois exemples « entendu → prêt à insérer » et fait alterner correction comprise, structure retrouvée et faits protégés.
2. **Les accès** relie visuellement chaque permission à son rôle dans la chaîne macOS. Chaque accès reste demandé séparément et son état affiché provient du système.
3. **Les moteurs** expose le pipeline local Parakeet → Qwen, son poids et un exemple de passage de la voix au texte. Un téléchargement réel affiche son véritable état ; aucune barre de progression simulée n’est autorisée.
4. **Le premier geste** fait maintenir puis relâcher un contrôle pour ressentir l’interaction. Dans le prototype, cette répétition est explicitement guidée et n’enregistre aucun audio ; dans l’app, elle doit être reliée au vrai raccourci et au vrai pipeline.
5. **Prêt** rassemble les preuves essentielles — raccourci, traitement local et historique désactivé — avant d’ouvrir l’application.

Les contrats système restent des portes réelles : permissions, présence et vérification des modèles, raccourci puis readiness globale. Il n’existe pas de sortie ambiguë qui laisserait une installation incomplète.

## Dither et mouvement

Le dither est fonctionnel :

- **Prêt** — signal discret et presque immobile.
- **Écoute** — amplitude accrue ; cobalt et corail se répondent.
- **Prépare** — les deux champs convergent vers le centre.
- **Insère** — le signal se résout brièvement dans le logo Seuil.

Les transitions courantes de l’application utilisent 180 à 320 ms. Le preflight assume une chorégraphie plus expressive de 620 à 820 ms parce qu’elle raconte le fonctionnement du produit. Il ne remplace plus une carte par une autre : deux panneaux sémantiques, le logo Seuil, le signal, les textes et le curseur de progression sont des éléments partagés. Leurs dimensions et positions se transforment continûment entre les actes. Le grand panneau se contracte brièvement vers un noyau arrondi, puis se redéploie dans la composition suivante ; le sens du mouvement s’inverse avec la navigation arrière.

Le prototype utilise la View Transitions API pour cette continuité et conserve l’ancienne transition CSS comme fallback. L’intégration SwiftUI devra reproduire le principe avec `matchedGeometryEffect` ou une primitive équivalente, sans figer les valeurs du prototype si les mesures natives demandent un autre réglage. Le dither agit comme matière de liaison : convergence pour la transformation, orbite pour les accès, transfert entre les moteurs, amplitude vocale pendant le maintien, puis résolution concentrique dans le logo. Son rendu temps réel est suspendu pendant le morph, car les instantanés animés suffisent et évitent du travail GPU inutile.

Les boutons se contractent à 0,96 à l’appui. Les confirmations d’icônes utilisent une seule arrivée nette, de 0,25 à 1 avec un flou de 4 px à 0. Le curseur de progression glisse comme une capsule continue au lieu d’allumer des segments indépendants. Les transitions peuvent être interrompues et repartir vers la nouvelle destination. Le mouvement est supprimé avec `Reduce Motion`, et le dither ne doit pas tourner en continu dans les écrans statiques hors état vivant ou preflight.

## Contrats d’implémentation

- Minimum de fenêtre visé : 820 × 620 px. L’action, l’état et les informations essentielles de chaque destination tiennent sans défilement ; seul un historique volontairement détaillé peut prolonger la page.
- Toutes les cibles interactives font au moins 40 × 40 px ; les actions principales visent 44 px.
- Focus clavier visible en cobalt ; contraste du texte préservé sur ivoire et porcelaine.
- Outfit, les icônes et les effets restent embarqués localement.
- Les animations ne doivent jamais bloquer l’insertion, le preflight ou la vérification des permissions.
- L’historique reste opt-in et local ; aucune interface de connexion n’est introduite.

## Ordre d’intégration SwiftUI proposé

1. Installer les tokens, Outfit, les logos et les composants de base, puis vérifier les états clair, focus et Reduce Motion.
2. Remplacer le shell et la navigation, puis porter le preflight sans changer ses garanties système.
3. Porter Aujourd’hui, Dictée, Insights, Bibliothèque et Réglages sur les données existantes.
4. Ajouter la destination Réunions comme aperçu désactivé, prête à recevoir les futurs modèles de données.
5. Ajouter le dither Metal/Canvas et les transitions d’état après validation fonctionnelle des écrans statiques.

## Prototype et vérification

- Ouvrir `signal-editorial-prototype/index.html` dans un navigateur pour changer d’écran et tester les états.
- Générer les captures avec `render.cjs`.
- Enregistrer le parcours animé avec `render-preflight-motion.cjs` ; la sortie de référence est `../renders/preflight-motion-demo.mp4`.
- Lancer `validate.cjs` pour vérifier le routage, les interactions principales, Outfit, les cibles de 40 px et l’absence de débordement horizontal ou vertical requis aux deux tailles de référence.

La prochaine décision de marque est simple : confirmer A · Seuil, ou sélectionner B · Portail / C · Grain avant de produire les assets SwiftUI définitifs.
