// Package sink ships Findings out: an append-only JSONL file and a webhook
// with retry + backoff.
//
// A delivery failure must never fail the cycle.
//
// Filled in during Block 4 (4.5, 4.6).
package sink
