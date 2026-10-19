\set ON_ERROR_STOP on
-- Disposable empty test database only; never production role provisioning.
BEGIN;
\ir helpers.sql
SELECT pg_temp.assert_true((SELECT rolsuper FROM pg_roles WHERE rolname=current_user), 'superuser test runner required');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT FROM public.domains), 'fresh disposable database required');
SELECT 'mirador_fixture05_' || pg_backend_pid() || '_' || txid_current() AS runtime_role \gset
CREATE ROLE :"runtime_role" NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
GRANT USAGE ON SCHEMA public TO :"runtime_role";
GRANT SELECT, INSERT ON public.domains, public.dns_streams, public.candidates, public.brands,
    public.events, public.dns_records, public.success_history, public.findings TO :"runtime_role";
GRANT UPDATE (status, dns_namespace, dns_sequence, ct_observed) ON public.candidates TO :"runtime_role";
GRANT USAGE ON SEQUENCE public.success_history_acceptance_order_seq TO :"runtime_role";
SET LOCAL ROLE :"runtime_role";
INSERT INTO public.domains VALUES ('permissions.test') ON CONFLICT DO NOTHING;
SELECT pg_temp.reject($q$SELECT public.lock_domain('permissions.test')$q$, '42501');
RESET ROLE;
GRANT EXECUTE ON FUNCTION public.lock_domain(TEXT) TO :"runtime_role";
SET LOCAL ROLE :"runtime_role";
SELECT public.lock_domain('permissions.test');
SELECT pg_temp.reject($q$SELECT public.lock_domain('missing.test')$q$, 'P0001');
-- Invoker helpers and trigger queries must work without table ownership or UPDATE.
SELECT pg_temp.dns('permissions.test', 'answer', 1, records => 2);
INSERT INTO public.dns_records(domain,namespace,event_id,ordinal,record_type,value_a) VALUES
    ('permissions.test','dns','answer',0,'A','192.0.2.1'),
    ('permissions.test','dns','answer',1,'A','192.0.2.1');
INSERT INTO public.candidates(domain) VALUES ('permissions.test');
UPDATE public.candidates SET status='RegisteredParked', dns_namespace='dns', dns_sequence=1,
    ct_observed=FALSE WHERE domain='permissions.test';
INSERT INTO public.brands VALUES ('permissions.test','fixture');
SELECT pg_temp.ct('permissions.test', 'ct', 'cert');
UPDATE public.candidates SET status='Certified', ct_observed=TRUE WHERE domain='permissions.test';
INSERT INTO public.findings(domain,namespace,event_id,from_status,to_status,observed_at)
    VALUES ('permissions.test','ct','cert','RegisteredParked','Certified','opaque source time');
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert_true((SELECT count(*)=2 FROM public.success_history WHERE domain='permissions.test'), 'identity allocation and history writes');
SELECT pg_temp.assert_true((SELECT status='Certified' AND ct_observed AND dns_sequence=1 FROM public.candidates WHERE domain='permissions.test'), 'narrow candidate updates');
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['domains','dns_streams','brands','events','dns_records','success_history','findings'] LOOP
        PERFORM pg_temp.reject(format('UPDATE public.%I SET domain=domain', t), '42501');
        PERFORM pg_temp.reject(format('DELETE FROM public.%I', t), '42501');
        PERFORM pg_temp.reject(format('TRUNCATE public.%I', t), '42501');
    END LOOP;
END $$;
SELECT pg_temp.reject($q$UPDATE public.candidates SET domain=domain$q$, '42501');
SELECT pg_temp.reject($q$DELETE FROM public.candidates$q$, '42501');
SELECT pg_temp.reject($q$TRUNCATE public.candidates$q$, '42501');
SELECT pg_temp.reject($q$SELECT FROM public.domains FOR UPDATE$q$, '42501');
SELECT pg_temp.reject($q$CREATE TABLE public.fixture_forbidden(id INTEGER)$q$, '42501');
SELECT pg_temp.reject($q$CREATE OR REPLACE FUNCTION public.lock_domain(TEXT) RETURNS VOID LANGUAGE plpgsql AS 'BEGIN RETURN; END'$q$, '42501');
SELECT pg_temp.reject(format('ALTER FUNCTION public.lock_domain(TEXT) OWNER TO %I', current_user), '42501');
SELECT pg_temp.reject(format('ALTER ROLE %I SUPERUSER', current_user), '42501');
SELECT pg_temp.reject(format('GRANT postgres TO %I', current_user), '42501');
SELECT pg_temp.assert_true(NOT pg_has_role(current_user, (SELECT proowner FROM pg_proc WHERE oid='public.lock_domain(text)'::regprocedure), 'MEMBER'), 'no trusted owner membership');
SELECT pg_temp.assert_true(has_sequence_privilege(current_user, 'public.success_history_acceptance_order_seq', 'USAGE'), 'identity sequence usage granted');
SELECT pg_temp.assert_true(NOT has_sequence_privilege(current_user, 'public.success_history_acceptance_order_seq', 'UPDATE'), 'no sequence reset privilege');
RESET ROLE;
-- No membership granted. Rollback removes role, grants, helpers, and fixture rows.
ROLLBACK;
\echo '05 runtime permissions passed'
