#!/usr/bin/env python3
"""Assemble the training corpus for the polisher's two cleanup contracts.

Three sources, all already on this machine:

- the frozen Wispr Flow reference — 101 real dictations by the owner with the
  competitor's final text, which is precisely the teacher behaviour VoxoL is
  trying to match. These become rewrite-mode pairs; the near-verbatim ones are
  also emitted as faithful pairs, since a light touch satisfies both contracts;
- the personal-capture corrections — real dictations the owner fixed by hand;
- synthetic pairs: written sentences corrupted into spoken form with the exact
  crutch inventory the rewrite validator can accept back out. Corruptions
  deliberately stay inside that inventory — training deletions the validator
  vetoes would teach the model to produce output that gets discarded.

One adapter serves both modes (it is fused at load; two adapters would double
resident memory), so the corpus must carry both contracts or retraining one
would erase the other. The dataset builder downstream validates every target
under its declared mode and drops what does not comply; its summary reports
how many were rejected, and that number should be read, not assumed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
from pathlib import Path

APPLICATION_SUPPORT = Path.home() / "Library/Application Support/VoxoL"
REFERENCE = APPLICATION_SUPPORT / "Reference/WisprFlow/evaluation-2026-07-23-v1"
SESSIONS = APPLICATION_SUPPORT / "PersonalBenchmark/sessions"

# The teacher sometimes rewrites beyond anything a validator should accept —
# summaries, whole reorderings, hallucinated framing. Above this normalized
# edit distance a pair teaches divergence, not cleanup.
MAXIMUM_TEACHER_DRIFT = 0.55
# Below this the teacher changed almost nothing, so the pair also demonstrates
# the faithful contract.
FAITHFUL_DRIFT = 0.12

PROFILES = {"automatic", "message", "email", "document", "developer", "prompt"}


def complete(example: dict) -> dict:
    """The dataset decoder requires every field, empty or not."""
    example.setdefault("dictionary", [])
    example.setdefault("protected_tokens", [])
    example.setdefault("before_cursor", "")
    example.setdefault("after_cursor", "")
    return example


def wispr_pairs() -> list[dict]:
    path = REFERENCE / "pipeline-results.jsonl"
    if not path.is_file():
        return []
    examples = []
    for line in path.read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        raw = (record.get("parakeetText") or "").strip()
        target = (record.get("referenceFinalText") or "").strip()
        if not raw or not target:
            continue
        drift = (record.get("parakeetVersusWisprFinal") or {}).get(
            "normalizedEditDistance", 1.0
        )
        if drift > MAXIMUM_TEACHER_DRIFT:
            continue
        language = record.get("language") or "fr"
        profile = record.get("profile") or "automatic"
        if profile not in PROFILES:
            profile = "automatic"
        base = {
            "language": language,
            "profile": profile,
            "app_category": record.get("appCategory") or "prompt",
            "raw_transcript": raw,
            "target_text": target,
            "operations": record.get("features") or [],
            "source": "wispr-distillation",
            "approved": True,
            "split_group": f"wispr-{record['id']}",
        }
        examples.append({**base, "id": f"wispr-{record['id']}", "mode": "rewrite"})
        if drift <= FAITHFUL_DRIFT:
            examples.append(
                {**base, "id": f"wispr-{record['id']}-faithful", "mode": "faithful"}
            )
    return examples


def personal_pairs() -> list[dict]:
    examples = []
    for meta_path in sorted(SESSIONS.glob("*/meta.json")):
        corrected_path = meta_path.parent / "corrected.txt"
        if not corrected_path.is_file():
            continue
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        raw = (meta.get("rawText") or "").strip()
        target = corrected_path.read_text(encoding="utf-8").strip()
        if not raw or not target:
            continue
        for mode in ("rewrite", "faithful"):
            examples.append(
                {
                    "id": f"personal-{meta_path.parent.name}-{mode}",
                    "language": "fr",
                    "profile": "automatic",
                    "app_category": "document",
                    "raw_transcript": raw,
                    "target_text": target,
                    "operations": ["personal-correction"],
                    "source": "personal-correction",
                    "approved": True,
                    "split_group": f"personal-{meta_path.parent.name}",
                    "mode": mode,
                }
            )
    return examples


# Written-form sentences, deliberately plain and varied in register. Each is a
# target; corruptions below manufacture the spoken form.
FRENCH_SENTENCES = [
    "Je pense qu'on devrait commencer par les chiffres du trimestre dernier.",
    "Le rapport est presque terminé, il reste la partie sur les coûts.",
    "On se retrouve demain matin pour finaliser la présentation.",
    "Peux-tu m'envoyer le document avant la réunion de cet après-midi ?",
    "La nouvelle version corrige le problème de connexion au serveur.",
    "Il faudra prévenir l'équipe que la livraison est décalée d'une semaine.",
    "Je préfère qu'on valide le budget avant de lancer le projet.",
    "Le client souhaite une démonstration complète vendredi prochain.",
    "Merci de relire la proposition et de me faire tes retours.",
    "La maquette est prête, on attend la validation du directeur artistique.",
    "Nous avons reçu plusieurs candidatures intéressantes pour le poste.",
    "Le déploiement s'est bien passé, aucun incident à signaler.",
    "Je serai en télétravail jeudi et vendredi cette semaine.",
    "La facture du prestataire doit être réglée avant la fin du mois.",
    "Il manque encore les captures d'écran dans la documentation.",
    "Le serveur de test sera indisponible en début d'après-midi.",
    "On devrait automatiser cette vérification plutôt que la refaire à la main.",
    "La réunion est reportée à lundi prochain à la même heure.",
    "Je te partage le lien du dossier dès que j'ai terminé.",
    "L'objectif est de réduire le temps de chargement de moitié.",
    "Les retours des utilisateurs sont globalement très positifs.",
    "Il faut vérifier que la sauvegarde automatique fonctionne correctement.",
    "Le contrat arrive à échéance à la fin de l'année.",
    "On pourrait organiser un point rapide mercredi pour faire le bilan.",
    "La mise à jour sera déployée progressivement sur tous les postes.",
    "Je n'ai pas encore eu le temps de tester la nouvelle fonctionnalité.",
    "Le problème venait d'un câble mal branché derrière l'écran.",
    "Nous avons besoin d'une salle plus grande pour la formation.",
    "Le prototype sera présenté au salon au printemps prochain.",
    "Pense à sauvegarder le fichier avant de fermer l'application.",
    "L'équipe technique travaille sur une solution de contournement.",
    "Les résultats du sondage seront publiés la semaine prochaine.",
    "Je voudrais ajouter une section sur la sécurité dans le guide.",
    "Le rendez-vous chez le notaire est confirmé pour mardi matin.",
    "On garde la même structure mais on simplifie le vocabulaire.",
    "La commande a été expédiée hier, elle arrivera dans la semaine.",
    "Il vaudrait mieux prévenir le support avant de modifier la configuration.",
    "Le stagiaire a fait un excellent travail sur la migration.",
    "La priorité reste la stabilité, les nouvelles fonctions attendront.",
    "Tu peux fermer le ticket, le correctif est en production.",
    "J'aimerais qu'on relise ensemble le compte rendu avant l'envoi.",
    "Le chantier prend du retard à cause de la météo.",
    "Les photos de la soirée sont disponibles dans l'album partagé.",
    "Il reste encore des places pour la session de formation de jeudi.",
    "La procédure de remboursement prend une dizaine de jours.",
    "On testera la charge du serveur pendant le week-end.",
    "Le document doit rester confidentiel jusqu'à l'annonce officielle.",
    "Je passe récupérer les clés en fin d'après-midi.",
    "L'imprimante du second étage est de nouveau en panne.",
    "Nous allons revoir l'organisation des dossiers partagés.",
]

ENGLISH_SENTENCES = [
    "I think we should start with last quarter's numbers.",
    "The report is almost done, only the cost section remains.",
    "Can you send me the document before this afternoon's meeting?",
    "The new build fixes the connection issue with the server.",
    "We should let the team know the delivery slips by a week.",
    "The client wants a full demo next Friday.",
    "Please review the proposal and send me your feedback.",
    "The deployment went smoothly, nothing to report.",
    "The invoice needs to be paid before the end of the month.",
    "The staging server will be down over lunchtime.",
    "We should automate this check instead of redoing it by hand.",
    "The meeting is postponed to next Monday at the same time.",
    "The goal is to cut the loading time in half.",
    "User feedback has been very positive overall.",
    "The contract expires at the end of the year.",
    "I have not had time to test the new feature yet.",
    "The issue was a loose cable behind the monitor.",
    "The prototype will be shown at the spring trade fair.",
    "Remember to save the file before closing the app.",
    "The survey results will be published next week.",
    "Keep the same structure but simplify the wording.",
    "It is safer to warn support before changing the configuration.",
    "Stability stays the priority; new features can wait.",
    "You can close the ticket, the fix is in production.",
    "The renovation is running late because of the weather.",
]

# Crutches whose removal the rewrite validator accepts. Multi-word crutches
# only combine words that are individually removable or grammatical.
FRENCH_OPENERS = ["Donc", "Alors", "Bon", "En fait", "Du coup", "Bref", "Voilà", "Écoute"]
FRENCH_FILLERS = ["euh", "bah", "ben", "hein", "genre", "en fait", "du coup", "en gros", "quoi"]
ENGLISH_OPENERS = ["So", "Well", "Okay", "Basically", "Actually", "Right"]
ENGLISH_FILLERS = ["um", "uh", "like", "you know", "basically", "actually"]


def spoken_form(sentence: str, rng: random.Random, fillers: list[str], openers: list[str]) -> str:
    words = sentence.split(" ")
    # Strip the written shell: punctuation gone, casing flattened. Restoring
    # them is the faithful half of the training signal.
    words = [re.sub(r"[.,;:!?…]+$", "", word) for word in words]
    words[0] = words[0][0].lower() + words[0][1:] if len(words[0]) > 1 else words[0].lower()

    if rng.random() < 0.8:
        words.insert(0, openers[rng.randrange(len(openers))].lower())
    if rng.random() < 0.9:
        position = rng.randrange(1, max(2, len(words) - 1))
        words.insert(position, fillers[rng.randrange(len(fillers))])
    if rng.random() < 0.5:
        position = rng.randrange(1, max(2, len(words) - 1))
        words.insert(position, "euh" if fillers is FRENCH_FILLERS else "um")
    if rng.random() < 0.35 and len(words) > 4:
        # A stutter: one word repeated, which both contracts may collapse.
        position = rng.randrange(1, len(words) - 1)
        words.insert(position, words[position])
    if rng.random() < 0.3 and fillers is FRENCH_FILLERS:
        words.append("quoi")
    return " ".join(words)


def synthetic_pairs() -> list[dict]:
    examples = []
    for language, sentences, fillers, openers in (
        ("fr", FRENCH_SENTENCES, FRENCH_FILLERS, FRENCH_OPENERS),
        ("en", ENGLISH_SENTENCES, ENGLISH_FILLERS, ENGLISH_OPENERS),
    ):
        for index, sentence in enumerate(sentences):
            seed = int(hashlib.sha256(f"{language}-{index}".encode()).hexdigest()[:8], 16)
            rng = random.Random(seed)
            for variant in range(3):
                spoken = spoken_form(sentence, rng, fillers, openers)
                examples.append(
                    {
                        "id": f"synthetic-{language}-{index:03d}-{variant}",
                        "language": language,
                        "profile": "automatic",
                        "app_category": "document",
                        "raw_transcript": spoken,
                        "target_text": sentence,
                        "operations": ["synthetic-spoken-scaffolding"],
                        "source": "synthetic-generated",
                        "approved": True,
                        "split_group": f"synthetic-{language}-{index:03d}",
                        "mode": "rewrite",
                    }
                )
            # One faithful variant: punctuation and casing restored, crutches
            # kept. This is the contract the shipped adapter already serves,
            # and the corpus must keep serving it or one mode erases the other.
            plain = " ".join(
                re.sub(r"[.,;:!?…]+$", "", word) for word in sentence.split(" ")
            )
            plain = plain[0].lower() + plain[1:]
            examples.append(
                {
                    "id": f"synthetic-{language}-{index:03d}-faithful",
                    "language": language,
                    "profile": "automatic",
                    "app_category": "document",
                    "raw_transcript": plain,
                    "target_text": sentence,
                    "operations": ["synthetic-punctuation"],
                    "source": "synthetic-generated",
                    "approved": True,
                    "split_group": f"synthetic-{language}-{index:03d}",
                    "mode": "faithful",
                }
            )
    return examples


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    examples = [complete(e) for e in wispr_pairs() + personal_pairs() + synthetic_pairs()]
    by_source: dict[str, int] = {}
    by_mode: dict[str, int] = {}
    for example in examples:
        by_source[example["source"]] = by_source.get(example["source"], 0) + 1
        by_mode[example["mode"]] = by_mode.get(example["mode"], 0) + 1

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with arguments.output.open("w", encoding="utf-8") as handle:
        for example in examples:
            handle.write(json.dumps(example, ensure_ascii=False, sort_keys=True) + "\n")

    print(f"{len(examples)} exemples -> {arguments.output}")
    for source, count in sorted(by_source.items()):
        print(f"  {source:22s} {count}")
    for mode, count in sorted(by_mode.items()):
        print(f"  mode {mode:17s} {count}")
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main())
