# Plan « texte parfait » — ASR + Qwen sur macOS

Date : 2026-09-03. Statut : **supplanté pour l'exécution** par
`Docs/text-quality-v3-implementation-2026-09-03.md`. Ce document reste l'analyse initiale ; ses
propositions de réparation phonétique directe, embeddings et entraînement ne sont pas autorisées
par l'incrément v3 actuel. Les chiffres
viennent du corpus humain (`Data/corpus/human-v1.jsonl`, 184 paires, 11 448 mots source) et des
mesures de la nuit (`Scripts/build-polisher-suite-from-corpus.py`, chemin `--through-processor`).

## 1. Diagnostic mesuré

Ce que les humains ont corrigé entre la transcription brute et la cible :

| Type d'édition | Occurrences | Ce que c'est |
| --- | ---: | --- |
| Suppressions de mots hors béquilles | 1 980 | Condensation de la phrase parlée en phrase écrite (46 segments de 6 mots ou plus) ; seulement 72 sont des répétitions ou faux départs |
| Réécritures de segments | 261 | « qu'on » → « dont on », « england cliquez » → « quand on clique », « assez » → « as fait » |
| Suppressions de béquilles | 241 | donc, genre, du coup, voilà, en fait, quoi, bah, ok |
| Insertions | 109 | surtout la négation restaurée : « c'est » → « ce n'est », « t'as » → « tu n'as », « j'ai » → « je n'ai » |
| Substitutions lourdes (distance > 2) | 93 | termes techniques et anglicismes : pen test → pentest, l'ong → l'onglet, 21 st → 21st, mp trois → mp3, chat scene like → chatcn-like, ibourifés → ébouriffés |
| Substitutions légères (distance ≤ 2) | 89 | accords et homophones : s'affiche → s'affichent, choisi → choisis, corres → corrige |
| Nombres | — | l'humain écrit « trois », « deux », « cinq » ; le pipeline impose « 3 », « 2 », « 5 » et les fige |

Ce que le pipeline fait : sur les 172 sorties acceptées par le validateur, le modèle a reproduit
**1 correction humaine sur 797**. Le texte ressort quasiment tel quel, ponctué. Trois verrous
l'expliquent, et aucun n'est un défaut du modèle de langue lui-même :

1. **Le validateur juge les mots, pas le sens.** Tout mot absent de la source est rejeté sauf à
   distance d'édition 1 ou 2 (`unexpectedContent`) ; toute suppression hors liste de béquilles
   est rejetée (`missingContent`) ; le budget d'édition est de 5 % en fidèle et 20 % en
   réécriture. Or les cibles humaines suppriment 19 % des mots et réécrivent des segments.
2. **L'adaptateur v8 a appris la timidité.** Entraîné sur le teacher Wispr sous le contrat
   fidèle, il ne tente pas ce que le validateur interdirait de toute façon (mémoire :
   *polisher-is-conservative*).
3. **Les faits sont figés dans leur forme.** Les nombres, dates et négations deviennent des
   espaces réservés `VOXOLPn` : « 3 » ne peut jamais redevenir « trois », et « ne » ajouté
   devant « pas » est un jeton inconnu.

Hésitations : la couche déterministe ne connaît que euh/heu/hum ; le reste est réservé au modèle,
qui n'a pas le droit. Dictée de code : le profil `developer` n'est qu'une ligne de style dans le
prompt et 20 termes de biais ; aucune grammaire de symboles parlés (« underscore », « point »,
« parenthèse »), aucun usage des identifiants visibles dans l'éditeur.

ASR : Parakeet gagne sur la parole spontanée au micro (14 victoires / 6 défaites, `Docs/RESULTS.md`).
Les erreurs qui restent sont concentrées sur les termes techniques, anglicismes et noms propres,
exactement ce que corrigent un biais contextuel et une réparation phonétique par dictionnaire. Le
biais d'écran n'atteignait pas le décodage final avant cette nuit. Données personnelles
disponibles : 134 sessions audio (38,9 min) avec texte corrigé — assez pour évaluer, pas pour
entraîner.

## 2. Principe directeur

Remplacer le contrat « mêmes mots » par le contrat **« mêmes faits, même sens »**. Le modèle
réécrit librement ; la sécurité vient de trois garde-fous vérifiables :

- **les faits** — nombres et valeurs, noms, identifiants, URL, dates — présents une fois,
  sous une forme libre dans leur classe d'équivalence (3 ≡ trois, 21 st ≡ 21st) ;
- **les propositions** — négation, quantificateur, modalité, condition — conservées par
  proposition alignée, pas par mot ;
- **une licence de correction pilotée par la confiance ASR** — un mot que Parakeet a émis avec
  une marge faible peut être remplacé, un mot sûr ne peut être que lemmatisé ou accordé.

