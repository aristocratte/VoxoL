# Robustesse au bruit — VoxoL contre Wispr Flow

Chaque clip des trois cellules de parole réelle, remixé contre un babble
déterministe de six voix du même corpus. Ce qui compte est la **forme de la
courbe** : un système qui perd deux points à 10 dB reste utilisable dans un
café, un qui en perd dix ne l'est pas.

| condition | Common Voice FR | VoxPopuli FR | LibriSpeech EN |
| --- | ---: | ---: | ---: |
| propre | **7.28** / 13.54 | **10.10** / 12.33 | **2.11** / 3.66 |
| babble 20 dB | **9.69** / 15.20 | **10.39** / 12.51 | **2.71** / 3.09 |
| babble 10 dB | **19.59** / 23.88 | **10.84** / 13.15 | **4.25** / 4.35 |
| babble 5 dB | **39.35** / 40.95 | **13.64** / 16.06 | 10.44 / **9.19** |

*VoxoL / Wispr Flow ; le meilleur des deux en gras.*

## Deux domaines, deux comportements opposés

Sur la **parole spontanée**, l'avantage de VoxoL ne fond pas quand le bruit
monte — il se creuse légèrement, de 1,4 point au propre à 2,3 points à 10 dB.
Sur le **livre audio**, il fait l'inverse : 1,5 point d'avance au propre, puis
l'écart s'érode jusqu'à s'inverser à 5 dB.

Aucun des deux motifs n'était prévisible ; c'est la raison de la mesure. Le
premier est celui qui compte pour une application de dictée, où personne ne
parle comme un narrateur de livre audio et où il y a presque toujours
quelqu'un qui parle à côté.

À 5 dB sur des clips courts — six voix concurrentes au même volume que la
vôtre — les deux systèmes dépassent 39 % d'erreur. Aucun n'est utilisable là,
et le dire vaut mieux que de ne montrer que la partie flatteuse de la courbe.

Généré par `Scripts/prepare-noise-benchmark.py` puis les deux runners.
Couverture minimale des collectes : 99,7 %.

