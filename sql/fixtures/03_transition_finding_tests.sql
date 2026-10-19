\set ON_ERROR_STOP on
BEGIN;
\ir helpers.sql
SELECT pg_temp.ct('initial.test','ct','first');
INSERT INTO findings(domain,namespace,event_id,from_status,to_status,observed_at)
    VALUES ('initial.test','ct','first',NULL,'Certified','opaque source time');
SELECT pg_temp.assert_true((SELECT from_status IS NULL FROM findings WHERE domain='initial.test'), 'initial CT nullable from');
SELECT pg_temp.reject($q$DELETE FROM success_history WHERE domain='initial.test'$q$, '23503');
SELECT pg_temp.reject($q$INSERT INTO findings(domain,namespace,event_id,to_status,observed_at)
    VALUES ('initial.test','ct','first','Certified','opaque source time')$q$, '23505');

SELECT pg_temp.dns('transition.test','up',1,'answer','MailReady');
INSERT INTO findings(domain,namespace,event_id,from_status,to_status,observed_at)
    VALUES ('transition.test','dns','up','RegisteredParked','MailReady','opaque source time');
SELECT pg_temp.dns('stale.test','stale',1,'answer','MailReady',FALSE);
SELECT pg_temp.reject($q$INSERT INTO findings(domain,namespace,event_id,from_status,to_status,observed_at)
    VALUES ('stale.test','dns','stale','Unregistered','MailReady','opaque source time')$q$, '23503');
SELECT pg_temp.ct('mismatch.test','ct','event');
SELECT pg_temp.reject($q$INSERT INTO findings(domain,namespace,event_id,from_status,to_status,observed_at)
    VALUES ('mismatch.test','ct','event','Unregistered','MailReady','opaque source time')$q$, '23503');
SELECT pg_temp.reject($q$INSERT INTO findings(domain,namespace,event_id,to_status,observed_at)
    VALUES ('mismatch.test','ct','event','Certified','changed time')$q$, '23503');
SELECT pg_temp.reject($q$INSERT INTO findings(domain,namespace,event_id,from_status,to_status,observed_at)
    VALUES ('mismatch.test','ct','event','Certified','Unregistered','opaque source time')$q$, '23514');
-- NULL must not sneak through CHECK's three-valued logic for DNS baseline.
SELECT pg_temp.reject($q$INSERT INTO findings(domain,namespace,event_id,to_status,observed_at)
    VALUES ('transition.test','dns','up','MailReady','opaque source time')$q$, '23514');

SELECT pg_temp.dns('error-history.test','error',1,'servfail');
SELECT pg_temp.reject($q$INSERT INTO success_history(domain,namespace,event_id,kind,status,applied)
    VALUES ('error-history.test','dns','error','dns','Unregistered',TRUE)$q$, '23503');
-- Isolated history-kind mismatch, without a preexisting history masking failure.
INSERT INTO domains VALUES ('kind.test');
INSERT INTO events(domain,namespace,event_id,kind,observed_at,certificate_id)
    VALUES ('kind.test','ct','event','ct','','cert');
SELECT pg_temp.reject($q$INSERT INTO success_history(domain,namespace,event_id,kind,status,applied)
    VALUES ('kind.test','ct','event','dns','Certified',TRUE)$q$, '23503');
SELECT pg_temp.reject($q$INSERT INTO success_history(domain,namespace,event_id,kind,status,applied)
    VALUES ('kind.test','ct','event','ct','MailReady',TRUE)$q$, '23514');
-- Force deferred FK to prove missing history rejected, then complete valid row.
SELECT pg_temp.reject('SET CONSTRAINTS events_require_success_history IMMEDIATE', '23503');
INSERT INTO success_history(domain,namespace,event_id,kind,status,applied)
    VALUES ('kind.test','ct','event','ct','Certified',TRUE);
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert_true((SELECT count(*)=count(DISTINCT acceptance_order) FROM success_history), 'database acceptance order unique');
ROLLBACK;
