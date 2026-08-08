# Architecture decision records

Les ADR sont immuables une fois remplacées : une nouvelle décision en crée une nouvelle et indique
celle qu'elle supersède.

- ADR-0001 — application native Swift
- ADR-0002 — exactement deux modèles locaux (partiellement remplacée par ADR-0009 et ADR-0010)
- ADR-0003 — Parakeet via Core ML et décodeur Swift
- ADR-0004 — Qwen text-only via MLX Swift (partiellement remplacée par ADR-0010)
- ADR-0005 — contexte minimal via Accessibility
- ADR-0006 — validation obligatoire et fallback déterministe
- ADR-0007 — SQLite chiffré pour la personnalisation
- ADR-0008 — modèles externes avec manifeste épinglé et vérifié (partiellement remplacée par ADR-0010)
- ADR-0009 — ASR système à langue verrouillée
- ADR-0010 — Qwen3.5-0.8B comme polisher expérimental
- Threat model — limites de confiance, défenses et gates de release
