"""Offline regression tests for the author/company affiliation pilot."""

from __future__ import annotations

import copy
import contextlib
import hashlib
import io
import json
import shutil
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from collections import Counter

from scripts import author_company_history as ach


ROOT = Path(__file__).resolve().parents[1]
PILOT = ROOT / "data" / "author-affiliations"
SAMPLE_COMMITS = PILOT / "commits.json"
UTC = timezone.utc


def load_pilot() -> dict:
    data = ach.load_dataset(PILOT)
    return copy.deepcopy(data)


def history(*, status="supported", company_id="company:enterprisedb", start="2025-01-01T00:00:00Z",
            start_latest=None, end="2026-01-01T00:00:00Z", end_latest=None, ongoing=False,
            as_of=None, mode=None, group=None, history_id="test-history", person_id="person:bruce-momjian"):
    return {
        "history_id": history_id,
        "person_id": person_id,
        "company_id": company_id,
        "relationship_type": "employment",
        "status": status,
        "start_earliest": start,
        "start_latest": start_latest if start_latest is not None else start,
        "start_precision": "instant",
        "end_earliest": end if not ongoing else None,
        "end_latest": end_latest if end_latest is not None else (end if not ongoing else None),
        "end_precision": "instant",
        "end_ongoing": ongoing,
        "as_of": as_of,
        "evidence_ids": ["ev:bruce-2025-02-18"],
        "history_revision": "tests-v1",
        "estimation_method": "synthetic test evidence" if status == "estimated" else None,
        "review_status": "agent-reviewed",
        "relationship_group_mode": mode,
        "relationship_group_id": group,
    }


def participant_record(records, branch, commit_id, email=None, role=None):
    found = []
    for row in records:
        if row["branch"] != branch or row["commit_id"] != commit_id:
            continue
        if email and not any(c.get("email") == email for c in row["raw_credits"]):
            continue
        if role and role not in row["roles"]:
            continue
        found.append(row)
    if len(found) != 1:
        raise AssertionError(f"expected one participant, got {len(found)}")
    return found[0]


class CreditParsingTests(unittest.TestCase):
    def test_bare_email_and_ambiguous_address_list(self):
        self.assertEqual(ach.split_credit("author@example.test"), (None, "author@example.test"))
        self.assertEqual(ach.split_credit("Alice, Bob <person@example.test>"), (None, None))
        self.assertEqual(ach.split_credit("A <a@example.test>, B <b@example.test>"), (None, None))

    def test_local_part_case_is_not_folded_and_git_raw_fields_are_preserved(self):
        self.assertEqual(ach.normalize_email("Alice@EXAMPLE.TEST "), "Alice@example.test")
        self.assertNotEqual(ach.normalize_email("Alice@example.test"), ach.normalize_email("alice@example.test"))
        row = ach.extract_credits([{
            "branch": "master", "commit_id": "raw", "author_name": "  Alice  ",
            "author_email": "Alice@EXAMPLE.TEST ", "trailer_author": [], "co_authored_by": [],
        }])[0]
        self.assertEqual(row["raw_name"], "  Alice  ")
        self.assertEqual(row["raw_email"], "Alice@EXAMPLE.TEST ")

    def test_duplicate_person_roles_keep_all_occurrences_after_mapping(self):
        data = load_pilot()
        commit = {
            "branch": "master", "commit_id": "same-person", "author_name": "Bruce Momjian",
            "author_email": "bruce@MOMJIAN.US", "author_date": "2025-02-18T20:51:31Z",
            "commit_date": "2025-02-18T20:51:31Z",
            "trailer_author": ["Bruce Momjian <bruce@momjian.us>", "bruce@momjian.us"],
            "co_authored_by": [],
        }
        credits = ach.extract_credits([commit])
        records, coverage = ach.build_attributions([commit], credits, data, "committer")
        self.assertEqual(len(records), 1)
        self.assertEqual(len(records[0]["credit_ids"]), 3)
        self.assertEqual(records[0]["roles"], ["git_author", "patch_author"])
        self.assertEqual(coverage["identity_resolution_by_role"]["git_author"], {"total": 1, "resolved": 1, "unresolved": 0})
        self.assertEqual(coverage["identity_resolution_by_year_and_role"]["2025:git_author"], {"resolved": 1})


