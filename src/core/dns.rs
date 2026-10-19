use std::net::Ipv4Addr;

/// DNS probe outcome
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(dead_code)]
pub enum DnsProbeOutcome {
    /// Domain does not exist (NXDOMAIN)
    NxDomain,
    /// Successful response with records
    Answer(Vec<DnsRecord>),
    /// Server failure (SERVFAIL)
    ServFail,
    /// Timeout or unreachable
    Timeout,
}

/// DNS record types
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(dead_code)]
pub enum DnsRecord {
    /// IPv4 address record
    A(Ipv4Addr),
    /// Mail exchange record
    MX(u16, String), // preference, exchange
    /// Nameserver record
    NS(String),
}

/// Result of a DNS probe attempt
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(dead_code)]
pub enum ProbeResult {
    /// Successful probe with observation
    Success(DnsObservation),
    /// Server failure (SERVFAIL)
    ServFail,
    /// Timeout or unreachable
    Timeout,
}

/// Observation from a successful DNS probe
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(dead_code)]
pub struct DnsObservation {
    pub probe_outcome: DnsProbeOutcome,
    pub has_certificate: bool,
}

#[allow(dead_code)]
impl DnsObservation {
    /// Check if observation contains any MX records
    pub fn has_mx_record(&self) -> bool {
        matches!(&self.probe_outcome, DnsProbeOutcome::Answer(ref records) if records.iter().any(|r| matches!(r, DnsRecord::MX(_, _))))
    }

    /// Check if observation is a valid DNS answer without MX records
    pub fn is_valid_answer_without_mx(&self) -> bool {
        match &self.probe_outcome {
            DnsProbeOutcome::Answer(ref records) => !records.is_empty() && !self.has_mx_record(),
            _ => false,
        }
    }
}
