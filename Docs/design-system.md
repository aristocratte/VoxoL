# VoxoL design system

## Direction

VoxoL doit paraître calme, premium et discret. L'interface est claire en premier lieu, presque
monochrome et légèrement chaude. Elle utilise la couleur pour transmettre un état réel, jamais
pour décorer ou distinguer artificiellement les fonctionnalités.

Le système privilégie les composants macOS natifs, la typographie système, les raccourcis clavier
et une hiérarchie spatiale stable. Les surfaces chaudes donnent une identité propre sans imiter la
palette de Wispr Flow ni transformer VoxoL en application de bien-être.

## Couleurs sémantiques

| Token | Clair | Sombre | Usage |
| --- | --- | --- | --- |
| `canvas` | `#F4F0E8` | `#191816` | Fond principal |
| `surface` | `#FCFBF8` | `#22201D` | Cartes et sidebar |
| `raisedSurface` | `#FFFFFF` | `#292621` | Popovers et surfaces élevées |
| `ink` | `#1B1A18` | `#F5F1E9` | Texte et actions principales |
| `secondaryInk` | `#6F6B64` | `#B8B1A6` | Texte secondaire |
| `line` | `#DCD7CE` | `#3A3631` | Séparateurs et bordures |
| `selection` | `#E8E2D8` | `#34302B` | Sélection et survol persistants |
| `recording` | `#C84D45` | `#E06A62` | Capture active uniquement |
| `warning` | `#A66B20` | `#D39A4A` | Attention et action requise |
| `success` | `#4D7A5B` | `#71A27F` | Résultat confirmé |

Le noir pur et le blanc optique sont évités pour les grandes surfaces. Les couleurs d'état ne
doivent jamais être le seul moyen de transmettre une information : elles sont toujours associées
à un libellé ou un symbole.

## Typographie

- SF Pro via les styles SwiftUI système pour toute l'interface.
- SF Mono via `.monospaced()` pour les raccourcis, durées, identifiants et métriques.
- Titre produit : 34 points, semibold.
- Titre d'écran : 28 points, semibold.
- Titre de carte : 15 points, semibold.
- Corps : 14 points, regular.
- Légende : 12 points, medium ou regular selon le contraste.

Les tailles système restent adaptables. Les titres ne portent pas toute la hiérarchie : espace,
alignement et largeur de ligne participent au rythme.

## Espace, forme et élévation

- Grille : 4, 8, 12, 16, 24, 32 et 48 points.
- Rayon compact : 10 points.
- Rayon de carte : 14 points.
- Rayon de scène : 20 points.
- Capsule : rayon continu égal à la moitié de sa hauteur.
- Bordures : 1 point maximum.
- Ombres : diffuses et très faibles, réservées aux fenêtres flottantes.
- Transparence : capsule et popovers seulement ; aucun empilement de matériaux dans le Hub.

La fenêtre principale vise 1120 × 760 points et reste utilisable à partir de 820 × 600 points.
Les pages limitent leur contenu à environ 960 points de largeur pour conserver des lignes lisibles.

## Mouvement

- Réponse au raccourci : objectif perceptif inférieur à 100 ms.
- Transition de contrôle : 140 ms.
- Transition de carte ou de navigation : 180 ms.
- Morphing de capsule : 220 ms maximum.
- Aucun spinner ou libellé d'étape pour une opération achevée en moins de 180 ms.
- Les animations sont interruptibles et remplacées par des fondus si Réduire les animations est
  activé.
- Aucune animation permanente dans le Hub. La forme d'onde est limitée à une fréquence visuelle
  raisonnable pendant une capture réelle.

## Composants fondamentaux

### Marque

Deux courbes vocales convergent vers un curseur vertical, puis trois traits courts évoquent le
texte produit. La marque reste plane, monochrome et lisible à 16 points dans la barre des menus ;
elle n'utilise ni lettre, ni microphone, ni contenant décoratif.

### Carte

Une carte utilise `surface`, une bordure `line`, un rayon de 14 points et au moins 16 points de
padding. Elle contient une intention cohérente, pas une collection arbitraire de métriques.

### Bouton principal

Le bouton principal utilise `ink` avec un libellé de couleur `surface`. Une page ne présente qu'une
action principale. Les actions secondaires utilisent les styles macOS natifs.

### Capsule vocale

La capsule est un `NSPanel` non focalisable de 48 points de haut. Sa largeur morph entre 48 et 198
points selon l'information utile. Ses états sont `listening`, `speechDetected`, `transcribing`,
`polishing`, `inserting`, `success`, `copiedFallback`, `noSpeech` et `error`; les erreurs distinguent
microphone, modèles, transcription et insertion.

### Studio de fonctionnalité

Chaque studio contient : un titre et une promesse, un showcase interactif, trois ou quatre réglages
essentiels et une explication locale/confidentielle. Les options expertes utilisent une divulgation
progressive au lieu d'un second produit destiné aux professionnels.

## Accessibilité et localisation

- Français et anglais sont conçus simultanément ; aucun libellé n'est dimensionné uniquement pour
  l'anglais.
- Les commandes essentielles ont un équivalent clavier et un label VoiceOver.
- Les états respectent Augmenter le contraste, Réduire la transparence et Réduire les animations.
- Les zones interactives mesurent au moins 28 points sur macOS et conservent un focus clavier
  visible.
- Les informations confidentielles ne sont jamais nécessaires aux previews, tests ou diagnostics.
