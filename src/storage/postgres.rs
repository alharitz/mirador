use crate::core::domain_status::canonical_hostname;
use crate::core::domain_status::DomainStatus;
use crate::core::engine::{eligible, Candidate, CtEvidence, SourceEvent};
use postgres::{Client, Error as PgError};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StorageError {
    InvalidHostname(String),
    InvalidEventIdentity,
    ConflictingReplay(SourceEvent),
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
        tx.commit().map_err(|error| {
            if error.as_db_error().is_some() {
                StorageError::Database
            } else {
                StorageError::AmbiguousCommit
            }
        })
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
