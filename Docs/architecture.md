# Architecture

VoxoL est découpé en modules natifs dont l'interface sert aussi de surface de test. Un module
n'est créé que lorsqu'un vertical slice lui donne un comportement observable; les répertoires
vides ne constituent pas une architecture.

L'application orchestre les sessions et affiche l'état. Les modules audio, ASR, normalisation,
contexte, nettoyage, fidélité et insertion restent séparés parce que leurs invariants, leurs
runtimes et leurs modes d'échec diffèrent. Les adaptateurs système vivent à l'intérieur du module
qui porte leur politique afin de ne pas exposer AVFoundation, Core ML, MLX ou Accessibility aux
appelants.

Le pipeline autorisé est : raccourci global, capture audio, endpointing déterministe, ASR local,
normalisation déterministe, contexte minimal, Qwen text-only, validation de fidélité, fallback sûr,
puis insertion. Auto utilise Parakeet; sur macOS 26 ou ultérieur, Français et English utilisent le
`DictationTranscriber` système avec un locale verrouillé. Aucun appel d'inférence réseau n'existe
dans ce chemin.

Le périmètre courant comprend `AudioCaptureKit`, `EndpointingKit`, `ParakeetCore` et
`InjectionKit`. `ParakeetCore` accepte le runtime public log-mel vDSP ou le runtime candidat qui
fusionne le préprocesseur NeMo et l'encodeur dans Core ML, puis réalise le décodage
TDT greedy avec des buffers réutilisés. Le runtime est préchargé hors du main actor dès que le
modèle ASR vérifié est disponible. L'endpointing pilote seulement le retour visuel pendant la
capture : au relâchement du raccourci, le résultat ASR reste l'autorité afin qu'un micro peu sensible
ne provoque pas un faux « No speech heard ».

Le processus et le champ Accessibility ciblés sont capturés au début de la dictée, avant l'inférence
asynchrone. Si une application web ou Electron n'expose pas de champ modifiable, VoxoL peut envoyer
un collage uniquement si le même processus possède encore le focus et si aucune saisie sécurisée
n'est active. Un changement d'app ou un champ sécurisé interdit toujours ce fallback. Les
diagnostics ne conservent aucun contenu et exposent seulement niveau micro, durée, détection, nombre
de caractères, moteur, latence et méthode de livraison.

Le nettoyage Qwen3.5-0.8B via MLX, la normalisation et le validateur de fidélité sont branchés. Le
modèle est préchauffé, la génération est bornée et toute sortie non fidèle revient immédiatement au
texte déterministe avant insertion.
