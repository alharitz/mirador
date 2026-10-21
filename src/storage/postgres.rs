use crate::core::dns::{DnsObservation, DnsProbeOutcome, DnsRecord, ProbeResult};
use crate::core::domain_status::canonical_hostname;
use crate::core::domain_status::DomainStatus;
use crate::core::engine::{classify_dns, eligible, Candidate, CtEvidence, SourceEvent};
use postgres::{Client, Error as PgError};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StorageError {
    InvalidHostname(String),
    InvalidEventIdentity,
    ConflictingReplay(SourceEvent),
    ConflictingSequence(String),
    ConflictingNamespace(String),
    InvalidDnsObservation,
    Database,
    /// Commit acknowledgement was lost; outcome may be committed or rolled back.
    /// Reconnect and retry the SAME (domain, namespace, event_id) and exact payload,
    /// never a new identity: exact replay safely resolves an already committed event.
    AmbiguousCommit,
}

pub struct PostgresStore {
    client: Client,
}

impl PostgresStore {
    pub fn new(client: Client) -> Self {
        Self { client }
    }

    pub fn observe_dns_event(
        &mut self,
        domain: &str,
        namespace: &str,
        event_id: &str,
        sequence: u64,
        result: ProbeResult,
        observed_at: &str,
    ) -> Result<(), StorageError> {
        let domain = canonical_hostname(domain).map_err(StorageError::InvalidHostname)?;
        if namespace.is_empty() || event_id.is_empty() {
            return Err(StorageError::InvalidEventIdentity);
        }
        let event = SourceEvent {
            domain: domain.clone(),
            namespace: namespace.to_owned(),
            event_id: event_id.to_owned(),
        };
        let mut tx = self.client.transaction().map_err(db)?;
        tx.execute(
            "INSERT INTO public.domains (domain) VALUES ($1) ON CONFLICT (domain) DO NOTHING",
            &[&domain],
        )
        .map_err(db)?;
        tx.execute("SELECT public.lock_domain($1)", &[&domain])
            .map_err(db)?;

        let previous = tx
            .query_opt(
                "SELECT status, ct_observed, trunc(dns_sequence)::text FROM public.candidates WHERE domain=$1",
                &[&domain],
            )
            .map_err(db)?;
        let previous_status = previous
            .as_ref()
            .map(|r| status(r.try_get::<_, Option<String>>(0).map_err(db)?))
            .transpose()?
            .flatten();
        let ct_observed = previous
            .as_ref()
            .map(|r| r.try_get::<_, bool>(1).map_err(db))
            .transpose()?
            .unwrap_or(false);
        let expected_status_at_event =
            if matches!(result, ProbeResult::ServFail | ProbeResult::Timeout) {
                previous_status.as_ref().map(status_text)
            } else {
                None
            };

        if let Some(row) = tx.query_opt(
            "SELECT kind, observed_at, trunc(sequence)::text, outcome, dns_record_count, has_certificate
             FROM public.events WHERE domain=$1 AND namespace=$2 AND event_id=$3",
            &[&domain, &namespace, &event_id],
        ).map_err(db)? {
            // Error status is saved at acceptance, not part of the caller's replay payload.
            let exact = if let Ok((outcome, has_certificate, records)) = dns_payload(&result) {
                let count = records.len() as i64;
                let exact = row.try_get::<_, String>(0).map_err(db)? == "dns"
                    && row.try_get::<_, String>(1).map_err(db)? == observed_at
                    && row.try_get::<_, Option<String>>(2).map_err(db)?.as_deref() == Some(&sequence.to_string())
                    && row.try_get::<_, Option<String>>(3).map_err(db)?.as_deref() == Some(outcome)
                    && row.try_get::<_, i64>(4).map_err(db)? == count
                    && row.try_get::<_, Option<bool>>(5).map_err(db)? == has_certificate;
                if exact {
                let rows = tx.query(
                    "SELECT ordinal, record_type, host(value_a), value_mx_pref, value_mx_exchange, value_ns
                     FROM public.dns_records WHERE domain=$1 AND namespace=$2 AND event_id=$3 ORDER BY ordinal",
                    &[&domain, &namespace, &event_id],
                ).map_err(db)?;
                if rows.len() != records.len() { false } else {
                    rows.iter().enumerate().try_fold(true, |matches, (ordinal, row)| {
                        if !matches || row.try_get::<_, i32>(0).map_err(db)? as usize != ordinal {
                            return Ok(false);
                        }
                        record_matches(row, &records[ordinal]).map_err(db)
                    })?
                }
                } else {
                    false
                }
            } else {
                false
            };
            tx.rollback().map_err(db)?;
            return if exact { Ok(()) } else { Err(StorageError::ConflictingReplay(event)) };
        }

        let (outcome, has_certificate, records) = dns_payload(&result)?;
        let count = records.len() as i64;
        let status_at_event = expected_status_at_event;

        tx.execute("INSERT INTO public.dns_streams (domain, namespace) VALUES ($1,$2) ON CONFLICT (domain) DO NOTHING", &[&domain, &namespace]).map_err(db)?;
        let stream_namespace: String = tx
            .query_one(
                "SELECT namespace FROM public.dns_streams WHERE domain=$1",
                &[&domain],
            )
            .map_err(db)?
            .get(0);
        if stream_namespace != namespace {
            tx.rollback().map_err(db)?;
            return Err(StorageError::ConflictingNamespace(domain));
        }
        if tx
            .query_opt(
                "SELECT 1 FROM public.events WHERE domain=$1 AND sequence=$2::text::numeric",
                &[&domain, &sequence.to_string()],
            )
            .map_err(db)?
            .is_some()
        {
            tx.rollback().map_err(db)?;
            return Err(StorageError::ConflictingSequence(domain));
        }
        tx.execute("INSERT INTO public.events (domain,namespace,event_id,kind,observed_at,sequence,outcome,dns_record_count,has_certificate,status_at_event) VALUES ($1,$2,$3,'dns',$4,$5::text::numeric,$6,$7,$8,$9)", &[&domain,&namespace,&event_id,&observed_at,&sequence.to_string(),&outcome,&count,&has_certificate,&status_at_event]).map_err(db)?;
        for (ordinal, record) in records.iter().enumerate() {
            insert_record(
                &mut tx,
                &domain,
                namespace,
                event_id,
                ordinal as i32,
                record,
            )
            .map_err(db)?;
        }
        if matches!(result, ProbeResult::ServFail | ProbeResult::Timeout) {
            tx.commit().map_err(commit_error)?;
            return Ok(());
        }
        let observation = match result {
            ProbeResult::Success(value) => value,
            _ => unreachable!(),
        };
        let next = classify_dns(previous_status.clone(), ct_observed, &observation);
        let watermark = previous
            .as_ref()
            .map(|r| r.try_get::<_, Option<String>>(2).map_err(db))
            .transpose()?
            .flatten()
            .map(|v| v.parse::<u64>().map_err(|_| StorageError::Database))
            .transpose()?;
        let stale = watermark.is_some_and(|old| sequence < old);
        if !stale {
            tx.execute("INSERT INTO public.candidates (domain,status,dns_namespace,dns_sequence,ct_observed) VALUES ($1,$2,$3,$4::text::numeric,$5) ON CONFLICT (domain) DO UPDATE SET status=$2,dns_namespace=$3,dns_sequence=$4::text::numeric,ct_observed=public.candidates.ct_observed", &[&domain,&status_text(&next),&namespace,&sequence.to_string(),&ct_observed]).map_err(db)?;
        }
        tx.execute("INSERT INTO public.success_history (domain,namespace,event_id,kind,status,applied) VALUES ($1,$2,$3,'dns',$4,$5)", &[&domain,&namespace,&event_id,&status_text(&next),&(!stale)]).map_err(db)?;
        if !stale && eligible(previous_status.clone(), &next) {
            tx.execute("INSERT INTO public.findings (domain,namespace,event_id,from_status,to_status,observed_at) VALUES ($1,$2,$3,$4,$5,$6)", &[&domain,&namespace,&event_id,&previous_status.as_ref().map(status_text),&status_text(&next),&observed_at]).map_err(db)?;
        }
        tx.commit().map_err(commit_error)
    }

