# Mission GPT 5.6 Pro — VoxoL : performance, précision et lancement

Tu interviens comme responsable technique et produit de VoxoL, une application de
dictée macOS locale sur Apple Silicon. Je veux une nouvelle passe sérieuse pour
réduire l'attente, améliorer la précision réellement obtenue, comparer les modèles,
préparer des résultats crédibles pour le site et décider où concentrer le travail
des prochaines semaines.

**Travaille jusqu'à des résultats vérifiés et des changements reviewables.**
Commence par comprendre et mesurer l'existant, implémente les améliorations justifiées,
puis livre une analyse critique et un plan de lancement. Les gains restent à démontrer.
Si une piste ne fonctionne pas, rapporte-le et réoriente le travail. Ne considère pas
une liste d'idées ou davantage de tests comme un gain de précision ou de vitesse.

## 1. Établir ce que tu peux réellement examiner et exécuter

Les projets locaux sont :

- Application : `/Users/aris/Documents/Zphyr`.
- Site : `/Users/aris/Documents/voxol-web`.

État constaté le 10 septembre 2026, à revérifier : l'application est sur
`codex/real-dictation-20260908`, base `b27f0c97edf9e6c47be9790158692710f4f7f79d`, avec
de nombreux changements non commités et fichiers non suivis. Le site est un projet
React/Vite et n'est pas un dépôt Git à cette date. Un clone distant de l'application
ne contient donc pas automatiquement le code, le site et les preuves disponibles ici.

Relève OS, puce, RAM, versions des dépendances, branche/commit, modifications locales,
modèles présents, données et outils accessibles. La cible de référence actuelle est
un MacBook Pro M4 avec 16 Go ; les autres machines doivent être identifiées séparément.
Conserve l'état initial et les empreintes des sources, binaires, poids et paramètres
que tu compares. Préserve le travail existant.

Si tu es dans ChatGPT sans terminal, dépôt ou Mac, dis exactement ce qui manque :
ne simule pas une exécution. Analyse les éléments fournis et prépare les correctifs,
expériences et commandes exécutables ailleurs. Si seul Linux est disponible, fais
les travaux portables et distingue ce qui reste à valider sur macOS. Ne déduis pas
les temps Core ML, l'énergie ou l'insertion macOS de résultats GPU distants.

Lis d'abord les éléments pertinents, puis les fonctions qu'ils désignent :

- `Docs/real-dictation-results-2026-09-08.md` — dernière comparaison réellement exécutée.
- `Docs/benchmarking.md` — protocoles et optimisations déjà testées.
- `Docs/text-quality-results-2026-09-07.md` — correcteur et cas de fidélité.
- `Models/manifests/runtime-models.json`, `Docs/models.yaml`, `Docs/dataset-policy.md`.
- `Docs/market-plan-2026-08-08.md` — ancien plan à critiquer, pas une conclusion à adopter.

Pour les sources : `DictationSessionCoordinator.swift`, `DictationTextProcessor.swift`,
`PolisherSmokeRunner.swift`, `ParakeetRuntime.swift`, `Pipeline.swift`,
`QwenPolisherRuntime.swift`, `SessionPolishingCache.swift` et les validateurs de fidélité.
Pour le site : `src/components/Benchmarks.tsx`, `SpeedRace.tsx` et les promesses du hero.
Évite une lecture exhaustive des archives lorsqu'une recherche ciblée répond à la question.

## 2. Partir des acquis sans les surinterpréter

Le registre déclare Parakeet TDT 0.6B v3/Core ML pour la reconnaissance et Qwen3.5
0.8B/MLX 4 bits pour la correction, avec un adaptateur historique. Vérifie les poids
effectivement chargés, leur conversion et leur révision.

Dernière campagne : 88 dictées personnelles avec références IA historiques et
40 extraits publics FLEURS FR/EN ; 384 transcriptions, puis 176 traitements de correction.

| Moteur | WER lexical sur 88 dictées IA | WER sur 40 extraits publics | Médiane ASR sur les dictées |
| --- | ---: | ---: | ---: |
| Parakeet actuel | 5,39 % | 6,70 % | 131 ms |
| Qwen3-ASR 0.6B MLX 8 bits | 12,96 % | 6,91 % | 715 ms |
| Whisper large-v3-turbo MLX FP16 | 11,52 % | 7,32 % | 2 825 ms |

