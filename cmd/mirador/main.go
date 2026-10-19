// Command mirador watches lookalike domains: it generates candidates, checks
// their state, and alerts when one starts moving.
//
// The subcommands here are operator-only. Reading data happens through the
// HTTP API (see internal/api), not through the CLI.
package main

import (
	"errors"
	"fmt"
	"os"

	"github.com/alharitz/mirador/internal/config"
)

var errNotImplemented = errors.New("not implemented yet")

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "migrate":
		err = cmdMigrate()
	case "run":
		err = cmdRun()
	case "serve":
		err = cmdServe()
	default:
		usage()
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "mirador: %v\n", err)
		os.Exit(1)
	}
}

// Every subcommand loads the config first, so a missing or malformed
// DATABASE_URL fails immediately at startup instead of halfway through a cycle.

func cmdMigrate() error {
	if _, err := config.Load(); err != nil {
		return err
	}
	return fmt.Errorf("migrate: %w", errNotImplemented)
}

func cmdRun() error {
	if _, err := config.Load(); err != nil {
		return err
	}
	return fmt.Errorf("run: %w", errNotImplemented)
}

func cmdServe() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if err := cfg.RequireAPIToken(); err != nil {
		return err
	}
	return fmt.Errorf("serve: %w", errNotImplemented)
}

func usage() {
	fmt.Fprint(os.Stderr, `mirador - lookalike domain monitor

usage:
  mirador migrate    run database migrations
  mirador run        run one detection cycle
  mirador serve      run the HTTP API
`)
}
