// Package state defines the Store interface, the single door into storage,
// plus its Postgres implementation.
//
// All of Mirador's state lives in Postgres. That's what lets the process
// serving HTTP and the process running detection cycles never talk to each
// other directly.
//
// Filled in during Block 2 (2.5, 2.6).
package state
