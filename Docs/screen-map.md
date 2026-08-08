# VoxoL screen map

## Principes de navigation

VoxoL utilise trois surfaces complémentaires : un Preflight linéaire pour les prérequis, une
capsule flottante pour l'action quotidienne et un Hub librement navigable pour découvrir,
configurer et vérifier les fonctionnalités.

```text
Premier lancement
└── Preflight
    ├── Welcome
    ├── Local by design
    ├── Permissions
    ├── Shortcut and engines
    ├── First flight
    └── Ready

Usage quotidien
├── Global shortcut
│   └── Voice capsule
│       └── Inserted text or actionable fallback
├── Menu bar
│   ├── Current state
│   ├── Private mode
│   ├── Preview capsule
│   └── Open VoxoL
└── Hub
    ├── Workspace
    │   ├── Home
    │   ├── Dictation
    │   └── Meetings — Coming soon
    ├── Personalize
    │   ├── Context
    │   ├── Dictionary
    │   ├── Snippets
    │   ├── Styles and app profiles
    │   └── Commands — Planned
    ├── Review
    │   └── History
    └── System
        └── Privacy and performance
```

## Preflight

Le parcours obligatoire se limite aux dépendances réelles. Les showcases complets restent
accessibles ensuite dans le Hub.

1. **Welcome** — marque, promesse et choix de langue.
2. **Local by design** — deux moteurs locaux, aucune donnée de dictée envoyée et historique
   désactivé par défaut.
3. **Permissions** — microphone, Accessibility et Input Monitoring expliqués puis demandés via les
   APIs macOS, avec suivi en direct de leur état.
4. **Shortcut and engines** — raccourci global et installateur réel : progression par octets,
   annulation, vérification SHA-256, erreur et reprise.
5. **First flight** — champ factice et aperçu de la capsule sans injection dans une autre app.
6. **Ready** — trois gestes essentiels et entrée dans le Hub.

Les permissions déclenchent de vraies demandes système. L'installateur ne s'active que pour un
artefact `ready` doté d'une URL HTTPS, d'une taille exacte et d'une somme SHA-256 ; les artefacts
actuels restent donc clairement marqués comme non publiés.

## Hub

### Home

Présente les mots dictés, le débit moyen, le nombre de sessions, le temps de parole et une activité
sur sept jours. Les résultats conservés affichent date, heure et app source ; le survol et le menu
contextuel permettent de copier, restaurer la révision précédente ou exporter un audio réellement
conservé. Les données d'exemple du build Debug sont explicitement étiquetées et jamais persistées.

### Dictation

Showcase avant/après, choix Push-to-talk ou Toggle-to-talk, mode Faithful ou Raw, langue et aperçu
de la capsule. Le chemin chaud reste indépendant de cette fenêtre.

### Context

Explique les limites exactes : application active, domaine éventuel et texte borné autour du
curseur. Les profils Mail, Messages, Documents et Developer peuvent être prévisualisés sans lire
le contenu réel de l'écran.

### Dictionary

Liste locale, recherche, forme canonique, variantes entendues et applications concernées. Le
prototype utilise uniquement des exemples non personnels.

### Snippets

Déclencheur vocal, expansion et aperçu d'insertion. Les conflits avec le dictionnaire sont signalés
avant l'enregistrement.

### Styles and app profiles

Compare une phrase dans les profils Faithful, Concise et Structured, puis montre leur affectation
à des catégories d'applications. Toute transformation reste bornée par la conservation du sens.

### Commands

Page de prévisualisation post-MVP. Elle sépare visuellement une commande d'une dictée et exige un
aperçu avant toute modification destructive.

### History

Archive locale recherchable, politique de rétention et récupération de la révision précédente.
L'activation de l'historique est explicite ; aucun fichier audio n'est créé par le parcours de
capture actuel.

### Meetings

Page accessible `Coming soon`, sans contrôle mort. Elle présente le futur flux : sélection d'une
source, capture locale, marqueurs, puis Summary, Decisions, Actions et Transcript. La première
version ne promet aucune attribution nominative des intervenants.

### Privacy and performance

Regroupe mode privé, historique, contexte, état des deux moteurs, budgets de latence et diagnostics
sans contenu. Les détails techniques utilisent une divulgation progressive.

## Capsule

```text
Hidden → Listening → Speech detected → Transcribing → Polishing → Inserting → Success → Hidden
              └────→ No speech                 └────→ Copied fallback or typed Error
```

La capsule est précréée, non focalisable et attachée à tous les Spaces. Elle ne montre une étape de
traitement que si celle-ci dure assez longtemps pour être perçue. `Escape` annule une capture ; le
fallback d'insertion conserve puis restaure tous les types du presse-papiers si l'utilisateur ne
l'a pas modifié entre-temps.

## État du prototype

L'application valide la navigation, la localisation, l'identité, les demandes de permissions, le
contrat d'installation et l'historique local. Elle capture maintenant le micro avec `⌥ Espace`,
détecte la parole sans terminer elle-même le push-to-talk et insère un texte de test avec
`⌥ ⇧ Espace`. Elle n'exécute pas encore les modèles : l'installateur reste bloqué par conception
tant que les artefacts CoreML et MLX vérifiés ne sont pas publiés.
