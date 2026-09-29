-- Independent, parallel storage for reviewed contributor affiliation research.
-- This schema has no dependencies on the existing commits/cache pipeline.

CREATE TABLE IF NOT EXISTS public.author_company_dataset_revision (
    revision_id text PRIMARY KEY,
    schema_version text NOT NULL,
    evidence_snapshot text NOT NULL,
    mapping_revision text NOT NULL,
    history_revision text NOT NULL,
    rule_revision text NOT NULL,
    retrieval_ledger_revision text NOT NULL,
    commit_snapshot_sha256 text NOT NULL,
    input_manifest jsonb NOT NULL,
    imported_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS public.author_company_person (
    person_id text PRIMARY KEY,
    display_name text NOT NULL CHECK (btrim(display_name) <> '')
);

CREATE TABLE IF NOT EXISTS public.author_company_company (
    company_id text PRIMARY KEY,
    name text NOT NULL CHECK (btrim(name) <> '')
);

CREATE TABLE IF NOT EXISTS public.author_company_alias (
    company_id text NOT NULL REFERENCES public.author_company_company(company_id),
    alias text NOT NULL CHECK (btrim(alias) <> ''),
    valid_from date,
    valid_to date,
    PRIMARY KEY (company_id, alias),
    CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from)
);

CREATE TABLE IF NOT EXISTS public.author_company_evidence (
    evidence_id text PRIMARY KEY,
    person_id text NOT NULL REFERENCES public.author_company_person(person_id),
    company_id text REFERENCES public.author_company_company(company_id),
    sender_email text,
    source_url text,
    message_id text,
    source_revision integer NOT NULL DEFAULT 1 CHECK (source_revision > 0),
    supersedes_evidence_id text REFERENCES public.author_company_evidence(evidence_id),
    context text NOT NULL CHECK (btrim(context) <> ''),
    excerpt text NOT NULL CHECK (btrim(excerpt) <> ''),
    source_date timestamptz,
    effective_date timestamptz,
    retrieved_at timestamptz NOT NULL,
    evidence_kind text NOT NULL CHECK (evidence_kind IN (
        'mail_body_first_person', 'mail_signature', 'company_announcement',
        'personal_announcement', 'conference_bio', 'mutable_inconclusive_observation', 'other'
    )),
    review_status text NOT NULL CHECK (review_status IN ('agent-reviewed', 'human-reviewed', 'rejected')),
    CHECK (source_url IS NOT NULL OR message_id IS NOT NULL),
    UNIQUE (message_id, source_revision)
);

