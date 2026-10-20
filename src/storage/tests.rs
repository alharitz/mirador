use super::{PostgresStore, StorageError};
use crate::core::domain_status::DomainStatus;
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
