-- Synthetic regression data only; run in the isolated schema-test cluster.
BEGIN;
INSERT INTO author_company_person VALUES ('p-old', 'Old mapping'), ('p-new', 'Corrected mapping');
INSERT INTO author_company_company VALUES ('c', 'Example Co');
INSERT INTO author_company_identity_mapping
    (mapping_id, email, person_id, decision, review_status, mapping_revision)
VALUES
    ('same-id', 'person@example.test', 'p-old', 'reviewed', 'agent-reviewed', 'v1'),
    ('same-id', 'person@example.test', 'p-new', 'reviewed', 'agent-reviewed', 'v2');
INSERT INTO author_company_credit
    (credit_id, branch, commit_id, role, occurrence, raw_value)
VALUES ('credit', 'master', 'synthetic', 'git_author', 0, 'person@example.test');
INSERT INTO author_company_credit_resolution
    (credit_id, mapping_revision, decision, person_id, mapping_id, rationale)
VALUES
    ('credit', 'v1', 'resolved', 'p-old', 'same-id', 'Initial test resolution'),
    ('credit', 'v2', 'resolved', 'p-new', 'same-id', 'Corrected test resolution');
INSERT INTO author_company_history
    (history_id, person_id, company_id, relationship_type, status,
     start_earliest, start_latest, start_precision,
     end_earliest, end_latest, end_precision, history_revision, review_status)
VALUES
    ('same-history', 'p-old', 'c', 'employment', 'supported',
     '2020-01-01', '2020-01-01', 'day', '2021-01-01', '2021-01-01', 'day', 'v1', 'agent-reviewed'),
    ('same-history', 'p-old', 'c', 'employment', 'supported',
     '2020-01-01', '2020-01-01', 'day', '2020-07-01', '2020-07-01', 'day', 'v2', 'agent-reviewed');
DO $$
BEGIN
    IF (SELECT count(*) FROM author_company_identity_mapping WHERE mapping_id='same-id') <> 2
       OR (SELECT count(*) FROM author_company_history WHERE history_id='same-history') <> 2
       OR (SELECT count(*) FROM author_company_credit_resolution WHERE credit_id='credit') <> 2 THEN
        RAISE EXCEPTION 'Prior revisions were not retained';
    END IF;
    BEGIN
        INSERT INTO author_company_identity_mapping
            (mapping_id,email,person_id,decision,review_status,mapping_revision)
        VALUES ('conflicting-id','person@EXAMPLE.TEST','p-new','reviewed','agent-reviewed','v2');
        RAISE EXCEPTION 'Duplicate normalized email accepted within one revision';
    EXCEPTION WHEN unique_violation THEN
        NULL;
    END;
    BEGIN
        UPDATE author_company_credit_resolution SET person_id='p-old'
        WHERE credit_id='credit' AND mapping_revision='v2';
        RAISE EXCEPTION 'Resolution accepted a person different from its mapping';
    EXCEPTION WHEN foreign_key_violation THEN
        NULL;
    END;
END $$;
ROLLBACK;
SELECT 'author company schema tests passed' AS result;