CREATE TABLE IF NOT EXISTS public.author_company_identity_mapping (
    mapping_id text NOT NULL,
    email text NOT NULL CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+$'),
    person_id text NOT NULL REFERENCES public.author_company_person(person_id),
    decision text NOT NULL CHECK (decision = 'reviewed'),
    review_status text NOT NULL CHECK (review_status IN ('agent-reviewed', 'human-reviewed')),
    mapping_revision text NOT NULL,
    PRIMARY KEY (mapping_revision, mapping_id),
    UNIQUE (mapping_revision, mapping_id, person_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS author_company_identity_email_exact_idx
    ON public.author_company_identity_mapping
       (mapping_revision, split_part(email, '@', 1), lower(split_part(email, '@', 2)));

CREATE TABLE IF NOT EXISTS public.author_company_identity_mapping_evidence (
    mapping_revision text NOT NULL,
    mapping_id text NOT NULL,
    evidence_id text NOT NULL REFERENCES public.author_company_evidence(evidence_id),
    PRIMARY KEY (mapping_revision, mapping_id, evidence_id),
    FOREIGN KEY (mapping_revision, mapping_id)
        REFERENCES public.author_company_identity_mapping(mapping_revision, mapping_id)
);

CREATE TABLE IF NOT EXISTS public.author_company_credit (
    credit_id text PRIMARY KEY,
    branch text NOT NULL,
    commit_id text NOT NULL,
    role text NOT NULL CHECK (role IN ('git_author', 'patch_author', 'co_author')),
    occurrence integer NOT NULL CHECK (occurrence >= 0),
    raw_value text NOT NULL,
    name text,
    email text,
    raw_name text,
    raw_email text,
    UNIQUE (branch, commit_id, role, occurrence)
);

CREATE TABLE IF NOT EXISTS public.author_company_credit_resolution (
    credit_id text NOT NULL REFERENCES public.author_company_credit(credit_id),
    mapping_revision text NOT NULL,
    decision text NOT NULL CHECK (decision IN ('resolved', 'unresolved', 'rejected')),
    person_id text REFERENCES public.author_company_person(person_id),
    mapping_id text,
    evidence_ids text[] NOT NULL DEFAULT '{}',
    rationale text NOT NULL,
    PRIMARY KEY (credit_id, mapping_revision),
    CHECK ((decision = 'resolved') = (person_id IS NOT NULL)),
    CHECK (decision <> 'resolved' OR mapping_id IS NOT NULL),
    FOREIGN KEY (mapping_revision, mapping_id, person_id)
        REFERENCES public.author_company_identity_mapping(mapping_revision, mapping_id, person_id)
);

CREATE TABLE IF NOT EXISTS public.author_company_history (
    history_id text NOT NULL,
    person_id text NOT NULL REFERENCES public.author_company_person(person_id),
    company_id text NOT NULL REFERENCES public.author_company_company(company_id),
    relationship_type text NOT NULL CHECK (relationship_type IN ('employment', 'consulting', 'other', 'unknown')),
    status text NOT NULL CHECK (status IN ('supported', 'estimated', 'unknown', 'conflicting')),
    start_earliest timestamptz,
    start_latest timestamptz,
    start_precision text NOT NULL CHECK (start_precision IN ('instant', 'day', 'month', 'year', 'unknown')),
    end_earliest timestamptz,
    end_latest timestamptz,
    end_precision text NOT NULL CHECK (end_precision IN ('instant', 'day', 'month', 'year', 'unknown')),
    end_ongoing boolean NOT NULL DEFAULT false,
    as_of timestamptz,
    relationship_group_id text,
    relationship_group_mode text CHECK (relationship_group_mode IN ('concurrent', 'alternative')),
    history_revision text NOT NULL,
    estimation_method text,
    review_status text NOT NULL CHECK (review_status IN ('agent-reviewed', 'human-reviewed')),
    PRIMARY KEY (history_revision, history_id),
    CHECK (start_earliest IS NULL OR start_latest IS NULL OR start_earliest <= start_latest),
    CHECK (end_earliest IS NULL OR end_latest IS NULL OR end_earliest <= end_latest),
    CHECK (end_latest IS NULL OR start_earliest IS NULL OR end_latest > start_earliest),
    CHECK (NOT end_ongoing OR (as_of IS NOT NULL AND end_earliest IS NULL AND end_latest IS NULL)),
    CHECK ((relationship_group_mode IS NULL) = (relationship_group_id IS NULL)),
    CHECK (status <> 'estimated' OR estimation_method IS NOT NULL),
    CHECK (status NOT IN ('supported', 'estimated') OR end_ongoing OR end_latest IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS public.author_company_history_evidence (
    history_revision text NOT NULL,
    history_id text NOT NULL,
    evidence_id text NOT NULL REFERENCES public.author_company_evidence(evidence_id),
    PRIMARY KEY (history_revision, history_id, evidence_id),
    FOREIGN KEY (history_revision, history_id)
        REFERENCES public.author_company_history(history_revision, history_id)
);

CREATE TABLE IF NOT EXISTS public.author_company_retrieval_run (
    ledger_id text PRIMARY KEY,
    query_text text NOT NULL,
    senders text[] NOT NULL DEFAULT '{}',
    after_at timestamptz,
    before_at timestamptz,
    result_offset integer CHECK (result_offset IS NULL OR result_offset >= 0),
    result_limit integer CHECK (result_limit IS NULL OR result_limit >= 0),
    result_count integer CHECK (result_count IS NULL OR result_count >= 0),
    retrieved_at timestamptz NOT NULL,
    semantics_verified boolean NOT NULL,
    coverage_status text NOT NULL CHECK (coverage_status IN ('sampled', 'bounded', 'exhaustive')),
    coverage_note text NOT NULL,
    CHECK (coverage_status <> 'exhaustive' OR semantics_verified)
);

CREATE TABLE IF NOT EXISTS public.author_company_retrieval_message (
    ledger_id text NOT NULL REFERENCES public.author_company_retrieval_run(ledger_id),
    message_id text NOT NULL,
    PRIMARY KEY (ledger_id, message_id)
);

CREATE TABLE IF NOT EXISTS public.author_company_attribution (
    dataset_revision_id text NOT NULL REFERENCES public.author_company_dataset_revision(revision_id),
    branch text NOT NULL,
    commit_id text NOT NULL,
    participant_key text NOT NULL,
    person_id text REFERENCES public.author_company_person(person_id),
    attribution_timestamp timestamptz,
    timestamp_basis text NOT NULL CHECK (timestamp_basis IN ('committer', 'author')),
    attribution_status text NOT NULL CHECK (attribution_status IN ('supported', 'estimated', 'unknown', 'conflicting')),
    reason text NOT NULL,
    PRIMARY KEY (dataset_revision_id, branch, commit_id, participant_key)
);

CREATE TABLE IF NOT EXISTS public.author_company_attribution_credit (
    dataset_revision_id text NOT NULL,
    branch text NOT NULL,
    commit_id text NOT NULL,
    participant_key text NOT NULL,
    credit_id text NOT NULL REFERENCES public.author_company_credit(credit_id),
    PRIMARY KEY (dataset_revision_id, branch, commit_id, participant_key, credit_id),
    FOREIGN KEY (dataset_revision_id, branch, commit_id, participant_key)
        REFERENCES public.author_company_attribution(dataset_revision_id, branch, commit_id, participant_key)
);

CREATE TABLE IF NOT EXISTS public.author_company_attribution_candidate (
    dataset_revision_id text NOT NULL,
    branch text NOT NULL,
    commit_id text NOT NULL,
    participant_key text NOT NULL,
    company_id text NOT NULL REFERENCES public.author_company_company(company_id),
    history_revision text NOT NULL,
    history_id text NOT NULL,
    relationship_type text NOT NULL CHECK (relationship_type IN ('employment', 'consulting', 'other', 'unknown')),
    status text NOT NULL CHECK (status IN ('supported', 'estimated', 'unknown', 'conflicting', 'candidate')),
    relationship_group_id text,
    relationship_group_mode text CHECK (relationship_group_mode IN ('concurrent', 'alternative')),
    reason text,
    PRIMARY KEY (dataset_revision_id, branch, commit_id, participant_key, history_id),
    FOREIGN KEY (history_revision, history_id)
        REFERENCES public.author_company_history(history_revision, history_id),
    FOREIGN KEY (dataset_revision_id, branch, commit_id, participant_key)
        REFERENCES public.author_company_attribution(dataset_revision_id, branch, commit_id, participant_key)
);
