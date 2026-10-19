use crate::core::dns::{DnsObservation, DnsProbeOutcome, ProbeResult};
use crate::core::domain_status::{canonical_hostname, DomainStatus};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct SourceEvent {
    pub domain: String,
    pub namespace: String,
    pub event_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub domain: String,
    pub status: Option<DomainStatus>,
    pub brand_associations: BTreeSet<String>,
    pub dns_sequence: Option<u64>,
    pub ct_observed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RawEvidence {
    Dns(DnsObservation),
    Ct(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateHistory {
    pub applied: bool,
    pub domain: String,
    pub status: DomainStatus,
    pub observation_key: SourceEvent,
    pub raw_evidence: RawEvidence,
    pub observed_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CtEvidence {
    pub event: SourceEvent,
    pub domain: String,
    pub certificate_id: String,
    pub observed_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub domain: String,
    pub from: Option<DomainStatus>,
    pub to: DomainStatus,
    pub observation_key: SourceEvent,
    pub observed_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SuccessfulSnapshot {
    pub event: SourceEvent,
    pub sequence: u64,
    pub observation: DnsObservation,
    pub observed_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ErrorRecord {
    pub event: SourceEvent,
    pub sequence: Option<u64>,
    pub result: ProbeResult,
    pub observed_at: String,
    pub status: Option<DomainStatus>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoreError {
    InvalidHostname(String),
    ConflictingReplay(SourceEvent),
    ConflictingSequence(String),
    ConflictingNamespace(String),
    InvalidEventIdentity,
    InvalidDnsObservation,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ReplayEnvelope {
    Dns {
        sequence: u64,
        result: ProbeResult,
        observed_at: String,
    },
    Ct {
        certificate_id: String,
        observed_at: String,
    },
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Store {
    candidates: BTreeMap<String, Candidate>,
    history: Vec<StateHistory>,
    findings: Vec<Finding>,
    ct_evidence: Vec<CtEvidence>,
    successful_snapshots: Vec<SuccessfulSnapshot>,
    errors: Vec<ErrorRecord>,
    seen_events: BTreeMap<SourceEvent, ReplayEnvelope>,
    dns_namespaces: BTreeMap<String, String>,
    dns_sequences: BTreeMap<(String, u64), SourceEvent>,
}

impl Store {
    pub fn associate(&mut self, domain: &str, brand: &str) -> Result<bool, StoreError> {
        let domain = canonical_hostname(domain).map_err(StoreError::InvalidHostname)?;
        let candidate = self.candidate(&domain);
        Ok(candidate.brand_associations.insert(brand.to_owned()))
    }

    pub fn observe_dns_event(
        &mut self,
        domain: &str,
        namespace: &str,
        event_id: &str,
        sequence: u64,
        result: ProbeResult,
        observed_at: &str,
    ) -> Result<(), StoreError> {
        let event = source_event(domain, namespace, event_id)?;
        let envelope = ReplayEnvelope::Dns {
            sequence,
            result: result.clone(),
            observed_at: observed_at.to_owned(),
        };
        if self.is_retry(&event, &envelope)? {
            return Ok(());
        }
        if matches!(
            &result,
            ProbeResult::Success(DnsObservation {
                probe_outcome: DnsProbeOutcome::ServFail | DnsProbeOutcome::Timeout,
                ..
            })
        ) {
            return Err(StoreError::InvalidDnsObservation);
        }
        let domain = event.domain.clone();
        if self
            .dns_namespaces
            .get(&domain)
            .is_some_and(|previous| previous != namespace)
        {
            return Err(StoreError::ConflictingNamespace(domain));
        }
        if self.dns_sequences.contains_key(&(domain.clone(), sequence)) {
            return Err(StoreError::ConflictingSequence(domain));
        }

        self.seen_events.insert(event.clone(), envelope);
        self.dns_namespaces
            .insert(domain.clone(), namespace.to_owned());
        self.dns_sequences
            .insert((domain.clone(), sequence), event.clone());
        let observation = match result {
            ProbeResult::Success(observation) => observation,
            failure => {
                let status = self.candidates.get(&domain).and_then(|c| c.status.clone());
                self.errors.push(ErrorRecord {
                    event,
                    sequence: Some(sequence),
                    result: failure,
                    observed_at: observed_at.to_owned(),
                    status,
                });
                return Ok(());
            }
        };
        let stale = self
            .candidates
            .get(&domain)
            .and_then(|candidate| candidate.dns_sequence)
            .is_some_and(|old| sequence < old);
        self.successful_snapshots.push(SuccessfulSnapshot {
            event: event.clone(),
            sequence,
            observation: observation.clone(),
            observed_at: observed_at.to_owned(),
        });
        let candidate = self.candidate(&domain);
        let next = classify_dns(
            candidate.status.clone(),
            candidate.ct_observed,
            &observation,
        );
        if stale {
            self.history.push(StateHistory {
                applied: false,
                domain,
                status: next,
                observation_key: event,
                raw_evidence: RawEvidence::Dns(observation),
                observed_at: observed_at.to_owned(),
            });
            return Ok(());
        }
        candidate.dns_sequence = Some(sequence);
        self.apply_status(
            domain,
            next,
            event,
            RawEvidence::Dns(observation),
            observed_at,
        );
        Ok(())
    }

    pub fn record_ct(
        &mut self,
        domain: &str,
        namespace: &str,
        event_id: &str,
        certificate_id: &str,
        observed_at: &str,
    ) -> Result<(), StoreError> {
        let event = source_event(domain, namespace, event_id)?;
        let envelope = ReplayEnvelope::Ct {
            certificate_id: certificate_id.to_owned(),
            observed_at: observed_at.to_owned(),
        };
        if self.is_retry(&event, &envelope)? {
            return Ok(());
        }
        let domain = event.domain.clone();
        self.seen_events.insert(event.clone(), envelope);
        self.candidate(&domain).ct_observed = true;
        self.ct_evidence.push(CtEvidence {
            event: event.clone(),
            domain: domain.clone(),
            certificate_id: certificate_id.to_owned(),
            observed_at: observed_at.to_owned(),
        });
        self.apply_status(
            domain,
            DomainStatus::Certified,
            event,
            RawEvidence::Ct(certificate_id.to_owned()),
            observed_at,
        );
        Ok(())
    }

    fn is_retry(&self, event: &SourceEvent, envelope: &ReplayEnvelope) -> Result<bool, StoreError> {
        match self.seen_events.get(event) {
            Some(previous) if previous == envelope => Ok(true),
            Some(_) => Err(StoreError::ConflictingReplay(event.clone())),
            None => Ok(false),
        }
    }

    pub fn findings_jsonl(&self) -> Result<String, &'static str> {
        Err("JSONL output is unsupported without a maintained serializer")
    }

    pub fn candidates(&self) -> &BTreeMap<String, Candidate> {
        &self.candidates
    }

    pub fn history(&self) -> &[StateHistory] {
        &self.history
    }

    pub fn findings(&self) -> &[Finding] {
        &self.findings
    }

    pub fn ct_evidence(&self) -> &[CtEvidence] {
        &self.ct_evidence
    }

    pub fn successful_snapshots(&self) -> &[SuccessfulSnapshot] {
        &self.successful_snapshots
    }

    pub fn errors(&self) -> &[ErrorRecord] {
        &self.errors
    }

    fn candidate(&mut self, domain: &str) -> &mut Candidate {
        self.candidates
            .entry(domain.to_owned())
            .or_insert_with(|| Candidate {
                domain: domain.to_owned(),
                status: None,
                brand_associations: BTreeSet::new(),
                dns_sequence: None,
                ct_observed: false,
            })
    }
    fn apply_status(
        &mut self,
        domain: String,
        next: DomainStatus,
        key: SourceEvent,
        raw_evidence: RawEvidence,
        at: &str,
    ) {
        let previous = self
            .candidates
            .get(&domain)
            .and_then(|candidate| candidate.status.clone());
        self.candidates.get_mut(&domain).unwrap().status = Some(next.clone());
        self.history.push(StateHistory {
            applied: true,
            domain: domain.clone(),
            status: next.clone(),
            observation_key: key.clone(),
            raw_evidence,
            observed_at: at.to_owned(),
        });
        if eligible(previous.clone(), &next) {
            self.findings.push(Finding {
                domain,
                from: previous,
                to: next,
                observation_key: key,
                observed_at: at.to_owned(),
            });
        }
    }
}

fn source_event(domain: &str, namespace: &str, event_id: &str) -> Result<SourceEvent, StoreError> {
    let domain = canonical_hostname(domain).map_err(StoreError::InvalidHostname)?;
    if namespace.is_empty() || event_id.is_empty() {
        return Err(StoreError::InvalidEventIdentity);
    }
    Ok(SourceEvent {
        domain,
        namespace: namespace.to_owned(),
        event_id: event_id.to_owned(),
    })
}

/// Classifies DNS evidence; only the independent CT latch can override DNS status.
/// Caller must validate the observation before accepting it as a successful event.
pub(crate) fn classify_dns(
    prior: Option<DomainStatus>,
    ct_observed: bool,
    observation: &DnsObservation,
) -> DomainStatus {
    let next = DomainStatus::classify_observation(
        prior.unwrap_or(DomainStatus::Unregistered),
        false,
        ProbeResult::Success(observation.clone()),
    );
    if ct_observed {
        DomainStatus::Certified
    } else {
        next
    }
}

/// Finding eligibility for applied successful events only; caller excludes errors and stale events.
pub(crate) fn eligible(from: Option<DomainStatus>, to: &DomainStatus) -> bool {
    matches!(
        (from, to),
        (None, DomainStatus::Certified)
            | (
                Some(DomainStatus::Unregistered),
                DomainStatus::RegisteredParked | DomainStatus::MailReady | DomainStatus::Certified
            )
            | (
                Some(DomainStatus::RegisteredParked),
                DomainStatus::MailReady | DomainStatus::Certified
            )
            | (Some(DomainStatus::MailReady), DomainStatus::Certified)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::dns::{DnsProbeOutcome, DnsRecord};

    const DOMAIN: &str = "example.test";

    fn success(outcome: DnsProbeOutcome) -> ProbeResult {
        ProbeResult::Success(DnsObservation {
            probe_outcome: outcome,
            has_certificate: false,
        })
    }

    fn parked() -> ProbeResult {
        success(DnsProbeOutcome::Answer(vec![DnsRecord::NS(
            "ns.example.test".into(),
        )]))
    }

    fn mail() -> ProbeResult {
        success(DnsProbeOutcome::Answer(vec![DnsRecord::MX(
            10,
            "mx.example.test".into(),
        )]))
    }

    fn observe(store: &mut Store, id: &str, sequence: u64, result: ProbeResult) {
        store
            .observe_dns_event(DOMAIN, "dns", id, sequence, result, id)
            .unwrap();
    }

    // Include private replay, sequence, and namespace reservations.
    fn assert_unchanged(before: &Store, after: &Store) {
        assert_eq!(before, after);
    }

    fn accepted_store() -> Store {
        let mut store = Store::default();
        store.associate(DOMAIN, "brand").unwrap();
        observe(
            &mut store,
            "baseline",
            1,
            success(DnsProbeOutcome::NxDomain),
        );
        observe(&mut store, "accepted", 2, parked());
        store
            .record_ct(DOMAIN, "ct", "cert-event", "cert", "ct-time")
            .unwrap();
        observe(&mut store, "error", 3, ProbeResult::Timeout);
        store
    }

    #[test]
    fn eligibility_matrix_all_prior_and_next_statuses() {
        use DomainStatus::*;
        let statuses = [Unregistered, RegisteredParked, MailReady, Certified];
        for (from, expected) in [
            (None, [false, false, false, true]),
            (Some(Unregistered), [false, true, true, true]),
            (Some(RegisteredParked), [false, false, true, true]),
            (Some(MailReady), [false, false, false, true]),
            (Some(Certified), [false, false, false, false]),
        ] {
            for (to, expected) in statuses.iter().zip(expected) {
                assert_eq!(eligible(from.clone(), to), expected, "{from:?} -> {to:?}");
            }
        }
    }

    #[test]
    fn dns_classification_ignores_certificate_payload_and_ct_overrides_even_nxdomain() {
        use DomainStatus::*;
        for prior in [
            None,
            Some(Unregistered),
            Some(RegisteredParked),
            Some(MailReady),
            Some(Certified),
        ] {
            for (outcome, expected) in [
                (DnsProbeOutcome::NxDomain, Unregistered),
                (DnsProbeOutcome::Answer(vec![]), RegisteredParked),
                (
                    DnsProbeOutcome::Answer(vec![DnsRecord::NS("ns.test".into())]),
                    RegisteredParked,
                ),
                (
                    DnsProbeOutcome::Answer(vec![DnsRecord::MX(10, "mx.test".into())]),
                    MailReady,
                ),
            ] {
                for has_certificate in [false, true] {
                    let observation = DnsObservation {
                        probe_outcome: outcome.clone(),
                        has_certificate,
                    };
                    assert_eq!(classify_dns(prior.clone(), false, &observation), expected);
                    assert_eq!(classify_dns(prior.clone(), true, &observation), Certified);
                }
            }
        }
    }

    #[test]
    fn empty_dns_answer_is_silent_parked_baseline_without_ct_latch() {
        let mut store = Store::default();
        let observation = DnsObservation {
            probe_outcome: DnsProbeOutcome::Answer(vec![]),
            has_certificate: true,
        };
        observe(
            &mut store,
            "empty",
            1,
            ProbeResult::Success(observation.clone()),
        );
        assert_eq!(
            store.candidates()[DOMAIN].status,
            Some(DomainStatus::RegisteredParked)
        );
        assert!(!store.candidates()[DOMAIN].ct_observed);
        assert_eq!(
            store.history()[0].raw_evidence,
            RawEvidence::Dns(observation)
        );
        assert!(store.history()[0].applied);
        assert!(store.findings().is_empty());
    }

    #[test]
    fn stale_dns_history_uses_ct_latch_without_mutating_candidate_or_findings() {
        let mut store = accepted_store();
        let candidate = store.candidates()[DOMAIN].clone();
        let findings = store.findings().to_vec();
        observe(&mut store, "stale", 0, success(DnsProbeOutcome::NxDomain));
        assert_eq!(store.candidates()[DOMAIN], candidate);
        assert_eq!(store.findings(), findings);
        let history = store.history().last().unwrap();
        assert_eq!(history.status, DomainStatus::Certified);
        assert!(!history.applied);
        assert_eq!(
            history.raw_evidence,
            RawEvidence::Dns(DnsObservation {
                probe_outcome: DnsProbeOutcome::NxDomain,
                has_certificate: false,
            })
        );
        assert_eq!(store.successful_snapshots().last().unwrap().sequence, 0);
    }

    #[test]
    fn distinct_unchanged_successes_each_append_raw_snapshot_and_history() {
        let mut store = Store::default();
        for (id, sequence) in [("first", 1), ("second", 2)] {
            observe(&mut store, id, sequence, parked());
        }
        assert_eq!(store.history().len(), 2);
        assert_eq!(store.successful_snapshots().len(), 2);
        for (index, id) in ["first", "second"].into_iter().enumerate() {
            let snapshot = &store.successful_snapshots()[index];
            assert_eq!(
                snapshot.event,
                SourceEvent {
                    domain: DOMAIN.into(),
                    namespace: "dns".into(),
                    event_id: id.into(),
                }
            );
            assert_eq!(snapshot.sequence, index as u64 + 1);
            assert_eq!(
                snapshot.observation,
                DnsObservation {
                    probe_outcome: DnsProbeOutcome::Answer(vec![DnsRecord::NS(
                        "ns.example.test".into()
                    )]),
                    has_certificate: false,
                }
            );
            assert_eq!(snapshot.observed_at, id);
            assert_eq!(
                store.history()[index].raw_evidence,
                RawEvidence::Dns(snapshot.observation.clone())
            );
            assert_eq!(
                store.history()[index],
                StateHistory {
                    domain: DOMAIN.into(),
                    status: DomainStatus::RegisteredParked,
                    applied: true,
                    observation_key: source_event(DOMAIN, "dns", id).unwrap(),
                    raw_evidence: RawEvidence::Dns(snapshot.observation.clone()),
                    observed_at: id.into(),
                }
            );
        }
        assert!(store.findings().is_empty());
    }

    #[test]
    fn returning_to_previous_status_keeps_all_history_and_downgrade_is_silent() {
        let mut store = Store::default();
        observe(&mut store, "a", 1, parked());
        observe(&mut store, "b", 2, mail());
        observe(&mut store, "a-again", 3, parked());
        assert_eq!(
            store
                .history()
                .iter()
                .map(|h| h.status.clone())
                .collect::<Vec<_>>(),
            vec![
                DomainStatus::RegisteredParked,
                DomainStatus::MailReady,
                DomainStatus::RegisteredParked
            ]
        );
        assert_eq!(store.successful_snapshots().len(), 3);
        assert_eq!(
            store.candidates()[DOMAIN].status,
            Some(DomainStatus::RegisteredParked)
        );
        assert_eq!(store.findings().len(), 1);
        assert_eq!(
            store.findings()[0].observation_key,
            source_event(DOMAIN, "dns", "b").unwrap()
        );
        observe(&mut store, "gone", 4, success(DnsProbeOutcome::NxDomain));
        assert_eq!(store.findings().len(), 1);
        assert_eq!(store.history().len(), 4);
        assert_eq!(
            store.candidates()[DOMAIN].status,
            Some(DomainStatus::Unregistered)
        );
    }

    #[test]
    fn exact_successful_retry_does_not_mutate_any_collection() {
        let before = accepted_store();
        let mut after = accepted_store();
        after
            .observe_dns_event(DOMAIN, "dns", "accepted", 2, parked(), "accepted")
            .unwrap();
        assert_unchanged(&before, &after);
    }

    #[test]
    fn conflicting_replay_is_checked_before_dns_validation() {
        let before = accepted_store();
        let mut after = accepted_store();
        assert_eq!(
            after.observe_dns_event(
                DOMAIN,
                "dns",
                "accepted",
                2,
                success(DnsProbeOutcome::ServFail),
                "accepted",
            ),
            Err(StoreError::ConflictingReplay(SourceEvent {
                domain: DOMAIN.into(),
                namespace: "dns".into(),
                event_id: "accepted".into(),
            }))
        );
        assert_unchanged(&before, &after);
    }

    #[test]
    fn conflicting_replay_preserves_all_collections() {
        let before = accepted_store();
        let mut after = accepted_store();
        for (sequence, result) in [(2, mail()), (3, parked()), (2, ProbeResult::Timeout)] {
            assert_eq!(
                after.observe_dns_event(DOMAIN, "dns", "accepted", sequence, result, "retry"),
                Err(StoreError::ConflictingReplay(SourceEvent {
                    domain: DOMAIN.into(),
                    namespace: "dns".into(),
                    event_id: "accepted".into(),
                }))
            );
            assert_unchanged(&before, &after);
        }
    }

    #[test]
    fn equal_sequence_conflict_and_its_retry_preserve_accepted_state() {
        let before = accepted_store();
        let mut after = accepted_store();
        for _ in 0..2 {
            assert_eq!(
                after.observe_dns_event(DOMAIN, "dns", "other", 2, mail(), "conflict"),
                Err(StoreError::ConflictingSequence(DOMAIN.into()))
            );
            assert_unchanged(&before, &after);
        }
    }

    #[test]
    fn stale_success_is_retained_without_applying_or_emitting_finding() {
        let mut store = Store::default();
        observe(&mut store, "latest", 10, parked());
        let candidate = store.candidates()[DOMAIN].clone();
        observe(&mut store, "stale", 9, mail());
        assert_eq!(store.candidates()[DOMAIN], candidate);
        assert_eq!(store.successful_snapshots().len(), 2);
        assert_eq!(store.successful_snapshots()[1].sequence, 9);
        assert_eq!(
            store.successful_snapshots()[1].observation,
            DnsObservation {
                probe_outcome: DnsProbeOutcome::Answer(vec![DnsRecord::MX(
                    10,
                    "mx.example.test".into()
                )]),
                has_certificate: false,
            }
        );
        assert_eq!(store.history().len(), 2);
        assert_eq!(store.history()[1].status, DomainStatus::MailReady);
        assert_eq!(
            store.history()[1].observation_key,
            source_event(DOMAIN, "dns", "stale").unwrap()
        );
        assert!(!store.history()[1].applied);
        assert!(store.findings().is_empty());
        observe(&mut store, "stale", 9, mail());
        assert_eq!(store.history().len(), 2);
        assert_eq!(store.successful_snapshots().len(), 2);
    }

    #[test]
    fn errors_before_and_after_success_retain_facts_without_changing_status() {
        let mut store = Store::default();
        store.associate(DOMAIN, "brand").unwrap();
        assert_eq!(store.candidates()[DOMAIN].status, None);
        for (id, sequence, result) in [
            ("timeout", 1, ProbeResult::Timeout),
            ("servfail", 2, ProbeResult::ServFail),
        ] {
            observe(&mut store, id, sequence, result);
        }
        assert_eq!(store.candidates()[DOMAIN].status, None);
        assert_eq!(store.candidates()[DOMAIN].dns_sequence, None);
        assert!(store.history().is_empty());
        assert!(store.successful_snapshots().is_empty());
        observe(&mut store, "success", 3, mail());
        let candidate = store.candidates()[DOMAIN].clone();
        for (id, sequence, result) in [
            ("timeout-after", 4, ProbeResult::Timeout),
            ("servfail-after", 5, ProbeResult::ServFail),
        ] {
            observe(&mut store, id, sequence, result);
        }
        assert_eq!(store.candidates()[DOMAIN], candidate);
        assert_eq!(store.history().len(), 1);
        assert_eq!(store.successful_snapshots().len(), 1);
        assert!(store.findings().is_empty());
        assert_eq!(store.errors().len(), 4);
        for (index, (id, sequence, result)) in [
            ("timeout", 1, ProbeResult::Timeout),
            ("servfail", 2, ProbeResult::ServFail),
            ("timeout-after", 4, ProbeResult::Timeout),
            ("servfail-after", 5, ProbeResult::ServFail),
        ]
        .into_iter()
        .enumerate()
        {
            assert_eq!(
                store.errors()[index],
                ErrorRecord {
                    event: SourceEvent {
                        domain: DOMAIN.into(),
                        namespace: "dns".into(),
                        event_id: id.into()
                    },
                    sequence: Some(sequence),
                    result,
                    observed_at: id.into(),
                    status: if index < 2 {
                        None
                    } else {
                        Some(DomainStatus::MailReady)
                    },
                }
            );
        }
    }

    #[test]
    fn initial_ct_emits_finding_distinct_certificates_persist_and_duplicates_are_silent() {
        let mut store = Store::default();
        store
            .record_ct(DOMAIN, "ct", "first", "cert-1", "first")
            .unwrap();
        assert_eq!(
            store.findings(),
            &[Finding {
                domain: DOMAIN.into(),
                from: None,
                to: DomainStatus::Certified,
                observation_key: source_event(DOMAIN, "ct", "first").unwrap(),
                observed_at: "first".into(),
            }]
        );
        store
            .record_ct(DOMAIN, "ct", "first", "cert-1", "first")
            .unwrap();
        store
            .record_ct(DOMAIN, "ct", "second", "cert-2", "second")
            .unwrap();
        assert_eq!(
            store.ct_evidence(),
            &[
                CtEvidence {
                    event: source_event(DOMAIN, "ct", "first").unwrap(),
                    domain: DOMAIN.into(),
                    certificate_id: "cert-1".into(),
                    observed_at: "first".into()
                },
                CtEvidence {
                    event: source_event(DOMAIN, "ct", "second").unwrap(),
                    domain: DOMAIN.into(),
                    certificate_id: "cert-2".into(),
                    observed_at: "second".into()
                },
            ]
        );
        assert_eq!(store.history().len(), 2);
        assert_eq!(
            store.history()[0].raw_evidence,
            RawEvidence::Ct("cert-1".into())
        );
        assert_eq!(
            store.history()[1].raw_evidence,
            RawEvidence::Ct("cert-2".into())
        );
        assert_eq!(store.findings().len(), 1);
        assert!(store.candidates()[DOMAIN].ct_observed);
        assert_eq!(
            store.candidates()[DOMAIN].status,
            Some(DomainStatus::Certified)
        );
    }

    #[test]
    fn late_ct_and_subsequent_nxdomain_keep_certified_status() {
        let mut store = Store::default();
        observe(
            &mut store,
            "baseline",
            1,
            success(DnsProbeOutcome::NxDomain),
        );
        store
            .record_ct(DOMAIN, "ct", "late", "late-cert", "older-time")
            .unwrap();
        observe(
            &mut store,
            "nxdomain-again",
            2,
            success(DnsProbeOutcome::NxDomain),
        );
        assert!(store.candidates()[DOMAIN].ct_observed);
        assert_eq!(
            store.candidates()[DOMAIN].status,
            Some(DomainStatus::Certified)
        );
        assert_eq!(store.candidates()[DOMAIN].dns_sequence, Some(2));
        assert_eq!(store.successful_snapshots().len(), 2);
        assert_eq!(
            store.successful_snapshots()[1].observation.probe_outcome,
            DnsProbeOutcome::NxDomain
        );
        assert_eq!(store.history().len(), 3);
        assert_eq!(store.history()[2].status, DomainStatus::Certified);
        assert_eq!(store.findings().len(), 1);
        assert_eq!(store.findings()[0].from, Some(DomainStatus::Unregistered));
        assert_eq!(store.findings()[0].to, DomainStatus::Certified);
    }

    #[test]
    fn dns_replay_compares_time_sequence_and_result_for_successes_and_errors() {
        for result in [parked(), ProbeResult::Timeout, ProbeResult::ServFail] {
            let mut store = Store::default();
            store
                .observe_dns_event(DOMAIN, "dns", "event", 1, result.clone(), "time")
                .unwrap();
            let before = store.clone();
            store
                .observe_dns_event(DOMAIN, "dns", "event", 1, result.clone(), "time")
                .unwrap();
            assert_unchanged(&before, &store);
            for (sequence, changed, time) in [
                (1, result.clone(), "changed-time"),
                (2, result.clone(), "time"),
                (1, mail(), "time"),
                (1, ProbeResult::ServFail, "changed-time"),
            ] {
                assert_eq!(
                    store.observe_dns_event(DOMAIN, "dns", "event", sequence, changed, time),
                    Err(StoreError::ConflictingReplay(
                        source_event(DOMAIN, "dns", "event").unwrap()
                    ))
                );
                assert_unchanged(&before, &store);
            }
        }
    }

    #[test]
    fn stale_and_error_sequences_are_reserved_without_advancing_latest_success() {
        let mut store = Store::default();
        observe(&mut store, "error", 20, ProbeResult::Timeout);
        assert!(store.candidates().is_empty());
        observe(&mut store, "latest", 10, parked());
        observe(&mut store, "stale", 9, mail());
        assert_eq!(store.candidates()[DOMAIN].dns_sequence, Some(10));
        let before = store.clone();
        for sequence in [9, 10, 20] {
            for result in [mail(), ProbeResult::Timeout] {
                assert_eq!(
                    store.observe_dns_event(DOMAIN, "dns", "duplicate", sequence, result, "time"),
                    Err(StoreError::ConflictingSequence(DOMAIN.into()))
                );
                assert_unchanged(&before, &store);
            }
        }
        observe(&mut store, "fresh", 11, mail());
        assert_eq!(store.candidates()[DOMAIN].dns_sequence, Some(11));
        assert!(store.history()[2].applied);
    }

    #[test]
    fn dns_namespace_is_fixed_even_by_errors_but_ct_namespaces_are_independent() {
        let mut store = Store::default();
        observe(&mut store, "error", 1, ProbeResult::ServFail);
        let before = store.clone();
        assert_eq!(
            store.observe_dns_event(DOMAIN, "another-dns", "next", 2, parked(), "time"),
            Err(StoreError::ConflictingNamespace(DOMAIN.into()))
        );
        assert_unchanged(&before, &store);
        for namespace in ["ct-one", "ct-two"] {
            store
                .record_ct(DOMAIN, namespace, "event", "same-cert", "time")
                .unwrap();
        }
        assert_eq!(store.ct_evidence().len(), 2);
        assert_eq!(store.history().len(), 2);
        assert_eq!(store.findings().len(), 1);
        observe(&mut store, "next", 2, parked());
        assert_eq!(
            store.candidates()[DOMAIN].status,
            Some(DomainStatus::Certified)
        );
    }

    #[test]
    fn ct_repeated_certificate_events_have_full_history_and_immutable_replay() {
        let mut store = Store::default();
        for event_id in ["first", "second"] {
            store
                .record_ct(DOMAIN, "ct", event_id, "cert", "time")
                .unwrap();
        }
        let before = store.clone();
        store
            .record_ct(DOMAIN, "ct", "second", "cert", "time")
            .unwrap();
        assert_unchanged(&before, &store);
        for (cert, time) in [("different", "time"), ("cert", "different")] {
            assert_eq!(
                store.record_ct(DOMAIN, "ct", "second", cert, time),
                Err(StoreError::ConflictingReplay(
                    source_event(DOMAIN, "ct", "second").unwrap()
                ))
            );
            assert_unchanged(&before, &store);
        }
        assert_eq!(store.ct_evidence().len(), 2);
        assert_eq!(store.history().len(), 2);
        assert!(store.history().iter().all(|history| history.applied));
        assert_ne!(
            store.history()[0].observation_key,
            store.history()[1].observation_key
        );
        assert_eq!(store.findings().len(), 1);
    }

    #[test]
    fn dns_and_ct_share_identity_without_colon_key_collisions() {
        let mut store = Store::default();
        observe(&mut store, "event", 1, ProbeResult::Timeout);
        let before = store.clone();
        assert_eq!(
            store.record_ct(DOMAIN, "dns", "event", "cert", "event"),
            Err(StoreError::ConflictingReplay(
                source_event(DOMAIN, "dns", "event").unwrap()
            ))
        );
        assert_unchanged(&before, &store);
        store
            .record_ct(DOMAIN, "ct", "event", "cert", "time")
            .unwrap();
        let before = store.clone();
        assert_eq!(
            store.observe_dns_event(DOMAIN, "ct", "event", 2, parked(), "time"),
            Err(StoreError::ConflictingReplay(
                source_event(DOMAIN, "ct", "event").unwrap()
            ))
        );
        assert_unchanged(&before, &store);
        store
            .record_ct(DOMAIN, "ct:a", "b", "cert", "time")
            .unwrap();
        store
            .record_ct(DOMAIN, "ct", "a:b", "cert", "time")
            .unwrap();
        assert_ne!(
            store.history()[1].observation_key,
            store.history()[2].observation_key
        );
    }

    #[test]
    fn invalid_identity_and_nested_failures_never_mutate_store() {
        for mut store in [Store::default(), accepted_store()] {
            let before = store.clone();
            for (namespace, event_id) in [("", "event"), ("dns", "")] {
                assert_eq!(
                    store.observe_dns_event(DOMAIN, namespace, event_id, 99, parked(), "time"),
                    Err(StoreError::InvalidEventIdentity)
                );
                assert_eq!(
                    store.record_ct(DOMAIN, namespace, event_id, "cert", "time"),
                    Err(StoreError::InvalidEventIdentity)
                );
                assert_unchanged(&before, &store);
            }
            for outcome in [DnsProbeOutcome::ServFail, DnsProbeOutcome::Timeout] {
                assert_eq!(
                    store.observe_dns_event(DOMAIN, "dns", "nested", 99, success(outcome), "time"),
                    Err(StoreError::InvalidDnsObservation)
                );
                assert_unchanged(&before, &store);
            }
            assert!(matches!(
                store.observe_dns_event("Bad.test", "dns", "bad", 99, parked(), "time"),
                Err(StoreError::InvalidHostname(_))
            ));
            assert!(matches!(
                store.record_ct("Bad.test", "ct", "bad", "cert", "time"),
                Err(StoreError::InvalidHostname(_))
            ));
            assert_unchanged(&before, &store);
            // Invalid attempts reserve neither identity nor sequence.
            observe(&mut store, "nested", 99, parked());
        }
    }

    #[test]
    fn canonical_hostname_supports_multiple_brands_and_rejects_invalid_names() {
        let mut store = Store::default();
        assert_eq!(store.associate(DOMAIN, "one"), Ok(true));
        assert_eq!(store.associate(DOMAIN, "two"), Ok(true));
        assert_eq!(store.associate(DOMAIN, "one"), Ok(false));
        assert_eq!(store.candidates().len(), 1);
        assert_eq!(store.candidates()[DOMAIN].domain, DOMAIN);
        assert_eq!(
            store.candidates()[DOMAIN].brand_associations,
            BTreeSet::from(["one".into(), "two".into()])
        );
        for invalid in [
            "",
            "Example.test",
            "example.test.",
            "\u{e9}xample.test",
            "bad..test",
            "-bad.test",
            "bad-.test",
            "bad_test",
            "https://example.test",
        ] {
            assert!(matches!(
                store.associate(invalid, "invalid"),
                Err(StoreError::InvalidHostname(_))
            ));
            assert!(matches!(
                store.observe_dns_event(invalid, "dns", "invalid", 1, parked(), "invalid"),
                Err(StoreError::InvalidHostname(_))
            ));
            assert!(matches!(
                store.record_ct(invalid, "ct", "invalid", "invalid", "invalid"),
                Err(StoreError::InvalidHostname(_))
            ));
        }
        assert_eq!(store.candidates().len(), 1);
        assert!(store.history().is_empty());
        assert!(store.ct_evidence().is_empty());
        assert!(store.successful_snapshots().is_empty());
        assert!(store.errors().is_empty());
        assert!(store.findings().is_empty());
    }
}
