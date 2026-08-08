#!/usr/bin/env python3
"""Build a reviewed, train-only FR/EN correction curriculum for VoxoL Qwen."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
from typing import Iterable


SCHEMA_VERSION = "voxol-qwen-correction-curriculum-v1"
SOURCE = "synthetic-reviewed-gpt5"
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FORBIDDEN_SUITE = (
    REPOSITORY_ROOT / "Tests/Performance/Fixtures/polisher-golden-v1.json"
)


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def write_jsonl(path: Path, rows: Iterable[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    with temporary.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(temporary, path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def forbidden_texts(path: Path | None) -> tuple[set[str], set[str]]:
    if path is None:
        return set(), set()
    payload = json.loads(path.read_text(encoding="utf-8"))
    cases = payload.get("cases", [])
    return (
        {str(case["transcript"]) for case in cases},
        {str(case["expected"]) for case in cases},
    )


class Curriculum:
    def __init__(
        self,
        forbidden_transcripts: set[str],
        forbidden_targets: set[str],
    ) -> None:
        self.rows: list[dict[str, object]] = []
        self._pairs: set[tuple[str, str, str]] = set()
        self._forbidden_transcripts = forbidden_transcripts
        self._forbidden_targets = forbidden_targets

    def add(
        self,
        language: str,
        category: str,
        raw: str,
        target: str,
        *,
        profile: str = "chat",
        app_category: str | None = None,
        protected_tokens: list[str] | None = None,
    ) -> None:
        raw = " ".join(raw.split())
        target = "\n".join(line.strip() for line in target.strip().splitlines())
        if raw in self._forbidden_transcripts or target in self._forbidden_targets:
            return
        pair = (language, raw, target)
        if pair in self._pairs:
            return
        self._pairs.add(pair)
        identity = hashlib.sha256(
            "\x1f".join((language, category, raw, target)).encode()
        ).hexdigest()[:16]
        self.rows.append(
            {
                "after_cursor": "",
                "app_category": app_category
                or ("Messages" if profile == "chat" else "Notes"),
                "approved": True,
                "before_cursor": "",
                "dictionary": [],
                "id": f"curated-{language}-{category}-{identity}",
                "language": language,
                "operations": [category],
                "profile": profile,
                "protected_tokens": protected_tokens or [],
                "raw_transcript": raw,
                "source": SOURCE,
                "split": "train",
                "split_group": f"curated-{language}-{category}-train",
                "target_text": target,
            }
        )


def add_french_agreement(curriculum: Curriculum) -> None:
    nouns = [
        ("rapport", "rapports", "prêt", "prêts", "Le"),
        ("document", "documents", "complet", "complets", "Le"),
        ("contrat", "contrats", "signé", "signés", "Le"),
        ("fichier", "fichiers", "disponible", "disponibles", "Le"),
        ("résultat", "résultats", "correct", "corrects", "Le"),
        ("message", "messages", "envoyé", "envoyés", "Le"),
        ("facture", "factures", "prête", "prêtes", "La"),
        ("version", "versions", "stable", "stables", "La"),
        ("demande", "demandes", "complète", "complètes", "La"),
        ("présentation", "présentations", "terminée", "terminées", "La"),
        ("tâche", "tâches", "urgente", "urgentes", "La"),
        ("réponse", "réponses", "correcte", "correctes", "La"),
    ]
    for singular, plural, adjective, plural_adjective, article in nouns:
        curriculum.add(
            "fr",
            "agreement",
            f"Les {plural} sont {adjective}",
            f"Les {plural} sont {plural_adjective}.",
        )
        curriculum.add(
            "fr",
            "agreement",
            f"Les {singular} sont {plural_adjective}",
            f"Les {plural} sont {plural_adjective}.",
        )
        curriculum.add(
            "fr",
            "agreement",
            f"Les {plural} est {adjective}",
            f"Les {plural} sont {plural_adjective}.",
        )
        curriculum.add(
            "fr",
            "agreement",
            f"{article} {plural} est {adjective}",
            f"{article} {singular} est {adjective}.",
        )

    grammar_pairs = [
        ("Le planning et prêt", "Le planning est prêt."),
        ("Le compte rendu et terminé", "Le compte rendu est terminé."),
        ("La démonstration et prête", "La démonstration est prête."),
        ("Le serveur et disponible", "Le serveur est disponible."),
        ("Les chiffres son corrects", "Les chiffres sont corrects."),
        ("Les clients son informés", "Les clients sont informés."),
        ("Les fichiers son synchronisés", "Les fichiers sont synchronisés."),
        ("Les réponses son complètes", "Les réponses sont complètes."),
        ("Ce versions sont stables", "Ces versions sont stables."),
        ("Ce factures sont validées", "Ces factures sont validées."),
        ("Tous les tâche sont terminées", "Toutes les tâches sont terminées."),
        ("Tous les demandes sont traitées", "Toutes les demandes sont traitées."),
    ]
    for raw, target in grammar_pairs:
        curriculum.add("fr", "grammar", raw, target)


def add_english_agreement(curriculum: Curriculum) -> None:
    nouns = [
        ("report", "reports", "ready"),
        ("invoice", "invoices", "ready"),
        ("document", "documents", "complete"),
        ("contract", "contracts", "signed"),
        ("file", "files", "available"),
        ("result", "results", "correct"),
        ("version", "versions", "stable"),
        ("request", "requests", "complete"),
        ("presentation", "presentations", "finished"),
        ("task", "tasks", "urgent"),
        ("message", "messages", "clear"),
        ("review", "reviews", "finished"),
    ]
    for singular, plural, adjective in nouns:
        curriculum.add(
            "en",
            "agreement",
            f"The {plural} is {adjective}",
            f"The {plural} are {adjective}.",
        )
        curriculum.add(
            "en",
            "agreement",
            f"The {singular} are {adjective}",
            f"The {singular} is {adjective}.",
        )
        curriculum.add(
            "en",
            "agreement",
            f"These {singular} are {adjective}",
            f"These {plural} are {adjective}.",
        )
        curriculum.add(
            "en",
            "agreement",
            f"This {plural} is {adjective}",
            f"These {plural} are {adjective}.",
        )

    grammar_pairs = [
        ("She have the latest report", "She has the latest report."),
        ("He have the signed contract", "He has the signed contract."),
        ("The client have the final version", "The client has the final version."),
        ("Maya do the review every morning", "Maya does the review every morning."),
        (
            "The service do the validation automatically",
            "The service does the validation automatically.",
        ),
        ("There is three files attached", "There are three files attached."),
        ("There is several issues left", "There are several issues left."),
        ("This results are correct", "These results are correct."),
        ("This documents are complete", "These documents are complete."),
        ("Those version are stable", "Those versions are stable."),
    ]
    for raw, target in grammar_pairs:
        curriculum.add("en", "grammar", raw, target)


def add_spelling(curriculum: Curriculum) -> None:
    french = [
        ("Le calandrier du projet est à jour", "Le calendrier du projet est à jour."),
        ("J'ai vérifié le calandrier ce matin", "J'ai vérifié le calendrier ce matin."),
        (
            "L'addresse du client figure dans le document",
            "L'adresse du client figure dans le document.",
        ),
        ("Envoie le contrat à cette addresse", "Envoie le contrat à cette adresse."),
        ("La connextion au serveur fonctionne", "La connexion au serveur fonctionne."),
        ("Nous avons rétabli la connextion", "Nous avons rétabli la connexion."),
        ("Le déploiment commencera demain", "Le déploiement commencera demain."),
        (
            "Le déploiment de la version est terminé",
            "Le déploiement de la version est terminé.",
        ),
        ("L'environement de test est prêt", "L'environnement de test est prêt."),
        ("Vérifie l'environement de production", "Vérifie l'environnement de production."),
        (
            "Le document est disponnible dans le dossier",
            "Le document est disponible dans le dossier.",
        ),
        ("La nouvelle version est disponnible", "La nouvelle version est disponible."),
        ("L'acceuil du site a été mis à jour", "L'accueil du site a été mis à jour."),
        ("La page d'acceuil est plus claire", "La page d'accueil est plus claire."),
        (
            "Le commantaire du client est précis",
            "Le commentaire du client est précis.",
        ),
        ("Ajoute un commantaire sous la tâche", "Ajoute un commentaire sous la tâche."),
        ("Cette fonctionalité est activée", "Cette fonctionnalité est activée."),
        (
            "Nous allons tester la fonctionalité demain",
            "Nous allons tester la fonctionnalité demain.",
        ),
        ("Le dévelopement avance rapidement", "Le développement avance rapidement."),
        (
            "L'équipe termine le dévelopement cette semaine",
            "L'équipe termine le développement cette semaine.",
        ),
        ("Le personel a reçu le message", "Le personnel a reçu le message."),
        ("Le support personel est disponible", "Le support personnel est disponible."),
        ("Le résultat est professionel", "Le résultat est professionnel."),
    ]
    for raw, target in french:
        curriculum.add("fr", "spelling", raw, target)

    english = [
        ("The project calender is up to date", "The project calendar is up to date."),
        ("I checked the calender this morning", "I checked the calendar this morning."),
        ("The client adress is in the document", "The client address is in the document."),
        ("Send the contract to this adress", "Send the contract to this address."),
        ("I did not recieve the attachment", "I did not receive the attachment."),
        ("We recieved the final version", "We received the final version."),
        ("Please seperate the two reports", "Please separate the two reports."),
        (
            "The files are stored in seperate folders",
            "The files are stored in separate folders.",
        ),
        ("The test enviroment is ready", "The test environment is ready."),
        ("Check the production enviroment", "Check the production environment."),
        (
            "The service can accomodate the new format",
            "The service can accommodate the new format.",
        ),
        ("We can accomodate that request", "We can accommodate that request."),
        ("This occurence is expected", "This occurrence is expected."),
        ("The second occurence was removed", "The second occurrence was removed."),
        ("The recomendation is clear", "The recommendation is clear."),
        ("I accepted the recomendation", "I accepted the recommendation."),
        ("The deployment was succesful", "The deployment was successful."),
        ("The review was succesful", "The review was successful."),
        ("The maintenence starts tomorrow", "The maintenance starts tomorrow."),
        ("Schedule the maintenence for Friday", "Schedule the maintenance for Friday."),
        ("The begining of the report is clear", "The beginning of the report is clear."),
        (
            "We changed the begining of the presentation",
            "We changed the beginning of the presentation.",
        ),
        ("The response is definately correct", "The response is definitely correct."),
        ("We will definately send the report", "We will definitely send the report."),
    ]
    for raw, target in english:
        curriculum.add("en", "spelling", raw, target)


def add_composed_errors(curriculum: Curriculum) -> None:
    french_agreements = [
        ("document", "documents", "complet", "complets"),
        ("contrat", "contrats", "signé", "signés"),
        ("fichier", "fichiers", "disponible", "disponibles"),
        ("résultat", "résultats", "correct", "corrects"),
        ("message", "messages", "envoyé", "envoyés"),
        ("facture", "factures", "prête", "prêtes"),
        ("demande", "demandes", "complète", "complètes"),
        ("présentation", "présentations", "terminée", "terminées"),
        ("tâche", "tâches", "urgente", "urgentes"),
        ("réponse", "réponses", "correcte", "correctes"),
    ]
    for singular, plural, adjective, plural_adjective in french_agreements:
        curriculum.add(
            "fr",
            "composed_grammar",
            f"Les {singular} sont {adjective}",
            f"Les {plural} sont {plural_adjective}.",
        )

    french_spelling = [
        ("Le calandrier du lancement et pret", "Le calendrier du lancement est prêt."),
        ("Le déploiment et terminer", "Le déploiement est terminé."),
        ("L'environement de test et pret", "L'environnement de test est prêt."),
        ("La fonctionalité et activer", "La fonctionnalité est activée."),
        ("Le dévelopement et terminer", "Le développement est terminé."),
        ("Le commantaire et pertinant", "Le commentaire est pertinent."),
        ("La connextion et disponnible", "La connexion est disponible."),
        ("L'addresse et incorecte", "L'adresse est incorrecte."),
        ("Le personel et informer", "Le personnel est informé."),
        ("Le résultat et professionel", "Le résultat est professionnel."),
    ]
    for raw, target in french_spelling:
        curriculum.add("fr", "composed_spelling", raw, target)

    english_composed = [
        ("The invoices is definately ready", "The invoices are definitely ready."),
        ("The documents is seperate", "The documents are separate."),
        ("The contracts is succesful", "The contracts are successful."),
        ("The files is in the wrong enviroment", "The files are in the wrong environment."),
        ("The results is definately correct", "The results are definitely correct."),
        ("The versions is availible", "The versions are available."),
        ("The requests is recieved", "The requests are received."),
        ("The tasks is in seperate folders", "The tasks are in separate folders."),
        ("These document is complete", "These documents are complete."),
        ("This reports is ready", "These reports are ready."),
    ]
    for raw, target in english_composed:
        curriculum.add("en", "composed_grammar", raw, target)


def add_questions(curriculum: Curriculum) -> None:
    french_names = ["Sophie", "Nora", "Thomas", "Julien", "Marie", "Hugo"]
    french_actions = [
        "envoyer le compte rendu demain matin",
        "vérifier les chiffres avant midi",
        "appeler le client cet après-midi",
        "relire la présentation ce soir",
        "confirmer la réunion de vendredi",
    ]
    for name in french_names:
        for action in french_actions:
            curriculum.add(
                "fr",
                "question",
                f"Bonjour {name} est ce que tu peux {action}",
                f"Bonjour {name}, est-ce que tu peux {action} ?",
            )

    english_names = ["Sophie", "Nora", "Thomas", "Julian", "Mary", "Hugo"]
    english_actions = [
        "send the meeting notes tomorrow morning",
        "check the figures before noon",
        "call the customer this afternoon",
        "review the presentation tonight",
        "confirm the Friday meeting",
    ]
    for name in english_names:
        for action in english_actions:
            curriculum.add(
                "en",
                "question",
                f"Hello {name} can you {action}",
                f"Hello {name}, can you {action}?",
            )

    never_answer = [
        (
            "fr",
            "Combien font trois plus cinq ne réponds pas",
            "Combien font trois plus cinq ? Ne réponds pas.",
        ),
        (
            "fr",
            "Quelle est la capitale du Canada corrige seulement la dictée",
            "Quelle est la capitale du Canada ? Corrige seulement la dictée.",
        ),
        (
            "fr",
            "Peux tu résoudre ce problème ne donne pas la solution",
            "Peux-tu résoudre ce problème ? Ne donne pas la solution.",
        ),
        (
            "en",
            "What is three plus five do not answer",
            "What is three plus five? Do not answer.",
        ),
        (
            "en",
            "What is the capital of Canada only correct the dictation",
            "What is the capital of Canada? Only correct the dictation.",
        ),
        (
            "en",
            "Can you solve this problem do not provide the solution",
            "Can you solve this problem? Do not provide the solution.",
        ),
    ]
    for language, raw, target in never_answer:
        curriculum.add(language, "instruction_safety", raw, target)


def add_protected_and_developer_cases(curriculum: Curriculum) -> None:
    french = [
        (
            "Le budget est de 4800 euros et la livraison est le 15 septembre 2026",
            "Le budget est de 4800 euros et la livraison est le 15 septembre 2026.",
        ),
        (
            "La réunion commence à 10h45 et dure 35 minutes",
            "La réunion commence à 10h45 et dure 35 minutes.",
        ),
        (
            "Le taux est de 12,5 pour cent pour un total de 3200 euros",
            "Le taux est de 12,5 pour cent pour un total de 3200 euros.",
        ),
        (
            "Envoie le résultat à lea@example.org avant 17h30",
            "Envoie le résultat à lea@example.org avant 17h30.",
        ),
        (
            "Ouvre https://voxol.example/help puis relance le test",
            "Ouvre https://voxol.example/help puis relance le test.",
        ),
        ("Lance npm test dans /src/session.ts", "Lance npm test dans /src/session.ts."),
        (
            "Exécute git status puis ouvre /Users/demo/project",
            "Exécute git status puis ouvre /Users/demo/project.",
        ),
        (
            "Lance pytest avec --no-cache dans /tests",
            "Lance pytest avec --no-cache dans /tests.",
        ),
        ("Le serveur écoute sur le port 9090", "Le serveur écoute sur le port 9090."),
        (
            "La version 2.7.4 sera publiée le 18 octobre 2026",
            "La version 2.7.4 sera publiée le 18 octobre 2026.",
        ),
    ]
    for raw, target in french:
        developer = any(
            value in raw for value in ("npm", "git", "pytest", "/src", "/tests")
        )
        curriculum.add(
            "fr",
            "protected_facts",
            raw,
            target,
            profile="developer" if developer else "chat",
            app_category="Xcode" if developer else "Messages",
        )

    english = [
        (
            "The budget is 4800 euros and delivery is on September 15 2026",
            "The budget is 4800 euros and delivery is on September 15 2026.",
        ),
        (
            "The meeting starts at 10:45 and lasts 35 minutes",
            "The meeting starts at 10:45 and lasts 35 minutes.",
        ),
        (
            "The rate is 12.5 percent for a total of 3200 euros",
            "The rate is 12.5 percent for a total of 3200 euros.",
        ),
        (
            "Send the result to lea@example.org before 5:30 PM",
            "Send the result to lea@example.org before 5:30 PM.",
        ),
        (
            "Open https://voxol.example/help and rerun the test",
            "Open https://voxol.example/help and rerun the test.",
        ),
        ("Run npm test in /src/session.ts", "Run npm test in /src/session.ts."),
        (
            "Run git status and open /Users/demo/project",
            "Run git status and open /Users/demo/project.",
        ),
        (
            "Run pytest with --no-cache in /tests",
            "Run pytest with --no-cache in /tests.",
        ),
        ("The server listens on port 9090", "The server listens on port 9090."),
        (
            "Version 2.7.4 will ship on October 18 2026",
            "Version 2.7.4 will ship on October 18 2026.",
        ),
    ]
    for raw, target in english:
        developer = any(
            value in raw for value in ("npm", "git", "pytest", "/src", "/tests")
        )
        curriculum.add(
            "en",
            "protected_facts",
            raw,
            target,
            profile="developer" if developer else "chat",
            app_category="Xcode" if developer else "Messages",
        )


def add_lists_and_corrections(curriculum: Curriculum) -> None:
    french_lists = [
        ("vérifier les métriques", "appeler Nora", "publier la version"),
        ("préparer la démo", "relire le contrat", "envoyer le message"),
        ("ouvrir le projet", "lancer les tests", "vérifier les journaux"),
        ("mettre à jour le budget", "confirmer la date", "prévenir le client"),
        ("corriger le document", "ajouter les chiffres", "exporter le fichier"),
        ("tester le micro", "mesurer la latence", "noter le résultat"),
    ]
    for first, second, third in french_lists:
        curriculum.add(
            "fr",
            "list",
            f"Premièrement {first} deuxièmement {second} troisièmement {third}",
            f"1. {first.capitalize()}\n2. {second.capitalize()}\n3. {third.capitalize()}",
            profile="document",
            app_category="Notes",
        )

    english_lists = [
        ("check the metrics", "call Nora", "publish the version"),
        ("prepare the demo", "review the contract", "send the message"),
        ("open the project", "run the tests", "check the logs"),
        ("update the budget", "confirm the date", "notify the customer"),
        ("correct the document", "add the figures", "export the file"),
        ("test the microphone", "measure the latency", "record the result"),
    ]
    for first, second, third in english_lists:
        curriculum.add(
            "en",
            "list",
            f"First {first} second {second} third {third}",
            f"1. {first.capitalize()}\n2. {second.capitalize()}\n3. {third.capitalize()}",
            profile="document",
            app_category="Notes",
        )

    corrections = [
        (
            "fr",
            "Envoie la facture jeudi non vendredi matin",
            "Envoie la facture vendredi matin.",
        ),
        (
            "fr",
            "La réunion est lundi enfin mardi après-midi",
            "La réunion est mardi après-midi.",
        ),
        ("fr", "Appelle Sophie pardon Nora avant midi", "Appelle Nora avant midi."),
        (
            "fr",
            "Le total est de 4200 euros non 4500 euros",
            "Le total est de 4500 euros.",
        ),
        ("fr", "Ouvre le fichier client pardon contrat", "Ouvre le fichier contrat."),
        (
            "en",
            "Send the invoice Thursday no Friday morning",
            "Send the invoice Friday morning.",
        ),
        (
            "en",
            "The meeting is Monday actually Tuesday afternoon",
            "The meeting is Tuesday afternoon.",
        ),
        ("en", "Call Sophie sorry Nora before noon", "Call Nora before noon."),
        (
            "en",
            "The total is 4200 euros no 4500 euros",
            "The total is 4500 euros.",
        ),
    ]
    for language, raw, target in corrections:
        curriculum.add(language, "self_correction", raw, target)


def add_noops(curriculum: Curriculum) -> None:
    french_subjects = [
        "Le rapport final",
        "La présentation",
        "Le contrat signé",
        "La nouvelle version",
        "Le compte rendu",
        "La facture corrigée",
        "Le document partagé",
        "La demande du client",
    ]
    french_predicates = [
        "est prêt pour la relecture.",
        "sera envoyé demain matin.",
        "reste disponible dans le dossier.",
        "a été validé par l'équipe.",
        "ne doit pas être publié aujourd'hui.",
        "peut être transmis au client.",
    ]
    for subject in french_subjects:
        for predicate in french_predicates:
            curriculum.add("fr", "noop", f"{subject} {predicate}", f"{subject} {predicate}")

    english_subjects = [
        "The final report",
        "The presentation",
        "The signed contract",
        "The new version",
        "The meeting notes",
        "The corrected invoice",
        "The shared document",
        "The customer request",
    ]
    english_predicates = [
        "is ready for review.",
        "will be sent tomorrow morning.",
        "remains available in the folder.",
        "was approved by the team.",
        "must not be published today.",
        "can be sent to the customer.",
    ]
    for subject in english_subjects:
        for predicate in english_predicates:
            curriculum.add("en", "noop", f"{subject} {predicate}", f"{subject} {predicate}")


def build(forbidden_suite: Path | None = DEFAULT_FORBIDDEN_SUITE) -> list[dict[str, object]]:
    transcripts, targets = forbidden_texts(forbidden_suite)
    curriculum = Curriculum(transcripts, targets)
    add_french_agreement(curriculum)
    add_english_agreement(curriculum)
    add_spelling(curriculum)
    add_composed_errors(curriculum)
    add_questions(curriculum)
    add_protected_and_developer_cases(curriculum)
    add_lists_and_corrections(curriculum)
    add_noops(curriculum)
    return sorted(curriculum.rows, key=lambda row: str(row["id"]))


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--forbidden-suite", type=Path, default=DEFAULT_FORBIDDEN_SUITE)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    rows = build(arguments.forbidden_suite)
    write_jsonl(arguments.output, rows)
    counts = Counter(
        (str(row["language"]), str(row["operations"][0])) for row in rows
    )
    write_json(
        arguments.report,
        {
            "counts": {
                language: {
                    category: counts[(language, category)]
                    for category in sorted(
                        {
                            str(row["operations"][0])
                            for row in rows
                            if row["language"] == language
                        }
                    )
                }
                for language in ("en", "fr")
            },
            "exampleCount": len(rows),
            "forbiddenSuite": str(arguments.forbidden_suite.resolve()),
            "output": str(arguments.output.resolve()),
            "outputSHA256": sha256(arguments.output),
            "schemaVersion": SCHEMA_VERSION,
            "source": SOURCE,
            "split": "train",
        },
    )
    print(json.dumps({"exampleCount": len(rows), "output": str(arguments.output)}))


if __name__ == "__main__":
    main()
