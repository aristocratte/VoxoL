# Robustesse au bruit — VoxoL sous babble

Chaque clip des trois cellules de parole réelle est remixé contre un babble
déterministe de six voix du même corpus, à rapport signal/bruit contrôlé.
Généré depuis les rapports gelés par `Scripts/prepare-noise-benchmark.py` ;
reproduction : préparer, puis `run-multilingual-voxol.sh` sur la racine bruit.

| condition | Common Voice FR | VoxPopuli FR | LibriSpeech EN |
| --- | ---: | ---: | ---: |
| propre | 7.28 | 10.10 | 2.11 |
| babble 20 dB | 9.69 | 10.39 | 2.71 |
| babble 10 dB | 19.59 | 10.84 | 4.25 |
| babble 5 dB | 39.35 | 13.64 | 10.44 |

Lecture : la parole spontanée (VoxPopuli) est quasi insensible — **+3,5 points
à 5 dB**, un rapport signal/bruit où l'on peine soi-même à suivre une
conversation. Les clips courts de Common Voice se dégradent le plus vite :
moins de contexte pour départager la voix cible du babble.

La colonne Wispr Flow attend le script de collecte (`wispr-transcribe.sh`),
absent de la machine au moment du run — les 2 688 clips dégradés sont gelés
et prêts.
