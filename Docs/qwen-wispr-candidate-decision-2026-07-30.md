# Décision Qwen Wispr — 2026-07-30

Le LoRA Qwen3.5-0.8B v6, checkpoint 400, est installé pour le développement
local. Il n'est pas appelé sur chaque dictée : VoxoL utilise d'abord son
traitement déterministe, appelle Qwen uniquement sur les corrections courtes
où un gain est plausible, puis rejette toute sortie qui perd, invente,
duplique ou réordonne un contenu protégé.

## Données et entraînement

- La cible reste le couple Wispr `raw → edited`.
- Les groupes d'enregistrement et de locuteurs sont séparés entre
  entraînement, validation et test.
- Le curriculum v6 conserve 393 exemples d'entraînement fortement filtrés,
  avec des exemples `no-op` pour apprendre à ne pas réécrire un texte déjà
  propre.
- Le modèle est Qwen3.5-0.8B 4-bit avec un LoRA rank 8 sur les huit derniers
  blocs, 400 itérations, accumulation 8 et learning rate `2e-5`.
- Les labels du test gelé n'ont reçu aucune correction manuelle ou générée par
  un autre LLM. Une revue humaine ou GPT éventuelle doit rester limitée au
  split d'entraînement et conserver une provenance explicite.

## Résultats produit

Sur les douze cas courts du gate produit, le checkpoint 400 obtient onze
sorties exactes. La douzième perd une instruction protégée ; le validateur la
rejette et réutilise le texte déterministe.

| Mesure chaude | Résultat |
| --- | ---: |
| Cas exacts et acceptés | 11 / 12 |
| Latence p50 | 145 ms |
| Latence p95 | 243 ms |
| Warm-up initial | 1 129 ms |
| Pic mémoire MLX mesuré sur le test de 192 exemples | 970 MB |

Sur les 192 exemples du test plus large, le validateur seul accepte 135
sorties et en rejette 57. Le routage de production contourne Qwen sur 185
exemples et ne l'appelle que sept fois. Le résultat routé est identique au
fallback déterministe sur ce jeu : 100 % de rappel des valeurs protégées,
0,612 % de mots inattendus et 1,365 % de distance d'édition normalisée
moyenne. Cette absence de gain global interdit d'élargir le routage sans
nouvelle preuve.

## Contrat de production

Qwen peut corriger une faute courte, un accord, une question ou une petite
mise en forme lorsque le routeur le demande. Le chemin déterministe reste
prioritaire pour les textes déjà propres, les longues dictées, les commandes,
le code, les URL, les chemins, les nombres et les cas à forte densité de spans
protégés.

Le validateur vérifie le multiensemble et l'ordre des placeholders, la
conservation du contenu, la portée de l'édition, la longueur, la dérive de
langue et les sorties de type réponse ou raisonnement. Toute violation revient
au texte déterministe ; il n'existe aucun mode dégradé qui insère une sortie
Qwen non validée.

## Décision

Promouvoir le checkpoint 400 pour le développement local avec ce routage
strict. Ne pas le promouvoir comme polisher systématique et ne pas relâcher le
validateur pour augmenter artificiellement son taux d'acceptation. Une
extension du chemin Qwen exige un gain mesuré sur un nouveau test indépendant,
100 % de rappel des spans protégés et une latence p95 inférieure à 300 ms sur
les dictées ordinaires.
