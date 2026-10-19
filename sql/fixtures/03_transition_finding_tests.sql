-- SQL Test Fixtures: State Transitions and Findings
-- Verifies: DNS baseline silent, CT Certified emits finding, eligible transitions only

\echo 'Test: DNS baseline (NXDOMAIN) emits no finding'

BEGIN;
INSERT INTO domains (domain) VALUES ('baseline.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('baseline.test', 'Unregistered', 'dns', 1, false);
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('baseline.test', 'dns', 'baseline', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('baseline.test', 'dns', 'baseline', 'nxdomain', false);
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('baseline.test', 'dns', 'baseline', 'dns', 'Unregistered', true, 1, '{}'::jsonb);
COMMIT;

SELECT 'Baseline findings:' AS test, count(*) FROM findings WHERE domain = 'baseline.test';

\echo 'Test: Initial CT Certified emits finding (from=NULL)'

BEGIN;
INSERT INTO domains (domain) VALUES ('initial-ct.test');
-- No candidate yet
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('initial-ct.test', 'ct', 'cert-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('initial-ct.test', 'ct', 'cert-1', 'cert-1');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('initial-ct.test', 'ct', 'cert-1', 'ct', 'Certified', true, 1, '{}'::jsonb);
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('initial-ct.test', NULL, 'Certified', 'ct', 'cert-1', '2024-01-01T00:00:00Z');
COMMIT;

SELECT 'Initial CT finding:' AS test, from_status, to_status FROM findings WHERE domain = 'initial-ct.test';

\echo 'Test: Eligible transitions only'

-- Unregistered -> RegisteredParked
BEGIN;
INSERT INTO domains (domain) VALUES ('trans-1.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('trans-1.test', 'Unregistered', 'dns', 1, false);
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('trans-1.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('trans-1.test', 'dns', 'event-1', 'answer', false);
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_ns)
VALUES ('trans-1.test', 'dns', 'event-1', 0, 'NS', 'ns.test');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('trans-1.test', 'dns', 'event-1', 'dns', 'RegisteredParked', true, 1, '{}'::jsonb);
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('trans-1.test', 'Unregistered', 'RegisteredParked', 'dns', 'event-1', '2024-01-01T00:00:00Z');
COMMIT;

-- Unregistered -> MailReady
BEGIN;
INSERT INTO domains (domain) VALUES ('trans-2.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('trans-2.test', 'Unregistered', 'dns', 1, false);
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('trans-2.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('trans-2.test', 'dns', 'event-1', 'answer', false);
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_mx_pref, value_mx_exchange)
VALUES ('trans-2.test', 'dns', 'event-1', 0, 'MX', 10, 'mx.test');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('trans-2.test', 'dns', 'event-1', 'dns', 'MailReady', true, 1, '{}'::jsonb);
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('trans-2.test', 'Unregistered', 'MailReady', 'dns', 'event-1', '2024-01-01T00:00:00Z');
COMMIT;

-- Unregistered -> Certified (via CT)
BEGIN;
INSERT INTO domains (domain) VALUES ('trans-3.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('trans-3.test', 'Unregistered', 'dns', 1, false);
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('trans-3.test', 'ct', 'cert-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('trans-3.test', 'ct', 'cert-1', 'cert-1');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('trans-3.test', 'ct', 'cert-1', 'ct', 'Certified', true, 1, '{}'::jsonb);
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('trans-3.test', 'Unregistered', 'Certified', 'ct', 'cert-1', '2024-01-01T00:00:00Z');
COMMIT;

-- RegisteredParked -> MailReady
BEGIN;
INSERT INTO domains (domain) VALUES ('trans-4.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('trans-4.test', 'RegisteredParked', 'dns', 1, false);
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('trans-4.test', 'dns', 'event-1', 'dns', 2, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('trans-4.test', 'dns', 'event-1', 'answer', false);
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_mx_pref, value_mx_exchange)
VALUES ('trans-4.test', 'dns', 'event-1', 0, 'MX', 10, 'mx.test');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('trans-4.test', 'dns', 'event-1', 'dns', 'MailReady', true, 1, '{}'::jsonb);
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('trans-4.test', 'RegisteredParked', 'MailReady', 'dns', 'event-1', '2024-01-01T00:00:00Z');
COMMIT;

-- RegisteredParked -> Certified
BEGIN;
INSERT INTO domains (domain) VALUES ('trans-5.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('trans-5.test', 'RegisteredParked', 'dns', 1, false);
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('trans-5.test', 'ct', 'cert-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('trans-5.test', 'ct', 'cert-1', 'cert-1');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('trans-5.test', 'ct', 'cert-1', 'ct', 'Certified', true, 1, '{}'::jsonb);
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('trans-5.test', 'RegisteredParked', 'Certified', 'ct', 'cert-1', '2024-01-01T00:00:00Z');
COMMIT;

-- MailReady -> Certified
BEGIN;
INSERT INTO domains (domain) VALUES ('trans-6.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('trans-6.test', 'MailReady', 'dns', 1, false);
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('trans-6.test', 'ct', 'cert-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('trans-6.test', 'ct', 'cert-1', 'cert-1');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('trans-6.test', 'ct', 'cert-1', 'ct', 'Certified', true, 1, '{}'::jsonb);
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('trans-6.test', 'MailReady', 'Certified', 'ct', 'cert-1', '2024-01-01T00:00:00Z');
COMMIT;

\echo 'Test: Ineligible transitions rejected'

-- Downgrade: Certified -> Unregistered (should fail)
BEGIN;
INSERT INTO domains (domain) VALUES ('trans-fail-1.test');
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('trans-fail-1.test', 'Certified', 'Unregistered', 'ct', 'event-1', '2024-01-01T00:00:00Z');
ROLLBACK;

-- Downgrade: MailReady -> RegisteredParked (should fail)
BEGIN;
INSERT INTO domains (domain) VALUES ('trans-fail-2.test');
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('trans-fail-2.test', 'MailReady', 'RegisteredParked', 'dns', 'event-1', '2024-01-01T00:00:00Z');
ROLLBACK;

-- Same status: RegisteredParked -> RegisteredParked (should fail)
BEGIN;
INSERT INTO domains (domain) VALUES ('trans-fail-3.test');
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('trans-fail-3.test', 'RegisteredParked', 'RegisteredParked', 'dns', 'event-1', '2024-01-01T00:00:00Z');
ROLLBACK;

-- Unregistered -> Unregistered (should fail - not in eligible list)
BEGIN;
INSERT INTO domains (domain) VALUES ('trans-fail-4.test');
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('trans-fail-4.test', 'Unregistered', 'Unregistered', 'dns', 'event-1', '2024-01-01T00:00:00Z');
ROLLBACK;

\echo 'Test: Stale observation does not emit finding'

BEGIN;
INSERT INTO domains (domain) VALUES ('stale-finding.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('stale-finding.test', 'MailReady', 'dns', 10, false);
-- Stale success (sequence 9 < 10)
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('stale-finding.test', 'dns', 'stale', 'dns', 9, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('stale-finding.test', 'dns', 'stale', 'answer', false);
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_ns)
VALUES ('stale-finding.test', 'dns', 'stale', 0, 'NS', 'ns.test');
-- Stale: applied=false, no finding
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('stale-finding.test', 'dns', 'stale', 'dns', 'RegisteredParked', false, 1, '{}'::jsonb);
COMMIT;

SELECT 'Stale findings:' AS test, count(*) FROM findings WHERE domain = 'stale-finding.test';

\echo 'Test: Error observation emits no finding'

BEGIN;
INSERT INTO domains (domain) VALUES ('error-finding.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('error-finding.test', 'RegisteredParked', 'dns', 1, false);
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('error-finding.test', 'dns', 'error', 'dns', 2, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('error-finding.test', 'dns', 'error', 'timeout', false);
INSERT INTO dns_errors (domain, namespace, event_id, sequence, outcome, status_at_event, observed_at)
VALUES ('error-finding.test', 'dns', 'error', 2, 'timeout', 'RegisteredParked', '2024-01-01T00:00:00Z');
COMMIT;

SELECT 'Error findings:' AS test, count(*) FROM findings WHERE domain = 'error-finding.test';

\echo 'All transition/finding tests defined.'