    pub fn record_ct(
        &mut self,
        domain: &str,
        namespace: &str,
        event_id: &str,
        certificate_id: &str,
        observed_at: &str,
    ) -> Result<(), StorageError> {
        let domain = canonical_hostname(domain).map_err(StorageError::InvalidHostname)?;
        if namespace.is_empty() || event_id.is_empty() {
            return Err(StorageError::InvalidEventIdentity);
        }
        let event = SourceEvent {
            domain: domain.clone(),
            namespace: namespace.to_owned(),
            event_id: event_id.to_owned(),
        };
        let mut tx = self.client.transaction().map_err(db)?;
        tx.execute(
            "INSERT INTO public.domains (domain) VALUES ($1) ON CONFLICT (domain) DO NOTHING",
            &[&domain],
        )
        .map_err(db)?;
        tx.execute("SELECT public.lock_domain($1)", &[&domain])
            .map_err(db)?;

        if let Some(row) = tx
            .query_opt(
                "SELECT kind, observed_at, certificate_id, sequence::text, outcome, has_certificate, status_at_event, dns_record_count
                 FROM public.events WHERE domain=$1 AND namespace=$2 AND event_id=$3",
                &[&domain, &namespace, &event_id],
            )
            .map_err(db)?
        {
            let exact = row.try_get::<_, String>(0).map_err(db)? == "ct"
                && row.try_get::<_, String>(1).map_err(db)? == observed_at
                && row.try_get::<_, Option<String>>(2).map_err(db)?.as_deref() == Some(certificate_id)
                && row.try_get::<_, Option<String>>(3).map_err(db)?.is_none()
                && row.try_get::<_, Option<String>>(4).map_err(db)?.is_none()
                && row.try_get::<_, Option<bool>>(5).map_err(db)?.is_none()
                && row.try_get::<_, Option<String>>(6).map_err(db)?.is_none()
                && row.try_get::<_, i64>(7).map_err(db)? == 0;
            if exact {
                tx.rollback().map_err(db)?;
                return Ok(());
            }
            tx.rollback().map_err(db)?;
            return Err(StorageError::ConflictingReplay(event));
        }

        tx.execute(
            "INSERT INTO public.events
             (domain, namespace, event_id, kind, observed_at, certificate_id)
             VALUES ($1,$2,$3,'ct',$4,$5)",
            &[
                &domain,
                &namespace,
                &event_id,
                &observed_at,
                &certificate_id,
            ],
        )
        .map_err(db)?;
        let previous = tx
            .query_opt(
                "SELECT status FROM public.candidates WHERE domain=$1",
                &[&domain],
            )
            .map_err(db)?
            .map(|r| status(r.try_get::<_, Option<String>>(0).map_err(db)?))
            .transpose()?
            .flatten();
        tx.execute(
            "INSERT INTO public.candidates (domain, status, ct_observed)
             VALUES ($1, 'Certified', TRUE)
             ON CONFLICT (domain) DO UPDATE SET status='Certified', ct_observed=TRUE",
            &[&domain],
        )
        .map_err(db)?;
        tx.execute(
            "INSERT INTO public.success_history (domain, namespace, event_id, kind, status, applied)
             VALUES ($1,$2,$3,'ct','Certified',TRUE)",
            &[&domain, &namespace, &event_id],
        )
        .map_err(db)?;
        if eligible(previous.clone(), &DomainStatus::Certified) {
            tx.execute(
                "INSERT INTO public.findings
                 (domain, namespace, event_id, from_status, to_status, observed_at)
                 VALUES ($1,$2,$3,$4,'Certified',$5)",
                &[
                    &domain,
                    &namespace,
                    &event_id,
                    &previous.as_ref().map(status_text),
                    &observed_at,
                ],
            )
            .map_err(db)?;
        }
        tx.commit().map_err(commit_error)
    }

