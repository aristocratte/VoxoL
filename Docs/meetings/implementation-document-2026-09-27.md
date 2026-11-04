# Mode Réunion — refonte du document

Implémentation locale du 27 septembre 2026, à partir du plan `refonte-produit-2026-09-27.md`. Les tests dans l’application sont laissés à Aris, conformément à sa demande. L’application installée et les archives réelles n’ont pas été ouvertes ni modifiées par cette intervention.

## Disponible dans le code

- Accueil avec semaine d’agenda, choix des calendriers macOS, historique filtrable, favoris, recherche dans les comptes rendus et classement par projet.
- Association persistante à une occurrence de calendrier ; date réelle de réunion distincte de la date d’import. Le calendrier reste en lecture seule.
- Page de compte rendu avec titre éditable, sommaire issu des sections, surface d’écriture native et volet latéral pour les sources, notes et actions. Le volet devient une feuille dans les fenêtres étroites.
- Édition riche : titres et sous-titres, gras, italique, surlignage, liens, listes à puces ou numérotées, tâches et citations. Copier-coller riche et annuler/rétablir natifs.
- Document sémantique versionné, partagé par l’éditeur et les exports. Migration des anciens brouillons avec conservation du Markdown original et sauvegarde de l’archive v1 avant sa première réécriture.
- Sauvegarde différée avec état affiché, vidage des modifications en attente à la fermeture normale, versions restaurables et état « Relue » explicite.
- Une régénération d’un document existant crée une proposition distincte. La comparaison affiche le document actuel et le nouveau brouillon ; l’acceptation conserve la version précédente.
- Sources liées aux paragraphes, navigation vers la transcription, recherche et lecture audio horodatée. Les modifications du texte signalent les références à revérifier. Un fichier déplacé peut être relié à nouveau.
- Notes personnelles et marqueurs pendant l’enregistrement. Ils restent distincts des propos transcrits. Les captures micro, micro + son du Mac et l’extraction audio des vidéos restent sur leurs chemins existants.
- Actions cochables dans le document et dans le volet latéral. Les responsables et échéances restent dans le texte lorsqu’ils sont exprimés ; il n’y a pas de synchronisation vers un gestionnaire de tâches.
- Export Word avec styles, vrais paragraphes de liste, liens et surlignage ; export PDF par pagination native ; export Markdown avec sources facultatives. Le Markdown conserve le texte surligné, sans représenter sa couleur. Les exports de transcription JSON excluent les bookmarks privés et les notes personnelles.
- Formats de rédaction : compte rendu complet, synthèse courte, note technique et brief de suivi. La préférence est retenue localement. Réécriture d’un paragraphe sourcé : clarifier, raccourcir ou développer, avec proposition avant remplacement.

## Génération locale

La nouvelle voie `document v4` demande des blocs sémantiques et des titres adaptés aux échanges. Elle remplace le contrat de 1 à 3 paragraphes sans mise en forme. Les passages sont indexés sur toute la transcription, avec références stables, déduplication et recherche lexicale.

- Réunion courte : un appel de rédaction, avec un budget de sortie de 1 800 tokens ; synthèse courte : 900 tokens.
- Réunion longue : plan borné à six sujets, puis rédaction par sujet à partir de passages retrouvés dans l’index complet. Chaque section a un budget de 750 tokens. Les sections réussies peuvent être réutilisées lors d’une reprise dans la même session.
- La rédaction longue reste fondée sur des passages sélectionnés : le document l’indique. Ce n’est pas une garantie de couverture exhaustive de tous les thèmes.
- Les références, nombres, citations exactes et certains énoncés de décision/action sont contrôlés. Ces contrôles mécaniques ne prouvent pas la fidélité sémantique de toutes les phrases.
- Une sortie invalide laisse les documents existants intacts et remonte une erreur. Elle n’est plus remplacée dans cette nouvelle voie par un collage de citations présenté comme un compte rendu terminé.

La latence, la mémoire et la qualité éditoriale de cette nouvelle voie n’ont pas été mesurées sur des réunions réelles pendant cette intervention. Aucun gain de performance n’est revendiqué.

## Vérification effectuée

- Compilation complète Debug macOS : `BUILD SUCCEEDED`.
- Formatage Swift strict sur les fichiers de cette refonte : réussi.
- Contrôle des espaces du diff Git pour les fichiers suivis concernés : réussi.
- Aucun lancement de l’application, enregistrement, accès à un calendrier personnel, test fonctionnel, test unitaire ou campagne Qwen pendant cette intervention.

Build : `.bench/meeting-prose-validation/DerivedData/Build/Products/Debug/VoxoL.app`.

Preuves : `.bench/meeting-document-refactor-20260927/build-final.log` et `format.log`. Les instantanés des sources présentes au départ sont conservés dans le sous-dossier `before/`. Les modifications préexistantes du dépôt ont été conservées.

## Pistes du plan encore exploratoires

La comparaison automatique des décisions entre plusieurs réunions, la détection sémantique des contradictions, les documents dérivés nommés et indépendants et les connexions Google/Microsoft directes ne font pas partie de cette première refonte. Les variantes de rédaction sont actuellement des propositions/versions du compte rendu de la réunion. La capture longue et la qualité naturelle des comptes rendus restent à qualifier dans l’application.
