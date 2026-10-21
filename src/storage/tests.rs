use super::{PostgresStore, StorageError};
use crate::core::dns::{DnsObservation, DnsProbeOutcome, DnsRecord, ProbeResult};
use crate::core::domain_status::DomainStatus;

fn dns(outcome: DnsProbeOutcome) -> ProbeResult {
    ProbeResult::Success(DnsObservation {
        probe_outcome: outcome,
        has_certificate: true,
    })
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn dns_ordered_raw_records_max_sequence_and_replay() {
    let domain = "dns-raw.test";
    let mut s = store();
    let mut db = connect("MIRADOR_TEST_ADMIN_URL");
    let records = vec![
        DnsRecord::A("192.0.2.1".parse().unwrap()),
        DnsRecord::MX(u16::MAX, "Mx.Raw.".into()),
        DnsRecord::NS("".into()),
        DnsRecord::NS("".into()),
    ];
    let payload = dns(DnsProbeOutcome::Answer(records.clone()));
    s.observe_dns_event(domain, "dns", "one", u64::MAX, payload.clone(), "opaque")
        .unwrap();
    let candidate = s.candidate(domain).unwrap().unwrap();
    assert_eq!(candidate.dns_sequence, Some(u64::MAX));
    assert_eq!(candidate.status, Some(DomainStatus::MailReady));
    assert!(!candidate.ct_observed);
    assert_eq!(counts(&mut db, domain), [1, 1, 1, 1, 0]);
    let rows = db.query("SELECT ordinal, host(value_a), value_mx_pref, value_mx_exchange, value_ns FROM dns_records WHERE domain=$1 ORDER BY ordinal", &[&domain]).unwrap();
    assert_eq!(rows.len(), 4);
    for (i, row) in rows.iter().enumerate() {
        assert_eq!(row.get::<_, i32>(0), i as i32);
    }
    assert_eq!(rows[0].get::<_, String>(1), "192.0.2.1");
    assert_eq!(rows[1].get::<_, i32>(2), 65535);
    assert_eq!(rows[1].get::<_, String>(3), "Mx.Raw.");
    assert_eq!(rows[2].get::<_, String>(4), "");
    assert_eq!(rows[3].get::<_, String>(4), "");
    // Integral NUMERIC values may retain scale when written by another adapter.
    db.execute(
        "UPDATE events SET sequence=sequence*1.000 WHERE domain=$1",
        &[&domain],
    )
    .unwrap();
    db.execute(
        "UPDATE candidates SET dns_sequence=dns_sequence*1.000 WHERE domain=$1",
        &[&domain],
    )
    .unwrap();
    drop(s);
    let mut s = store();
    assert_eq!(s.candidate(domain).unwrap(), Some(candidate));
    s.observe_dns_event(domain, "dns", "one", u64::MAX, payload.clone(), "opaque")
        .unwrap();
    let mut reordered = records.clone();
    reordered.swap(0, 1);
    let mut changed_raw = records.clone();
    changed_raw[1] = DnsRecord::MX(u16::MAX, "mx.raw.".into());
    for replacement in [
        dns(DnsProbeOutcome::Answer(reordered)),
        dns(DnsProbeOutcome::Answer(changed_raw)),
        dns(DnsProbeOutcome::Answer(records[..3].to_vec())),
        dns(DnsProbeOutcome::ServFail),
        dns(DnsProbeOutcome::Timeout),
        ProbeResult::Success(DnsObservation {
            probe_outcome: DnsProbeOutcome::Answer(records),
            has_certificate: false,
        }),
    ] {
        assert!(matches!(
            s.observe_dns_event(domain, "dns", "one", u64::MAX, replacement, "opaque"),
            Err(StorageError::ConflictingReplay(_))
        ));
    }
    for (sequence, time) in [(u64::MAX - 1, "opaque"), (u64::MAX, "changed")] {
        assert!(matches!(
            s.observe_dns_event(domain, "dns", "one", sequence, payload.clone(), time),
            Err(StorageError::ConflictingReplay(_))
        ));
    }
    assert_eq!(
        s.observe_dns_event(domain, "dns", "other", u64::MAX, payload.clone(), "opaque"),
        Err(StorageError::ConflictingSequence(domain.into()))
    );
    assert_eq!(
        s.observe_dns_event(domain, "other", "other", 0, payload, "opaque"),
        Err(StorageError::ConflictingNamespace(domain.into()))
    );
    assert_eq!(counts(&mut db, domain), [1, 1, 1, 1, 0]);
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn dns_errors_replay_after_ct_without_state_or_watermark_changes() {
    let domain = "dns-errors.test";
    let mut s = store();
    let mut db = connect("MIRADOR_TEST_ADMIN_URL");
    s.observe_dns_event(domain, "dns", "timeout", u64::MAX, ProbeResult::Timeout, "")
        .unwrap();
    assert_eq!(s.candidate(domain).unwrap(), None);
    assert_eq!(counts(&mut db, domain), [1, 1, 0, 0, 0]);
    s.observe_dns_event(domain, "dns", "ok", 10, dns(DnsProbeOutcome::NxDomain), "")
        .unwrap();
    let before = s.candidate(domain).unwrap();
    s.observe_dns_event(
        domain,
        "dns",
        "servfail",
        11,
        ProbeResult::ServFail,
        "error",
    )
    .unwrap();
    assert_eq!(s.candidate(domain).unwrap(), before);
    assert_eq!(counts(&mut db, domain), [1, 3, 1, 1, 0]);
    s.record_ct(domain, "ct", "ct", "cert", "").unwrap();
    let before = s.candidate(domain).unwrap();
    let totals = counts(&mut db, domain);
    for (id, seq, result, time) in [
        ("timeout", u64::MAX, ProbeResult::Timeout, ""),
        ("servfail", 11, ProbeResult::ServFail, "error"),
    ] {
        s.observe_dns_event(domain, "dns", id, seq, result, time)
            .unwrap();
        assert!(matches!(
            s.observe_dns_event(domain, "dns", id, seq, dns(DnsProbeOutcome::ServFail), time),
            Err(StorageError::ConflictingReplay(_))
        ));
    }
    assert_eq!(s.candidate(domain).unwrap(), before);
    assert_eq!(counts(&mut db, domain), totals);
    let rows = db.query("SELECT status_at_event FROM events WHERE domain=$1 AND outcome IN ('timeout','servfail') ORDER BY sequence", &[&domain]).unwrap();
    assert_eq!(
        rows[0].get::<_, Option<String>>(0),
        Some("Unregistered".into())
    );
    assert_eq!(rows[1].get::<_, Option<String>>(0), None);
    assert_eq!(
        s.observe_dns_event(domain, "dns", "reserved", 11, ProbeResult::Timeout, ""),
        Err(StorageError::ConflictingSequence(domain.into()))
    );
    assert!(matches!(
        s.observe_dns_event(domain, "ct", "ct", 0, ProbeResult::Timeout, ""),
        Err(StorageError::ConflictingReplay(_))
    ));
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn dns_transitions_stale_history_and_ct_override() {
    let domain = "dns-state.test";
    let mut s = store();
    let mut db = connect("MIRADOR_TEST_ADMIN_URL");
    for (id, seq, outcome) in [
        ("base", 1, DnsProbeOutcome::NxDomain),
        ("park", 2, DnsProbeOutcome::Answer(vec![])),
        (
            "mail",
            10,
            DnsProbeOutcome::Answer(vec![DnsRecord::MX(0, "".into())]),
        ),
        ("down", 11, DnsProbeOutcome::Answer(vec![])),
    ] {
        s.observe_dns_event(domain, "dns", id, seq, dns(outcome), id)
            .unwrap();
    }
    assert_eq!(counts(&mut db, domain), [1, 4, 1, 4, 2]);
    db.execute("INSERT INTO brands VALUES ($1,'Brand')", &[&domain])
        .unwrap();
    let before = s.candidate(domain).unwrap();
    s.observe_dns_event(
        domain,
        "dns",
        "stale",
        3,
        dns(DnsProbeOutcome::NxDomain),
        "stale",
    )
    .unwrap();
    assert_eq!(s.candidate(domain).unwrap(), before);
    assert_eq!(counts(&mut db, domain), [1, 5, 1, 5, 2]);
    s.record_ct(domain, "ct", "cert", "cert", "").unwrap();
    let before = s.candidate(domain).unwrap();
    s.observe_dns_event(
        domain,
        "dns",
        "stale-ct",
        4,
        dns(DnsProbeOutcome::NxDomain),
        "",
    )
    .unwrap();
    assert_eq!(s.candidate(domain).unwrap(), before);
    s.observe_dns_event(
        domain,
        "dns",
        "new-ct",
        12,
        dns(DnsProbeOutcome::NxDomain),
        "",
    )
    .unwrap();
    let candidate = s.candidate(domain).unwrap().unwrap();
    assert_eq!(candidate.status, Some(DomainStatus::Certified));
    assert_eq!(candidate.dns_sequence, Some(12));
    assert_eq!(
        candidate.brand_associations,
        before.unwrap().brand_associations
    );
    s.observe_dns_event(
        domain,
        "dns",
        "park",
        2,
        dns(DnsProbeOutcome::Answer(vec![])),
        "park",
    )
    .unwrap();
    let rows = db
        .query(
            "SELECT status, applied FROM success_history WHERE domain=$1 ORDER BY acceptance_order",
            &[&domain],
        )
        .unwrap();
    assert_eq!(
        rows.iter()
            .map(|r| (r.get::<_, String>(0), r.get::<_, bool>(1)))
            .collect::<Vec<_>>(),
        vec![
            ("Unregistered".into(), true),
            ("RegisteredParked".into(), true),
            ("MailReady".into(), true),
            ("RegisteredParked".into(), true),
            ("Unregistered".into(), false),
            ("Certified".into(), true),
            ("Certified".into(), false),
            ("Certified".into(), true)
        ]
    );
    assert_eq!(counts(&mut db, domain), [1, 8, 1, 8, 3]);
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn dns_invalid_and_failed_transactions_leave_no_reservations() {
    let domain = "dns-rollback.test";
    let mut s = store();
    let mut db = connect("MIRADOR_TEST_ADMIN_URL");
    for outcome in [DnsProbeOutcome::ServFail, DnsProbeOutcome::Timeout] {
        assert_eq!(
            s.observe_dns_event(domain, "dns", "one", 1, dns(outcome), ""),
            Err(StorageError::InvalidDnsObservation)
        );
    }
    assert_eq!(
        s.observe_dns_event(domain, "", "one", 1, ProbeResult::Timeout, ""),
        Err(StorageError::InvalidEventIdentity)
    );
    assert_eq!(
        s.observe_dns_event(domain, "dns", "", 1, ProbeResult::Timeout, ""),
        Err(StorageError::InvalidEventIdentity)
    );
    assert!(matches!(
        s.observe_dns_event("INVALID.test", "dns", "one", 1, ProbeResult::Timeout, ""),
        Err(StorageError::InvalidHostname(_))
    ));
    assert_eq!(counts(&mut db, domain), [0, 0, 0, 0, 0]);
    for deferred in [false, true] {
        db.batch_execute("CREATE FUNCTION public.fail_dns_test() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.domain='dns-rollback.test' THEN RAISE EXCEPTION 'forced failure'; END IF; RETURN NEW; END $$;").unwrap();
        let trigger = if deferred {
            "CREATE CONSTRAINT TRIGGER fail_dns_test AFTER INSERT ON success_history DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.fail_dns_test()"
        } else {
            "CREATE TRIGGER fail_dns_test BEFORE INSERT ON success_history FOR EACH ROW EXECUTE FUNCTION public.fail_dns_test()"
        };
        db.batch_execute(trigger).unwrap();
        let result = s.observe_dns_event(
            domain,
            "dns",
            "one",
            1,
            dns(DnsProbeOutcome::Answer(vec![DnsRecord::NS("Raw.".into())])),
            "",
        );
        db.batch_execute(
            "DROP TRIGGER fail_dns_test ON success_history; DROP FUNCTION public.fail_dns_test()",
        )
        .unwrap();
        assert_eq!(result, Err(StorageError::Database));
        assert_eq!(counts(&mut db, domain), [0, 0, 0, 0, 0]);
        for table in ["dns_records", "dns_streams"] {
            assert_eq!(
                db.query_one(
                    &format!("SELECT count(*) FROM {table} WHERE domain=$1"),
                    &[&domain]
                )
                .unwrap()
                .get::<_, i64>(0),
                0
            );
        }
    }
    s.observe_dns_event(
        domain,
        "new-stream",
        "one",
        1,
        dns(DnsProbeOutcome::Answer(vec![])),
        "",
    )
    .unwrap();
    assert_eq!(counts(&mut db, domain), [1, 1, 1, 1, 0]);
}
use postgres::{Client, NoTls};

// Only disposable local PostgreSQL: schema 002 and runtime grants must already exist.
fn connect(variable: &str) -> Client {
    let mut client = Client::connect(
        &std::env::var(variable).expect("disposable test database required"),
        NoTls,
    )
    .unwrap();
    client
        .batch_execute("SET lock_timeout = '2s'; SET statement_timeout = '5s';")
        .unwrap();
    if variable == "MIRADOR_TEST_DATABASE_URL" {
        let row = client
            .query_one(
                "SELECT r.rolsuper, r.rolbypassrls,
             EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                     WHERE n.nspname='public' AND pg_has_role(current_user,c.relowner,'USAGE')),
             has_schema_privilege(current_user,'public','CREATE')
             FROM pg_roles r WHERE r.rolname=current_user",
                &[],
            )
            .unwrap();
        for index in 0..4 {
            assert!(
                !row.get::<_, bool>(index),
                "runtime must be unprivileged nonowner"
            );
        }
    }
    client
}

fn store() -> PostgresStore {
    PostgresStore::new(connect("MIRADOR_TEST_DATABASE_URL"))
}

fn counts(client: &mut Client, domain: &str) -> Vec<i64> {
    [
        "domains",
        "events",
        "candidates",
        "success_history",
        "findings",
    ]
    .iter()
    .map(|table| {
        client
            .query_one(
                &format!("SELECT count(*) FROM public.{table} WHERE domain=$1"),
                &[&domain],
            )
            .unwrap()
            .get(0)
    })
    .collect()
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn ct_atomic_replay_conflict_and_reconnect() {
    let domain = "ct-atomic.test";
    let mut db = connect("MIRADOR_TEST_ADMIN_URL");
    let mut s = store();
    s.record_ct(domain, "ct", "one", "", "").unwrap();
    assert_eq!(counts(&mut db, domain), [1, 1, 1, 1, 1]);
    let row = db
        .query_one(
            "SELECT from_status, to_status, observed_at FROM findings WHERE domain=$1",
            &[&domain],
        )
        .unwrap();
    assert_eq!(row.get::<_, Option<String>>(0), None);
    assert_eq!(row.get::<_, String>(1), "Certified");
    assert_eq!(row.get::<_, String>(2), "");
    let before = s.ct_evidence(domain).unwrap();
    s.record_ct(domain, "ct", "one", "", "").unwrap();
    for (certificate, timestamp) in [("changed", ""), ("", "changed")] {
        assert!(matches!(
            s.record_ct(domain, "ct", "one", certificate, timestamp),
            Err(StorageError::ConflictingReplay(_))
        ));
    }
    assert_eq!(counts(&mut db, domain), [1, 1, 1, 1, 1]);
    assert_eq!(s.ct_evidence(domain).unwrap(), before);
    s.record_ct(domain, "ct", "two", "", "").unwrap();
    assert_eq!(counts(&mut db, domain), [1, 2, 1, 2, 1]);
    let expected = s.candidate(domain).unwrap().unwrap();
    assert_eq!(expected.status, Some(DomainStatus::Certified));
    assert!(expected.ct_observed);
    drop(s);
    let mut reopened = store();
    assert_eq!(reopened.candidate(domain).unwrap(), Some(expected));
    assert_eq!(reopened.ct_evidence(domain).unwrap().len(), 2);
    reopened.record_ct(domain, "ct", "two", "", "").unwrap();
    assert_eq!(counts(&mut db, domain), [1, 2, 1, 2, 1]);
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn ct_preserves_dns_watermark_brands_and_cross_kind_identity() {
    let domain = "ct-dns.test";
    let mut db = connect("MIRADOR_TEST_ADMIN_URL");
    db.batch_execute("BEGIN;
        INSERT INTO domains VALUES ('ct-dns.test');
        INSERT INTO dns_streams VALUES ('ct-dns.test','dns');
        INSERT INTO candidates (domain,status,dns_namespace,dns_sequence) VALUES ('ct-dns.test','MailReady','dns',18446744073709551615.000);
        INSERT INTO brands VALUES ('ct-dns.test',''), ('ct-dns.test','Brand');
        INSERT INTO events (domain,namespace,event_id,kind,observed_at,sequence,outcome,has_certificate)
          VALUES ('ct-dns.test','dns','same','dns','opaque',18446744073709551615,'answer',false);
        INSERT INTO success_history (domain,namespace,event_id,kind,status,applied)
          VALUES ('ct-dns.test','dns','same','dns','MailReady',true);
        COMMIT;").unwrap();
    let mut s = store();
    let before = s.candidate(domain).unwrap().unwrap();
    assert_eq!(before.dns_sequence, Some(u64::MAX));
    assert!(matches!(
        s.record_ct(domain, "dns", "same", "cert", "opaque"),
        Err(StorageError::ConflictingReplay(_))
    ));
    assert_eq!(s.candidate(domain).unwrap(), Some(before.clone()));
    assert_eq!(counts(&mut db, domain), [1, 1, 1, 1, 0]);
    s.record_ct(domain, "ct", "new", "cert", "opaque").unwrap();
    let after = s.candidate(domain).unwrap().unwrap();
    assert_eq!(after.dns_sequence, before.dns_sequence);
    assert_eq!(
        before
            .brand_associations
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        ["", "Brand"]
    );
    assert_eq!(after.brand_associations, before.brand_associations);
    assert_eq!(after.status, Some(DomainStatus::Certified));
    assert!(after.ct_observed);
    let row = db
        .query_one(
            "SELECT dns_namespace, dns_sequence::text FROM candidates WHERE domain=$1",
            &[&domain],
        )
        .unwrap();
    assert_eq!(row.get::<_, String>(0), "dns");
    assert_eq!(row.get::<_, String>(1), "18446744073709551615.000");
    let row = db
        .query_one(
            "SELECT from_status FROM findings WHERE domain=$1",
            &[&domain],
        )
        .unwrap();
    assert_eq!(row.get::<_, String>(0), "MailReady");
    assert_eq!(counts(&mut db, domain), [1, 2, 1, 2, 1]);
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn ct_forced_failure_rolls_back_all_writes() {
    let domain = "ct-rollback.test";
    let mut db = connect("MIRADOR_TEST_ADMIN_URL");
    db.batch_execute("CREATE FUNCTION public.fail_test_finding() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN IF NEW.domain = 'ct-rollback.test' THEN RAISE EXCEPTION 'forced rollback'; END IF; RETURN NEW; END $$;
        CREATE TRIGGER fail_test_finding BEFORE INSERT ON public.findings FOR EACH ROW EXECUTE FUNCTION public.fail_test_finding();").unwrap();
    let mut s = store();
    let result = s.record_ct(domain, "ct", "one", "cert", "time");
    db.batch_execute(
        "DROP TRIGGER fail_test_finding ON findings; DROP FUNCTION public.fail_test_finding();",
    )
    .unwrap();
    assert_eq!(result, Err(StorageError::Database));
    assert_eq!(counts(&mut db, domain), [0, 0, 0, 0, 0]);
    assert_eq!(s.candidate(domain).unwrap(), None);
    assert!(s.ct_evidence(domain).unwrap().is_empty());
    s.record_ct(domain, "ct", "one", "cert", "time").unwrap();
    assert_eq!(counts(&mut db, domain), [1, 1, 1, 1, 1]);
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn ct_invalid_input_has_no_writes() {
    let mut s = store();
    assert!(matches!(
        s.record_ct("INVALID.test", "ct", "id", "", ""),
        Err(StorageError::InvalidHostname(_))
    ));
    assert_eq!(
        s.record_ct("ct-invalid.test", "", "id", "", ""),
        Err(StorageError::InvalidEventIdentity)
    );
    assert_eq!(
        s.record_ct("ct-invalid.test", "ct", "", "", ""),
        Err(StorageError::InvalidEventIdentity)
    );
    assert_eq!(
        counts(&mut connect("MIRADOR_TEST_ADMIN_URL"), "ct-invalid.test"),
        [0, 0, 0, 0, 0]
    );
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn ct_evidence_uses_acceptance_order_across_reconnect() {
    let mut s = store();
    // Reverse lexical IDs, namespaces and source times must not determine order.
    for (domain, namespace, id, time) in [
        ("ct-order.test", "z", "z", "z-time"),
        ("ct-order-other.test", "z", "z", "other-time"),
        ("ct-order.test", "z", "a", "a-time"),
        ("ct-order.test", "a", "z", "0-time"),
    ] {
        s.record_ct(domain, namespace, id, "same-cert", time)
            .unwrap();
    }
    let expected = s.ct_evidence("ct-order.test").unwrap();
    assert_eq!(
        expected
            .iter()
            .map(|e| (
                e.event.namespace.as_str(),
                e.event.event_id.as_str(),
                e.observed_at.as_str()
            ))
            .collect::<Vec<_>>(),
        [
            ("z", "z", "z-time"),
            ("z", "a", "a-time"),
            ("a", "z", "0-time")
        ]
    );
    drop(s);
    assert_eq!(store().ct_evidence("ct-order.test").unwrap(), expected);
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn runtime_cannot_update_or_delete_immutable_tables() {
    let mut client = connect("MIRADOR_TEST_DATABASE_URL");
    for table in [
        "domains",
        "dns_streams",
        "brands",
        "events",
        "dns_records",
        "success_history",
        "findings",
    ] {
        for statement in [
            format!("UPDATE public.{table} SET domain=domain WHERE false"),
            format!("DELETE FROM public.{table} WHERE false"),
        ] {
            let error = client.execute(&statement, &[]).unwrap_err();
            assert_eq!(
                error.code(),
                Some(&postgres::error::SqlState::INSUFFICIENT_PRIVILEGE),
                "{statement}"
            );
        }
    }
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn ct_two_clients_serialize_exact_and_conflicting_replays() {
    for (domain, certificates) in [
        ("ct-concurrent-exact.test", ["same", "same"]),
        ("ct-concurrent-conflict.test", ["first", "second"]),
    ] {
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let handles = certificates.map(|certificate| {
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                let mut s = store();
                barrier.wait();
                s.record_ct(domain, "ct", "same-id", certificate, "time")
            })
        });
        let results = handles.map(|handle| handle.join().unwrap());
        if certificates[0] == certificates[1] {
            assert_eq!(results, [Ok(()), Ok(())]);
        } else {
            assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
            assert_eq!(
                results
                    .iter()
                    .filter(|r| matches!(r, Err(StorageError::ConflictingReplay(_))))
                    .count(),
                1
            );
        }
        assert_eq!(
            counts(&mut connect("MIRADOR_TEST_ADMIN_URL"), domain),
            [1, 1, 1, 1, 1]
        );
    }
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn ct_server_commit_rejection_is_not_ambiguous() {
    let mut db = connect("MIRADOR_TEST_ADMIN_URL");
    db.batch_execute("CREATE FUNCTION public.fail_test_commit() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN IF NEW.domain = 'ct-commit-rejected.test' THEN RAISE EXCEPTION 'forced commit rejection'; END IF; RETURN NEW; END $$;
        CREATE CONSTRAINT TRIGGER fail_test_commit AFTER INSERT ON public.findings DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION public.fail_test_commit();").unwrap();
    let result = store().record_ct("ct-commit-rejected.test", "ct", "one", "cert", "time");
    db.batch_execute("DROP TRIGGER fail_test_commit ON public.findings; DROP FUNCTION public.fail_test_commit();").unwrap();
    assert_eq!(result, Err(StorageError::Database));
    assert_eq!(counts(&mut db, "ct-commit-rejected.test"), [0, 0, 0, 0, 0]);
}

#[test]
#[ignore = "requires disposable PostgreSQL 16 with standalone schema 002 and runtime grants"]
fn candidate_reads_state_and_brands_from_one_snapshot() {
    let domain = "ct-snapshot.test";
    let mut s = store();
    s.record_ct(domain, "ct", "one", "cert", "time").unwrap();
    let mut db = connect("MIRADOR_TEST_ADMIN_URL");
    db.execute("INSERT INTO brands VALUES ($1, 'Certified')", &[&domain])
        .unwrap();
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
    let writer_barrier = barrier.clone();
    let writer = std::thread::spawn(move || {
        writer_barrier.wait();
        for index in 0..100 {
            let state = if index % 2 == 0 {
                "MailReady"
            } else {
                "Certified"
            };
            let mut tx = db.transaction().unwrap();
            tx.execute(
                "UPDATE candidates SET status=$2 WHERE domain=$1",
                &[&domain, &state],
            )
            .unwrap();
            tx.execute("DELETE FROM brands WHERE domain=$1", &[&domain])
                .unwrap();
            tx.execute("INSERT INTO brands VALUES ($1,$2)", &[&domain, &state])
                .unwrap();
            tx.commit().unwrap();
        }
    });
    barrier.wait();
    for _ in 0..100 {
        let candidate = s.candidate(domain).unwrap().unwrap();
        let brand = match candidate.status.unwrap() {
            DomainStatus::MailReady => "MailReady",
            DomainStatus::Certified => "Certified",
            status => panic!("unexpected status: {status:?}"),
        };
        assert_eq!(
            candidate.brand_associations,
            [brand.to_owned()].into_iter().collect()
        );
    }
    writer.join().unwrap();
}
