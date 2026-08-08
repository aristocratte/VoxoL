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
  au commit `8ff3f781af07b2a186317babf73d13c171295c91`. Depuis le 2026-08-05, VoxoL publie sa
  propre conversion au lieu de consommer celle d'un tiers : l'encodeur livré porte le fine-tune
  français/anglais, et le paquet embarque `language-penalty.json`, que la conversion amont n'a
  aucune raison de contenir ;
- Qwen utilise la conversion affine 4-bit `bobkitchen/Qwen3.5-4B-Text-4bit`, épinglée au commit
  `bbad837ea6c860d8258fdee0cf31ed48165d64fd`. Son index ne contient que des poids
  `language_model.*` et aucun poids d'encodeur visuel.

Le téléchargement ne démarre qu'après une action explicite. La taille exacte et le SHA-256 de
chaque fichier sont vérifiés dans un répertoire temporaire avant activation atomique. Parakeet est
ensuite compilé et chargé par Core ML. Qwen passe une validation locale de format, de quantification
et d'absence de poids vision ; le vrai chargement MLX reste une gate de l'intégration runtime.

Les octets reçus sont écrits dans un fichier `.partial` rattaché aux deux révisions épinglées. Une
pause conserve ce fichier et une reprise utilise une requête HTTP `Range` ; une fermeture inattendue
de l'application reprend automatiquement au prochain lancement, tandis qu'une pause explicite reste
en pause. Les contrôles de taille et de SHA-256 restent l'autorité avant toute activation.

Le manifeste est une ressource du bundle et bénéficie donc de la signature de code de l'application.
VoxoL n'accepte pas de manifeste distant mutable ; si des mises à jour distantes sont ajoutées, elles
devront avoir leur propre signature détachée et une politique de rotation de clés documentée.

## Conséquences

Hugging Face héberge les fichiers mais n'exécute aucune inférence : après installation, la dictée
reste locale et n'effectue aucun appel réseau. Les fournisseurs communautaires et leurs licences
sont visibles dans l'interface et dans `THIRD_PARTY_NOTICES.md`. Une future conversion publiée par
VoxoL pourra les remplacer seulement après une nouvelle ADR, des tests de parité et de performance,
et la publication de nouveaux checksums.
