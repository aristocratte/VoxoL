import copy
import unittest

import dictation_campaign as c
import reference_contract_v2 as r


def inputs(text="Keep 3 commits, not 4."):
    return {"schemaVersion": "voxol-ai-text-reference-review-v2", "sourceManifestSHA256": "1" * 64,
            "trainingEligible": False, "humanReviewed": False, "audioReviewed": False,
            "items": [{"id": "case-1", "sourceGroup": "group-1", "audioSHA256": "2" * 64,
                       "sourceItemSHA256": "3" * 64, "verbatim": text,
                       "verbatimSHA256": r.sha_text(text), "parentProvenance": "ai-legacy"}]}


def review(source, **overrides):
    item = source["items"][0]
    return {"id": item["id"], "verbatimSHA256": item["verbatimSHA256"],
            "decision": "accepted", "faithfulText": item["verbatim"], "reason": "text-only review", **overrides}


class ReferenceContractV2Tests(unittest.TestCase):
    def test_ai_review_cannot_become_human_or_training_approval(self):
        source = inputs()
        row = review(source, humanReviewed=True, trainingEligible=True)
        result = r.apply_reviews(source, [row])
        self.assertFalse(result["humanReviewed"])
        self.assertFalse(result["trainingEligible"])
        self.assertFalse(result["items"][0]["humanReviewed"])
        self.assertFalse(result["items"][0]["trainingEligible"])
        self.assertFalse(result["audioReviewed"])

    def test_all_inputs_need_explicit_decision(self):
        with self.assertRaises(ValueError):
            r.apply_reviews(inputs(), [])

    def test_duplicate_review_rejected(self):
        source = inputs()
        with self.assertRaises(ValueError):
            r.apply_reviews(source, [review(source), review(source)])

    def test_rejects_unknown_id(self):
        source = inputs()
        with self.assertRaises(ValueError):
            r.apply_reviews(source, [review(source, id="held-out-do-not-use")])

    def test_stale_verbatim_cannot_be_reviewed(self):
        source = inputs()
        with self.assertRaises(ValueError):
            r.apply_reviews(source, [review(source, verbatimSHA256="0" * 64)])

    def test_number_role_swap_requires_explanation(self):
        source = inputs()
        with self.assertRaises(ValueError):
            r.apply_reviews(source, [review(source, faithfulText="Keep 4 commits, not 3.")])

    def test_negation_deletion_requires_explanation(self):
        source = inputs("Do not delete the backup.")
        with self.assertRaises(ValueError):
            r.apply_reviews(source, [review(source, faithfulText="Do delete the backup.")])

    def test_excluded_case_has_no_usable_target(self):
        source = inputs()
        result = r.apply_reviews(source, [review(source, decision="excluded", faithfulText=None, reason="ambiguous")])
        self.assertIsNone(result["items"][0]["faithfulText"])
        self.assertIsNone(result["items"][0]["faithfulSHA256"])

    def test_exclusion_cannot_keep_target(self):
        source = inputs()
        with self.assertRaises(ValueError):
            r.apply_reviews(source, [review(source, decision="excluded")])

    def test_accepted_target_cannot_be_empty(self):
        source = inputs()
        with self.assertRaises(ValueError):
            r.apply_reviews(source, [review(source, faithfulText=" ")])

    def test_parent_and_audio_are_preserved(self):
        source = inputs()
        original = copy.deepcopy(source)
        result = r.apply_reviews(source, [review(source)])
        self.assertEqual(source, original)
        self.assertEqual(result["items"][0]["audioSHA256"], "2" * 64)
        self.assertEqual(result["items"][0]["sourceGroup"], "group-1")
        self.assertEqual(result["items"][0]["parentProvenance"], "ai-legacy")

    def test_reproducible_content_hash(self):
        source = inputs()
        first = r.apply_reviews(source, [review(source)])
        second = r.apply_reviews(source, [review(source)])
        self.assertEqual(first["referenceSetSHA256"], second["referenceSetSHA256"])
        digest_input = {k: v for k, v in first.items() if k != "referenceSetSHA256"}
        self.assertEqual(c.digest(digest_input), first["referenceSetSHA256"])


if __name__ == "__main__":
    unittest.main()