class PeriodAndAttributionTests(unittest.TestCase):
    def test_uncertain_bounds_use_possible_and_guaranteed_ranges(self):
        row = history(start="2025-01-01T00:00:00Z", start_latest="2025-02-01T00:00:00Z",
                      end="2025-06-01T00:00:00Z", end_latest="2025-07-01T00:00:00Z")
        self.assertEqual(ach.history_membership(row, datetime(2025, 1, 15, tzinfo=UTC)), ("possible", "uncertain_boundary"))
        self.assertEqual(ach.history_membership(row, datetime(2025, 3, 1, tzinfo=UTC)), ("guaranteed", None))
        self.assertEqual(ach.history_membership(row, datetime(2025, 6, 15, tzinfo=UTC)), ("possible", "uncertain_boundary"))
        self.assertEqual(ach.history_membership(row, datetime(2025, 7, 1, tzinfo=UTC)), ("none", None))

    def test_unknown_conflicting_bounds_are_checked_before_status(self):
        at = datetime(2025, 1, 1, tzinfo=UTC)
        conflict = history(status="conflicting", start="2011-01-01T00:00:00Z", end="2012-01-01T00:00:00Z")
        self.assertEqual(ach.history_membership(conflict, at), ("none", None))
        unknown_start = history(start=None, start_latest=None, end="2012-01-01T00:00:00Z", end_latest="2012-01-01T00:00:00Z")
        self.assertEqual(ach.history_membership(unknown_start, at), ("none", None))
        self.assertEqual(ach.history_membership(history(start=None, start_latest=None), at), ("unknown", "unknown_start_boundary"))

    def test_ongoing_period_stops_at_as_of(self):
        row = history(ongoing=True, as_of="2025-02-01T00:00:00Z")
        self.assertEqual(ach.history_membership(row, datetime(2025, 1, 31, 23, 59, tzinfo=UTC)), ("guaranteed", None))
        self.assertEqual(ach.history_membership(row, datetime(2025, 2, 1, tzinfo=UTC)), ("none", "outside_reviewed_horizon"))

    def test_gap_and_unclassified_overlap_do_not_claim_two_companies(self):
        data = load_pilot()
        first = history(start="2025-01-01T00:00:00Z", end="2025-02-01T00:00:00Z", history_id="first")
        second = history(company_id="company:databricks", start="2025-03-01T00:00:00Z", end="2025-04-01T00:00:00Z", history_id="second")
        data["histories"] = [first, second]
        gap = datetime(2025, 2, 15, tzinfo=UTC)
        self.assertEqual(ach.history_membership(first, gap), ("none", None))
        overlapping = [first, history(company_id="company:databricks", start=first["start_earliest"], end=first["end_earliest"], history_id="second-overlap")]
        data["histories"] = overlapping
        commit = {"branch": "master", "commit_id": "overlap", "author_name": "Bruce Momjian", "author_email": "bruce@momjian.us", "commit_date": "2025-01-15T00:00:00Z"}
        records, _ = ach.build_attributions([commit], ach.extract_credits([commit]), data, "committer")
        self.assertEqual(records[0]["attribution_status"], "unknown")
        self.assertEqual(records[0]["reason"], "unclassified_overlapping_companies")
        self.assertTrue(all(row["status"] == "candidate" for row in records[0]["affiliations"]))

    def test_only_explicit_shared_concurrent_group_allows_multiple_supported_companies(self):
        data = load_pilot()
        data["histories"] = [
            history(start="2025-01-01T00:00:00Z", end="2026-01-01T00:00:00Z", mode="concurrent", group="dual", history_id="edb"),
            history(company_id="company:databricks", start="2025-01-01T00:00:00Z", end="2026-01-01T00:00:00Z", mode="concurrent", group="dual", history_id="dbx"),
        ]
        commit = {"branch": "master", "commit_id": "concurrent", "author_name": "Bruce Momjian", "author_email": "bruce@momjian.us", "commit_date": "2025-03-01T00:00:00Z"}
        records, _ = ach.build_attributions([commit], ach.extract_credits([commit]), data, "committer")
        self.assertEqual(records[0]["attribution_status"], "supported")
        self.assertEqual({row["company_id"] for row in records[0]["affiliations"]}, {"company:enterprisedb", "company:databricks"})

    def test_alternative_candidates_are_not_two_supported_affiliations(self):
        data = load_pilot()
        data["histories"] = [
            history(start="2025-01-01T00:00:00Z", end="2026-01-01T00:00:00Z", mode="alternative", group="either", history_id="edb"),
            history(company_id="company:databricks", start="2025-01-01T00:00:00Z", end="2026-01-01T00:00:00Z", mode="alternative", group="either", history_id="dbx"),
        ]
        commit = {"branch": "master", "commit_id": "alternative", "author_name": "Bruce Momjian", "author_email": "bruce@momjian.us", "commit_date": "2025-03-01T00:00:00Z"}
        records, _ = ach.build_attributions([commit], ach.extract_credits([commit]), data, "committer")
        self.assertEqual(records[0]["attribution_status"], "unknown")
        self.assertTrue(all(row["status"] == "candidate" for row in records[0]["affiliations"]))

    def test_invalid_timestamp_never_falls_back_to_other_commit_date(self):
        data = load_pilot()
        commit = {"branch": "master", "commit_id": "bad-date", "author_name": "Bruce Momjian", "author_email": "bruce@momjian.us", "author_date": "2025-02-18T20:51:31Z", "commit_date": "not-a-date"}
        rows, _ = ach.build_attributions([commit], ach.extract_credits([commit]), data, "committer")
        self.assertIsNone(rows[0]["attribution_timestamp"])
        self.assertEqual(rows[0]["reason"], "invalid_timestamp")

    def test_missing_timestamp_never_falls_back(self):
        data = load_pilot()
        commit = {"branch": "master", "commit_id": "missing-date", "author_name": "Bruce Momjian", "author_email": "bruce@momjian.us", "author_date": "2025-02-18T20:51:31Z", "commit_date": None}
        rows, _ = ach.build_attributions([commit], ach.extract_credits([commit]), data, "committer")
        self.assertIsNone(rows[0]["attribution_timestamp"])
        self.assertEqual(rows[0]["reason"], "missing_timestamp")

    def test_committer_and_author_basis_can_differ_for_delayed_commit(self):
        data = load_pilot()
        commit = {"branch": "master", "commit_id": "delayed", "author_name": "Bruce Momjian", "author_email": "bruce@momjian.us", "author_date": "2025-02-17T20:51:31Z", "commit_date": "2025-02-18T20:51:31Z"}
        credits = ach.extract_credits([commit])
        committer_rows, _ = ach.build_attributions([commit], credits, data, "committer")
        author_rows, _ = ach.build_attributions([commit], credits, data, "author")
        self.assertEqual(committer_rows[0]["attribution_status"], "estimated")
        self.assertEqual(author_rows[0]["attribution_status"], "unknown")