Ces temps portent sur l'inférence, sans chargement ni insertion. Les labels privés
peuvent favoriser un modèle ayant participé à leur construction ; le public est
petit. Ces chiffres ne prouvent pas une supériorité générale de VoxoL sur le marché.

Sur ces 88 dictées, retirer l'adaptateur n'a amélioré aucun score lexical final et
a augmenté les échecs de génération signalés de 4 à 9. Le correcteur n'a apporté
aucune modification lexicale finale après normalisation dans cette campagne.
46 des 88 cibles dites fidèles dépassent 20 % de modifications par rapport au verbatim :
elles mélangent des intentions de correction et de réécriture. Le gain de 20 % visé
n'a pas été démontré. Les 60 prises réservées n'ont pas encore servi à cette comparaison.

Des optimisations existent déjà : cache de buffers MLX borné, annulation propagée
et attente de fin des producteurs, anticipation de corrections pendant la capture,
cache exact de résultats par session et cache d'encodeur. Sur un rejeu de 180 secondes,
l'attente après arrêt jusqu'au texte prêt est passée d'environ 7,4 secondes à 1,5 seconde,
avec texte identique. Cela déplace du calcul pendant la parole ; ce n'est ni un gain
équivalent de débit, ni une mesure d'énergie, ni une validation de l'insertion réelle.

Le décodage par prompt lookup a accéléré certains essais mais changé des sorties ;
il est resté désactivé. Plusieurs essais de batching, graphes de génération et
redécoupage n'ont pas été promus. Ne recommence une expérience rejetée que si une
hypothèse nouvelle explique comment dépasser son échec.

## 3. Trouver et réduire le vrai coût du parcours utilisateur

Établis une baseline instrumentée avant de proposer les optimisations. La mesure
principale de latence doit aller de la fin de dictée au **texte final visible dans
l'application cible**. Mesure séparément :

- démarrage à froid, chargement, préchauffage et reprise après veille ;
- capture/conversion, préparation audio, encodeur et décodeur ASR ;
- nettoyage, préparation du prompt, génération, validation et éventuels replis ;
- attente liée à l'annulation d'un aperçu, livraison et insertion inter-apps ;
- calcul anticipé pendant la parole, mémoire de l'ensemble du produit, pression
  mémoire et impact thermique/énergétique lorsque les outils permettent de les mesurer.

Couvre dictées courtes, moyennes et longues, FR, EN, mélange FR/EN, microphone interne
et autres entrées disponibles. Distingue capture réelle, rejeu audio en temps réel,
import de fichier et simulation textuelle. Rapporte p50/p95, dispersion, échecs et
effectifs ; ne remplace pas un scénario long défavorable par une moyenne de phrases courtes.

Exécute les mesures comparatives dans des conditions stables, avec ordre des variantes
alterné et répétitions suffisantes. Identifie les caches actifs, modèles chauds/froids,
charge du Mac, alimentation, taille des entrées et version du binaire. Une prise rejouée
vingt fois donne vingt mesures de temps, pas vingt sources audio indépendantes.

Classe les postes par contribution à l'attente. Choisis ensuite les pistes avec le
meilleur gain attendu : copies et allocations, synchronisation, annulation, cadence
d'aperçu, réutilisation exacte, préchauffage, segmentation, prompt et budget de génération,
choix CPU/GPU/ANE, compilation/quantification ou stratégie de correction. Les techniques
plus complexes, dont décodage spéculatif et changement d'architecture, exigent un bénéfice
mesuré supérieur à leur coût de maintenance.

Pour chaque expérience, fige l'hypothèse, le mécanisme, la baseline, le budget de temps,
la métrique de succès, les contre-exemples et le critère d'abandon. Les optimisations
annoncées comme exactes doivent préserver les sorties. Celles qui les changent doivent
passer une évaluation de qualité distincte. Ne gagne pas du temps en tronquant, en
supprimant silencieusement la correction, en ignorant les échecs ou en retirant des protections.

## 4. Améliorer la précision et les modèles selon les erreurs observées