    pub fn candidate(&mut self, domain: &str) -> Result<Option<Candidate>, StorageError> {
        let domain = canonical_hostname(domain).map_err(StorageError::InvalidHostname)?;
        let row = self
            .client
            .query_opt(
                "SELECT status, trunc(dns_sequence)::text, ct_observed,
                 ARRAY(SELECT brand FROM public.brands WHERE domain=$1 ORDER BY brand COLLATE \"C\")
                 FROM public.candidates WHERE domain=$1",
                &[&domain],
            )
            .map_err(db)?;
        let Some(row) = row else { return Ok(None) };
        Ok(Some(Candidate {
            domain,
            status: status(row.try_get::<_, Option<String>>(0).map_err(db)?)?,
            brand_associations: row
                .try_get::<_, Vec<String>>(3)
                .map_err(db)?
                .into_iter()
                .collect(),
            dns_sequence: row
                .try_get::<_, Option<String>>(1)
                .map_err(db)?
                .map(|v| v.parse::<u64>().map_err(|_| StorageError::Database))
                .transpose()?,
            ct_observed: row.try_get(2).map_err(db)?,
        }))
    }

    pub fn ct_evidence(&mut self, domain: &str) -> Result<Vec<CtEvidence>, StorageError> {
        let domain = canonical_hostname(domain).map_err(StorageError::InvalidHostname)?;
        self.client.query(
            "SELECT e.namespace, e.event_id, e.certificate_id, e.observed_at FROM public.events e
             JOIN public.success_history h USING (domain, namespace, event_id, kind)
             WHERE e.domain=$1 AND e.kind='ct' ORDER BY h.acceptance_order",
            &[&domain],
        ).map_err(db)?.into_iter().map(|r| Ok(CtEvidence {
            event: SourceEvent { domain: domain.clone(), namespace: r.try_get(0).map_err(db)?, event_id: r.try_get(1).map_err(db)? },
            domain: domain.clone(), certificate_id: r.try_get(2).map_err(db)?, observed_at: r.try_get(3).map_err(db)?,
        })).collect::<Result<_, StorageError>>()
    }
}

fn dns_payload(
    result: &ProbeResult,
) -> Result<(&'static str, Option<bool>, Vec<DnsRecord>), StorageError> {
    match result {
        ProbeResult::ServFail => Ok(("servfail", None, Vec::new())),
        ProbeResult::Timeout => Ok(("timeout", None, Vec::new())),
        ProbeResult::Success(DnsObservation {
            probe_outcome: DnsProbeOutcome::NxDomain,
            has_certificate,
        }) => Ok(("nxdomain", Some(*has_certificate), Vec::new())),
        ProbeResult::Success(DnsObservation {
            probe_outcome: DnsProbeOutcome::Answer(records),
            has_certificate,
        }) => Ok(("answer", Some(*has_certificate), records.clone())),
        ProbeResult::Success(DnsObservation {
            probe_outcome: DnsProbeOutcome::ServFail | DnsProbeOutcome::Timeout,
            ..
        }) => Err(StorageError::InvalidDnsObservation),
    }
}

fn insert_record(
    tx: &mut postgres::Transaction<'_>,
    domain: &str,
    namespace: &str,
    event_id: &str,
    ordinal: i32,
    record: &DnsRecord,
) -> Result<u64, PgError> {
    match record {
        DnsRecord::A(value) => tx.execute("INSERT INTO public.dns_records (domain,namespace,event_id,ordinal,record_type,value_a) VALUES ($1,$2,$3,$4,'A',$5::text::inet)", &[&domain,&namespace,&event_id,&ordinal,&value.to_string()]),
        DnsRecord::MX(pref, exchange) => tx.execute("INSERT INTO public.dns_records (domain,namespace,event_id,ordinal,record_type,value_mx_pref,value_mx_exchange) VALUES ($1,$2,$3,$4,'MX',$5,$6)", &[&domain,&namespace,&event_id,&ordinal,&i32::from(*pref),exchange]),
        DnsRecord::NS(value) => tx.execute("INSERT INTO public.dns_records (domain,namespace,event_id,ordinal,record_type,value_ns) VALUES ($1,$2,$3,$4,'NS',$5)", &[&domain,&namespace,&event_id,&ordinal,value]),
    }
}

fn record_matches(row: &postgres::Row, record: &DnsRecord) -> Result<bool, PgError> {
    Ok(match record {
        DnsRecord::A(value) => {
            row.try_get::<_, String>(1)? == "A"
                && row.try_get::<_, Option<String>>(2)?.as_deref()
                    == Some(value.to_string().as_str())
                && row.try_get::<_, Option<i32>>(3)?.is_none()
                && row.try_get::<_, Option<String>>(4)?.is_none()
                && row.try_get::<_, Option<String>>(5)?.is_none()
        }
        DnsRecord::MX(pref, exchange) => {
            row.try_get::<_, String>(1)? == "MX"
                && row.try_get::<_, Option<String>>(2)?.is_none()
                && row.try_get::<_, Option<i32>>(3)? == Some(i32::from(*pref))
                && row.try_get::<_, Option<String>>(4)?.as_deref() == Some(exchange)
                && row.try_get::<_, Option<String>>(5)?.is_none()
        }
        DnsRecord::NS(value) => {
            row.try_get::<_, String>(1)? == "NS"
                && row.try_get::<_, Option<String>>(2)?.is_none()
                && row.try_get::<_, Option<i32>>(3)?.is_none()
                && row.try_get::<_, Option<String>>(4)?.is_none()
                && row.try_get::<_, Option<String>>(5)?.as_deref() == Some(value)
        }
    })
}

fn status(value: Option<String>) -> Result<Option<DomainStatus>, StorageError> {
    value
        .map(|v| {
            Ok(match v.as_str() {
                "Unregistered" => DomainStatus::Unregistered,
                "RegisteredParked" => DomainStatus::RegisteredParked,
                "MailReady" => DomainStatus::MailReady,
                "Certified" => DomainStatus::Certified,
                _ => return Err(StorageError::Database),
            })
        })
        .transpose()
}

fn status_text(value: &DomainStatus) -> &'static str {
    match value {
        DomainStatus::Unregistered => "Unregistered",
        DomainStatus::RegisteredParked => "RegisteredParked",
        DomainStatus::MailReady => "MailReady",
        DomainStatus::Certified => "Certified",
    }
}

fn db(_: PgError) -> StorageError {
    StorageError::Database
}

fn commit_error(error: PgError) -> StorageError {
    if error.as_db_error().is_some() {
        StorageError::Database
    } else {
        StorageError::AmbiguousCommit
    }
}