class SnapshotAndCliTests(unittest.TestCase):
    def run_build(self, data_dir: Path, commits: Path, output: Path, basis="committer"):
        args = ["build", "--data-dir", str(data_dir), "--commits", str(commits), "--out-dir", str(output), "--timestamp-basis", basis]
        self.assertEqual(ach.main(args), 0)

    def test_real_pilot_validation_and_deterministic_build(self):
        self.assertEqual(ach.main(["validate", "--data-dir", str(PILOT)]), 0)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            one, two = root / "one", root / "two"
            self.run_build(PILOT, SAMPLE_COMMITS, one)
            self.run_build(PILOT, SAMPLE_COMMITS, two)
            names = ("raw_credits.json", "commit_author_companies.json", "coverage.json", "manifest.json")
            self.assertEqual({name: (one / name).read_bytes() for name in names}, {name: (two / name).read_bytes() for name in names})
            output = json.loads((one / "commit_author_companies.json").read_text())
            credits = json.loads((one / "raw_credits.json").read_text())
            self.assertEqual(len(credits), 16)
            self.assertEqual(len(output), 15)
            robert_git = participant_record(output, "master", "95dbd827f2edc4d10bebd7e840a0bd6782cf69b7", email="rhaas@postgresql.org")
            robert_patch = participant_record(output, "master", "95dbd827f2edc4d10bebd7e840a0bd6782cf69b7", email="robertmhaas@gmail.com")
            self.assertIsNone(robert_git["person_id"])
            self.assertEqual(robert_patch["person_id"], "person:robert-haas")
            bruce = participant_record(output, "master", "06dc1ffd24096f7c71d1abeaa9e96fec4db9313d", email="bruce@momjian.us")
            self.assertEqual(bruce["attribution_status"], "estimated")
            tom = participant_record(output, "master", "95f650674d2ceea1ba6440a9b0ae89ed3867fd7e", email="tgl@sss.pgh.pa.us")
            self.assertEqual(tom["attribution_status"], "unknown")
            self.assertTrue(any(credit["raw_value"] == "Laurenz Albe" for row in output if row["branch"] == "master" and row["commit_id"] == "06dc1ffd24096f7c71d1abeaa9e96fec4db9313d" and row["person_id"] is None for credit in row["raw_credits"]))

    def test_checked_in_sample_matches_full_export_and_hash(self):
        source = ROOT / "site" / "dist" / "data" / "commits.json"
        manifest = ach.read_json(PILOT / "manifest.json")
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), manifest["commit_source"]["sha256"])
        selected = {(row["branch"], row["commit_id"]): row for row in ach.read_json(SAMPLE_COMMITS)}
        full = {(row["branch"], row["commit_id"]): row for row in ach.read_json(source)}
        compare_fields = ("author_name", "author_email", "author_date", "committer_name", "committer_email", "commit_date", "summary", "trailer_author", "co_authored_by")
        for key, row in selected.items():
            self.assertIn(key, full)
            self.assertEqual({field: row.get(field) for field in compare_fields}, {field: full[key].get(field) for field in compare_fields})

    def test_validation_rejects_inverse_period_and_wrong_person_evidence(self):
        data = load_pilot()
        data["histories"][0]["end_earliest"] = "2010-01-01T00:00:00Z"
        data["histories"][0]["end_latest"] = "2010-01-01T00:00:00Z"
        self.assertTrue(any("earliest end cannot precede" in error or "latest possible end" in error for error in ach.validate_dataset(data)))
        data = load_pilot()
        data["histories"][0]["evidence_ids"] = ["ev:tom-2025-03-03"]
        self.assertTrue(any("does not support this person history" in error for error in ach.validate_dataset(data)))

    def test_message_id_revision_chain_is_explicit(self):
        data = load_pilot()
        old = {**data["evidence"][0], "evidence_id": "ev:revision-one", "message_id": "revision@example.test", "source_revision": 1}
        new = {**data["evidence"][0], "evidence_id": "ev:revision-two", "message_id": "revision@example.test", "source_revision": 2, "supersedes_evidence_id": "ev:revision-one"}
        data["evidence"].extend((old, new))
        self.assertEqual(ach.validate_dataset(data), [])
        data["evidence"][-1].pop("supersedes_evidence_id")
        self.assertTrue(any("explicitly supersede" in error for error in ach.validate_dataset(data)))

    def test_mapping_correction_rebuilds_without_losing_raw_credit(self):
        data = load_pilot()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            data_dir = root / "data"
            data_dir.mkdir()
            for name in ("manifest.json", "people.json", "identity-mappings.json", "companies.json", "evidence.json", "histories.json", "retrieval-ledger.json"):
                (data_dir / name).write_text(json.dumps(data["manifest"] if name == "manifest.json" else data[name.removesuffix(".json")]))
            commit = root / "commits.json"
            commit.write_text(json.dumps([{"branch": "master", "commit_id": "correction", "author_name": "Synthetic", "author_email": "synthetic@example.test", "commit_date": "2025-01-01T00:00:00Z", "trailer_author": ["Synthetic <synthetic@example.test>"], "co_authored_by": []}]))
            before = root / "before"
            self.run_build(data_dir, commit, before)
            rows_before = json.loads((before / "commit_author_companies.json").read_text())
            self.assertEqual(sum(row["person_id"] is None for row in rows_before), 2)
            copied = json.loads((data_dir / "people.json").read_text())
            copied.append({"person_id": "person:synthetic", "display_name": "Synthetic"})
            (data_dir / "people.json").write_text(json.dumps(copied))
            evidence = json.loads((data_dir / "evidence.json").read_text())
            evidence.append({"evidence_id": "ev:synthetic", "person_id": "person:synthetic", "sender_email": "synthetic@example.test", "company_id": None, "message_id": "synthetic-message-id", "source_url": None, "context": "Synthetic test fixture sender identity", "excerpt": "Synthetic test fixture", "source_date": None, "effective_date": None, "retrieved_at": "2026-09-29T00:00:00Z", "retrieval_precision": "day", "evidence_kind": "other", "review_status": "agent-reviewed"})
            (data_dir / "evidence.json").write_text(json.dumps(evidence))
            mappings = json.loads((data_dir / "identity-mappings.json").read_text())
            mappings.append({"mapping_id": "map:synthetic", "email": "synthetic@example.test", "person_id": "person:synthetic", "decision": "reviewed", "review_status": "agent-reviewed", "evidence_ids": ["ev:synthetic"], "mapping_revision": "mapping-v2"})
            (data_dir / "identity-mappings.json").write_text(json.dumps(mappings))
            manifest = json.loads((data_dir / "manifest.json").read_text())
            manifest["mapping_revision"] = "mapping-v2"
            (data_dir / "manifest.json").write_text(json.dumps(manifest))
            after = root / "after"
            self.run_build(data_dir, commit, after)
            rows_after = json.loads((after / "commit_author_companies.json").read_text())
            self.assertEqual(sum(row["person_id"] is None for row in rows_after), 0)
            self.assertEqual({row["raw_credits"][0]["raw_value"] for row in rows_after}, {"Synthetic <synthetic@example.test>"})
            before_manifest = json.loads((before / "manifest.json").read_text())
            after_manifest = json.loads((after / "manifest.json").read_text())
            self.assertNotEqual(before_manifest["input_sha256"]["identity-mappings.json"], after_manifest["input_sha256"]["identity-mappings.json"])

    def test_output_alias_and_symlink_are_rejected_before_write(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(ach.DataError):
                ach.ensure_output_is_separate(PILOT, PILOT, SAMPLE_COMMITS)
            out = root / "out"
            out.mkdir()
            (out / "manifest.json").symlink_to(PILOT / "evidence.json")
            with self.assertRaises(ach.DataError):
                ach.ensure_output_is_separate(out, PILOT, SAMPLE_COMMITS)

    def test_failed_validation_leaves_raw_inputs_and_existing_outputs_untouched(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            data_dir = root / "data"
            data_dir.mkdir()
            for source in PILOT.glob("*.json"):
                shutil.copyfile(source, data_dir / source.name)
            output = root / "output"
            output.mkdir()
            sentinel = output / "coverage.json"
            sentinel.write_text("sentinel\n")
            mapping_path = data_dir / "identity-mappings.json"
            mapping_bytes = mapping_path.read_bytes()
            mappings = json.loads(mapping_bytes)
            mappings[0]["evidence_ids"] = ["ev:tom-2025-03-03"]
            mapping_path.write_text(json.dumps(mappings))
            invalid_bytes = mapping_path.read_bytes()
            status = ach.main(["build", "--data-dir", str(data_dir), "--commits", str(SAMPLE_COMMITS), "--out-dir", str(output)])
            self.assertEqual(status, 2)
            self.assertEqual(mapping_path.read_bytes(), invalid_bytes)
            self.assertEqual(sentinel.read_text(), "sentinel\n")

    def test_required_snapshot_arrays_cannot_be_omitted(self):
        with tempfile.TemporaryDirectory() as temp:
            data_dir = Path(temp)
            for source in PILOT.glob("*.json"):
                if source.name != "histories.json":
                    shutil.copyfile(source, data_dir / source.name)
            with self.assertRaises(ach.DataError):
                ach.load_dataset(data_dir)


class ResearchCoverageTests(unittest.TestCase):
    def test_shared_primary_author_fallback_policy(self):
        cases = ach.read_json(ROOT / "tests" / "fixtures" / "author-fallback.json")
        for row in cases:
            with self.subTest(row["name"]):
                self.assertEqual(ach.primary_author_source(row["commit"]), row["source"])

    def test_frozen_rel19_cohort_and_complete_sender_query_inventory(self):
        data = load_pilot()
        scope = data["manifest"]["rel19_coverage_sample"]
        cohort_path = PILOT / scope["path"]
        commits = ach.read_json(cohort_path)
        self.assertEqual(hashlib.sha256(cohort_path.read_bytes()).hexdigest(), scope["sha256"])
        self.assertEqual(len(commits), 619)
        self.assertEqual(ach.validate_commit_snapshot(commits), [])
        fork = ach.parse_iso(scope["fork_commit_date"], field="fork_commit_date")
        for commit in commits:
            self.assertEqual(commit["branch"], "REL_19_STABLE")
            self.assertNotEqual(commit["commit_id"], scope["fork_commit"])
            self.assertGreater(ach.parse_iso(commit["commit_date"], field="commit_date"), fork)
            self.assertIsInstance(commit["author_email"], str)
        recovered = [c for c in commits if c["trailer_author"] != c["exported_trailer_author"]]
        self.assertEqual(len(recovered), 30)
        self.assertTrue(all(not c["exported_trailer_author"] and c["trailer_author"] for c in recovered))
        self.assertEqual(sum(not c["exported_trailer_author"] for c in commits), 242)
        report = ach.research_coverage(commits, data)
        self.assertEqual(report["coverage_funnel"], {
            "matched_company": 178, "no_author_credit": 8,
            "unresolved_author_identity": 357, "no_usable_company_at_date": 76})
        self.assertEqual(report["author_sources"], {"trailer_author": 407,
            "git_author_fallback": 204, "unextracted_author": 8})
        self.assertEqual(Counter(c["author_source"] for c in report["commits"] if c["company_ids"]),
                         {"trailer_author": 143, "git_author_fallback": 35})
        self.assertEqual(report["candidate_count"], 144)
        self.assertEqual(report["email_candidate_count"], 141)
        ledger = [r for r in data["retrieval-ledger"] if r["ledger_id"].startswith("ledger:rel19:")]
        self.assertEqual(len(ledger), 125)
        trailer_emails = {ach.normalize_email(c["email"]) for c in ach.extract_credits(commits)
                          if c["role"] == "patch_author" and c["email"]}
        self.assertEqual({r["author"] for r in ledger}, trailer_emails)
        self.assertEqual(sum(bool(r["message_ids"]) for r in ledger), 77)
        self.assertEqual(len({mid for r in ledger for mid in r["message_ids"]}), 150)
        self.assertTrue(all(r["query"] == "" and r["limit"] == 2 and not r["semantics_verified"]
                            and r["coverage_status"] == "sampled" for r in ledger))

    def test_saved_rel19_audit_is_reproducible_and_agrees_with_website(self):
        data = load_pilot()
        scope = data["manifest"]["rel19_coverage_sample"]
        commits = ach.read_json(PILOT / scope["path"])
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(ach.main(["research-coverage", "--data-dir", str(PILOT),
                "--commits", str(PILOT / scope["path"]), "--branch", scope["branch"], "--include-commits"]), 0)
        self.assertEqual(output.getvalue(), (PILOT / scope["audit_path"]).read_text())
        report = json.loads(output.getvalue())
        self.assertEqual(len(report["commits"]), len(commits))
        self.assertEqual(Counter(c["coverage_status"] for c in report["commits"]), report["coverage_funnel"])
        records, _ = ach.build_attributions(commits, ach.extract_credits(commits), data, "committer")
        website = ach.website_snapshot(commits, records, data, {})
        self.assertEqual(website["coverage"]["matched_commits"], 178)
        self.assertEqual({c["commit_id"] for c in report["commits"] if c["company_ids"]},
                         {c["commit_id"] for c in website["matches"]})
        self.assertEqual(Counter(a["company_id"] for c in website["matches"] for a in c["companies"]), {
            "company:amazon": 47, "company:microsoft": 52, "company:snowflake": 40,
            "company:enterprisedb": 21, "company:percona": 17, "company:databricks": 2})
        self.assertTrue(all(a["status"] == "estimated" for c in website["matches"] for a in c["companies"]))

    def test_rel19_profile_dates_and_bounded_estimates_remain_explicit(self):
        data = load_pilot()
        evidence = {e["evidence_id"]: e for e in data["evidence"]}
        profiles = [e for e in evidence.values() if e["evidence_id"].startswith("ev:rel19:profile-observed:")]
        self.assertEqual(len(profiles), 15)
        for row in profiles:
            self.assertIsNone(row["source_date"])
            self.assertEqual(row["observed_at"], "2026-09-30T00:00:00Z")
        histories = [h for h in data["histories"]
                     if h["history_revision"] == "rel19-since-fork-research-2026-09-30-v4"]
        self.assertEqual(len(histories), 88)
        self.assertEqual(sum(len(h["evidence_ids"]) == 2 for h in histories), 40)

        def observation_day(row):
            date = row.get("observation_month", "") + "-01" if row.get("observation_month") else (
                row.get("observed_at") or row["source_date"])[:10]
            return ach.parse_iso(date, field="observation_day")

        for row in histories:
            self.assertEqual(row["status"], "estimated")
            self.assertFalse(row["end_ongoing"])
            self.assertLessEqual(row["end_latest"], "2026-10-01T00:00:00Z")
            endpoints = [evidence[key] for key in row["evidence_ids"]]
            self.assertTrue(all(e["review_status"] != "rejected" for e in endpoints))
            self.assertEqual({e["person_id"] for e in endpoints}, {row["person_id"]})
            self.assertEqual({e["company_id"] for e in endpoints}, {row["company_id"]})
            if len(endpoints) != 2:
                continue
            left, right = endpoints
            self.assertIsNotNone(left["source_date"])
            start, end = observation_day(left), observation_day(right)
            self.assertGreater((end - start).days, 0)
            self.assertLessEqual((end - start).days, 366)
            for candidate in evidence.values():
                if (candidate["person_id"] != row["person_id"] or not candidate.get("company_id")
                        or candidate["review_status"] == "rejected"
                        or not (candidate.get("source_date") or candidate.get("observed_at"))):
                    continue
                if start <= observation_day(candidate) <= end:
                    self.assertEqual(candidate["company_id"], row["company_id"])

    def test_rel19_research_does_not_guess_transition_dates_or_extend_old_evidence(self):
        data = load_pilot()
        cases = [
            ("Richard Guo <guofenglinux@gmail.com>", "2026-09-15", None),
            ("Richard Guo <guofenglinux@gmail.com>", "2026-09-30", "company:microsoft"),
            ("Etsuro Fujita <etsuro.fujita@gmail.com>", "2026-09-15", None),
            ("Etsuro Fujita <etsuro.fujita@gmail.com>", "2026-09-30", "company:amazon"),
            ("Ayush Tiwari <ayushtiwari.slg01@gmail.com>", "2026-09-15", None),
            ("Tom Lane <tgl@sss.pgh.pa.us>", "2026-09-15", "company:snowflake"),
            ("Tom Lane <tgl@sss.pgh.pa.us>", "2026-10-01", None),
        ]
        commits = [{"branch": "REL_19_STABLE", "commit_id": str(i), "trailer_author": [credit],
                    "commit_date": day + "T12:00:00Z"} for i, (credit, day, _) in enumerate(cases)]
        report = ach.research_coverage(commits, data)
        for row in report["commits"]:
            expected = cases[int(row["commit_id"])][2]
            self.assertEqual(row["company_ids"], [expected] if expected else [])

    def test_branch_filter_and_missing_branch(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(ach.main(["research-coverage", "--data-dir", str(PILOT),
                "--commits", str(SAMPLE_COMMITS), "--branch", "master", "--include-commits"]), 0)
        report = json.loads(output.getvalue())
        self.assertEqual(report["branch_filter"], "master")
        self.assertTrue(all(row["branch"] == "master" for row in report["commits"]))
        self.assertEqual(sum(report["coverage_funnel"].values()), report["total_commits"])
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(ach.main(["research-coverage", "--data-dir", str(PILOT),
                "--commits", str(SAMPLE_COMMITS), "--branch", "missing"]), 2)

    def test_cli_report_is_read_only_and_identifies_input_revisions(self):
        before = {path.name: path.read_bytes() for path in PILOT.glob("*.json")}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = ach.main(["research-coverage", "--data-dir", str(PILOT),
                               "--commits", str(SAMPLE_COMMITS)])
        self.assertEqual(status, 0)
        report = json.loads(output.getvalue())
        self.assertEqual(report["commit_snapshot_sha256"], hashlib.sha256(SAMPLE_COMMITS.read_bytes()).hexdigest())
        self.assertEqual(report["research_provenance"]["input_sha256"]["histories.json"],
                         hashlib.sha256(before["histories.json"]).hexdigest())
        self.assertEqual(report["attribution_source"], "trailer_author_or_git_author")
        self.assertFalse(report["exhaustive_affiliation_research"])
        self.assertNotIn("commits", report)
        self.assertEqual(before, {path.name: path.read_bytes() for path in PILOT.glob("*.json")})

    def test_inventory_is_trailer_only_and_does_not_merge_names(self):
        data = load_pilot()
        data["histories"] = [history()]
        base = {"author_name": "Git Only", "author_email": "git@example.test",
                "co_authored_by": ["Coauthor <co@example.test>"],
                "commit_date": "2025-02-18T20:51:31Z", "commit_id": "same", "branch": "master"}
        commits = [
            {**base, "trailer_author": ["Bruce Momjian <bruce@MOMJIAN.US>", "bruce@momjian.us"]},
            {**base, "branch": "stable", "trailer_author": ["Bruce Momjian <bruce@momjian.us>"]},
            {**base, "commit_id": "unresolved", "trailer_author": ["Bruce Momjian", "Unreviewed <new@example.test>"]},
            {**base, "commit_id": "git-only"},
        ]
        report = ach.research_coverage(commits, data)
        self.assertEqual(report["candidate_count"], 3)
        self.assertEqual(report["email_candidate_count"], 2)
        self.assertEqual(report["resolved_people"], 1)
        self.assertEqual(report["coverage_funnel"], {"matched_company": 2,
            "no_author_credit": 1, "unresolved_author_identity": 1, "no_usable_company_at_date": 0})
        self.assertFalse(report["exhaustive_affiliation_research"])
        resolved = next(row for row in report["candidates"] if row["person_id"])
        self.assertEqual(resolved["commit_count"], 2)
        self.assertEqual(resolved["matched_commit_count"], 2)
        self.assertEqual(resolved["companies_with_history"], ["company:enterprisedb"])
        for row in report["candidates"]:
            if row["email"] != "bruce@momjian.us":
                self.assertIsNone(row["person_id"])
                self.assertEqual(row["matched_commit_count"], 0)

    def test_inventory_missing_dates_opaque_credits_and_determinism(self):
        data = load_pilot()
        commits = [{"branch": "master", "commit_id": "one", "trailer_author": [
            "Alice, Bob <person@example.test>", "Bruce Momjian <bruce@momjian.us>"]}]
        first = ach.research_coverage(commits, data)
        self.assertEqual(first, ach.research_coverage(commits, data))
        self.assertEqual(first["email_candidate_count"], 1)
        self.assertEqual(first["candidate_count"], 2)
        self.assertTrue(all(row["first_commit_date"] is None and row["last_commit_date"] is None
                            and row["matched_commit_count"] == 0 for row in first["candidates"]))


class WebsiteSnapshotTests(unittest.TestCase):
    def test_git_fallback_uses_exact_author_identity_and_existing_date_evidence(self):
        data = load_pilot()
        data["histories"] = [history(), history(person_id="person:tom-lane", company_id="company:snowflake", history_id="tom")]
        base = {"branch": "master", "author_name": "Bruce Momjian", "author_email": "bruce@momjian.us",
                "commit_date": "2025-02-18T20:51:31Z", "message": "Subject\n\nA correction.",
                "committer_name": "Tom Lane", "committer_email": "tgl@sss.pgh.pa.us", "trailer_author": []}
        commits = [
            {**base, "commit_id": "no-tags"},
            {**base, "commit_id": "coauthor-only", "message": "Subject\n\nCo-authored-by: Tom Lane <tgl@sss.pgh.pa.us>",
             "co_authored_by": ["Tom Lane <tgl@sss.pgh.pa.us>"]},
            {**base, "commit_id": "earlier-author", "message": "Subject\n\nAuthor: Someone\n\nBackpatch-through: 19"},
            {**base, "commit_id": "malformed-block", "message": "Subject\n\nAuthor: Someone\nBackpatch through: 19"},
            {**base, "commit_id": "unresolved-author", "trailer_author": ["Someone"]},
            {**base, "commit_id": "unresolved-git", "author_email": "unreviewed@example.test"},
            {**base, "commit_id": "name-only-git", "author_email": None},
            {**base, "commit_id": "missing-git", "author_name": None, "author_email": None},
            {**base, "commit_id": "undated", "commit_date": None},
            {**base, "commit_id": "outside-horizon", "commit_date": "2026-10-01T00:00:00Z"},
        ]
        before = copy.deepcopy(commits)
        credits = ach.extract_credits(commits)
        self.assertFalse(any(c["role"] == "patch_author" for c in credits if c["commit_id"] in {"no-tags", "coauthor-only"}))
        records, _ = ach.build_attributions(commits, credits, data, "committer")
        snapshot = ach.website_snapshot(commits, records, data, {})
        self.assertEqual(snapshot["matches"], [{"branch": "master", "commit_id": key,
            "author_source": "git_author_fallback", "companies": [{"company_id": "company:enterprisedb", "status": "supported"}]}
            for key in ["coauthor-only", "no-tags"]])
        report = ach.research_coverage(commits, data)
        self.assertEqual(report["matched_commits"], 2)
        self.assertEqual({c["commit_id"] for c in report["commits"] if c["company_ids"]}, {"no-tags", "coauthor-only"})
        self.assertNotIn("tgl@sss.pgh.pa.us", {c["email"] for c in report["candidates"]})
        self.assertEqual(commits, before)

    def test_website_projection_never_promotes_candidates_and_deduplicates_roles(self):
        def row(status, company_status="supported", company_id="company:enterprisedb", branch="master",
                roles=("patch_author",)):
            return {"branch": branch, "commit_id": "one", "attribution_status": status,
                    "roles": list(roles),
                    "affiliations": [{"company_id": company_id, "status": company_status}]}
        records = [row("supported"), row("estimated", "estimated"), row("unknown", company_id="company:databricks"),
                   row("conflicting", company_id="company:databricks"), row("supported", "candidate", "company:databricks"),
                   row("estimated", "estimated", branch="stable"),
                   row("supported", company_id="company:databricks", roles=("git_author",)),
                   row("supported", company_id="company:databricks", roles=("co_author",)),
                   row("supported", company_id="company:databricks", roles=()),
                   row("supported", branch="stable", roles=("git_author", "co_author"))]
        commits = [{"branch": branch, "commit_id": "one", "trailer_author": ["Explicit Person"]}
                   for branch in ("master", "stable")]
        snapshot = ach.website_snapshot(commits, records, load_pilot(), {"timestamp_basis": "committer"})
        self.assertEqual(snapshot["coverage"]["matched_commits"], 2)
        self.assertEqual(len(snapshot["companies"]), 6)
        self.assertEqual(snapshot["matches"][0]["companies"], [{"company_id": "company:enterprisedb", "status": "supported"}])
        self.assertEqual(snapshot["matches"][1]["companies"][0]["status"], "estimated")

    def test_website_uses_trailer_people_not_git_or_coauthor_people(self):
        data = load_pilot()
        data["histories"] = [
            history(),
            history(person_id="person:tom-lane", company_id="company:snowflake", history_id="tom"),
            history(person_id="person:zsolt-parragi", company_id="company:percona", history_id="zsolt"),
        ]
        commits = [{
            "branch": "master", "commit_id": "different-people", "author_name": "Bruce Momjian",
            "author_email": "bruce@momjian.us", "committer_email": "bruce@momjian.us",
            "author_date": "2024-01-01T00:00:00Z", "commit_date": "2025-02-18T20:51:31Z",
            "trailer_author": ["Tom Lane <tgl@sss.pgh.pa.us>", "Zsolt Parragi <zsolt.parragi@percona.com>"],
            "co_authored_by": ["Bruce Momjian <bruce@momjian.us>"],
        }]
        records, _ = ach.build_attributions(commits, ach.extract_credits(commits), data, "committer")
        # The offline audit still records all roles and their companies.
        self.assertEqual(len(records), 3)
        self.assertTrue(all(row["attribution_status"] == "supported" for row in records))
        snapshot = ach.website_snapshot(commits, records, data, {"timestamp_basis": "committer"})
        self.assertEqual(snapshot["matches"][0]["companies"], [
            {"company_id": "company:percona", "status": "supported"},
            {"company_id": "company:snowflake", "status": "supported"},
        ])

    def test_website_never_falls_back_without_message_or_for_unresolved_trailer_authors(self):
        data = load_pilot()
        data["histories"] = [history()]
        base = {"branch": "master", "author_name": "Bruce Momjian", "author_email": "bruce@momjian.us",
                "commit_date": "2025-02-18T20:51:31Z", "co_authored_by": ["Bruce Momjian <bruce@momjian.us>"]}
        commits = [{**base, "commit_id": "missing"}]
        for i, trailer in enumerate([None, [], ["Bruce Momjian"], ["Bruce <broken>"], ["Unknown <unknown@example.test>"]]):
            commits.append({**base, "commit_id": str(i), "trailer_author": trailer})
        # A Git/co-author qualifies only if also resolved from an actual Author trailer.
        commits.append({**base, "commit_id": "also-patch", "trailer_author": [
            "Bruce Momjian <bruce@momjian.us>", "Bruce Momjian <bruce@momjian.us>"]})
        records, _ = ach.build_attributions(commits, ach.extract_credits(commits), data, "committer")
        snapshot = ach.website_snapshot(commits, records, data, {})
        self.assertEqual(snapshot["matches"], [{"branch": "master", "commit_id": "also-patch", "author_source": "trailer_author", "companies": [
            {"company_id": "company:enterprisedb", "status": "supported"}]}])
        self.assertEqual(snapshot["coverage"]["matched_commits"], 1)

    def test_website_build_is_deterministic_sparse_and_bound_to_commit_snapshot(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            output = path / "company_affiliations.json"
            args = ["build-site", "--data-dir", str(PILOT), "--commits", str(SAMPLE_COMMITS), "--out-dir", str(path)]
            self.assertEqual(ach.main(args), 0)
            before = output.read_bytes()
            self.assertEqual(ach.main(args), 0)
            self.assertEqual(before, output.read_bytes())
            snapshot = json.loads(before)
            self.assertEqual(snapshot["schema_version"], 3)
            self.assertEqual(snapshot["attribution_source"], "trailer_author_or_git_author")
            self.assertEqual(snapshot["provenance"]["timestamp_basis"], "committer")
            self.assertEqual(snapshot["provenance"]["input_sha256"]["commit_snapshot_sha256"], hashlib.sha256(SAMPLE_COMMITS.read_bytes()).hexdigest())
            self.assertEqual(snapshot["coverage"], {"total_commits": 7, "matched_commits": 5,
                                                    "researched_people": len(load_pilot()["people"])})
            # Newly reviewed Robert histories now cover his five patch credits;
            # Bruce's Git-only EDB affiliation still cannot supply a match.
            self.assertTrue(all(row["companies"] == [{"company_id": "company:enterprisedb", "status": "estimated"}]
                                for row in snapshot["matches"]))
            self.assertEqual(len(snapshot["companies"]), 6)
            self.assertEqual(len(list(path.iterdir())), 1)

    def test_website_output_cannot_alias_input(self):
        with tempfile.TemporaryDirectory() as temp:
            data_dir = Path(temp) / "research"
            shutil.copytree(PILOT, data_dir)
            out = Path(temp) / "out"
            out.mkdir()
            original = (data_dir / "companies.json").read_bytes()
            (out / "company_affiliations.json").symlink_to(data_dir / "companies.json")
            self.assertEqual(ach.main(["build-site", "--data-dir", str(data_dir), "--commits", str(SAMPLE_COMMITS), "--out-dir", str(out)]), 2)
            self.assertEqual((data_dir / "companies.json").read_bytes(), original)


class SixCompanyCoverageTests(unittest.TestCase):
    def test_real_sample_keeps_six_company_catalog_but_excludes_git_only_matches(self):
        data = load_pilot()
        commits = ach.read_json(PILOT / "company-coverage-commits.json")
        self.assertEqual(ach.validate_dataset(data), [])
        self.assertEqual(ach.validate_commit_snapshot(commits), [])
        records, _ = ach.build_attributions(commits, ach.extract_credits(commits), data, "committer")
        snapshot = ach.website_snapshot(commits, records, data, {"timestamp_basis": "committer"})
        self.assertEqual({c["company_id"] for c in snapshot["companies"]}, {
            "company:microsoft", "company:amazon", "company:databricks",
            "company:snowflake", "company:enterprisedb", "company:percona",
        })
        self.assertEqual(snapshot["coverage"], {"total_commits": 6, "matched_commits": 4,
                                               "researched_people": len(data["people"])})
        self.assertEqual({c["company_id"] for row in snapshot["matches"] for c in row["companies"]}, {
            "company:microsoft", "company:amazon", "company:databricks", "company:percona",
        })
        self.assertTrue(all(row["commit_id"] not in {
            "06dc1ffd24096f7c71d1abeaa9e96fec4db9313d",  # Git Bruce, patch Laurenz
            "1fd772d192909a4f0e1ce88ebc72c8c43b81b025",  # Git Tom, patch Michael
        } for row in snapshot["matches"]))
        for row in snapshot["matches"]:
            self.assertEqual(len(row["companies"]), 1)
            self.assertEqual(row["companies"][0]["status"], "estimated")

    def test_aliases_share_company_ids_without_renaming_crunchy_data(self):
        data = load_pilot()
        aliases = {alias.casefold(): row["company_id"] for row in data["companies"] for alias in row["aliases"]}
        for alias in ("amazon", "aws", "amazon web services"):
            self.assertEqual(aliases[alias], "company:amazon")
        for alias in ("edb", "enterprisedb"):
            self.assertEqual(aliases[alias], "company:enterprisedb")
        self.assertEqual(aliases["snowflakes"], "company:snowflake")
        self.assertNotIn("crunchy data", aliases)

    def test_expansion_preserves_uncertainty_and_review_horizons(self):
        histories = {h["history_id"]: h for h in load_pilot()["histories"]}
        tom = histories["hist:tom-snowflake-parent-team"]
        self.assertEqual(tom["relationship_type"], "other")
        self.assertEqual(tom["status"], "estimated")
        self.assertEqual(ach.history_membership(tom, datetime(2025, 5, 31, tzinfo=UTC)), ("none", None))
        self.assertEqual(ach.history_membership(tom, datetime(2025, 6, 15, tzinfo=UTC)), ("possible", "uncertain_boundary"))
        self.assertEqual(ach.history_membership(tom, datetime(2026, 7, 15, tzinfo=UTC)), ("none", "outside_reviewed_horizon"))
        zsolt = histories["hist:zsolt-percona-retrospective"]
        self.assertEqual(ach.history_membership(zsolt, datetime(2016, 12, 31, tzinfo=UTC)), ("none", None))
        self.assertEqual(ach.history_membership(zsolt, datetime(2017, 6, 1, tzinfo=UTC)), ("possible", "uncertain_boundary"))
        self.assertEqual(ach.history_membership(zsolt, datetime(2026, 9, 29, tzinfo=UTC)), ("none", "outside_reviewed_horizon"))
        nazir = histories["hist:nazir-2026-03-18-observation"]
        self.assertEqual(ach.history_membership(nazir, datetime(2026, 3, 19, tzinfo=UTC)), ("none", None))

    def test_domains_plus_aliases_and_current_employers_are_not_guessed(self):
        data = load_pilot()
        commits = [
            {"branch": "master", "commit_id": str(i), "author_email": email,
             "author_name": name, "commit_date": "2026-03-02T10:00:00Z"}
            for i, (email, name) in enumerate([
                ("unresearched@microsoft.com", "Unresearched Person"),
                ("msawada@postgresql.org", "Masahiko Sawada"),
                ("boekewurm@gmail.com", "Matthias van de Meent"),
                ("robertmhaas@gmail.com", "Robert Haas"),
            ])
        ]
        records, _ = ach.build_attributions(commits, ach.extract_credits(commits), data, "committer")
        self.assertTrue(all(r["attribution_status"] == "unknown" for r in records if r["commit_id"] != "3"))
        robert = next(r for r in records if r["commit_id"] == "3")
        self.assertEqual(robert["attribution_status"], "estimated")
        self.assertEqual({a["company_id"] for a in robert["affiliations"]}, {"company:enterprisedb"})
        self.assertEqual(ach.website_snapshot(commits, records, data, {})["matches"], [])

    def test_new_transition_observations_do_not_fill_company_change_gaps(self):
        data = load_pilot()
        cases = [
            ("Robert Haas <robertmhaas@gmail.com>", "2026-08-31", "company:enterprisedb"),
            ("Robert Haas <robertmhaas@gmail.com>", "2026-09-10", None),
            ("Robert Haas <robertmhaas@gmail.com>", "2026-09-29", "company:databricks"),
            ("Tristan Partin <tristan@partin.io>", "2026-01-10", "company:databricks"),
            ("Tristan Partin <tristan@partin.io>", "2026-06-01", None),
            ("Tristan Partin <tristan@partin.io>", "2026-09-28", "company:amazon"),
        ]
        commits = [{"branch": "master", "commit_id": str(i), "trailer_author": [credit],
                    "commit_date": day + "T12:00:00Z"}
                   for i, (credit, day, _) in enumerate(cases)]
        records, _ = ach.build_attributions(commits, ach.extract_credits(commits), data, "committer")
        patch_rows = [row for row in records if "patch_author" in row["roles"]]
        self.assertEqual(len(patch_rows), len(cases))
        for row in patch_rows:
            expected = cases[int(row["commit_id"])][2]
            self.assertEqual(row["attribution_status"], "estimated" if expected else "unknown")
            self.assertEqual({a["company_id"] for a in row["affiliations"]}, {expected} if expected else set())

    def test_bounded_estimates_have_two_nearby_same_company_observations(self):
        data = load_pilot()
        evidence = {e["evidence_id"]: e for e in data["evidence"]}
        bounded = [h for h in data["histories"] if h["history_id"].startswith("hist:bounded-")]
        self.assertGreater(len(bounded), 100)
        for history_row in bounded:
            self.assertEqual(history_row["status"], "estimated")
            self.assertFalse(history_row["end_ongoing"])
            self.assertEqual(len(history_row["evidence_ids"]), 2)
            left, right = [evidence[key] for key in history_row["evidence_ids"]]
            start, end = [datetime.fromisoformat(e["source_date"][:10]).replace(tzinfo=UTC)
                          for e in (left, right)]
            self.assertGreater((end - start).days, 0)
            self.assertLessEqual((end - start).days, 366)
            self.assertEqual(history_row["start_earliest"], start.strftime("%Y-%m-%dT00:00:00Z"))
            self.assertEqual(history_row["end_earliest"], end.strftime("%Y-%m-%dT23:59:59Z"))
            self.assertEqual({left["person_id"], right["person_id"]}, {history_row["person_id"]})
            self.assertEqual({left["company_id"], right["company_id"]}, {history_row["company_id"]})
            for observation in evidence.values():
                if (observation["person_id"] != history_row["person_id"] or not observation.get("company_id")
                        or not observation.get("source_date") or observation["review_status"] == "rejected"):
                    continue
                observed = ach.parse_iso(observation["source_date"], field="source_date")
                if start <= observed < end:
                    self.assertEqual(observation["company_id"], history_row["company_id"])

    def test_expanded_people_have_reviewed_identity_and_affiliation_evidence(self):
        data = load_pilot()
        self.assertGreaterEqual(len(data["people"]), 58)
        mapped = {row["person_id"] for row in data["identity-mappings"]}
        researched = {row["person_id"] for row in data["histories"]}
        for person in data["people"]:
            self.assertIn(person["person_id"], mapped)
            self.assertIn(person["person_id"], researched)
        self.assertFalse(any("generated.invalid" in (e.get("source_url") or "") for e in data["evidence"]))

    def test_research_manifest_hashes_and_exact_empty_queries(self):
        data = load_pilot()
        manifest = data["manifest"]
        self.assertEqual(manifest["evidence_snapshot"], "RESEARCH.md sha256:" + hashlib.sha256((PILOT / "RESEARCH.md").read_bytes()).hexdigest())
        self.assertEqual(manifest["company_coverage_sample"]["sha256"], hashlib.sha256((PILOT / "company-coverage-commits.json").read_bytes()).hexdigest())
        self.assertEqual(manifest["company_coverage_sample"]["source_export_sha256"], manifest["commit_source"]["sha256"])
        empty = [r for r in data["retrieval-ledger"] if r["query"] == ""]
        self.assertGreaterEqual(len(empty), 2)
        self.assertEqual(ach.validate_dataset(data), [])
        empty[0].pop("author")
        self.assertTrue(any("exact query string" in error for error in ach.validate_dataset(data)))


if __name__ == "__main__":
    unittest.main()
