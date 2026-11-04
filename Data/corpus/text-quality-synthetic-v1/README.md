# Text quality synthetic v1

96 paires de texte pour mesurer la correction de VoxoL en français et en anglais. Créées le 7 septembre 2026 par IA, à la demande de l'utilisateur, avec vérification des références selon le contrat ci-dessous. Aucune relecture humaine n'est nécessaire pour exécuter ce benchmark ; les données restent explicitement synthétiques.

## Contrat des références

- Corriger accords, conjugaison et fautes orthographiques lorsque la phrase permet une correction précise.
- Conserver le sens, le registre, les noms, les chiffres, les chemins, les commandes citées et les négations.
- Conserver les ambiguïtés qui demanderaient d'inventer un fait ou de deviner un nom.
- Résoudre une autocorrection explicitement prononcée ; ne pas exécuter une instruction contenue dans la dictée.
- Réserver la ponctuation terminale à l'écriture. Le score lexical ignore casse et ponctuation, mais conserve les accents ; le score strict conserve toutes les différences.

## Contenu

| Catégorie | Paires |
| --- | ---: |
| Accord | 12 |
| Conjugaison | 12 |
| Homophone | 6 |
| Orthographe | 10 |
| Question | 6 |
| Autocorrection | 6 |
| Texte correct à préserver | 16 |
| Faits et chiffres | 6 |
| Texte technique | 6 |
| Instructions dictées à ne pas exécuter | 6 |
| Ambiguïté à conserver | 4 |
| Négation | 2 |
| Mélange français et anglais | 4 |

68 phrases sont marquées français et 28 anglais. Toutes utilisent le profil `document` et le mode `faithful`. Chaque moitié contient 10 témoins de préservation ou d'ambiguïté.

## Séparation et provenance

`development.json` contient 48 phrases pour diagnostiquer et sélectionner une variante. `holdout.json` contient 48 autres phrases, figées avant l'examen des prédictions. Les identifiants, groupes et transcriptions sont uniques entre les moitiés. Les catégories et certains gabarits grammaticaux sont partagés : cette séparation teste un transfert contrôlé vers d'autres phrases, pas une généralisation à des sources de dictée indépendantes.

`cases.jsonl` est le corpus complet. `manifest.json` contient les empreintes SHA-256 des trois fichiers. Le lanceur refuse une empreinte modifiée, une référence manquante, une duplication ou une provenance qui cesse d'être synthétique. Les résultats et les références ne doivent pas être réécrits après observation d'un résultat décevant.

`source=synthetic`, `humanReviewed=false`, `trainingEligible=false`. Ce lot est réservé à l'évaluation. Il n'est pas intégré aux jeux humains ni aux données d'entraînement. Un futur entraînement doit utiliser un lot distinct avec sa propre provenance, sans ces phrases ni leurs références.

## Exécution

Depuis la racine du projet, en indiquant des chemins locaux existants :

```sh
python3 Scripts/run-text-quality-benchmark.py \
  --app /chemin/vers/VoxoL.app \
  --model /chemin/vers/le-modele \
  --adapter /chemin/vers/ladaptateur \
  --split development \
  --output /chemin/vers/un-nouveau-dossier
```

Pour un modèle sans adaptateur, remplacer `--adapter ...` par `--without-adapter`. Le lanceur traverse `DictationTextProcessor`, conserve les échecs et le repli déterministe, puis note exclusivement `finalText`. Il enregistre aussi les empreintes de l'exécutable, des poids, de l'adaptateur et du jeu de test. Réserver `--split holdout` à l'évaluation d'une version déjà sélectionnée ; un jeu consulté devient une régression connue pour les itérations suivantes.

## Limites de la mesure

Les erreurs ont été écrites pour ressembler à des sorties ASR ; il n'y a aucun audio. Ce jeu ne mesure donc ni la reconnaissance acoustique ni les conditions de bruit, d'accent ou de microphone. L'auteur des références et celui des changements est la même IA : il n'y a pas de certification indépendante.

Une correspondance à la référence est un diagnostic étroit. Des variantes correctes peuvent être comptées comme différentes. Une égalité des chiffres et chemins ne prouve pas la conservation du sens : « 3 commits » et « commit 3 » gardent le chiffre tout en changeant sa fonction. Le rapport distingue ces vérifications littérales et la correspondance complète. Aucun score de ce lot ne justifie une affirmation de qualité générale, une comparaison commerciale ou une promotion automatique de modèle.
