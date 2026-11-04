# YouTube → MP3 → ChatGPT

Petit outil local, indépendant des collectes Wispr et de l’application VoxoL installée.

## Utilisation

Double-cliquer sur `Scripts/YouTube-MP3.command`, ou lancer depuis le dépôt :

```sh
python3 Scripts/youtube_mp3_ui.py
```

1. Coller plusieurs liens de **vidéos** YouTube, un par ligne, puis choisir **Lancer les téléchargements**.
2. Trois vidéos sont traitées simultanément ; les suivantes restent en attente. La page affiche pour chaque vidéo les octets téléchargés, le pourcentage, la vitesse et le temps restant quand YouTube fournit ces valeurs. La conversion et la vérification ont une animation sans pourcentage inventé.
3. Les MP3 sont déjà enregistrés dans `/Volumes/0_Oueillez/VoxoL-YouTube/mp3/`. Ouvrir ChatGPT et joindre directement le MP3 du SSD via le bouton **+**, puis utiliser **Copier la consigne**. **Copier le chemin** facilite la sélection du fichier.

Le bouton **Ouvrir ChatGPT** ouvre le site ; il ne joint pas automatiquement le fichier. Codex peut effectuer cette étape dans `@navigateur` quand l’envoi lui est demandé. La consigne demande un **fichier JSON UTF-8 téléchargeable** : transcription mot à mot, correction minimale, passages incertains et bilan des contrôles. Enregistrer le JSON sur le SSD à côté de l’audio.

Avant de livrer, ChatGPT doit réécouter le début et la fin, vérifier que `cleaned` préserve les noms/chiffres/négations du `verbatim`, puis rouvrir le fichier avec un parseur JSON et contrôler les champs/types. Un contrôle impossible doit porter `not_checked`. `human_gold` et `training_included` restent `false`. Le bilan est une déclaration du modèle : un JSON valide et un autocontrôle ne prouvent pas la fidélité à l’audio. Vérifier les annotations à l’écoute avant toute utilisation pour l’entraînement. Pour le pilote, privilégier un seul extrait de 30–60 secondes par demande.

Garder le lanceur ouvert pendant l’utilisation. Pour afficher la page uniquement dans le navigateur intégré Codex, démarrer avec `--no-open`, puis y ouvrir l’URL affichée. `--port`, `--out-dir` et `--workers` (1 à 4, défaut 3) sont facultatifs. Le lanceur utilise le SSD `0_Oueillez` par défaut.

## Contrôle du navigateur — 9 octobre 2026

Le module historique `browser-use/0.1.0-alpha1` affichait « No Codex IAB
backends were discovered » avec l'application actuelle. Le module fourni
avec la version `26.1007.21159` utilise le service du Node REPL et rétablit
le contrôle de l'onglet connecté, avec les pièces jointes :

```js
const { setupBrowserRuntime } = await import('/Users/aris/.codex/plugins/cache/openai-bundled/browser/26.1007.21159/scripts/browser-client.mjs');
const agent = await setupBrowserRuntime({ environment: 'codex-app' });
const browser = await agent.browsers.get('iab');
console.log(await browser.tabs.list());
```

Exécuter ce code dans le Node REPL de l'application, puis suivre la
documentation du navigateur sélectionné. Utiliser le module correspondant
à la version installée lors d'une mise à jour. La réparation ne modifie pas
l'application et ne nécessite aucune extraction de cookies.

Les identifiants numériques des navigateurs peuvent changer après une
réinitialisation du Node REPL. Utiliser le sélecteur `iab`, puis retrouver
les onglets par les URL de conversations enregistrées. Les attentes
`filechooser` et `download` doivent avoir un gestionnaire de rejet dès leur
création : un téléchargement expiré sans gestionnaire a réinitialisé le
REPL pendant ce lot, puis les conversations existantes ont été reprises.

Pour récupérer le JSON affiché, utiliser `getByRole('code')` : certains
blocs visibles ne sont pas des éléments HTML `<code>`. Demander le JSON
complet dans un bloc de code en complément du fichier évite une demande
d'export supplémentaire. Vérifier le nom du WAV joint avant l'envoi et
celui du fichier dans le message envoyé. Préparer les pièces jointes et
envoyer les messages successivement ; les analyses peuvent ensuite tourner
en parallèle. Tout brouillon restauré qui ne correspond pas à une consigne
créée pour le lot arrête la file pour inspection.

## Fonctionnement

