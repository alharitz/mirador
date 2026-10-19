\set ON_ERROR_STOP on
BEGIN;
\ir helpers.sql

SELECT pg_temp.dns('bounds.test', 'max', 18446744073709551615);
SELECT pg_temp.dns('bounds.test', 'zero', 0);
SELECT pg_temp.reject($q$SELECT pg_temp.dns('bounds.test', 'negative', -1)$q$, '23514');
SELECT pg_temp.reject($q$SELECT pg_temp.dns('bounds.test', 'overflow', 18446744073709551616)$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO candidates(domain, dns_sequence) VALUES ('bounds.test', -1)$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO candidates(domain, dns_sequence) VALUES ('bounds.test', 18446744073709551616)$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO candidates(domain, dns_sequence) VALUES ('bounds.test', 1.5)$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,sequence,outcome)
    VALUES ('bounds.test','dns','fractional','dns','',1.5,'timeout')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO domains VALUES ('Upper.test')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO domains VALUES ('')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO domains VALUES (repeat('a.', 126) || 'aa')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,certificate_id)
    VALUES ('bounds.test','','e','ct','','cert')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,certificate_id)
    VALUES ('bounds.test','ct','','ct','','cert')$q$, '23514');
SELECT pg_temp.ct('bounds.test', 'ct', 'empty-cert', '');
SELECT pg_temp.assert_true((SELECT certificate_id = '' FROM events
    WHERE domain='bounds.test' AND event_id='empty-cert'), 'empty certificate preserved');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,certificate_id)
    VALUES ('bounds.test','ct','null-cert','ct','',NULL)$q$, '23514');
SELECT pg_temp.reject($q$SELECT pg_temp.dns('count.test','negative',1,records => -1)$q$, '23514');
SELECT pg_temp.reject($q$SELECT pg_temp.dns('count.test','overflow',1,records => 2147483649)$q$, '23514');
SELECT pg_temp.reject($q$SELECT pg_temp.dns('count.test','null',1,records => NULL)$q$, '23502');
SELECT pg_temp.reject($q$SELECT pg_temp.dns('count.test','nx',1,'nxdomain',records => 1)$q$, '23514');
SELECT pg_temp.reject($q$SELECT pg_temp.dns('count.test','error',1,'timeout',records => 1)$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,certificate_id,dns_record_count)
    VALUES ('bounds.test','ct','count','ct','','',1)$q$, '23514');

-- Error facts reserve namespace and sequence without any candidate or history.
SELECT pg_temp.dns('error.test', 'error', 7, 'timeout');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT FROM candidates WHERE domain='error.test'), 'error before candidate');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT FROM success_history WHERE domain='error.test'), 'errors have no history');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,sequence,outcome)
    VALUES ('error.test','other','second','dns','',8,'timeout')$q$, '23503');
SELECT pg_temp.reject($q$SELECT pg_temp.dns('error.test', 'duplicate', 7, 'servfail')$q$, '23505');
SELECT pg_temp.reject($q$INSERT INTO candidates(domain,dns_namespace) VALUES ('error.test','other')$q$, '23503');

SELECT pg_temp.dns('records.test', 'answer', 1, records => 4);
INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_a) VALUES
    ('records.test','dns','answer',0,'A','192.0.2.1'),
    ('records.test','dns','answer',1,'A','192.0.2.1');
INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_mx_pref,value_mx_exchange)
    VALUES ('records.test','dns','answer',2,'MX',65535,'MX.Example.');
INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_ns)
    VALUES ('records.test','dns','answer',3,'NS','');
SELECT pg_temp.assert_true((SELECT array_agg(ordinal ORDER BY ordinal) = ARRAY[0,1,2,3]
    FROM dns_records WHERE domain='records.test'), 'ordered duplicate records');
SELECT pg_temp.assert_true((SELECT value_mx_exchange='MX.Example.' FROM dns_records
    WHERE domain='records.test' AND ordinal=2), 'raw MX unchanged');
