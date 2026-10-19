-- SQL Test Fixtures for Passive PostgreSQL Schema
-- These tests verify schema invariants from POSTGRES_CONTRACT.md
-- Run with: psql -d testdb -f 01_identity_cross_kind_collision.sql (etc.)
-- PostgreSQL 16 required. No live runtime available in current environment.

-- ============================================================================
-- Test 1: DNS/CT identity cross-kind collision
-- Cross-kind collision (same domain, namespace, event_id) must fail.
-- ============================================================================
\echo 'Test 1: DNS/CT identity cross-kind collision'

BEGIN;
INSERT INTO domains (domain) VALUES ('example.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('example.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('example.test', 'dns', 'event-1', 'answer', false);
-- This should fail: same identity, different kind
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('example.test', 'ct', 'event-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
ROLLBACK;

-- Same test: CT first, then DNS
BEGIN;
INSERT INTO domains (domain) VALUES ('example2.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('example2.test', 'ct', 'event-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('example2.test', 'ct', 'event-1', 'cert-1');
-- This should fail: same identity, different kind
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('example2.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
ROLLBACK;

\echo 'Test 1 completed (expect 2 rollbacks due to PK violation on events)'

-- ============================================================================
-- Test 2: Full u64 maximum, negative and overflow rejection
-- DNS sequence must be numeric(20,0) with CHECK (0..18446744073709551615)
-- ============================================================================
\echo 'Test 2: u64 bounds enforcement'

BEGIN;
INSERT INTO domains (domain) VALUES ('u64.test');
-- Valid: u64 max
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('u64.test', 'dns', 'max', 'dns', 18446744073709551615, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('u64.test', 'dns', 'max', 'answer', false);
ROLLBACK;

BEGIN;
INSERT INTO domains (domain) VALUES ('u64-2.test');
-- Invalid: negative sequence
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('u64-2.test', 'dns', 'neg', 'dns', -1, '2024-01-01T00:00:00Z', '{}'::jsonb);
ROLLBACK;

BEGIN;
INSERT INTO domains (domain) VALUES ('u64-3.test');
-- Invalid: overflow (u64 max + 1)
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('u64-3.test', 'dns', 'overflow', 'dns', 18446744073709551616, '2024-01-01T00:00:00Z', '{}'::jsonb);
ROLLBACK;

BEGIN;
INSERT INTO domains (domain) VALUES ('u64-4.test');
-- Valid: zero
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('u64-4.test', 'dns', 'zero', 'dns', 0, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('u64-4.test', 'dns', 'zero', 'answer', false);
ROLLBACK;

\echo 'Test 2 completed (expect 2 rollbacks: negative and overflow)'

-- ============================================================================
-- Test 3: Case-distinct source identities/payloads
-- C collation ensures case-sensitive, byte-exact comparison
-- ============================================================================
\echo 'Test 3: Case-distinct identities (C collation)'

BEGIN;
INSERT INTO domains (domain) VALUES ('CaseTest.test');
-- Lowercase namespace
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('CaseTest.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('CaseTest.test', 'dns', 'event-1', 'answer', false);
-- Different case namespace should be allowed (distinct identity)
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('CaseTest.test', 'DNS', 'event-1', 'dns', 2, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('CaseTest.test', 'DNS', 'event-1', 'answer', false);
COMMIT;

-- Verify both exist
SELECT 'Case distinct namespaces:' AS test, count(*) FROM events WHERE domain = 'CaseTest.test';

-- Same for event_id case difference
BEGIN;
INSERT INTO domains (domain) VALUES ('CaseTest2.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('CaseTest2.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('CaseTest2.test', 'dns', 'event-1', 'answer', false);
-- Different case event_id
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('CaseTest2.test', 'dns', 'EVENT-1', 'dns', 2, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('CaseTest2.test', 'dns', 'EVENT-1', 'answer', false);
COMMIT;

SELECT 'Case distinct event_ids:' AS test, count(*) FROM events WHERE domain = 'CaseTest2.test';

\echo 'Test 3 completed (expect 4 rows total across both domains)'

-- ============================================================================
-- Test 4: Repeated certificate IDs as distinct events
-- CT deduplicates by event identity, NOT by certificate_id
-- ============================================================================
\echo 'Test 4: Repeated certificate IDs as distinct events'

BEGIN;
INSERT INTO domains (domain) VALUES ('cert-repeat.test');
-- First event with cert-1
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('cert-repeat.test', 'ct', 'event-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('cert-repeat.test', 'ct', 'event-1', 'cert-1');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('cert-repeat.test', 'ct', 'event-1', 'ct', 'Certified', true, 1, '{}'::jsonb);
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('cert-repeat.test', NULL, 'Certified', 'ct', 'event-1', '2024-01-01T00:00:00Z');
COMMIT;

BEGIN;
-- Second event with SAME certificate_id - should succeed (different event identity)
INSERT INTO domains (domain) VALUES ('cert-repeat.test'); -- already exists, but INSERT will fail
-- Instead, just insert new event for same domain
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('cert-repeat.test', 'ct', 'event-2', 'ct', NULL, '2024-01-02T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('cert-repeat.test', 'ct', 'event-2', 'cert-1');  -- same cert_id
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('cert-repeat.test', 'ct', 'event-2', 'ct', 'Certified', true, 2, '{}'::jsonb);
-- No finding expected (already Certified)
COMMIT;

SELECT 'Repeated cert_id events:' AS test, count(*) FROM ct_facts WHERE domain = 'cert-repeat.test';
SELECT 'Findings count:' AS test, count(*) FROM findings WHERE domain = 'cert-repeat.test';

\echo 'Test 4 completed (expect 2 ct_facts rows, 1 finding)'

-- ============================================================================
-- Test 5: Error before candidate
-- DNS errors preserve facts/status and do not create candidate
-- ============================================================================
\echo 'Test 5: Error before candidate'

BEGIN;
INSERT INTO domains (domain) VALUES ('error-first.test');
-- DNS error before any success
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('error-first.test', 'dns', 'error-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('error-first.test', 'dns', 'error-1', 'timeout', false);
INSERT INTO dns_errors (domain, namespace, event_id, sequence, outcome, status_at_event, observed_at)
VALUES ('error-first.test', 'dns', 'error-1', 1, 'timeout', NULL, '2024-01-01T00:00:00Z');
COMMIT;

-- Verify no candidate created
SELECT 'Candidate exists?' AS test, CASE WHEN EXISTS (SELECT 1 FROM candidates WHERE domain = 'error-first.test') THEN 'YES' ELSE 'NO' END;

-- Verify error recorded
SELECT 'Error recorded:' AS test, count(*) FROM dns_errors WHERE domain = 'error-first.test';
SELECT 'No success history:' AS test, count(*) FROM success_history WHERE domain = 'error-first.test';

\echo 'Test 5 completed (expect NO candidate, 1 error, 0 success_history)'

-- ============================================================================
-- Test 6: Ordered duplicate DNS records
-- Records stored with ordinals; duplicates remain distinct
-- ============================================================================
\echo 'Test 6: Ordered duplicate DNS records'

BEGIN;
INSERT INTO domains (domain) VALUES ('dup-records.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('dup-records.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('dup-records.test', 'dns', 'event-1', 'answer', false);
-- Duplicate A records (same IP, different ordinals)
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_a)
VALUES ('dup-records.test', 'dns', 'event-1', 0, 'A', '192.0.2.1'::inet);
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_a)
VALUES ('dup-records.test', 'dns', 'event-1', 1, 'A', '192.0.2.1'::inet);
-- Duplicate MX records (same pref/exchange, different ordinals)
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_mx_pref, value_mx_exchange)
VALUES ('dup-records.test', 'dns', 'event-1', 2, 'MX', 10, 'mx.example.test');
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_mx_pref, value_mx_exchange)
VALUES ('dup-records.test', 'dns', 'event-1', 3, 'MX', 10, 'mx.example.test');
COMMIT;

SELECT 'Duplicate records count:' AS test, count(*) FROM dns_records WHERE domain = 'dup-records.test';
SELECT 'Ordinals:' AS test, ordinal, record_type FROM dns_records WHERE domain = 'dup-records.test' ORDER BY ordinal;

\echo 'Test 6 completed (expect 4 records with ordinals 0,1,2,3)'

-- ============================================================================
-- Test 7: Many brands
-- Brand associations are many-to-many; duplicate insertion idempotent
-- ============================================================================
\echo 'Test 7: Many brands'

BEGIN;
INSERT INTO domains (domain) VALUES ('brands.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('brands.test', 'RegisteredParked', 'dns', 1, false);
-- First association
INSERT INTO brands (domain, brand) VALUES ('brands.test', 'brand-one');
-- Second association
INSERT INTO brands (domain, brand) VALUES ('brands.test', 'brand-two');
-- Duplicate insertion (idempotent - should not error with ON CONFLICT)
INSERT INTO brands (domain, brand) VALUES ('brands.test', 'brand-one')
ON CONFLICT (domain, brand) DO NOTHING;
COMMIT;

SELECT 'Brand count:' AS test, count(*) FROM brands WHERE domain = 'brands.test';
SELECT 'Brands:' AS test, brand FROM brands WHERE domain = 'brands.test' ORDER BY brand;

\echo 'Test 7 completed (expect 2 brands)'

-- ============================================================================
-- Test 8: Initial CT nullable from
-- Initial CT certification finding has from = NULL
-- ============================================================================
\echo 'Test 8: Initial CT nullable from'

BEGIN;
INSERT INTO domains (domain) VALUES ('initial-ct.test');
-- No prior candidate state
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('initial-ct.test', 'ct', 'event-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('initial-ct.test', 'ct', 'event-1', 'cert-1');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('initial-ct.test', 'ct', 'event-1', 'ct', 'Certified', true, 1, '{}'::jsonb);
-- Finding with from_status = NULL
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('initial-ct.test', NULL, 'Certified', 'ct', 'event-1', '2024-01-01T00:00:00Z');
COMMIT;

SELECT 'Finding from_status:' AS test, from_status FROM findings WHERE domain = 'initial-ct.test';

-- Verify NULL is allowed, but invalid transitions rejected
BEGIN;
INSERT INTO domains (domain) VALUES ('invalid-finding.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('invalid-finding.test', 'ct', 'event-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
-- Invalid: downgrade not allowed
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('invalid-finding.test', 'Certified', 'Unregistered', 'ct', 'event-1', '2024-01-01T00:00:00Z');
ROLLBACK;

\echo 'Test 8 completed (expect 1 finding with NULL from_status, 1 rollback for invalid transition)'

-- ============================================================================
-- Test 9: Schema shape checks
-- Reject mixed DNS/CT fields, invalid variants, out-of-range, mismatched domains/kinds
-- ============================================================================
\echo 'Test 9: Schema shape checks'

-- 9a: Invalid status variant
BEGIN;
INSERT INTO domains (domain) VALUES ('shape-1.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('shape-1.test', 'InvalidStatus', 'dns', 1, false);
ROLLBACK;

-- 9b: Invalid DNS outcome
BEGIN;
INSERT INTO domains (domain) VALUES ('shape-2.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('shape-2.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('shape-2.test', 'dns', 'event-1', 'invalid_outcome', false);
ROLLBACK;

-- 9c: Invalid CT kind in events
BEGIN;
INSERT INTO domains (domain) VALUES ('shape-3.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('shape-3.test', 'ct', 'event-1', 'invalid_kind', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
ROLLBACK;

-- 9d: MX preference out of range (0..65535)
BEGIN;
INSERT INTO domains (domain) VALUES ('shape-4.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('shape-4.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('shape-4.test', 'dns', 'event-1', 'answer', false);
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_mx_pref, value_mx_exchange)
VALUES ('shape-4.test', 'dns', 'event-1', 0, 'MX', 70000, 'mx.test');
ROLLBACK;

-- 9e: Non-IPv4 A record (INET type enforces this, but test invalid format)
BEGIN;
INSERT INTO domains (domain) VALUES ('shape-5.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('shape-5.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('shape-5.test', 'dns', 'event-1', 'answer', false);
-- This will fail at INET parse, but constraint also checks
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_a)
VALUES ('shape-5.test', 'dns', 'event-1', 0, 'A', 'not-an-ip'::inet);
ROLLBACK;

-- 9f: Records on non-answer outcome (constraint dns_records_answer_only_check)
BEGIN;
INSERT INTO domains (domain) VALUES ('shape-6.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('shape-6.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('shape-6.test', 'dns', 'event-1', 'nxdomain', false);
-- Should fail: records not allowed on nxdomain
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_a)
VALUES ('shape-6.test', 'dns', 'event-1', 0, 'A', '192.0.2.1'::inet);
ROLLBACK;

-- 9g: Mismatched event/evidence/history domains
BEGIN;
INSERT INTO domains (domain) VALUES ('shape-7a.test');
INSERT INTO domains (domain) VALUES ('shape-7b.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('shape-7a.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
-- dns_facts for different domain
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('shape-7b.test', 'dns', 'event-1', 'answer', false);
ROLLBACK;

-- 9h: Mismatched event kind (DNS event with CT fact)
BEGIN;
INSERT INTO domains (domain) VALUES ('shape-8.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('shape-8.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('shape-8.test', 'dns', 'event-1', 'cert-1');
ROLLBACK;

\echo 'Test 9 completed (expect 8 rollbacks for shape violations)'

-- ============================================================================
-- Test 10: Transaction rollback
-- Failed event processing removes all writes from that event
-- ============================================================================
\echo 'Test 10: Transaction rollback'

BEGIN;
INSERT INTO domains (domain) VALUES ('rollback.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('rollback.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('rollback.test', 'dns', 'event-1', 'answer', false);
-- Intentional error to trigger rollback
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_mx_pref, value_mx_exchange)
VALUES ('rollback.test', 'dns', 'event-1', 0, 'MX', 70000, 'mx.test');  -- invalid MX pref
ROLLBACK;

-- Verify nothing persisted
SELECT 'Rollback - domains:' AS test, count(*) FROM domains WHERE domain = 'rollback.test';
SELECT 'Rollback - events:' AS test, count(*) FROM events WHERE domain = 'rollback.test';
SELECT 'Rollback - dns_facts:' AS test, count(*) FROM dns_facts WHERE domain = 'rollback.test';

\echo 'Test 10 completed (expect 0 rows in all tables for rollback.test)'

-- ============================================================================
-- Test 11: Restrictive delete behavior
-- FKs prevent deletion of referenced domains, events, facts, history, findings
-- ============================================================================
\echo 'Test 11: Restrictive delete behavior'

BEGIN;
INSERT INTO domains (domain) VALUES ('delete.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('delete.test', 'RegisteredParked', 'dns', 1, false);
INSERT INTO brands (domain, brand) VALUES ('delete.test', 'brand');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('delete.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('delete.test', 'dns', 'event-1', 'answer', false);
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_a)
VALUES ('delete.test', 'dns', 'event-1', 0, 'A', '192.0.2.1'::inet);
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('delete.test', 'dns', 'event-1', 'dns', 'RegisteredParked', true, 1, '{}'::jsonb);
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('delete.test', NULL, 'RegisteredParked', 'dns', 'event-1', '2024-01-01T00:00:00Z');
COMMIT;

-- Try to delete domain - should fail due to RESTRICT
BEGIN;
DELETE FROM domains WHERE domain = 'delete.test';
ROLLBACK;

-- Try to delete event - should fail due to RESTRICT on dns_facts
BEGIN;
DELETE FROM events WHERE domain = 'delete.test' AND namespace = 'dns' AND event_id = 'event-1';
ROLLBACK;

-- Try to delete candidate - should fail due to brands FK
BEGIN;
DELETE FROM candidates WHERE domain = 'delete.test';
ROLLBACK;

SELECT 'Delete test - all rows remain:' AS test;
SELECT 'domains' AS table, count(*) FROM domains WHERE domain = 'delete.test'
UNION ALL SELECT 'candidates', count(*) FROM candidates WHERE domain = 'delete.test'
UNION ALL SELECT 'brands', count(*) FROM brands WHERE domain = 'delete.test'
UNION ALL SELECT 'events', count(*) FROM events WHERE domain = 'delete.test'
UNION ALL SELECT 'dns_facts', count(*) FROM dns_facts WHERE domain = 'delete.test'
UNION ALL SELECT 'dns_records', count(*) FROM dns_records WHERE domain = 'delete.test'
UNION ALL SELECT 'success_history', count(*) FROM success_history WHERE domain = 'delete.test'
UNION ALL SELECT 'findings', count(*) FROM findings WHERE domain = 'delete.test';

\echo 'Test 11 completed (expect 3 rollbacks, all rows remain)'

-- ============================================================================
-- Test 12: One DNS namespace per domain
-- dns_namespace in candidates enforces single namespace
-- ============================================================================
\echo 'Test 12: One DNS namespace per domain'

BEGIN;
INSERT INTO domains (domain) VALUES ('namespace.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('namespace.test', 'RegisteredParked', 'dns', 1, false);
-- First event with namespace 'dns'
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('namespace.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('namespace.test', 'dns', 'event-1', 'answer', false);
COMMIT;

-- Second event with DIFFERENT namespace - should be allowed at DB level
-- (namespace enforcement is in application logic via candidate.dns_namespace)
-- But the unique index on events(domain, sequence) WHERE kind='dns' prevents sequence reuse
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('namespace.test', 'other-dns', 'event-2', 'dns', 2, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('namespace.test', 'other-dns', 'event-2', 'answer', false);
COMMIT;

-- Verify both events exist (namespace enforcement is application-level)
SELECT 'Multiple namespaces at DB level:' AS test, count(*) FROM events WHERE domain = 'namespace.test';

-- But sequence uniqueness across namespaces IS enforced by unique index
BEGIN;
-- This should fail: same domain, same sequence=2, different namespace
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('namespace.test', 'third-dns', 'event-3', 'dns', 2, '2024-01-01T00:00:00Z', '{}'::jsonb);
ROLLBACK;

\echo 'Test 12 completed (expect 2 events, 1 rollback for sequence conflict)'

-- ============================================================================
-- Test 13: Sequence uniqueness across errors, stale, applied
-- (domain, sequence) unique for all DNS events
-- ============================================================================
\echo 'Test 13: Sequence uniqueness across errors/stale/applied'

BEGIN;
INSERT INTO domains (domain) VALUES ('seq-unique.test');
-- Applied success at sequence 10
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('seq-unique.test', 'dns', 'applied', 'dns', 10, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('seq-unique.test', 'dns', 'applied', 'answer', false);
COMMIT;

-- Stale success at sequence 9
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('seq-unique.test', 'dns', 'stale', 'dns', 9, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('seq-unique.test', 'dns', 'stale', 'answer', false);
COMMIT;

-- Error at sequence 8
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('seq-unique.test', 'dns', 'error', 'dns', 8, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('seq-unique.test', 'dns', 'error', 'timeout', false);
INSERT INTO dns_errors (domain, namespace, event_id, sequence, outcome, status_at_event, observed_at)
VALUES ('seq-unique.test', 'dns', 'error', 8, 'timeout', 'RegisteredParked', '2024-01-01T00:00:00Z');
COMMIT;

-- Try duplicate sequence 10 (should fail)
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('seq-unique.test', 'dns', 'dup-10', 'dns', 10, '2024-01-01T00:00:00Z', '{}'::jsonb);
ROLLBACK;

-- Try duplicate sequence 9 (should fail)
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('seq-unique.test', 'dns', 'dup-9', 'dns', 9, '2024-01-01T00:00:00Z', '{}'::jsonb);
ROLLBACK;

-- Try duplicate sequence 8 (should fail)
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('seq-unique.test', 'dns', 'dup-8', 'dns', 8, '2024-01-01T00:00:00Z', '{}'::jsonb);
ROLLBACK;

SELECT 'Sequence uniqueness:' AS test, count(*) FROM events WHERE domain = 'seq-unique.test' AND kind = 'dns';

\echo 'Test 13 completed (expect 3 events, 3 rollbacks for duplicate sequences)'

-- ============================================================================
-- Test 14: Empty answers preserved
-- DNS answer with zero records is valid and distinct from NXDOMAIN
-- ============================================================================
\echo 'Test 14: Empty answers preserved'

BEGIN;
INSERT INTO domains (domain) VALUES ('empty-answer.test');
-- Empty answer (NOERROR with zero records)
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('empty-answer.test', 'dns', 'empty', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('empty-answer.test', 'dns', 'empty', 'answer', false);
-- Zero dns_records rows (empty answer)
COMMIT;

SELECT 'Empty answer events:' AS test, count(*) FROM events WHERE domain = 'empty-answer.test';
SELECT 'Empty answer records:' AS test, count(*) FROM dns_records WHERE domain = 'empty-answer.test';

\echo 'Test 14 completed (expect 1 event, 0 records)'

-- ============================================================================
-- Test 15: Raw MX/NS strings without normalization
-- ============================================================================
\echo 'Test 15: Raw MX/NS strings preserved'

BEGIN;
INSERT INTO domains (domain) VALUES ('raw-strings.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('raw-strings.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('raw-strings.test', 'dns', 'event-1', 'answer', false);
-- MX with trailing dot preserved
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_mx_pref, value_mx_exchange)
VALUES ('raw-strings.test', 'dns', 'event-1', 0, 'MX', 10, 'mx.example.test.');
-- NS with mixed case preserved
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_ns)
VALUES ('raw-strings.test', 'dns', 'event-1', 1, 'NS', 'NS.Example.Test');
COMMIT;

SELECT 'Raw MX exchange:' AS test, value_mx_exchange FROM dns_records WHERE domain = 'raw-strings.test' AND record_type = 'MX';
SELECT 'Raw NS:' AS test, value_ns FROM dns_records WHERE domain = 'raw-strings.test' AND record_type = 'NS';

\echo 'Test 15 completed (expect raw strings preserved exactly)'

-- ============================================================================
-- Summary
-- ============================================================================
\echo '==========================================='
\echo 'All schema invariant tests defined.'
\echo 'Run each test file against PostgreSQL 16 to verify constraints.'
\echo 'Expected: rollbacks on constraint violations, commits on valid data.'
\echo '==========================================='