\set ON_ERROR_STOP on
-- Schema identity/evidence tests, NOT adapter exact-replay no-op tests.
BEGIN;
\ir helpers.sql
SELECT pg_temp.dns('identity.test','shared',1);
SELECT pg_temp.reject($q$SELECT pg_temp.ct('identity.test','dns','shared')$q$, '23505');
SELECT pg_temp.ct('reverse.test','dns','shared');
SELECT pg_temp.reject($q$SELECT pg_temp.dns('reverse.test','shared',1)$q$, '23505');
-- Both identical and conflicting direct inserts reject; adapter must compare first.
SELECT pg_temp.reject($q$SELECT pg_temp.dns('identity.test','shared',1)$q$, '23505');
SELECT pg_temp.reject($q$SELECT pg_temp.dns('identity.test','shared',2)$q$, '23505');
SELECT pg_temp.assert_true((SELECT sequence=1 FROM events WHERE domain='identity.test'), 'conflict unchanged');

SELECT pg_temp.ct('case.test','ct','event','Cert');
SELECT pg_temp.ct('case.test','CT','event','cert');
SELECT pg_temp.ct('case.test','ct','EVENT','Cert');
SELECT pg_temp.assert_true((SELECT count(*)=3 FROM events WHERE domain='case.test'), 'case-distinct identity');
SELECT pg_temp.assert_true((SELECT count(DISTINCT certificate_id)=2 FROM events WHERE domain='case.test'), 'exact certificate text');
SELECT pg_temp.assert_true((SELECT count(*)=2 FROM events WHERE domain='case.test' AND certificate_id='Cert'), 'repeated certificates distinct events');
-- Test setup updates only: production append-only role must not permit these writes.
UPDATE events SET observed_at='TIME' WHERE domain='case.test' AND namespace='ct' AND event_id='event';
UPDATE events SET observed_at='time' WHERE domain='case.test' AND namespace='CT';
SELECT pg_temp.assert_true((SELECT count(DISTINCT observed_at)=3 FROM events WHERE domain='case.test'), 'exact opaque source time');
SELECT pg_temp.assert_true((SELECT array_agg(event_id ORDER BY acceptance_order)=ARRAY['event','event','EVENT']
    FROM success_history WHERE domain='case.test'), 'acceptance independent of source timestamp');
-- No JSONB loss: all canonical text columns declare C collation.
SELECT pg_temp.assert_true(NOT EXISTS (
    SELECT FROM pg_attribute a JOIN pg_class t ON t.oid=a.attrelid
    JOIN pg_namespace n ON n.oid=t.relnamespace JOIN pg_collation c ON c.oid=a.attcollation
    WHERE n.nspname=current_schema() AND t.relname IN
        ('domains','dns_streams','candidates','brands','events','dns_records','success_history','findings')
        AND a.attnum>0 AND NOT a.attisdropped AND a.atttypid='text'::regtype AND c.collname <> 'C'
), 'canonical text uses C collation');
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
