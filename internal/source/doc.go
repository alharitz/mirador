// Package source defines the Source interface: a supplier of domain
// candidates.
//
// The first implementation wraps dnstwist as a binary (Block 3). The CT log
// collector comes in through the same interface (Block 8), so adding a third
// source later touches nothing downstream.
package source
