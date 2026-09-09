# Development notes

Working notes that don't belong in README or the architecture docs -- decisions
made along the way, measurements, things learned by doing.

## Test domain

`bca.co.id` (Bank Central Asia) is the one real domain used throughout
development -- Block 1's spike, Block 3's resolve loop, Block 5's scoring, all
of it. Chosen deliberately: financial institutions are the most heavily
typosquatted targets in practice, so candidate volume and CT log patterns
against it are realistic, not synthetic.

Everything done against it in phase 1 is passive: DNS resolution and public CT
log reads. No HTTP requests to candidate domains -- that's phase 2, once
deployment has moved off a home IP.
