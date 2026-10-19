// Package config reads runtime configuration from the environment.
//
// Environment variables only, no config file: one image has to behave the same
// in dev, in the cloud, and self-hosted, and a file would be one more thing to
// mount and keep in sync. Values that shape a verdict deliberately do not live
// here -- weights and thresholds belong in the versioned policy YAML, where a
// score can be traced back to the rule that produced it.
package config

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

// Config is what every process reads once at startup. It grows one variable at
// a time, as the block that needs it lands -- not in advance.
type Config struct {
	// DatabaseURL is required by every subcommand. All state lives in
	// Postgres, which is what makes the worker and the API independent.
	DatabaseURL string

	// HTTPAddr is the listen address for "mirador serve".
	HTTPAddr string

	// APIToken is the single static bearer token for the API. Required by
	// "serve" only, so it is checked by RequireAPIToken rather than Load.
	// Real user accounts are phase 3.
	APIToken string
}

// Load reads the environment and applies defaults.
func Load() (Config, error) {
	cfg := Config{
		DatabaseURL: strings.TrimSpace(os.Getenv("DATABASE_URL")),
		HTTPAddr:    envOr("MIRADOR_HTTP_ADDR", ":8080"),
		APIToken:    strings.TrimSpace(os.Getenv("MIRADOR_API_TOKEN")),
	}

	if cfg.DatabaseURL == "" {
		return Config{}, errors.New("DATABASE_URL is not set")
	}
	if !strings.HasPrefix(cfg.DatabaseURL, "postgres://") &&
		!strings.HasPrefix(cfg.DatabaseURL, "postgresql://") {
		return Config{}, fmt.Errorf("DATABASE_URL must be a postgres:// URL, got %q", truncate(cfg.DatabaseURL, 24))
	}

	return cfg, nil
}

// RequireAPIToken reports whether the API can be served with this config.
// Serving the API without a token would leave it open, so this is a hard
// failure at startup rather than a warning in a log nobody reads.
func (c Config) RequireAPIToken() error {
	if c.APIToken == "" {
		return errors.New("MIRADOR_API_TOKEN is not set")
	}
	return nil
}

func envOr(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

// truncate keeps error messages readable without echoing a full connection
// string -- it carries a password.
func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
