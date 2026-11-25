# ADR-0008 — Modèles externes avec manifeste épinglé et vérifié

- Statut : acceptée
- Date : 2026-07-22

## Contexte

Les poids dépassent plusieurs gigaoctets et ne doivent pas être inclus dans Git ni dans le bundle.
Les dépôts officiels publient les poids source, mais pas les deux formats natifs attendus par VoxoL.
Une conversion communautaire ne doit pas être présentée comme un artefact officiel.

## Décision

Le manifeste distingue l'identité du modèle officiel de celle du fournisseur de sa conversion. Les
deux révisions sont des commits immuables et chaque URL de téléchargement doit appartenir exactement
au dépôt fournisseur déclaré :

- Parakeet utilise la conversion Core ML `arhesstide/voxol-parakeet-tdt-0.6b-v3-coreml`, épinglée
  au commit `8ff3f781af07b2a186317babf73d13c171295c91`, pour le modèle officiel
  `nvidia/parakeet-tdt-0.6b-v3` ;
- Qwen utilise la conversion 4-bit `mlx-community/Qwen3.5-0.8B-4bit`, épinglée au commit
  `da28692b5f139cb0ec58a356b437486b7dac7462`, pour le modèle officiel `Qwen/Qwen3.5-0.8B`.

Le téléchargement ne démarre qu'après une action explicite. La taille exacte et le SHA-256 de
chaque fichier sont vérifiés dans un répertoire temporaire avant activation atomique. Parakeet est
ensuite compilé et chargé par Core ML et Qwen par MLX.

Les octets reçus sont écrits dans un fichier `.partial` rattaché aux deux révisions épinglées. Une
pause conserve ce fichier et une reprise utilise une requête HTTP `Range` ; une fermeture inattendue
de l'application reprend automatiquement au prochain lancement, tandis qu'une pause explicite reste
en pause. Les contrôles de taille et de SHA-256 restent l'autorité avant toute activation.

Le manifeste est une ressource du bundle et bénéficie donc de la signature de code de l'application.
VoxoL n'accepte pas de manifeste distant mutable ; si des mises à jour distantes sont ajoutées, elles
devront avoir leur propre signature détachée et une politique de rotation de clés documentée.

## Conséquences

Hugging Face héberge les fichiers mais n'exécute aucune inférence : la dictée elle-même n'effectue
aucun appel réseau. L'application en fait trois autres, documentés dans `PRIVACY.md` : la
vérification des mises à jour, leur téléchargement accepté par l'utilisateur et le modèle de
diarisation des réunions. Les fournisseurs des conversions et leurs licences figurent dans
`THIRD_PARTY_NOTICES.md`. Remplacer une conversion exige une nouvelle ADR, des tests de parité et de
performance, et la publication de nouveaux checksums.
