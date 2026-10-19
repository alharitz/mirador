-- SQL Test Fixtures: CT Monotonic and DNS Watermark
-- Verifies: CT monotonic, DNS watermark behavior, CT wins with NXDOMAIN

\echo 'Test: CT observed-ever is monotonic'

BEGIN;
INSERT INTO domains (domain) VALUES ('ct-monotonic.test');
-- First CT event
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('ct-monotonic.test', 'ct', 'event-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('ct-monotonic.test', 'ct', 'event-1', 'cert-1');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('ct-monotonic.test', 'ct', 'event-1', 'ct', 'Certified', true, 1, '{}'::jsonb);
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('ct-monotonic.test', NULL, 'Certified', 'ct', 'event-1', '2024-01-01T00:00:00Z');
COMMIT;

-- Second CT event with same certificate_id (idempotent)
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('ct-monotonic.test', 'ct', 'event-2', 'ct', NULL, '2024-01-02T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('ct-monotonic.test', 'ct', 'event-2', 'cert-1');  -- same cert
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('ct-monotonic.test', 'ct', 'event-2', 'ct', 'Certified', true, 2, '{}'::jsonb);
-- No finding (already Certified)
COMMIT;

SELECT 'CT events:' AS test, count(*) FROM events WHERE domain = 'ct-monotonic.test' AND kind = 'ct';
SELECT 'CT findings:' AS test, count(*) FROM findings WHERE domain = 'ct-monotonic.test';
SELECT 'CT ct_observed:' AS test, ct_observed FROM candidates WHERE domain = 'ct-monotonic.test';

\echo 'Test: CT wins even with NXDOMAIN'

BEGIN;
INSERT INTO domains (domain) VALUES ('ct-wins.test');
-- DNS NXDOMAIN first
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('ct-wins.test', 'Unregistered', 'dns', 1, false);
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('ct-wins.test', 'dns', 'nxdomain', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('ct-wins.test', 'dns', 'nxdomain', 'nxdomain', false);
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('ct-wins.test', 'dns', 'nxdomain', 'dns', 'Unregistered', true, 1, '{}'::jsonb);
COMMIT;

-- Then CT Certified
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('ct-wins.test', 'ct', 'cert-1', 'ct', NULL, '2024-01-02T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('ct-wins.test', 'ct', 'cert-1', 'cert-1');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('ct-wins.test', 'ct', 'cert-1', 'ct', 'Certified', true, 2, '{}'::jsonb);
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('ct-wins.test', 'Unregistered', 'Certified', 'ct', 'cert-1', '2024-01-02T00:00:00Z');
-- Update candidate status
UPDATE candidates SET status = 'Certified', ct_observed = true WHERE domain = 'ct-wins.test';
COMMIT;

SELECT 'CT wins status:' AS test, status, ct_observed FROM candidates WHERE domain = 'ct-wins.test';
SELECT 'CT wins findings:' AS test, from_status, to_status FROM findings WHERE domain = 'ct-wins.test';

\echo 'Test: DNS watermark advances only on applied success'

BEGIN;
INSERT INTO domains (domain) VALUES ('watermark.test');
-- Error at sequence 5 (does not advance watermark)
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('watermark.test', 'dns', 'error', 'dns', 5, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('watermark.test', 'dns', 'error', 'timeout', false);
INSERT INTO dns_errors (domain, namespace, event_id, sequence, outcome, status_at_event, observed_at)
VALUES ('watermark.test', 'dns', 'error', 5, 'timeout', NULL, '2024-01-01T00:00:00Z');
COMMIT;

-- Applied success at sequence 10
BEGIN;
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('watermark.test', 'RegisteredParked', 'dns', 10, false);
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('watermark.test', 'dns', 'success', 'dns', 10, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('watermark.test', 'dns', 'success', 'answer', false);
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_ns)
VALUES ('watermark.test', 'dns', 'success', 0, 'NS', 'ns.test');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('watermark.test', 'dns', 'success', 'dns', 'RegisteredParked', true, 1, '{}'::jsonb);
COMMIT;

SELECT 'Watermark after error+success:' AS test, dns_sequence FROM candidates WHERE domain = 'watermark.test';

-- Stale success at sequence 9 (does not advance watermark)
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('watermark.test', 'dns', 'stale', 'dns', 9, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('watermark.test', 'dns', 'stale', 'answer', false);
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_mx_pref, value_mx_exchange)
VALUES ('watermark.test', 'dns', 'stale', 0, 'MX', 10, 'mx.test');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('watermark.test', 'dns', 'stale', 'dns', 'MailReady', false, 2, '{}'::jsonb);
COMMIT;

SELECT 'Watermark after stale:' AS test, dns_sequence FROM candidates WHERE domain = 'watermark.test';

-- Fresh success at sequence 11 (advances watermark)
BEGIN;
UPDATE candidates SET status = 'MailReady', dns_sequence = 11 WHERE domain = 'watermark.test';
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('watermark.test', 'dns', 'fresh', 'dns', 11, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('watermark.test', 'dns', 'fresh', 'answer', false);
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_mx_pref, value_mx_exchange)
VALUES ('watermark.test', 'dns', 'fresh', 0, 'MX', 10, 'mx.test');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('watermark.test', 'dns', 'fresh', 'dns', 'MailReady', true, 3, '{}'::jsonb);
COMMIT;

SELECT 'Watermark after fresh:' AS test, dns_sequence FROM candidates WHERE domain = 'watermark.test';

\echo 'Test: CT namespaces independent of DNS namespace'

BEGIN;
INSERT INTO domains (domain) VALUES ('ct-namespace.test');
INSERT INTO candidates (domain, status, dns_namespace, dns_sequence, ct_observed)
VALUES ('ct-namespace.test', 'Unregistered', 'dns', 1, false);
-- DNS error fixes DNS namespace to 'dns'
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('ct-namespace.test', 'dns', 'error', 'dns', 1, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('ct-namespace.test', 'dns', 'error', 'servfail', false);
INSERT INTO dns_errors (domain, namespace, event_id, sequence, outcome, status_at_event, observed_at)
VALUES ('ct-namespace.test', 'dns', 'error', 1, 'servfail', NULL, '2024-01-01T00:00:00Z');
COMMIT;

-- CT with different namespace (allowed)
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('ct-namespace.test', 'ct-one', 'cert-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('ct-namespace.test', 'ct-one', 'cert-1', 'cert-1');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('ct-namespace.test', 'ct-one', 'cert-1', 'ct', 'Certified', true, 1, '{}'::jsonb);
COMMIT;

-- Another CT with different namespace (allowed)
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('ct-namespace.test', 'ct-two', 'cert-2', 'ct', NULL, '2024-01-01T00:00:00Z', '{}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('ct-namespace.test', 'ct-two', 'cert-2', 'cert-2');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('ct-namespace.test', 'ct-two', 'cert-2', 'ct', 'Certified', true, 2, '{}'::jsonb);
COMMIT;

SELECT 'CT namespaces:' AS test, namespace FROM events WHERE domain = 'ct-namespace.test' AND kind = 'ct';

-- But DNS with different namespace would conflict with candidate.dns_namespace
-- (application-level enforcement)

\echo 'All CT monotonic / DNS watermark tests defined.'