\set ON_ERROR_STOP on
-- Disposable empty test database only. Committed rows require database disposal.
BEGIN;
\ir helpers.sql
SELECT pg_temp.assert_true((SELECT rolsuper FROM pg_roles WHERE rolname=current_user), 'superuser test runner required');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT FROM public.domains), 'fresh disposable database required');
SELECT 'mirador_fixture06_' || pg_backend_pid() || '_' || txid_current() AS runtime_role \gset
CREATE ROLE :"runtime_role" NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
GRANT USAGE ON SCHEMA public TO :"runtime_role";
GRANT SELECT, INSERT ON public.domains, public.dns_streams, public.events,
    public.dns_records, public.success_history TO :"runtime_role";
GRANT USAGE ON SEQUENCE public.success_history_acceptance_order_seq TO :"runtime_role";
GRANT EXECUTE ON FUNCTION public.lock_domain(TEXT) TO :"runtime_role";
SET LOCAL ROLE :"runtime_role";
INSERT INTO public.domains VALUES ('sealed.test');
SELECT public.lock_domain('sealed.test');
SELECT pg_temp.dns('sealed.test', 'duplicates', 1, records => 2);
INSERT INTO public.dns_records(domain,namespace,event_id,ordinal,record_type,value_ns) VALUES
    ('sealed.test','dns','duplicates',0,'NS','NS.Raw.'),
    ('sealed.test','dns','duplicates',1,'NS','NS.Raw.');
SELECT pg_temp.dns('sealed.test', 'empty', 2);
-- Real COMMIT runs deferred count/history checks as runtime, not merely owner.
COMMIT;

BEGIN;
SET LOCAL ROLE :"runtime_role";
SELECT public.lock_domain('sealed.test');
SELECT pg_temp.assert_true((SELECT array_agg(ordinal ORDER BY ordinal)=ARRAY[0,1]
    AND array_agg(value_ns ORDER BY ordinal)=ARRAY['NS.Raw.','NS.Raw.']
    FROM public.dns_records WHERE domain='sealed.test' AND event_id='duplicates'), 'committed ordered duplicates preserved');
SELECT pg_temp.assert_true((SELECT dns_record_count=0 FROM public.events
    WHERE domain='sealed.test' AND event_id='empty') AND NOT EXISTS (SELECT FROM public.dns_records
    WHERE domain='sealed.test' AND event_id='empty'), 'committed empty answer sealed');
SELECT pg_temp.reject($q$INSERT INTO public.dns_records(domain,namespace,event_id,ordinal,record_type,value_ns)
    VALUES ('sealed.test','dns','duplicates',2,'NS','late')$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO public.dns_records(domain,namespace,event_id,ordinal,record_type,value_ns)
    VALUES ('sealed.test','dns','duplicates',0,'NS','duplicate ordinal')$q$, '23505');
SELECT pg_temp.reject($q$INSERT INTO public.dns_records(domain,namespace,event_id,ordinal,record_type,value_ns)
    VALUES ('sealed.test','dns','empty',0,'NS','late')$q$, '23514');
SELECT pg_temp.reject($q$UPDATE public.dns_records SET value_ns='changed' WHERE domain='sealed.test'$q$, '42501');
SELECT pg_temp.reject($q$DELETE FROM public.dns_records WHERE domain='sealed.test'$q$, '42501');
SELECT pg_temp.reject($q$UPDATE public.events SET dns_record_count=3 WHERE domain='sealed.test' AND event_id='duplicates'$q$, '42501');
SELECT pg_temp.reject($q$UPDATE public.events SET dns_record_count=1 WHERE domain='sealed.test' AND event_id='empty'$q$, '42501');
SELECT pg_temp.reject($q$DELETE FROM public.events WHERE domain='sealed.test'$q$, '42501');
RESET ROLE;
-- Independently prove count guard remains effective even for trusted owner UPDATE.
SELECT pg_temp.reject($q$UPDATE public.events SET dns_record_count=3 WHERE domain='sealed.test' AND event_id='duplicates'$q$, '23514');
SELECT pg_temp.reject($q$UPDATE public.events SET dns_record_count=1 WHERE domain='sealed.test' AND event_id='empty'$q$, '23514');
SELECT pg_temp.assert_true((SELECT count(*)=2 FROM public.dns_records WHERE domain='sealed.test'), 'failed mutations preserve committed records');
SELECT pg_temp.assert_true((SELECT array_agg(dns_record_count ORDER BY sequence)=ARRAY[2,0]::BIGINT[]
    FROM public.events WHERE domain='sealed.test'), 'failed mutations preserve declared counts');
SET CONSTRAINTS ALL IMMEDIATE;
COMMIT;
-- No memberships granted. Remove only this fixture role's grants, then role.
-- Do not delete committed evidence or reset schema; dispose of entire test DB.
DROP OWNED BY :"runtime_role" RESTRICT;
DROP ROLE :"runtime_role";
\echo '06 committed envelope sealing passed'