Analyse les étapes séparément : erreur acoustique, mot technique/nombre mal reconnu,
faute non corrigée, bonne correction rejetée, reformulation infidèle acceptée,
segmentation, mélange de langues, commande ou formatage. Produis des exemples qui
expliquent les causes et leur fréquence ; un taux d'acceptation du validateur n'est
pas une mesure de justesse.

Je t'autorise à créer et contrôler des références par IA sans me demander de tout
relire. Conserve leur provenance explicite et sépare verbatim, correction fidèle,
réécriture et code. Corrige le problème de contrat des cibles historiques avant de
les utiliser pour entraîner ou sélectionner un correcteur. Exclue les cas ambigus
avec une raison, sans inventer de mots inaudibles.

Préserve l'association audio/ID/hash et les groupes source. Fige train, développement
et contrôle séparément ; une variante, un extrait ou un quasi-doublon reste dans son
groupe. Ne construis pas la référence d'un contrôle à partir du modèle que tu veux y
classer. L'accord de plusieurs modèles reste une référence IA avec un biais possible.
Le contrôle déjà consulté devient une régression, pas un nouveau test aveugle.

Mesure ASR brut et texte final séparément : erreurs lexicales, omissions/ajouts,
noms, nombres et leur rôle, négations, intention interrogative, modalités, code et
formatage. Ajoute un indicateur de corrections nécessaires pour obtenir un texte
utilisable. Si le temps de correction humain n'a pas été mesuré, ne l'invente pas.

Fais une recherche actuelle sur les modèles pertinents, leurs licences, leur support
Apple Silicon et leurs contraintes de distribution. Une petite shortlist motivée suffit.
Compare les variantes de taille, quantification, décodage ou adaptation quand elles
répondent à une faiblesse observée. Un nouveau nom ou un meilleur classement publié
n'est pas à lui seul une raison de réécrire le runtime.

Si un entraînement ciblé est justifié, prépare puis exécute ce qui est possible avec
les ressources locales autorisées : parent pristine reproductible, données adaptées
au contrat, recette/hyperparamètres, budget calculé, ablations et évaluation avant/après.
Ne repars pas de l'adaptateur historique à la lignée incomplète. N'assimile jamais
des références IA à une approbation humaine pour contourner un script. Ajoute un
protocole IA explicite si nécessaire, sans falsifier le gate humain existant.

## 5. Produire des comparaisons utilisables sur le site

Il faut comparer à la fois les **moteurs ASR** et les **produits complets de dictée**.
Sélectionne des concurrents pertinents pour notre utilisateur cible après recherche
actuelle. Pour chaque comparaison exécutée, utilise les mêmes enregistrements, règles
de normalisation, périmètre de texte et conditions équitables. Les aides de langue ou
de vocabulaire ne doivent pas provenir des bonnes réponses.

Sépare visiblement : mesures réalisées avec notre protocole, résultats publiés par
un tiers et modèles non testés. Les deux premières catégories ne deviennent pas
un classement commun si les datasets ou conditions diffèrent. Marque « non mesuré »
les valeurs absentes. Date et source chaque information externe ; vérifie les cartes
officielles, publications et documentations des fournisseurs.

Construis un export JSON/CSV versionné depuis les rapports : modèle/produit et version,
date, matériel, runtime, corpus/split/langue/durée, nombre de sources et de mots,
configuration, métrique, incertitude, échecs, limites et source. Pour des benchmarks
cloud autorisés, ajoute les conditions réseau et le coût. Les échecs restent dans
le dénominateur ; publie aussi les régressions et les cas où VoxoL perd.

Prépare l'intégration locale dans le site avec une méthodologie accessible, des
graphiques comparables et un lien vers les preuves publiques. Les audios personnels,
leurs transcriptions, chemins privés et métadonnées de contexte ne doivent pas entrer
dans l'export public. Préserve la direction visuelle existante ; aucune refonte globale
n'est nécessaire pour ajouter une comparaison sérieuse.

Audite aussi les affirmations déjà présentes. Au dernier relevé, le site affichait
115 ms de reconnaissance, environ 850 ms de chaîne complète, 3 261 ms de trajet cloud
et « 28× ». Vérifie leurs sources, dates et points de départ/arrivée. Un ratio entre
un composant local et une chaîne cloud complète ne démontre pas que le produit est
28 fois plus rapide. Identifie les promesses à conserver, préciser, retirer ou remesurer.

