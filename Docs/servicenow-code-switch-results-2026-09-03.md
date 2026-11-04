# ServiceNow FR/EN code-switch — run local du 3 septembre 2026

## Verdict

Le modèle ASR Core ML installé atteint **9,79 % de WER micro** sur les 486 clips publics
ServiceNow FR/EN. Il reste derrière le Parakeet TDT 0.6B v3 publié par ServiceNow sur les deux
configurations : **8,73 % contre 7,50 %** en EN/FR et **11,49 % contre 9,90 %** en EN/FR-CA.
L'écart vient surtout des segments anglais : leur taux d'erreur attribué atteint **15,19 %**, contre
**1,62 %** en français international et **4,90 %** en français canadien.

## Résultats comparables

| Système | EN/FR WER | EN/FR-CA WER |
|---|---:|---:|
| ElevenLabs Scribe V2 | 3,10 % | 4,10 % |
| AssemblyAI Universal 3-Pro | 3,50 % | 4,30 % |
| Google Gemini 3 Flash | 4,00 % | 5,50 % |
| Deepgram Nova-3 Multilang | 5,20 % | 7,20 % |
| Mistral Voxtral Small 24B-2507 | 6,00 % | 5,90 % |
| NVIDIA Parakeet TDT 0.6B v3 | 7,50 % | 9,90 % |
| **VoxoL local Core ML** | **8,73 %** | **11,49 %** |
| OpenAI Whisper Large v3 Turbo | 43,40 % | 53,50 % |

Les lignes externes sont les runs indépendants publiés par ServiceNow, et non des inférences
relancées sur cette machine. La comparaison porte uniquement sur le WER déterministe. VoxoL ne
revendique ni SWER ni AER, car ces métriques du harnais officiel utilisent un juge externe.

## Diagnostic VoxoL

- 11 385 mots de référence : 754 substitutions, 275 insertions et 86 suppressions.
- Le WER monte avec le nombre de changements de langue : **6,49 %** pour 0–2 switches,
  **9,76 %** pour 3–5, puis **10,61 %** pour 6 ou plus.
- La latence d'inférence locale est de **151,64 ms en p50** et **197,36 ms en p95** sur 486 clips.
- Les tranches CMI ne sont pas monotones (9,68 % faible, 10,89 % moyen, 8,16 % élevé) ; elles sont
  donc conservées comme diagnostic et ne justifient pas, seules, une conclusion causale.

La prochaine campagne ASR doit prioriser l'anglais enchâssé dans une phrase française et les
séquences à nombreux switches. Elle devra comparer le checkpoint source, le fine-tune, la
quantification Core ML et le décodage sur ce test verrouillé afin de localiser la régression avant
un nouvel entraînement massif.

## Protocole et provenance

- Dataset : `ServiceNow-AI/asr_codeswitched`, révision
  `82bf4b49499bcaa6f4cf6a67bebfab3ee2affcbb`, 298 clips `en_fr` et 188 `en_fr_ca`.
- Manifeste gelé : SHA-256
  `5d66a23d222212d8b1666c4288f0d787214209fe1bc1b5d76107d90dbd0b745e`.
- AU-Harness contrôlé à la révision `e07548bafd94ef816c9108c3983fc2f3c2356d55`.
- Score : sortie ASR brute en langue automatique, normalisation indépendante reproduisant le
  chemin `normalize_text(..., "en/fr")`; trois alignements de labels ont été ajustés après retrait
  des parenthèses par le normaliseur.
- Artefacts locaux :
  `~/Library/Application Support/VoxoL/Benchmarks/ServiceNowCodeSwitch/runs/voxol-local-20260903-v1`.

Sources : [dataset ServiceNow](https://huggingface.co/datasets/ServiceNow-AI/asr_codeswitched),
[publication des résultats](https://huggingface.co/blog/ServiceNow-AI/code-switching) et
[AU-Harness](https://github.com/ServiceNow/AU-Harness).
