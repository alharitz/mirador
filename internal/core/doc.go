// Package core holds Mirador's domain types: domain state (DomainState),
// findings (Finding), and status enums.
//
// RULE THAT MUST NOT BE BROKEN: this package imports no other Mirador package,
// and sticks to the standard library wherever possible. That's what lets
// state, source, policy, sink, and api all depend on core without depending on
// each other -- and without a cyclic import.
//
// Filled in during Block 2.
package core
