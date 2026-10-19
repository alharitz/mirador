CREATE TABLE candidates (
    domain TEXT PRIMARY KEY,
    status TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE state_history (
    id BIGSERIAL PRIMARY KEY,
    domain TEXT NOT NULL REFERENCES candidates(domain),
    status TEXT NOT NULL,
    observation_key TEXT NOT NULL,
    observed_at TIMESTAMPTZ NOT NULL,
    UNIQUE (domain, status, observation_key)
);

CREATE TABLE findings (
    id BIGSERIAL PRIMARY KEY,
    domain TEXT NOT NULL REFERENCES candidates(domain),
    from_status TEXT NOT NULL,
    to_status TEXT NOT NULL,
    observation_key TEXT NOT NULL,
    observed_at TIMESTAMPTZ NOT NULL,
    UNIQUE (domain, from_status, to_status, observation_key)
);

CREATE TABLE ct_evidence (
    id BIGSERIAL PRIMARY KEY,
    domain TEXT NOT NULL REFERENCES candidates(domain),
    certificate_id TEXT NOT NULL,
    observed_at TIMESTAMPTZ NOT NULL,
    UNIQUE (domain, certificate_id)
);
