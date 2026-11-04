# Collecter des transcriptions Wispr depuis YouTube

Depuis la racine du dépôt, lancer l'interface locale :

```sh
bash Scripts/wispr-transcribe.sh --ui
```

Une page s'ouvre sur `127.0.0.1`. Coller les liens de vidéos ou de playlists, puis cliquer sur **Démarrer la collecte**. Les listes avec puces ou liens Markdown sont acceptées ; les vidéos en double sont traitées une seule fois. Trois vidéos sont traitées en parallèle par défaut. L'interface affiche une heure estimée de fin du passage à partir des segments terminés ; elle reste provisoire tant que certaines durées vidéo sont inconnues ou que des segments sont en échec. Ces segments doivent être relancés pour obtenir une transcription complète. Le bouton **Arrêter** interrompt le traitement en conservant l'état. **Reprendre la dernière collecte** retente les vidéos et les segments manquants. Garder le processus de l'interface lancé tant qu'on veut utiliser les boutons ; fermer seulement l'onglet du navigateur ne coupe pas la collecte.

La même collecte fonctionne sans interface :

```sh
bash Scripts/wispr-transcribe.sh --urls-file /chemin/vers/liens.txt
pbpaste | bash Scripts/wispr-transcribe.sh --urls-stdin
bash Scripts/wispr-transcribe.sh --resume
bash Scripts/wispr-transcribe.sh --resume --parallel 4
```

Les liens peuvent aussi être passés directement en arguments. Une playlist est développée en vidéos individuelles. Les vidéos indisponibles ou refusées par YouTube restent signalées en échec dans le journal ; les autres continuent. Relancer après avoir résolu la cause retente uniquement ce qui manque. Le collecteur exige `yt-dlp`, `ffmpeg`, `ffprobe`, `jq`, `curl`, Python 3 et une session ouverte dans Wispr Flow. Il utilise la session de l'application installée ; aucune clé API n'est à coller dans la page.

Par défaut, les fichiers sont sous `~/Documents/wispr/transcripts` :

- `youtube-jobs/` : listes collées, état de la collecte et journal ;
- `youtube-audio/` : audio téléchargé et provenance YouTube ;
- `dataset/records/` : audio découpé, états des segments et transcriptions ;
- `dataset/dataset-summary.json` et les fichiers `*manifest.jsonl` : vues consolidées.

On peut changer le dossier avec `WISPR_OUT_DIR=/chemin/vers/sortie`. `--parallel N` accepte de 1 à 8 vidéos pour la CLI ; l'interface utilise trois vidéos à la fois. Les workers partagent `WISPR_MIN_REQUEST_INTERVAL` (0,8 seconde par défaut) entre les démarrages de requêtes Wispr : augmenter le nombre de vidéos ne multiplie pas le débit autorisé vers le service. Une requête Wispr réussie est sauvegardée par segment et par sortie (`raw` ou `edited`) avant de passer à la suivante. La reprise réutilise ces résultats, même après une coupure au milieu d'une vidéo. Les téléchargements mis en cache sont vérifiés par `ffprobe` avant réutilisation ; un fichier invalide est mis de côté et retéléchargé. Ne lancer qu'une collecte YouTube à la fois dans ce dossier.

Ces transcriptions sont des **cibles teacher silver**. Elles ne sont pas des références humaines pour les benchmarks et ne sont pas automatiquement prêtes pour l'entraînement Qwen. Vérifier les droits d'usage des vidéos et séparer les sources d'entraînement des jeux d'évaluation avant toute distillation.

Le lot de 25 vidéos du 24 septembre, son stockage sur SSD et la préparation
expérimentale des manifestes sont décrits dans
[`wispr-youtube-training-prep.md`](wispr-youtube-training-prep.md).