## 6. Faire une analyse critique et choisir les priorités de lancement

Définis le public initial et les scénarios où VoxoL peut apporter un avantage mesurable.
Évalue le temps pour obtenir un texte exploitable, sa précision, la confidentialité,
le fonctionnement hors ligne, les ressources et la fiabilité. La supériorité sur toutes
les langues et tous les usages n'est pas une hypothèse acquise.

Réexamine les anciennes conclusions, notamment « la guerre ASR est gagnée » ou
« avantage incopiable ». Dis ce que les preuves permettent réellement de défendre.
Identifie les obstacles au lancement : pas seulement l'ASR, mais aussi première
installation, permissions, téléchargement/récupération des modèles, raccourci,
annulation, veille, stabilité, insertion dans les applications importantes, mise à jour
et distribution signée/notarisée. Vérifie l'état actuel avant de les déclarer manquants.

Livre une décision **poursuivre / différer / abandonner** pour chaque piste importante,
avec preuve, bénéfice utilisateur attendu, coût, risque et condition qui pourrait
changer le verdict. Limite le travail simultané à deux ou trois priorités. Donne une
liste explicite de ce qui ne devrait plus consommer de temps avant le lancement.

Construis un plan réaliste sur les **4 à 6 prochaines semaines**, pour un développeur
assisté par IA. Explicite ta capacité de travail supposée. Chaque semaine doit avoir :
objectif utilisateur, travaux ordonnés, estimation en jours, dépendances, livrable
testable, indicateur de réussite et décision de passage à l'étape suivante. Sépare
chemin minimal de lancement et améliorations post-lancement. Prévois une marge de
validation et une solution de repli si un entraînement ou remplacement de modèle échoue.

Fixe des objectifs chiffrés de latence/qualité à partir de la baseline et des usages,
avant de lire les résultats du contrôle final. Les précédents « −20 % d'erreurs » et
« moins d'une seconde » sont des cibles à qualifier par scénario, pas des obligations
à satisfaire en changeant le protocole. Conclus par les trois prochaines actions concrètes.

## 7. Vérifier et livrer

Tu peux avancer sur les inspections, changements locaux réversibles, benchmarks et
préparations de données autorisés. Les modèles restent locaux dans le produit ; les
enseignants distants éventuels servent à la préparation hors ligne des datasets.
N'envoie pas mes enregistrements à un fournisseur externe sans autorisation explicite.
Pour une dépense cloud, prépare d'abord le budget et le travail à lancer.

Préserve les fichiers originaux, les poids et les travaux non commités. Prépare les
changements de l'app et du site sans publier, fusionner ou remplacer mon application
installée. Fournis un correctif ou une version candidate identifiable et un retour
arrière. Ne prétends pas avoir commit/push le site s'il n'a pas de dépôt Git.

Sur le Mac, exécute les vérifications appropriées : `./Scripts/verify.sh --fast`,
build et contrôles natifs ciblés, puis `npm run build` dans le site et inspection
visuelle desktop/mobile si son affichage change. Les tests d'insertion réelle sont
distincts d'un test du processeur de texte. Aucune réussite ne doit être affirmée
sans trace correspondante.

Livrables attendus, dans le dépôt ou dans des pièces jointes exploitables :

1. Diagnostic priorisé et décision d'architecture/modèles étayée.
2. Changements implémentés, avec tests, bilan avant/après et limites.
3. Benchmark reproductible en une commande, manifestes et paramètres figés.
4. Résultats comparatifs, export public contrôlé et intégration locale au site.
5. Analyse critique : promesses défendables, points faibles, pistes à arrêter.
6. Plan de lancement sur 4–6 semaines avec critères de passage et budget.

Dans ton compte rendu, distingue **implémenté et vérifié**, **mesuré mais non retenu**,
**hypothèse** et **travail restant**. Si aucun gain n'est obtenu, dis-le clairement,
explique la cause et livre ce qui permettra de trancher la prochaine expérience.
Commence par un inventaire court, puis exécute les travaux réalisables sans attendre
une validation de chaque choix technique courant.
