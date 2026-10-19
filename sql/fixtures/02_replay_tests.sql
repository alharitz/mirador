-- SQL Test Fixtures: Exact Replay and Conflicting Replay
-- Verifies: exact replay is no-op, conflicting replay fails without mutation

\echo 'Test: Exact replay is no-op (DNS)'

BEGIN;
INSERT INTO domains (domain) VALUES ('replay.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('replay.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{"test": "data"}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('replay.test', 'dns', 'event-1', 'answer', false);
INSERT INTO dns_records (domain, namespace, event_id, ordinal, record_type, value_a)
VALUES ('replay.test', 'dns', 'event-1', 0, 'A', '192.0.2.1'::inet);
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('replay.test', 'dns', 'event-1', 'dns', 'RegisteredParked', true, 1, '{"test": "data"}'::jsonb);
COMMIT;

-- Exact replay: same identity, same payload
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('replay.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{"test": "data"}'::jsonb);
ROLLBACK;

-- Verify no duplicate
SELECT 'Exact replay - events count:' AS test, count(*) FROM events WHERE domain = 'replay.test' AND event_id = 'event-1';

\echo 'Test: Exact replay is no-op (CT)'

BEGIN;
INSERT INTO domains (domain) VALUES ('replay-ct.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('replay-ct.test', 'ct', 'event-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{"cert": "cert-1"}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('replay-ct.test', 'ct', 'event-1', 'cert-1');
INSERT INTO success_history (domain, namespace, event_id, kind, status, applied, acceptance_order, raw_evidence_ref)
VALUES ('replay-ct.test', 'ct', 'event-1', 'ct', 'Certified', true, 1, '{"cert": "cert-1"}'::jsonb);
INSERT INTO findings (domain, from_status, to_status, namespace, event_id, observed_at)
VALUES ('replay-ct.test', NULL, 'Certified', 'ct', 'event-1', '2024-01-01T00:00:00Z');
COMMIT;

-- Exact replay
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('replay-ct.test', 'ct', 'event-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{"cert": "cert-1"}'::jsonb);
ROLLBACK;

SELECT 'Exact replay CT - events count:' AS test, count(*) FROM events WHERE domain = 'replay-ct.test' AND event_id = 'event-1';

\echo 'Test: Conflicting replay fails without mutation (DNS)'

BEGIN;
INSERT INTO domains (domain) VALUES ('conflict.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('conflict.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{"orig": "data"}'::jsonb);
INSERT INTO dns_facts (domain, namespace, event_id, outcome, has_certificate)
VALUES ('conflict.test', 'dns', 'event-1', 'answer', false);
COMMIT;

-- Conflicting replay: same identity, different payload
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('conflict.test', 'dns', 'event-1', 'dns', 1, '2024-01-01T00:00:00Z', '{"different": "data"}'::jsonb);
ROLLBACK;

-- Verify original unchanged
SELECT 'Conflict replay - events count:' AS test, count(*) FROM events WHERE domain = 'conflict.test' AND event_id = 'event-1';
SELECT 'Conflict replay - original payload:' AS test, raw_payload FROM events WHERE domain = 'conflict.test' AND event_id = 'event-1';

\echo 'Test: Conflicting replay fails without mutation (CT)'

BEGIN;
INSERT INTO domains (domain) VALUES ('conflict-ct.test');
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('conflict-ct.test', 'ct', 'event-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{"cert": "cert-1"}'::jsonb);
INSERT INTO ct_facts (domain, namespace, event_id, certificate_id)
VALUES ('conflict-ct.test', 'ct', 'event-1', 'cert-1');
COMMIT;

-- Conflicting replay: same identity, different cert
BEGIN;
INSERT INTO events (domain, namespace, event_id, kind, sequence, observed_at, raw_payload)
VALUES ('conflict-ct.test', 'ct', 'event-1', 'ct', NULL, '2024-01-01T00:00:00Z', '{"cert": "cert-2"}'::jsonb);
ROLLBACK;

SELECT 'Conflict replay CT - events count:' AS test, count(*) FROM events WHERE domain = 'conflict-ct.test' AND event_id = 'event-1';
SELECT 'Conflict replay CT - original cert:' AS test, certificate_id FROM ct_facts WHERE domain = 'conflict-ct.test' AND event_id = 'event-1';

\echo 'All replay tests defined.'