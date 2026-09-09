// Command mirador watches lookalike domains: it generates candidates, checks
// their state, and alerts when one starts moving.
//
// The subcommands here are operator-only. Reading data happens through the
// HTTP API (see internal/api), not through the CLI.
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	switch os.Args[1] {
	case "migrate", "run", "serve":
		fmt.Fprintf(os.Stderr, "mirador: subcommand %q not implemented yet\n", os.Args[1])
		os.Exit(1)
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `mirador - lookalike domain monitor

usage:
  mirador migrate    run database migrations
  mirador run        run one detection cycle
  mirador serve      run the HTTP API
`)
}