SELECT pg_temp.reject($q$INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_a)
    VALUES ('records.test','dns','answer',0,'A','::1')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_a)
    VALUES ('records.test','dns','answer',0,'A','192.0.2.1/24')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_a,value_ns)
    VALUES ('records.test','dns','answer',0,'A','192.0.2.1','ns')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_mx_pref,value_mx_exchange)
    VALUES ('records.test','dns','answer',0,'MX',65536,'mx')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_mx_pref,value_mx_exchange)
    VALUES ('records.test','dns','answer',0,'MX',-1,'mx')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_ns)
    VALUES ('records.test','dns','answer',-1,'NS','ns')$q$, '23514');
SELECT pg_temp.dns('records.test', 'empty', 2);
SELECT pg_temp.assert_true(NOT EXISTS (SELECT FROM dns_records WHERE domain='records.test' AND event_id='empty'), 'empty answer');
SELECT pg_temp.dns('records.test', 'nx', 3, 'nxdomain', 'Unregistered');
SELECT pg_temp.reject($q$INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_ns)
    VALUES ('records.test','dns','nx',0,'NS','ns')$q$, '23503');
SELECT pg_temp.reject($q$INSERT INTO dns_records(domain,namespace,event_id,ordinal,outcome,record_type,value_ns)
    VALUES ('records.test','dns','nx',0,'nxdomain','NS','ns')$q$, '23514');

INSERT INTO candidates(domain) VALUES ('records.test');
INSERT INTO brands VALUES ('records.test','one'), ('records.test','two'), ('records.test','');
INSERT INTO brands VALUES ('records.test','one') ON CONFLICT DO NOTHING;
SELECT pg_temp.assert_true((SELECT count(*)=3 FROM brands WHERE domain='records.test'), 'idempotent many brands including empty');
SELECT pg_temp.reject($q$INSERT INTO brands VALUES ('records.test',NULL)$q$, '23502');
SELECT pg_temp.reject($q$DELETE FROM candidates WHERE domain='records.test'$q$, '23503');
SELECT pg_temp.reject($q$DELETE FROM domains WHERE domain='records.test'$q$, '23503');
SELECT pg_temp.reject($q$DELETE FROM events WHERE domain='records.test' AND event_id='answer'$q$, '23503');
SELECT pg_temp.reject($q$DELETE FROM success_history WHERE domain='records.test' AND event_id='answer'$q$, '23503');

-- Failed event processing rolls back anchor, stream, and all event writes.
SELECT pg_temp.reject($q$SELECT pg_temp.dns('rollback.test','bad',-1)$q$, '23514');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT FROM domains WHERE domain='rollback.test'), 'rollback anchor');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT FROM dns_streams WHERE domain='rollback.test'), 'rollback stream');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT FROM events WHERE domain='rollback.test'), 'rollback event');
-- Force sealing inside reject's subtransaction; failed parent/history writes roll back.
SELECT pg_temp.reject($q$DO $body$ BEGIN
    PERFORM pg_temp.dns('seal.test','missing',1,records => 2);
    INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_ns)
        VALUES ('seal.test','dns','missing',1,'NS','ns');
    SET CONSTRAINTS ALL IMMEDIATE;
END; $body$$q$, '23514');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT FROM events WHERE domain='seal.test'), 'incomplete envelope rolled back');
DO $body$ BEGIN
    PERFORM pg_temp.dns('seal.test','max-count',1,records => 2147483648);
    PERFORM pg_temp.assert_true((SELECT dns_record_count=2147483648 FROM events
        WHERE domain='seal.test' AND event_id='max-count'), 'maximum count accepted');
    RAISE EXCEPTION 'rollback maximum-count setup' USING ERRCODE = 'ZX001';
EXCEPTION WHEN SQLSTATE 'ZX001' THEN NULL;
END; $body$;
SELECT pg_temp.reject($q$UPDATE events SET dns_record_count=5
    WHERE domain='records.test' AND event_id='answer'$q$, '23514');
SET CONSTRAINTS ALL IMMEDIATE;
-- Exact count + unique bounded ordinals seal existing envelopes against later appends.
SELECT pg_temp.reject($q$INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_ns)
    VALUES ('records.test','dns','answer',4,'NS','late')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_ns)
    VALUES ('records.test','dns','answer',0,'NS','replacement')$q$, '23505');
SELECT pg_temp.reject($q$INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_ns)
    VALUES ('records.test','dns','empty',0,'NS','late')$q$, '23514');
ROLLBACK;
