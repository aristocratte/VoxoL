# Réunions VoxoL — interface, capture et analyse Qwen

État du 24 septembre 2026. Travail local ; application installée inchangée.

## Parcours livré dans le code

- Accueil avec enregistrement, import audio/vidéo, agenda et recherche dans les titres, intervenants et transcriptions.
- Transitions courtes, visualisation animée pendant le traitement, étapes audio → transcription → intervenants → compte rendu. Progression déterminée uniquement quand le moteur la fournit ; animation décorative pendant ASR. Préférence de réduction des animations respectée.
- Enregistrement présentiel : microphone, AAC M4A, niveau sonore réel, pause/reprise.
- Enregistrement d'appel : ScreenCaptureKit, micro + son des applications du Mac, deux pistes audio synchronisées dans un conteneur MOV sans piste vidéo. Le son de VoxoL est exclu. Utiliser un casque évite de réenregistrer les haut-parleurs dans le micro. L'accès macOS est demandé au démarrage explicite.
- Fichier de destination choisi avant l'enregistrement. Il reste sur le disque si la transcription échoue ou si la réunion est supprimée. Bouton Terminer : finalisation, puis transcription si les modèles sont disponibles. En cas d'erreur, le fichier peut être révélé dans Finder et réessayé. Arrêt automatique avant la limite d'une heure, puis transcription disponible depuis la carte.
- L'application attend la finalisation du conteneur avant de quitter pendant un enregistrement. Les interruptions et erreurs d'encodage sont affichées.
- Calendrier : lecture locale EventKit après connexion volontaire, rendez-vous des sept prochains jours, actualisation, liens Meet/Teams/Zoom/Webex et titre repris au lancement d'un enregistrement. Trois événements visibles initialement, jusqu'à douze en développant. Comptes configurés dans Calendrier macOS (iCloud, Google, Exchange), pas d'OAuth Google/Microsoft autonome et aucune écriture d'événement.
- Import vidéo : extraction des seules pistes audio et mélange des pistes simultanées. Nettoyage du fichier temporaire en sortie. Vidéo sans audio refusée explicitement ; audio mono-piste conserve le chemin direct sans recompression quand son conteneur est lisible par AVAudioFile.

## Vérifications

- `swift test --filter SpeakerKitTests` : 25 tests passés, dont quatre nouveaux : vidéo deux pistes, vidéo muette, identité des échantillons du chemin audio direct, annulation.
- `python3 Scripts/check-meeting-recording.py` : utilise le writer de production avec PCM synthétique. Deux pistes, zéro vidéo, deux secondes utiles avec une pause de deux secondes supprimée, deux fins de piste décodables. Aucun microphone n'est ouvert par ce test.
- `python3 Scripts/check-meeting-calendar.py` : liens de conférence reconnus, liens non HTTPS, domaines trompeurs et liens locaux exclus. Aucun calendrier réel lu par ce test.
- Build Debug macOS ARM64 effectué avec `CODE_SIGNING_ALLOWED=NO`.
- Inspection native en thème sombre de l'accueil, de la feuille d'enregistrement et des états transcription/intervenants dans un clone isolé de l'app. Données de démonstration et états supplémentaires disponibles uniquement avec `--speaker-preview` et `VOXOL_MEETING_PREVIEW_STATE=transcribing|speakers|reporting` ; aucun enregistrement de ces fixtures dans l'historique.

Restent à qualifier sur les périphériques et comptes de l'utilisateur : autorisations macOS, capture réelle d'une réunion présentielle et d'un appel, changement de périphérique, veille, longue session de plus de trois minutes, agenda réel et parcours complet jusqu'au compte rendu. Les tests de conteneur et le build ne constituent pas cette qualification.

Fixtures médias : deux vidéos noires de 16 × 16 px générées avec FFmpeg ; la première comporte deux sinusoïdes de 440 et 880 Hz sur des pistes séparées, la seconde n'a aucune piste audio. Aucun contenu de réunion réel. Journaux de validation conservés dans `.bench/meetings-ui-validation/evidence/`.

## Avis sur l'optimisation Qwen

Source actuelle : `.bench/daq_mode_comparison.json` et scripts `.bench/compare_daq_modes.py`, `.bench/run_daq_lines.py`. Modèle local Qwen 3.5 4B ; trois répétitions par mode et par cas. Aucune nouvelle campagne d'inférence n'a été réalisée pour cette analyse.

| Lignes restant à classer | JSON groupé, médiane | Étiquette par ligne, médiane | Réduction |
|---|---:|---:|---:|
| 1 | 693 ms | 208 ms | 70,0 % |
| 4 | 1 194 ms | 840 ms | 29,7 % |
| 12 | 2 691 ms | 2 585 ms | 3,9 % |

Le gain vient principalement de la réduction du décodage : une étiquette d/a/q/x par ligne au lieu d'un objet JSON avec des références. Swift reconstruit les références depuis les sources immuables. Le coût du préremplissage s'accumule avec le nombre d'appels : à douze lignes, ~1 818 ms de prompt contre ~698 ms en batch, ce qui absorbe presque tout le gain de génération. Le seuil de quatre lignes est donc un compromis raisonnable sur les cas observés ; les points cinq à onze n'ont pas été mesurés.

Ces durées de classification **excluent** la préparation du modèle et du préfixe. En additionnant les trois étapes mesurées pour chaque exécution, puis en prenant la médiane, on obtient :

| Lignes | Batch + préparations | Par ligne + préparations | Réduction |
|---|---:|---:|---:|
| 1 | 1 981 ms | 1 397 ms | 29,5 % |
| 4 | 2 438 ms | 2 034 ms | 16,6 % |
| 12 | 3 967 ms | 3 817 ms | 3,8 % |

Cette somme est un diagnostic des étapes chronométrées, pas une mesure du démarrage complet du processus ou du parcours UI. Le préchauffage parallèle peut en masquer une partie dans l'application ; il faut le mesurer avant de l'annoncer.

Tous les cas comparés correspondent aux attendus **après sanitation des questions ouvertes**. Les sorties brutes contiennent certaines questions supplémentaires filtrées ensuite : ce n'est pas une preuve de justesse intrinsèque du modèle. L'échantillon est petit, synthétique, les variantes de douze lignes répètent des motifs et le batch précède systématiquement les lignes ; pas d'ordre ABBA, pas de P95 robuste, pas de validation humaine indépendante.

**Recommandation : conserver l'hybride actuel et les contrôles de sources.** Le gain des petits lots est utile et le traitement reste fondé sur la transcription. Prochaine qualification pertinente : vraies réunions FR/EN de longueurs différentes, cas ambigus, contradictions et négations, ordre alterné des méthodes, contrôle humain des omissions et temps total fichier/arrêt → compte rendu. Ne pas réduire le modèle ou élargir le chemin par ligne sur la seule base de ces chiffres.

## Références des API

- Apple, [Accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store).
- Apple, [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) et [captureMicrophone](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone).
