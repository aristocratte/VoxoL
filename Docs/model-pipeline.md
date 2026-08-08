# Model pipeline

VoxoL distribue exactement deux modèles : Parakeet TDT v3 pour la transcription automatique, puis
Qwen3.5-0.8B 4-bit pour nettoyer la forme. Sur macOS 26 ou ultérieur, un choix explicite Français
ou English route l'ASR vers `DictationTranscriber`, dont les assets sont gérés par macOS; Auto et le
repli utilisent Parakeet. Une passe déterministe protège les tokens avant Qwen et le validateur de
fidélité contrôle chaque sortie avant insertion.

Les deux conversions externes sont épinglées et téléchargeables. Chaque fichier passe le contrôle
de taille et de SHA-256 avant activation. Le runtime Parakeet public conserve le log-mel vDSP. Le
candidat v5 validé fusionne le préprocesseur waveform NeMo, l'encodeur et sa projection dans Core ML,
puis utilise le décodeur TDT Swift. Celui-ci ne valide l'état LSTM candidat qu'après une émission
lexicale, comme NeMo. Le détecteur de parole ne bloque pas cette passe finale, car il sert uniquement
au feedback temps réel.

Le runtime Qwen via MLX est branché, préchauffé et borné. Le validateur rejette les placeholders
perdus, le contenu ajouté ou supprimé, les sorties tronquées et les préambules avant de choisir le
fallback déterministe. Le 0.8B reste un candidat expérimental jusqu'aux goldens et au fine-tuning.