L'évaluation change avec le contrat : ce qui compte est la **distance à la cible humaine** et le
**nombre de corrections humaines reproduites**, sous la contrainte de zéro inversion de sens sur
le corpus d'attaques (`ChallengeCorpusTests`).

## 3. Architecture cible

```
capture ─▶ Parakeet (biais : dictionnaire + écran + identifiants) ─▶ texte + marges par jeton
        ─▶ déterministe v2 : normalisation · réparation phonétique (dictionnaire, gating marge)
                            · grammaire de dictée de code · faits en classes d'équivalence
        ─▶ Qwen v2 (LoRA réécriture) : spans douteux marqués, dictionnaire réel, contexte
        ─▶ validateur v3 « sens » : faits · propositions · couverture · similarité sémantique
                                  · budget d'édition relatif à la confiance
        ─▶ réparation par spans ─▶ insertion
```

### 3.1 ASR

- Biais contextuel unifié (dictionnaire, nom d'app, mots de l'écran, identifiants de l'éditeur
  découpés en mots) reconstruit une fois par dictée. Fait pour la partie écran ; reste l'éditeur.
- Marges par jeton exposées jusqu'au pipeline texte (`TranscriptionConfidence` les calcule déjà ;
  `RepairShadow` les lit) ; c'est la matière première de la licence de correction.
- Réparation phonétique par dictionnaire promue du mode ombre au direct, avec gating : marge
  faible, distance normalisée ≤ 0,3, première lettre commune, jamais sur un mot sûr.
- Segments de 30 s (fenêtre de l'encodeur) au lieu de 20, passe partielle interruptible ;
  comparaison mesurée `gpu` / `ane` / `all` sur les 134 sessions perso.
- Fine-tune Parakeet FR uniquement si le gate FLEURS/MediaSpeech existant tient ; le pipeline
  Colab est prêt. À défaut, le biais et la réparation suffisent à la classe d'erreurs observée.

### 3.2 Couche déterministe v2

- **Inventaire de disfluences FR appris** : liste et positions extraites des suppressions
  humaines (donc, genre, du coup, voilà, en fait, quoi, bah, ok, « et » de liaison, « c'est » de
  présentation), avec règles de position (début et fin de phrase, avant virgule), et détection
  des faux départs par répétition de n-grammes. Ce que la règle traite, le modèle n'a plus à
  l'apprendre.
- **Faits en classes d'équivalence** : un fait est extrait avec sa valeur normalisée (nombre,
  date, heure, unité, identifiant) ; le texte envoyé au modèle garde la forme d'origine, le
  validateur compare les valeurs. Les espaces réservés restent pour ce que le modèle ne doit pas
  voir (code, URL, e-mail, chemins).
- **Grammaire de dictée de code** (profil developer) : symboles parlés FR/EN → jetons
  (« underscore », « tiret », « point », « égal », « parenthèse ouvrante », « guillemets »),
  casse dictée (« camel case », « majuscule »), collage d'identifiants connus de l'éditeur ; le
  validateur accepte un identifiant si sa forme repliée (sans espaces, sans casse) égale la
  concaténation des mots dictés.
- Nombres : convention typographique FR (zéro à dix en lettres dans la prose, chiffres avec
  unité, dans le code et le profil developer), appliquée après le modèle, sur la valeur.

### 3.3 Polisher Qwen v2

- Prompt : contrat réécriture, spans douteux balisés (`⟨?⟩ mot ⟨/?⟩`) comme licence explicite,
  dictionnaire réduit aux quasi-homonymes présents dans le texte, quelques exemples courts par
  contrat et par langue (hésitation, négation restaurée, terme technique, code).
- Adaptateur v2 entraîné sur le moteur de données du §4, repris depuis le champion, mélange
  fidèle/réécriture, jamais depuis la base (leçon du retrain d'août).
- Taille : rester en 0,8 B jusqu'à la spéculation n-gramme (§5), puis essayer 1,7 B à latence
  égale.

### 3.4 Validateur v3 « sens »

Dans l'ordre, chaque étape ne coûtant que si la précédente passe :

1. **Faits** : chaque fait source apparaît une fois, forme libre dans sa classe ; aucun fait
   nouveau.
2. **Propositions** : alignement phrase à phrase (SpanRepair étendu) ; par proposition, les
   marqueurs critiques (négation, quantificateur, modalité, condition, sujet) sont conservés ou
   transformés de façon équivalente (« ne … pas » ≡ « pas » parlé).
3. **Couverture** : chaque proposition source a un correspondant ; les mots de contenu sont
   alignés avec tolérance phonétique (clé phonétique FR) et lemmatique ; mots-fonction et
   béquilles libres. Une proposition entière absente est un rejet, un mot isolé ne l'est plus.
4. **Sémantique** : similarité d'embeddings par phrase (modèle multilingue léger sous MLX,
   quelques dizaines de millisecondes par phrase) ; sous le seuil calibré sur le corpus
   d'attaques, réparation par spans.
