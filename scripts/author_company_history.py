#!/usr/bin/env python3
"""Build an auditable, offline commit-participant/company attribution snapshot.

The input directory is an explicitly reviewed pilot dataset. This tool does not
infer employment from signatures, company names, or missing evidence; it applies
only the person mappings and affiliation histories supplied by reviewers.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from collections import Counter, defaultdict
from datetime import date, datetime, time, timezone
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = "1"
RULE_VERSION = "author-company-attribution/1"
ROLES = ("git_author", "patch_author", "co_author")
RELATIONSHIPS = {"employment", "consulting", "other", "unknown"}
HISTORY_STATUSES = {"supported", "estimated", "unknown", "conflicting"}
PRECISIONS = {"instant", "day", "month", "year", "unknown"}
EVIDENCE_KINDS = {"mail_body_first_person", "mail_signature", "company_announcement", "personal_announcement", "conference_bio", "mutable_inconclusive_observation", "other"}
REVIEW_STATUSES = {"agent-reviewed", "human-reviewed"}
EMAIL_RE = re.compile(r"^(.*?)\s*<([^<>]+)>\s*$")
BARE_EMAIL_RE = re.compile(r"^[^@\s<>]+@[^@\s<>]+$")


class DataError(ValueError):
    """Raised for invalid or internally inconsistent pilot data."""


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def stable_id(prefix: str, *parts: str) -> str:
    payload = "\0".join(parts).encode("utf-8")
    return f"{prefix}_{hashlib.sha256(payload).hexdigest()[:24]}"


def read_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        if default is not None:
            return default
        raise DataError(f"required file is missing: {path}")
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise DataError(f"cannot read JSON {path}: {exc}") from exc


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = canonical_json(value)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def parse_iso(value: Any, *, field: str, allow_date: bool = True) -> datetime | None:
    if value is None or value == "":
        return None
    if not isinstance(value, str):
        raise DataError(f"{field} must be an ISO-8601 string or null")
    try:
        if allow_date and re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            parsed = datetime.combine(date.fromisoformat(value), time.min, timezone.utc)
        else:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise DataError(f"{field} is not a valid ISO-8601 date/time: {value!r}") from exc
    if parsed.tzinfo is None:
        raise DataError(f"{field} must include a timezone (use Z for UTC)")
    return parsed.astimezone(timezone.utc)


def iso_utc(value: datetime | None) -> str | None:
    return value.isoformat(timespec="seconds").replace("+00:00", "Z") if value else None


def normalize_email(value: Any) -> str:
    """Trim the address and lowercase only its domain, preserving local-part case."""
    if not isinstance(value, str):
        return ""
    address = value.strip()
    if address.count("@") != 1:
        return ""
    local, domain = address.rsplit("@", 1)
    if not local or not domain:
        return ""
    return f"{local}@{domain.lower()}"


def load_dataset(data_dir: Path) -> dict[str, Any]:
    names = ("people", "identity-mappings", "companies", "evidence", "histories", "retrieval-ledger")
    result: dict[str, Any] = {name: read_json(data_dir / f"{name}.json") for name in names}
    result["manifest"] = read_json(data_dir / "manifest.json")
    for name in names:
        if not isinstance(result[name], list):
            raise DataError(f"{name}.json must contain a JSON array")
    if not isinstance(result["manifest"], dict):
        raise DataError("manifest.json must contain a JSON object")
    return result


def validate_dataset(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    manifest = data["manifest"]
    if str(manifest.get("schema_version")) != SCHEMA_VERSION:
        errors.append(f"manifest.schema_version must be {SCHEMA_VERSION!r}")
    for key in ("evidence_snapshot", "mapping_revision", "history_revision", "rule_revision", "retrieval_ledger_revision"):
        if not isinstance(manifest.get(key), str) or not manifest[key].strip():
            errors.append(f"manifest.{key} must be a non-empty string")

    def index_rows(name: str, key: str) -> dict[str, dict[str, Any]]:
        index: dict[str, dict[str, Any]] = {}
        for i, row in enumerate(data[name]):
            if not isinstance(row, dict):
                errors.append(f"{name}[{i}] must be an object")
                continue
            value = row.get(key)
            if not isinstance(value, str) or not value.strip():
                errors.append(f"{name}[{i}].{key} must be a non-empty string")
            elif value in index:
                errors.append(f"duplicate {name}.{key}: {value}")
            else:
                index[value] = row
        return index

    people = index_rows("people", "person_id")
    companies = index_rows("companies", "company_id")
    evidence = index_rows("evidence", "evidence_id")
    mappings = index_rows("identity-mappings", "mapping_id")
    histories = index_rows("histories", "history_id")
    for person_id, row in people.items():
        if not isinstance(row.get("display_name"), str) or not row["display_name"].strip():
            errors.append(f"person {person_id} requires a display_name")
    emails: dict[str, str] = {}
    for mapping_id, row in mappings.items():
        email = row.get("email")
        person_id = row.get("person_id")
        if not isinstance(email, str) or not email.strip() or "@" not in email:
            errors.append(f"identity mapping {mapping_id} requires a valid exact email")
        else:
            normalized = normalize_email(email)
            if normalized in emails:
                errors.append(f"email {email!r} maps more than once ({emails[normalized]}, {mapping_id})")
            emails[normalized] = mapping_id
        if person_id not in people:
            errors.append(f"identity mapping {mapping_id} references unknown person_id {person_id!r}")
        if row.get("decision") != "reviewed":
            errors.append(f"identity mapping {mapping_id} must have decision='reviewed'")
        if row.get("review_status") not in REVIEW_STATUSES:
            errors.append(f"identity mapping {mapping_id} requires review_status agent-reviewed or human-reviewed")
        refs = row.get("evidence_ids", [])
        if not isinstance(refs, list) or not refs or any(ref not in evidence for ref in refs):
            errors.append(f"identity mapping {mapping_id} has invalid evidence_ids")
        if not isinstance(row.get("mapping_revision"), str) or not row.get("mapping_revision"):
            errors.append(f"identity mapping {mapping_id} requires mapping_revision")
        for ref in refs if isinstance(refs, list) else []:
            ev = evidence.get(ref, {})
            if ev.get("person_id") != person_id or ev.get("review_status") == "rejected":
                errors.append(f"identity mapping {mapping_id} evidence {ref} does not support this person mapping")
            if normalize_email(ev.get("sender_email", "")) != normalize_email(email or ""):
                errors.append(f"identity mapping {mapping_id} evidence {ref} does not verify the exact sender email")

    aliases: dict[str, str] = {}
    for company_id, row in companies.items():
        if not isinstance(row.get("name"), str) or not row["name"].strip():
            errors.append(f"company {company_id} requires a name")
        if not isinstance(row.get("aliases"), list) or not row["aliases"]:
            errors.append(f"company {company_id} requires a non-empty aliases array")
        for alias in row.get("aliases", []):
            if not isinstance(alias, str) or not alias.strip():
                errors.append(f"company {company_id} has an empty alias")
                continue
            token = alias.strip().casefold()
            if token in aliases and aliases[token] != company_id:
                errors.append(f"company alias {alias!r} belongs to multiple companies")
            aliases[token] = company_id

    for evidence_id, row in evidence.items():
        if not isinstance(row.get("retrieved_at"), str):
            errors.append(f"evidence {evidence_id} requires retrieved_at")
        if row.get("retrieval_precision", "instant") not in {"instant", "day"}:
            errors.append(f"evidence {evidence_id} has invalid retrieval_precision")
        if row.get("source_url") is not None and not isinstance(row.get("source_url"), str):
            errors.append(f"evidence {evidence_id}.source_url must be a string or null")
        if row.get("message_id") is not None and not isinstance(row.get("message_id"), str):
            errors.append(f"evidence {evidence_id}.message_id must be a string or null")
        for field in ("source_url", "message_id", "source_date", "effective_date", "retrieved_at"):
            if field in row and row[field] not in (None, ""):
                try:
                    parse_iso(row[field], field=f"evidence.{evidence_id}.{field}") if field.endswith("date") or field == "retrieved_at" else None
                except DataError as exc:
                    errors.append(str(exc))
        if not any(row.get(k) for k in ("source_url", "message_id")):
            errors.append(f"evidence {evidence_id} needs source_url or message_id")
        if not isinstance(row.get("person_id"), str) or row.get("person_id") not in people:
            errors.append(f"evidence {evidence_id} requires a known person_id identifying the source subject")
        if row.get("company_id") is not None and row.get("company_id") not in companies:
            errors.append(f"evidence {evidence_id} references unknown company_id")
        if row.get("evidence_kind") not in EVIDENCE_KINDS:
            errors.append(f"evidence {evidence_id} has invalid evidence_kind")
        if row.get("review_status") not in REVIEW_STATUSES | {"rejected"}:
            errors.append(f"evidence {evidence_id} has invalid review_status")
        if not isinstance(row.get("context"), str) or not row["context"].strip():
            errors.append(f"evidence {evidence_id} requires context identifying whose claim is recorded")
        if not row.get("excerpt"):
            errors.append(f"evidence {evidence_id} requires an excerpt")

    message_revisions: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in evidence.values():
        if row.get("message_id"):
            message_revisions[row["message_id"]].append(row)
    for message_id, rows in message_revisions.items():
        if len(rows) > 1:
            revisions = [r.get("source_revision") for r in rows]
            if any(not isinstance(rev, int) or rev < 1 for rev in revisions) or len(set(revisions)) != len(rows):
                errors.append(f"duplicate Message-ID {message_id} requires unique positive source_revision values")
            ordered = sorted(rows, key=lambda r: r.get("source_revision", 0))
            for previous, current in zip(ordered, ordered[1:]):
                if current.get("supersedes_evidence_id") != previous.get("evidence_id"):
                    errors.append(f"Message-ID {message_id} revision must explicitly supersede the previous evidence row")

    for history_id, row in histories.items():
        if row.get("person_id") not in people:
            errors.append(f"history {history_id} references unknown person_id")
        if row.get("company_id") not in companies:
            errors.append(f"history {history_id} references unknown company_id")
        if row.get("relationship_type") not in RELATIONSHIPS:
            errors.append(f"history {history_id} has invalid relationship_type")
        if row.get("status") not in HISTORY_STATUSES:
            errors.append(f"history {history_id} has invalid status")
        if not row.get("history_revision"):
            errors.append(f"history {history_id} requires history_revision")
        if row.get("review_status") not in REVIEW_STATUSES:
            errors.append(f"history {history_id} requires review_status agent-reviewed or human-reviewed")
        refs = row.get("evidence_ids", [])
        if not isinstance(refs, list) or any(ref not in evidence for ref in refs):
            errors.append(f"history {history_id} has invalid evidence_ids")
        for ref in refs if isinstance(refs, list) else []:
            ev = evidence.get(ref, {})
            if ev.get("person_id") != row.get("person_id") or ev.get("review_status") == "rejected":
                errors.append(f"history {history_id} evidence {ref} does not support this person history")
            if row.get("status") in {"supported", "estimated"} and ev.get("company_id") != row.get("company_id"):
                errors.append(f"history {history_id} evidence {ref} does not identify the attributed company")
            elif ev.get("company_id") not in (None, row.get("company_id")):
                errors.append(f"history {history_id} evidence {ref} names a different company")
        if row.get("status") in {"supported", "estimated"} and not refs:
            errors.append(f"history {history_id} cannot be {row.get('status')} without evidence")
        if row.get("status") == "estimated" and not row.get("estimation_method"):
            errors.append(f"estimated history {history_id} requires estimation_method")
        if row.get("relationship_group_mode") not in (None, "concurrent", "alternative"):
            errors.append(f"history {history_id} relationship_group_mode must be concurrent or alternative")
        if row.get("relationship_group_mode") and not row.get("relationship_group_id"):
            errors.append(f"history {history_id} relationship_group_mode requires relationship_group_id")
        bounds: dict[str, datetime | None] = {}
        for key in ("start_earliest", "start_latest", "end_earliest", "end_latest"):
            try:
                bounds[key] = parse_iso(row.get(key), field=f"history.{history_id}.{key}")
            except DataError as exc:
                errors.append(str(exc))
                bounds[key] = None
        if bounds["start_earliest"] and bounds["start_latest"] and bounds["start_earliest"] > bounds["start_latest"]:
            errors.append(f"history {history_id} start_earliest is after start_latest")
        if bounds["end_earliest"] and bounds["end_latest"] and bounds["end_earliest"] > bounds["end_latest"]:
            errors.append(f"history {history_id} end_earliest is after end_latest")
        if row.get("start_precision", "unknown") not in PRECISIONS or row.get("end_precision", "unknown") not in PRECISIONS:
            errors.append(f"history {history_id} has invalid date precision")
        if row.get("end_ongoing") and (row.get("end_earliest") or row.get("end_latest")):
            errors.append(f"history {history_id}: end_ongoing cannot have end bounds")
        if row.get("end_ongoing") and not row.get("as_of"):
            errors.append(f"history {history_id}: end_ongoing requires an explicit as_of horizon")
        if row.get("as_of"):
            try:
                parse_iso(row.get("as_of"), field=f"history.{history_id}.as_of")
            except DataError as exc:
                errors.append(str(exc))
        if not row.get("end_ongoing") and not row.get("end_earliest") and not row.get("end_latest") and row.get("status") in {"supported", "estimated"}:
            errors.append(f"history {history_id}: supported/estimated periods need bounded end or explicit end_ongoing")
        if bounds["start_earliest"] and bounds["end_latest"] and bounds["end_latest"] <= bounds["start_earliest"]:
            errors.append(f"history {history_id}: latest possible end must be after earliest possible start")
        if bounds["start_earliest"] and bounds["end_earliest"] and bounds["end_earliest"] < bounds["start_earliest"]:
            errors.append(f"history {history_id}: earliest end cannot precede earliest start")
        if bounds["start_latest"] and bounds["end_latest"] and bounds["end_latest"] <= bounds["start_latest"]:
            # Empty guaranteed interval is valid when boundary uncertainty is intentional.
            if bounds["end_latest"] <= bounds["start_earliest"]:
                errors.append(f"history {history_id}: no possible interval remains")

    seen_ledger_ids: set[str] = set()
    for i, row in enumerate(data["retrieval-ledger"]):
        if not isinstance(row, dict):
            errors.append(f"retrieval-ledger[{i}] must be an object")
            continue
        ledger_id = row.get("ledger_id")
        if not ledger_id or ledger_id in seen_ledger_ids:
            errors.append(f"retrieval-ledger[{i}] requires a unique ledger_id")
        seen_ledger_ids.add(ledger_id)
        has_sender_filter = isinstance(row.get("author"), str) and bool(row["author"].strip())
        if not isinstance(row.get("query"), str) or (not row["query"].strip() and not has_sender_filter):
            errors.append(f"retrieval ledger {ledger_id} requires the exact query string (sender-filtered empty queries are allowed)")
        if not isinstance(row.get("senders"), list) or any(not isinstance(sender, str) or not sender for sender in row["senders"]):
            errors.append(f"retrieval ledger {ledger_id} senders must be an array of addresses")
        message_ids = row.get("message_ids")
        if not isinstance(message_ids, list) or any(not isinstance(mid, str) or not mid for mid in message_ids):
            errors.append(f"retrieval ledger {ledger_id} message_ids must be an array of Message-IDs")
        elif len(message_ids) != len(set(message_ids)):
            errors.append(f"retrieval ledger {ledger_id} repeats a Message-ID")
        if not isinstance(row.get("semantics_verified"), bool):
            errors.append(f"retrieval ledger {ledger_id} semantics_verified must be boolean")
        if row.get("coverage_status") not in {"sampled", "bounded", "exhaustive"}:
            errors.append(f"retrieval ledger {ledger_id} has invalid coverage_status")
        if row.get("semantics_verified") is not True and row.get("coverage_status") == "exhaustive":
            errors.append(f"retrieval ledger {ledger_id}: unverified query semantics cannot claim exhaustive coverage")
        try:
            parse_iso(row.get("retrieved_at"), field=f"retrieval-ledger.{ledger_id}.retrieved_at")
        except DataError as exc:
            errors.append(str(exc))
        for field in ("after", "before"):
            if row.get(field):
                try:
                    parse_iso(row[field], field=f"retrieval-ledger.{ledger_id}.{field}")
                except DataError as exc:
                    errors.append(str(exc))
        for field in ("offset", "limit"):
            if row.get(field) is not None and (not isinstance(row[field], int) or row[field] < 0):
                errors.append(f"retrieval ledger {ledger_id} {field} must be a non-negative integer or null")
    return errors


def split_credit(raw_value: Any, fallback_name: Any = None, fallback_email: Any = None) -> tuple[str | None, str | None]:
    if isinstance(raw_value, str):
        value = raw_value.strip()
        if value.count("<") == 1 and value.count(">") == 1:
            if "," in value.split("<", 1)[0]:
                return None, None
            match = EMAIL_RE.fullmatch(value)
            if match and BARE_EMAIL_RE.fullmatch(match.group(2).strip()):
                return match.group(1).strip() or None, match.group(2).strip()
            return None, None
        if BARE_EMAIL_RE.fullmatch(value):
            return None, value
        if "<" in value or ">" in value:
            return None, None
        return value or None, None
    name = fallback_name if isinstance(fallback_name, str) else None
    email = fallback_email if isinstance(fallback_email, str) else None
    return (name or None, email or None)


def extract_credits(commits: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not isinstance(commits, list):
        raise DataError("commit snapshot must contain a JSON array")
    output: list[dict[str, Any]] = []
    for row_number, commit in enumerate(commits):
        if not isinstance(commit, dict) or not commit.get("branch") or not commit.get("commit_id"):
            raise DataError(f"commit row {row_number} needs branch and commit_id")
        branch, commit_id = str(commit["branch"]), str(commit["commit_id"])
        raw_name = commit.get("author_name") if isinstance(commit.get("author_name"), str) else None
        raw_email = commit.get("author_email") if isinstance(commit.get("author_email"), str) else None
        name, email = split_credit(None, raw_name, raw_email)
        raw = "" if name is None and email is None else (f"{name or ''} <{email or ''}>" if email else name or "")
        output.append(credit_row(branch, commit_id, "git_author", 0, raw, name, email, raw_name, raw_email))
        for field, role in (("trailer_author", "patch_author"), ("co_authored_by", "co_author")):
            values = commit.get(field) or []
            if not isinstance(values, list):
                raise DataError(f"{branch}/{commit_id}.{field} must be an array")
            for ordinal, value in enumerate(values):
                if not isinstance(value, str):
                    raise DataError(f"{branch}/{commit_id}.{field}[{ordinal}] must be a string")
                parsed_name, parsed_email = split_credit(value)
                output.append(credit_row(branch, commit_id, role, ordinal, value, parsed_name, parsed_email, parsed_name, parsed_email))
    return sorted(output, key=lambda c: (c["branch"], c["commit_id"], ROLES.index(c["role"]), c["occurrence"]))


def credit_row(branch: str, commit_id: str, role: str, occurrence: int, raw: str,
               name: str | None, email: str | None, raw_name: str | None = None,
               raw_email: str | None = None) -> dict[str, Any]:
    occurrence_key = str(occurrence)
    return {
        "credit_id": stable_id("credit", branch, commit_id, role, occurrence_key),
        "branch": branch,
        "commit_id": commit_id,
        "role": role,
        "occurrence": occurrence,
        "raw_value": raw,
        "name": name,
        "email": email,
        "raw_name": raw_name,
        "raw_email": raw_email,
    }


def parse_commit_time(value: Any, field: str) -> tuple[datetime | None, str | None]:
    if value in (None, ""):
        return None, "missing_timestamp"
    try:
        parsed = parse_iso(value, field=field)
    except DataError:
        return None, "invalid_timestamp"
    return parsed, None


def history_membership(history: dict[str, Any], at: datetime) -> tuple[str, str | None]:
    """Return possible/guaranteed/none/unknown without extending uncertain periods."""
    start_min = parse_iso(history.get("start_earliest"), field="start_earliest")
    start_max = parse_iso(history.get("start_latest"), field="start_latest")
    end_min = parse_iso(history.get("end_earliest"), field="end_earliest")
    end_max = parse_iso(history.get("end_latest"), field="end_latest")
    as_of = parse_iso(history.get("as_of"), field="as_of")
    if as_of is not None and at >= as_of:
        return "none", "outside_reviewed_horizon"
    if start_min is not None and at < start_min:
        return "none", None
    if end_max is not None and at >= end_max:
        return "none", None
    if history["status"] in {"unknown", "conflicting"}:
        return "unknown", history["status"]
    if start_min is None:
        return "unknown", "unknown_start_boundary"
    if not history.get("end_ongoing") and end_min is None and end_max is None:
        return "unknown", "unknown_end_boundary"
    possible_end = history.get("end_ongoing") is True or end_max is None or at < end_max
    if not possible_end:
        return "none", None
    guaranteed_start = start_max is not None and at >= start_max
    guaranteed_end = history.get("end_ongoing") is True or (end_min is not None and at < end_min)
    if guaranteed_start and guaranteed_end:
        return "guaranteed", None
    return "possible", "uncertain_boundary"


def build_attributions(commits: list[dict[str, Any]], credits: list[dict[str, Any]], data: dict[str, Any], timestamp_basis: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    mappings_by_email = {normalize_email(row["email"]): row for row in data["identity-mappings"]}
    people = {row["person_id"]: row for row in data["people"]}
    companies = {row["company_id"]: row for row in data["companies"]}
    commit_index = {(str(row["branch"]), str(row["commit_id"])): row for row in commits}
    credits_by_commit: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for credit in credits:
        credits_by_commit[(credit["branch"], credit["commit_id"])].append(credit)

    records: list[dict[str, Any]] = []
    all_roles: Counter[str] = Counter()
    identity_roles: dict[str, Counter[str]] = defaultdict(Counter)
    identity_year_roles: dict[str, Counter[str]] = defaultdict(Counter)
    affiliation_roles: dict[str, Counter[str]] = defaultdict(Counter)
    years_roles: dict[str, Counter[str]] = defaultdict(Counter)
    for key in sorted(credits_by_commit):
        branch, commit_id = key
        commit = commit_index[key]
        ts_field = "commit_date" if timestamp_basis == "committer" else "author_date"
        timestamp, timestamp_problem = parse_commit_time(commit.get(ts_field), f"{branch}/{commit_id}.{ts_field}")
        grouped: dict[tuple[str, str], dict[str, Any]] = {}
        for credit in credits_by_commit[key]:
            all_roles[credit["role"]] += 1
            mapping = mappings_by_email.get(normalize_email(credit.get("email"))) if credit.get("email") else None
            person_id = mapping["person_id"] if mapping else None
            if person_id:
                identity_roles[credit["role"]]["resolved"] += 1
                group_key = ("person", person_id)
            else:
                identity_roles[credit["role"]]["unresolved"] += 1
                group_key = ("credit", credit["credit_id"])
            if timestamp is not None:
                identity_year_roles[f"{timestamp.year}:{credit['role']}"]["resolved" if person_id else "unresolved"] += 1
            participant = grouped.setdefault(group_key, {
                "person_id": person_id,
                "credit_ids": [],
                "roles": [],
                "identity_status": "resolved" if person_id else "unresolved",
                "identity_mapping_ids": [],
                "identity_evidence_ids": [],
                "identity_confidence": "exact_email_mapping" if person_id else "unknown",
                "raw_credits": [],
                "identity_mapping_review_status": [],
            })
            participant["credit_ids"].append(credit["credit_id"])
            participant["roles"].append(credit["role"])
            participant["raw_credits"].append({key: credit[key] for key in ("credit_id", "role", "occurrence", "raw_value", "name", "email")})
            if mapping:
                participant["identity_mapping_ids"].append(mapping["mapping_id"])
                participant["identity_evidence_ids"].extend(mapping.get("evidence_ids", []))
                participant["identity_mapping_review_status"].append(mapping["review_status"])

        for participant in grouped.values():
            person_id = participant["person_id"]
            histories = [h for h in data["histories"] if h.get("person_id") == person_id] if person_id else []
            candidate_rows: list[dict[str, Any]] = []
            attribution_status = "unknown"
            reason = "unresolved_identity" if not person_id else "no_affiliation_history"
            if person_id and timestamp is None:
                reason = timestamp_problem or "missing_timestamp"
            elif person_id and timestamp is not None:
                active: list[tuple[dict[str, Any], str, str | None]] = []
                for history in histories:
                    membership, membership_reason = history_membership(history, timestamp)
                    if membership != "none":
                        active.append((history, membership, membership_reason))
                if active:
                    alternatives: dict[str, list[tuple[dict[str, Any], str, str | None]]] = defaultdict(list)
                    for item in active:
                        history = item[0]
                        if history.get("relationship_group_mode") == "alternative":
                            alternatives[history["relationship_group_id"]].append(item)
                        else:
                            candidate_rows.append(item)
                    if alternatives:
                        for group_id, choices in alternatives.items():
                            for item in choices:
                                candidate_rows.append(item)
                    explicit_groups = {item[0].get("relationship_group_id") for item in candidate_rows if item[0].get("relationship_group_mode") == "concurrent"}
                    active_companies = {item[0].get("company_id") for item in candidate_rows}
                    implicit_multi_company = len(active_companies) > 1 and not (
                        all(item[0].get("relationship_group_mode") == "concurrent" for item in candidate_rows)
                        and len(explicit_groups) == 1
                    )
                    materialized: list[dict[str, Any]] = []
                    supported_count = estimated_count = 0
                    has_conflict = False
                    has_unknown = False
                    for history, membership, membership_reason in candidate_rows:
                        status = history["status"]
                        if membership == "unknown" and status in {"supported", "estimated"}:
                            status = "unknown"
                        if membership == "possible" and status == "supported":
                            status = "estimated"
                            membership_reason = "uncertain_boundary"
                        if status == "conflicting":
                            has_conflict = True
                        elif status == "unknown":
                            has_unknown = True
                        elif status == "supported":
                            supported_count += 1
                        elif status == "estimated":
                            estimated_count += 1
                        company = companies[history["company_id"]]
                        materialized.append({
                            "history_id": history["history_id"],
                            "company_id": company["company_id"],
                            "company_name": company["name"],
                            "relationship_type": history["relationship_type"],
                            "status": status,
                            "membership": membership,
                            "reason": membership_reason,
                            "evidence_ids": sorted(history.get("evidence_ids", [])),
                            "history_review_status": history["review_status"],
                            "relationship_group_id": history.get("relationship_group_id"),
                            "relationship_group_mode": history.get("relationship_group_mode"),
                            "period": {k: history.get(k) for k in ("start_earliest", "start_latest", "start_precision", "end_earliest", "end_latest", "end_precision", "end_ongoing", "as_of")},
                        })
                    # Competing candidates are an unresolved choice, never multiple supported affiliations.
                    has_alternative = bool(alternatives)
                    if has_conflict or has_alternative or implicit_multi_company:
                        attribution_status = "conflicting" if has_conflict else "unknown"
                        reason = "conflicting_evidence" if has_conflict else ("alternative_candidates" if has_alternative else "unclassified_overlapping_companies")
                        for item in materialized:
                            if item["relationship_group_mode"] == "alternative" or implicit_multi_company:
                                item["status"] = "candidate"
                    elif has_unknown:
                        attribution_status, reason = "unknown", "insufficient_or_conflicting_evidence"
                    elif estimated_count:
                        attribution_status, reason = "estimated", "estimated_affiliation_period"
                    elif supported_count:
                        attribution_status, reason = "supported", "evidence_supported_period"
                    else:
                        attribution_status, reason = "unknown", "no_supported_affiliation"
                    candidate_rows = materialized
                else:
                    reason = "no_affiliation_history_at_timestamp"
            roles = sorted(set(participant["roles"]), key=ROLES.index)
            for role, role_occurrences in Counter(participant["roles"]).items():
                affiliation_roles[role][attribution_status] += role_occurrences
                if timestamp:
                    years_roles[f"{timestamp.year}:{role}"][attribution_status] += role_occurrences
            records.append({
                "branch": branch,
                "commit_id": commit_id,
                "person_id": person_id,
                "participant_key": person_id or participant["credit_ids"][0],
                "roles": roles,
                "credit_ids": sorted(participant["credit_ids"]),
                "raw_credits": sorted(participant["raw_credits"], key=lambda c: (ROLES.index(c["role"]), c["occurrence"])),
                "identity": {"status": participant["identity_status"], "confidence": participant["identity_confidence"], "review_status": sorted(set(participant["identity_mapping_review_status"])), "mapping_ids": sorted(set(participant["identity_mapping_ids"])), "evidence_ids": sorted(set(participant["identity_evidence_ids"]))},
                "attribution_timestamp": iso_utc(timestamp),
                "timestamp_basis": timestamp_basis,
                "timestamp_field": ts_field,
                "evidence_snapshot": data["manifest"]["evidence_snapshot"],
                "identity_mapping_revision": data["manifest"]["mapping_revision"],
                "affiliation_history_revision": data["manifest"]["history_revision"],
                "attribution_rule_revision": data["manifest"]["rule_revision"],
                "attribution_status": attribution_status,
                "affiliation_confidence": attribution_status,
                "reason": reason,
                "affiliations": sorted(candidate_rows, key=lambda a: (a["company_id"], a["history_id"])),
            })
    records.sort(key=lambda r: (r["branch"], r["commit_id"], r["participant_key"]))
    coverage = {
        "participant_commit_rows": len(records),
        "raw_credit_occurrences": len(credits),
        "identity_resolution_by_role": {role: {"total": sum(identity_roles[role].values()), "resolved": identity_roles[role]["resolved"], "unresolved": identity_roles[role]["unresolved"]} for role in ROLES},
        "identity_resolution_by_year_and_role": {key: dict(sorted(counts.items())) for key, counts in sorted(identity_year_roles.items())},
        "affiliation_status_by_role": {role: {"total": sum(affiliation_roles[role].values()), **{status: affiliation_roles[role][status] for status in ("supported", "estimated", "unknown", "conflicting")}} for role in ROLES},
        "affiliation_status_by_year_and_role": {key: dict(sorted(counts.items())) for key, counts in sorted(years_roles.items())},
        "timestamp_basis": timestamp_basis,
        "retrieval": {
            "searches": len(data["retrieval-ledger"]),
            "semantics_verified": sum(row.get("semantics_verified") is True for row in data["retrieval-ledger"]),
            "exhaustive_searches": sum(row.get("coverage_status") == "exhaustive" for row in data["retrieval-ledger"]),
            "note": "Search results are sampled observations unless query semantics and pagination coverage are explicitly verified; no result does not establish no affiliation.",
        },
    }
    return records, coverage


def validate_commit_snapshot(commits: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(commits, list):
        return ["commit snapshot must be a JSON array"]
    seen: set[tuple[str, str]] = set()
    for i, row in enumerate(commits):
        if not isinstance(row, dict):
            errors.append(f"commits[{i}] must be an object")
            continue
        branch, commit_id = row.get("branch"), row.get("commit_id")
        if not isinstance(branch, str) or not branch or not isinstance(commit_id, str) or not commit_id:
            errors.append(f"commits[{i}] needs non-empty branch and commit_id")
            continue
        key = (branch, commit_id)
        if key in seen:
            errors.append(f"duplicate branch-qualified commit: {branch}/{commit_id}")
        seen.add(key)
    return errors


def ensure_output_is_separate(out_dir: Path, data_dir: Path, commits_path: Path) -> None:
    inputs = [data_dir / "manifest.json", commits_path]
    inputs.extend(data_dir / f"{name}.json" for name in ("people", "identity-mappings", "companies", "evidence", "histories", "retrieval-ledger"))
    protected = {path.resolve(strict=False) for path in inputs}
    for name in ("raw_credits.json", "commit_author_companies.json", "coverage.json", "manifest.json", "company_affiliations.json"):
        target = out_dir / name
        resolved_target = target.resolve(strict=False)
        if resolved_target in protected:
            raise DataError(f"output {target} would overwrite an input or authoritative research file")
        if target.exists():
            for source in inputs:
                if source.exists() and os.path.samefile(target, source):
                    raise DataError(f"output {target} aliases input {source}")


def website_snapshot(commits: list[dict[str, Any]], records: list[dict[str, Any]],
                     data: dict[str, Any], provenance: dict[str, Any]) -> dict[str, Any]:
    """Sparse commit/company matches; unresolved candidates never become filters.

    A commit is counted once per company, regardless of people or credit roles.
    A supported participant takes precedence over estimated participants for the
    same company. Full participant/evidence detail remains in the audit build.
    """
    matches: dict[tuple[str, str], dict[str, str]] = defaultdict(dict)
    for row in records:
        if row["attribution_status"] not in {"supported", "estimated"}:
            continue
        for affiliation in row["affiliations"]:
            status = affiliation["status"]
            if status not in {"supported", "estimated"}:
                continue
            companies = matches[(row["branch"], row["commit_id"])]
            company_id = affiliation["company_id"]
            if companies.get(company_id) != "supported":
                companies[company_id] = status
    used = {company for companies in matches.values() for company in companies}
    return {
        "schema_version": 1,
        "provenance": provenance,
        "coverage": {"total_commits": len(commits), "matched_commits": len(matches),
                     "researched_people": len(data["people"])},
        "companies": sorted((company for company in data["companies"] if company["company_id"] in used),
                            key=lambda company: company["company_id"]),
        "matches": [{"branch": branch, "commit_id": commit_id,
                     "companies": [{"company_id": company_id, "status": status}
                                   for company_id, status in sorted(companies.items())]}
                    for (branch, commit_id), companies in sorted(matches.items())],
    }


def build_command(args: argparse.Namespace) -> int:
    data_dir = Path(args.data_dir)
    data = load_dataset(data_dir)
    commits_path = Path(args.commits)
    commits = read_json(commits_path)
    errors = validate_dataset(data) + validate_commit_snapshot(commits)
    if errors:
        raise DataError("\n".join(errors))
    out_dir = Path(args.out_dir)
    ensure_output_is_separate(out_dir, data_dir, commits_path)
    credits = extract_credits(commits)
    attributions, coverage = build_attributions(commits, credits, data, args.timestamp_basis)
    outputs = {
        "raw_credits.json": credits,
        "commit_author_companies.json": attributions,
        "coverage.json": coverage,
    }
    input_hashes = {
        "commit_snapshot_sha256": sha256_bytes(commits_path.read_bytes()),
        **{f"{name}.json": sha256_bytes((data_dir / f"{name}.json").read_bytes()) for name in ("people", "identity-mappings", "companies", "evidence", "histories", "retrieval-ledger")},
        "manifest.json": sha256_bytes((data_dir / "manifest.json").read_bytes()),
    }
    input_manifest = {"data_manifest": data["manifest"], "input_sha256": input_hashes, "commit_snapshot_name": commits_path.name, "timestamp_basis": args.timestamp_basis, "rule_version": RULE_VERSION}
    if args.command == "build-site":
        write_json(out_dir / "company_affiliations.json", website_snapshot(commits, attributions, data, input_manifest))
        print(f"Wrote website company affiliations for {len(commits)} commits to {out_dir}")
        return 0
    output_hashes = {name: sha256_bytes(canonical_json(value)) for name, value in outputs.items()}
    output_manifest = {**input_manifest, "outputs_sha256": output_hashes}
    for name, value in outputs.items():
        write_json(out_dir / name, value)
    write_json(out_dir / "manifest.json", output_manifest)
    print(f"Wrote {len(credits)} raw credits and {len(attributions)} participant/commit records to {out_dir}")
    return 0


def validate_command(args: argparse.Namespace) -> int:
    data = load_dataset(Path(args.data_dir))
    errors = validate_dataset(data)
    if errors:
        raise DataError("\n".join(errors))
    print("Affiliation dataset is valid")
    return 0


def extract_command(args: argparse.Namespace) -> int:
    commits = read_json(Path(args.commits))
    errors = validate_commit_snapshot(commits)
    if errors:
        raise DataError("\n".join(errors))
    credits = extract_credits(commits)
    write_json(Path(args.out), credits)
    print(f"Wrote {len(credits)} raw credit occurrences to {args.out}")
    return 0


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate", help="validate reviewed pilot data")
    validate.add_argument("--data-dir", required=True)
    validate.set_defaults(func=validate_command)
    extract = subparsers.add_parser("extract-credits", help="extract stable raw credit occurrences")
    extract.add_argument("--commits", required=True)
    extract.add_argument("--out", required=True)
    extract.set_defaults(func=extract_command)
    build = subparsers.add_parser("build", help="build a deterministic attribution snapshot")
    build.add_argument("--data-dir", required=True)
    build.add_argument("--commits", required=True)
    build.add_argument("--out-dir", required=True)
    build.add_argument("--timestamp-basis", choices=("committer", "author"), default="committer")
    build.set_defaults(func=build_command)
    website = subparsers.add_parser("build-site", help="build sparse, evidence-qualified website company matches")
    website.add_argument("--data-dir", required=True)
    website.add_argument("--commits", required=True)
    website.add_argument("--out-dir", required=True)
    website.add_argument("--timestamp-basis", choices=("committer", "author"), default="committer")
    website.set_defaults(func=build_command)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    parser = make_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except DataError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
