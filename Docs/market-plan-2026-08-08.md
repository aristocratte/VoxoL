# Plan : être le meilleur du marché

Établi le 2026-08-08, sur les mesures de la campagne complète (31 benchmarks
clusterisés, audit externe intégré, retours d'usage réel).

## Le constat qui structure tout

| fait mesuré | conséquence |
| --- | --- |
| 14 V / 6 D / 11 nuls contre Wispr Flow ; **parole réelle : 13 gagnées, 0 perdue sur 15** | la guerre ASR est gagnée là où on dicte |
| les 6 défaites : prose lue studio + un livre audio, marges < 2,2 pts | on ne les poursuit pas ; on les publie |
| 28,3× plus rapide (115 ms vs 3 261 ms), 100 % local | avantage structurel incopiable |
| benchmark « excellent » vs usage réel « affreux » (nombres, béquilles, vocab technique) | **le produit se joue hors benchmark** |
| Wispr sur-génère sur l'audio court (2× nos insertions < 10 mots) | sa faiblesse est mécanique, documentable |

Donc : priorité au produit, chaque amélioration mesurée contre **votre** dictée,
plus jamais contre FLEURS seul.

## Pilier A — La boucle de vérité (semaine 1)

Sans référence sur la dictée réelle, tout le reste est à l'aveugle.

- **A1. Capture de corrections dans l'app** : quand vous corrigez un texte
  inséré, la paire (sortie, correction) est journalisée en local, opt-in,
  mode privé respecté. Chaque usage construit le benchmark personnel.
- **A2. Benchmark personnel** : audio brut + texte voulu, scoré avec le
  harnais existant, ponctuation et chiffres **comptés** (contrairement aux
  corpus publics). C'est LA métrique du produit.
- **A3. Journal ombre déjà actif** (`repair-shadow.jsonl`) : après ~2 semaines
  d'usage, décision chiffrée sur la réparation par dictionnaire.
- **A4. git init + commit + CI** (219 tests + assertions benchmark). Zéro
  commit aujourd'hui : risque maximal, coût nul.

**Gate A : le benchmark personnel existe et tourne en une commande.**

## Pilier B — Le français technique (semaines 1–3)

Le trou que l'usage réel a exposé et qu'aucun corpus ne mesure :
`edited→élite`, `chipset→chip set`, `Ro→raw`.

- **B1. Dictionnaire amorcé** : pack de départ (votre stack), ajout en un clic
  depuis une correction capturée (A1).
- **B2. Boost trie mesuré sur vocabulaire réel** — le mécanisme est sûr
  (plus le −0,67 pt du boost plat), son gain sur *votre* vocab reste à prouver.
- **B3. Mini-benchmark code-switching fr/en** tiré de vos dictées.
- **B4. Redécodage contraint sur l'audio** pour les cas hors de portée du
  texte (`Ro→raw`) : candidats du dictionnaire rescorés sur les trames
  audio. C'est la fonctionnalité de fond à construire — le cloud ne peut pas
  la copier à coût égal. Déploiement : ombre → suggestion → auto seulement
  sous seuil de fausses substitutions prouvé (< 1/1000).

**Gate B : sur le benchmark personnel, les termes techniques passent de
« souvent faux » à « corrects », zéro dégât collatéral mesuré.**

## Pilier C — L'expérience « meilleur » (semaines 2–5)

- **C1. Contexte d'app vérifié de bout en bout** : bundleId/selectedText
  alimentent déjà la préparation — vérifier la capture réelle par app,
  profils par destination (Mail soigné, Cursor code).
- **C2. Profils de ton** (l'équivalent local du « context » de Wispr),
  toujours sous FidelityValidator.
- **C3. Budget latence perçue** : p95 de bout en bout (insertion incluse),
  cible < 400 ms court, < 1,5 s long avec nettoyage complet. Démarrage à
  froid audité.
- **C4. Long-form > 30 s** : mesurer sur vos vraies dictées longues.
- **C5. Suite de robustesse au bruit** (20/10/5 dB SNR) : la condition réelle
  de la dictée, là où on gagne déjà — et le graphe le plus vendeur du site.
  Local, autonome, je peux la lancer seul.

**Gate C : latence p95 tenue + bruit publié + contexte démontré sur 3 apps.**

## Pilier D — La distribution qui transforme « bon » en « gagnant » (semaines 3–6)

Le pari open source (votre choix) devient l'arme : personne d'autre ne peut
dire « vérifiez vous-même ».

- **D1. v0.1.0 notariée** — bloqué par : certificat Apple + 6 secrets GitHub + tag.
- **D2. Sparkle** dès la clé EdDSA.
- **D3. Page résultats publique** générée depuis `benchmark-final-verdicts.json` :
  intervalles clusterisés, **défaites incluses**, reproductible en 4 commandes.
  « 14/6/11, 28× plus rapide, 0 octet envoyé » — et on publie nos pertes,
  ce qu'aucun concurrent ne fait.
- **D4. README + site** : privé par construction, mesuré honnêtement, extensible.

**Gate D : un inconnu installe, dicte en français technique, et ça marche.**

## Le cimetière — ce qu'on ne refait pas

| piste | verdict mesuré |
| --- | --- |
| distillation Wispr | +0,003 pt sur ses propres langues |
| fusion LM / faisceau | le LM préfère l'erreur dans 77–97 % des cas |
| échange canary-1b | 3/8 cellules, runtime à réécrire, latence détruite |
| données nl/de/pl | ces langues gagnent déjà la parole réelle |
| courir après FLEURS | domaine où personne ne dicte ; on documente, point |
| réparation LLM libre | 0 réparation, précision du signal 23 % |

## Backlog v2 (déclencheurs explicites)

Mode réunion (après mesure AMI), mode commande, dictionnaire auto-alimenté
(après A1 ; les suggestions viennent des corrections), langues au-delà de
fr/en (après demande utilisateurs).

## Ce qui n'attend que le propriétaire

1. Révoquer le token HF exposé.
2. Un mot d'accord pour `git init` + commit initial.
3. Certificat Apple + 6 secrets → v0.1.0.
4. Utiliser l'app avec la capture A1 — chaque dictée corrigée nourrit tout le reste.
