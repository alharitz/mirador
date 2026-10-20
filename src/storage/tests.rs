use super::{PostgresStore, StorageError};
use crate::core::domain_status::DomainStatus;
use postgres::{Client, NoTls};

// Only disposable local PostgreSQL: schema 002 and runtime grants must already exist.
fn connect(variable: &str) -> Client {
    Client::connect(
        &std::env::var(variable).expect("disposable test database required"),
        NoTls,
    )
    .unwrap()
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