5. **Budget relatif à la confiance** : distance d'édition autorisée proportionnelle au nombre de
   jetons douteux, plus un plancher pour les accords et la ponctuation.

Le corpus d'attaques reste le gate absolu : zéro inversion en fidèle comme en réécriture, dans
les deux langues.

## 4. Moteur de données

C'est le levier principal : le modèle corrige ce qu'il a vu corrigé.

- **Or** : le corpus humain. 184 paires aujourd'hui, 500 exigées par le gate v2
  (`voxol-qwen-human-gate-v2`). Le Training Studio est en place ; à cent dictées relues par
  semaine, l'objectif est atteint en cinq semaines. Ce corpus n'entraîne jamais : il teste.
- **Boucle synthétique locale** (macOS, zéro cloud, zéro annotation) : texte propre (cibles
  humaines, historique poli de l'utilisateur, textes FR publics, scripts de code dictés) →
  injection de disfluences FR selon l'inventaire appris (§3.2) → synthèse vocale macOS (plusieurs
  voix, vitesses, avec bruit et réponse de pièce) → Parakeet Core ML → transcription brute
  portant de vraies erreurs ASR → paire (brut, propre). Objectif : 5 000 à 10 000 paires par nuit,
  filtrées (WER brut/propre entre 5 % et 40 %, aucun recouvrement avec le corpus humain).
- **Argent** : distillation locale par un grand modèle (Qwen3 32B 4 bits sous MLX ou équivalent)
  sur les dictées brutes réelles → cibles de réécriture, passées au validateur v3 puis à un juge
  (le même modèle, contrat « faits »). Jamais promu sans le gate humain ; provenance non humaine
  conservée dans le manifeste.
- **Entraînement** : LoRA r4 depuis le champion, `mask_prompt`, cache Metal plafonné
  (`train-capped.py`), jamais de build Xcode pendant l'entraînement, revalidation du binaire
  d'évaluation avant toute conclusion.

## 5. Performance macOS

- **Spéculation n-gramme depuis le prompt** (prompt-lookup decoding) dans la boucle de génération
  MLX : la sortie recopie plus de 80 % des jetons d'entrée, donc un brouillon tiré du prompt est
  vérifié par blocs et la génération gagne un facteur 2 à 3 sans second modèle. C'est ce qui
  paie un polisher 1,7 B à latence égale.
- Déjà en place : cache de préfixe pour les deux contrats, tranches de phrases pour les longues
  dictées, biais d'écran au décodage final, historique hors du chemin critique.
- ASR : fenêtre de 30 s, passe partielle interruptible dans `Pipeline.run`, biais reconstruit une
  fois, unités de calcul mesurées.
- Cibles : p50 sous 1 s jusqu'à 40 mots, p95 sous 3 s, dictées longues sous 8 s.

## 6. Phases et gates

| Phase | Contenu | Gate de sortie |
| --- | --- | --- |
| 0 — cette semaine | marges par jeton jusqu'au texte ; inventaire de disfluences appris ; classes d'équivalence des nombres ; réparation phonétique en direct avec gating ; grammaire code v1 ; suite de dictée de code | corpus humain ≥ 172 acceptées, faits 100 %, 0 inversion, latence p50 inchangée |
| 1 — semaines 1 à 2 | validateur v3 derrière un flag, comparé au v2 sur les mêmes sorties | corrections humaines reproduites ≥ 40 % (contre 0,1 %), 0 inversion |
| 2 — semaines 2 à 4 | moteur de données synthétique et distillation ; candidat LoRA v2 | distance à la cible humaine réduite d'au moins 30 %, fidèle sans régression, 0 inversion |
| 3 — semaines 4 à 6 | spéculation n-gramme ; essai 1,7 B ; ASR biais éditeur et fine-tune FR si le gate tient | p50 < 1 s, p95 < 3 s ; WER perso en baisse |
| continu | Training Studio jusqu'à 500 corrections ; métriques live | sans-retouche > 70 % sur sept jours |

## 7. Risques et parades

- **Sur-suppression** (le retrain d'août inversait « aucun incident ») : contrôle de couverture
  par proposition, juge sur les données argent, corpus d'attaques en gate.
- **Coût de la vérification sémantique** : embeddings calculés phrase par phrase pendant la
  génération des suivantes ; seuil calibré, repli par spans plutôt que rejet global.
- **Synthétique ≠ voix réelle** : mélange avec les données réelles, évaluation uniquement sur du
  réel (corpus humain, sessions perso).
- **Lisibilité du contrat** : le mode Réécriture doit rester expliqué dans Réglages et visible
  dans Insights (« Nettoyée / Telle quelle » existe déjà).
