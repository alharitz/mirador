\set ON_ERROR_STOP on
-- Structural payload checks only. Classifier, CT monotonicity, and watermark
-- transaction behavior require the future adapter; SQL does not implement them.
BEGIN;
\ir helpers.sql
SELECT pg_temp.dns('shape.test','error',1,'timeout');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,sequence,outcome,has_certificate)
    VALUES ('shape.test','dns','bad','dns','',2,'timeout',FALSE)$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,sequence,outcome)
    VALUES ('shape.test','dns','bad','dns','',2,'answer')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,sequence,outcome)
    VALUES ('shape.test','dns','bad','dns','',2,'invalid')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,sequence,outcome,certificate_id)
    VALUES ('shape.test','dns','bad','dns','',2,'timeout','cert')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,sequence,certificate_id)
    VALUES ('shape.test','ct','bad','ct','',2,'cert')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,outcome,certificate_id)
    VALUES ('shape.test','ct','bad','ct','','answer','cert')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO events(domain,namespace,event_id,kind,observed_at,certificate_id)
    VALUES ('shape.test','ct','bad','invalid','','cert')$q$, '23514');
SELECT pg_temp.reject($q$UPDATE events SET status_at_event='ActiveReserved' WHERE domain='shape.test'$q$, '23514');
SELECT pg_temp.dns('shape.test','success',2,'nxdomain','Unregistered');
SELECT pg_temp.reject($q$UPDATE events SET status_at_event='Certified' WHERE domain='shape.test' AND event_id='success'$q$, '23514');
SELECT pg_temp.ct('shape.test','ct-one','cert');
SELECT pg_temp.ct('shape.test','ct-two','cert');
SELECT pg_temp.assert_true((SELECT count(*)=2 FROM events WHERE domain='shape.test' AND kind='ct'), 'CT namespace independent');
SELECT pg_temp.dns('other.test','error',1,'timeout');
SELECT pg_temp.reject($q$INSERT INTO dns_records(domain,namespace,event_id,ordinal,record_type,value_ns)
    VALUES ('other.test','dns','success',0,'NS','ns')$q$, '23503');
SELECT pg_temp.reject($q$INSERT INTO success_history(domain,namespace,event_id,kind,status,applied)
    VALUES ('other.test','ct-one','cert','ct','Certified',TRUE)$q$, '23503');
-- DNS has_certificate is payload, not a candidate CT latch.
UPDATE events SET has_certificate=TRUE WHERE domain='shape.test' AND event_id='success';
SELECT pg_temp.assert_true(NOT EXISTS (SELECT FROM candidates WHERE domain='shape.test'), 'no automatic CT candidate mutation');
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