- Dépendances : Python 3, `yt-dlp`, `ffmpeg`, `ffprobe`. Elles sont déjà présentes sur le Mac utilisé pour le développement. Installation éventuelle : `brew install yt-dlp ffmpeg`.
- Utilise `yt-dlp` avec sa progression JSON, et les helpers de validation audio/provenance de `wispr_youtube_batch.py`, sans requête Wispr.
- Jusqu’à 100 liens dans la file ; doublons normalisés et ignorés, MP3 déjà valides réutilisés. Les liens `watch` comportant une playlist sélectionnent uniquement la vidéo. Une erreur est isolée à sa vidéo ; le bouton **Réessayer** relance ce lien.
- MP3, fichiers intermédiaires, `TMPDIR` et cache `yt-dlp` restent sous `/Volumes/0_Oueillez/VoxoL-YouTube/`. Le SSD doit être monté ; aucune création de dossier de remplacement sur le Mac si le disque est absent. L’interface signale une déconnexion. Un `--out-dir` explicitement choisi permet une autre destination.
- Un fichier `.source.json` conserve l’URL et le SHA-256 audio. La consigne reste dans `.prompt.txt` ; elle est mise à jour au relancement pour les MP3 déjà prêts. `jobs.json` conserve la file ; les fichiers prêts sont restaurés au prochain lancement et les travaux interrompus sont signalés pour reprise. Les écritures de manifeste sont sérialisées pour éviter la perte d’un résultat simultané.
- Serveur limité à `127.0.0.1`, session locale pour les commandes, aucun secret OpenAI ni extraction de cookies.
- Un MP3 dépassant 512 Mo est conservé mais signalé trop volumineux pour ce parcours ChatGPT.
- Les annotations obtenues sont automatiques ; cet outil ne les ajoute à aucun jeu d’entraînement et ne les valide pas comme références humaines.

## Vérification

```sh
python3 -m unittest discover -s Scripts -p 'test_youtube_mp3_ui.py'
```

Les tests couvrent la sélection des vidéos, les trois workers et la file d’attente, la progression réelle, les doublons, les reprises, les échecs isolés, la protection en cas de SSD absent/débranché, l’intégrité du MP3 et l’accès HTTP aux seuls fichiers produits.

Le 6 octobre 2026, le parcours complet a été vérifié dans le navigateur intégré Codex : vidéo YouTube `jNQXAC9IVRw` → MP3 de 19 secondes téléchargé depuis la page → fichier joint à ChatGPT → réponse JSON reçue. Les 8 tests ont passé. Le SHA-256 du téléchargement navigateur correspond au cache ; la qualité de l’annotation n’a pas été auditée.

Les captures, la réponse et le manifeste du test sont dans `outputs/youtube-mp3-chatgpt-verification-20261007T055012Z/`.

## Vérification du lot sur SSD — 7 octobre 2026

15 tests réussis. Trois vidéos réelles (`jNQXAC9IVRw`, `aqz-KE-bpKQ`, `YE7VzlLtp-4`) ont été téléchargées en parallèle depuis la page. Les trois intervalles se chevauchent ; les MP3, hashes et octets de progression ont été contrôlés. Copie du chemin/consigne et ignorance d’un lien équivalent vérifiées. Les captures et le manifeste sont dans `/Volumes/0_Oueillez/VoxoL-YouTube/verification/2026-10-07-batch/`. La déconnexion du SSD a été simulée dans les tests, sans démonter le disque réel.

## Test du fichier JSON — 7 octobre 2026

La nouvelle consigne et sa copie dans le navigateur ont été vérifiées ; les 19 MP3 prêts ont reçu la mise à jour sans téléchargement supplémentaire. Les 15 tests passent, dont la migration des anciennes consignes.

ChatGPT a créé un fichier JSON dans la conversation de l’extrait de 30 secondes `Wpc8I2f37gs-tail30`. Dans cette tentative, il n’a pas pu réinterpréter la parole : les contrôles audio sont `not_checked`. Une seconde demande a exporté la transcription automatique précédente avec une provenance explicite et `complete=false`. Le contenu a été récupéré depuis l’aperçu du fichier, car les commandes de téléchargement n’ont pas abouti dans le navigateur intégré. Syntaxe, champs/types et identité avec la transcription précédente vérifiés localement ; aucune validation humaine ou nouvelle vérification auditive.

JSON, contrôles et capture : `/Volumes/0_Oueillez/VoxoL-YouTube/annotations/json-file-pilot-20261007T203604Z/`.

## Collecte automatique vérifiée — 9–10 octobre 2026

48 WAV ont été joints dans 48 conversations ChatGPT et les 48 JSON sont
récupérés sur le SSD : 24 fichiers téléchargés et 24 blocs JSON complets
lus depuis les réponses. Le format, les identifiants, les empreintes, les
durées WAV et les noms des 48 pièces jointes envoyées ont été contrôlés.
Les splits d'origine restent 32 train, 8 validation et 8 test.

Les réponses déclarent toutes un accès direct à l'audio et une couverture
complète. Ce sont des déclarations du modèle, sans validation auditive
indépendante. 97 passages incertains sont signalés dans 46 extraits.
`human_gold`, `humanReviewed` et `training_included` restent `false`.
Aucun entraînement n'a été lancé.

Résultats individuels, JSONL regroupé, comparaison VoxoL/Wispr, incertitudes,
manifeste et captures :
`/Volumes/0_Oueillez/VoxoL-Artifacts/Training/asr-champion-pilot-20261010T031910Z-a81ed485/chatgpt-review/`.
`automation-recipe.js` conserve les fonctions de la session Node REPL ;
`finalize_collection.py` vérifie et regroupe le lot terminé.
