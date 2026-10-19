use crate::core::dns::{DnsProbeOutcome, ProbeResult};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DomainStatus {
    Unregistered,
    RegisteredParked,
    MailReady,
    Certified,
}

impl DomainStatus {
    pub fn classify_observation(
        current: DomainStatus,
        _reserved: bool,
        result: ProbeResult,
    ) -> DomainStatus {
        match result {
            ProbeResult::Success(observation) => match observation.probe_outcome {
                DnsProbeOutcome::NxDomain => DomainStatus::Unregistered,
                DnsProbeOutcome::Answer(ref records) => {
                    if observation.has_mx_record() {
                        DomainStatus::MailReady
                    } else {
                        let _ = records;
                        DomainStatus::RegisteredParked
                    }
                }
                DnsProbeOutcome::ServFail | DnsProbeOutcome::Timeout => current,
            },
            ProbeResult::ServFail | ProbeResult::Timeout => current,
        }
    }
}

pub fn canonical_hostname(value: &str) -> Result<String, String> {
    if value.is_empty() || value.len() > 253 || value.ends_with('.') || !value.is_ascii() {
        return Err("invalid hostname".into());
    }
    for label in value.split('.') {
        if label.is_empty()
            || label.len() > 63
            || label.starts_with('-')
            || label.ends_with('-')
            || !label
                .bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
        {
            return Err("invalid hostname label".into());
        }
    }
    Ok(value.to_owned())
}
