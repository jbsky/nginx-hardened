package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEnv(t *testing.T) {
	const key = "NGINX_INIT_TEST_VAR"

	if got := env(key, "default"); got != "default" {
		t.Errorf("env(%q, %q) = %q, want default value", key, "default", got)
	}

	t.Setenv(key, "custom")
	if got := env(key, "default"); got != "custom" {
		t.Errorf("env(%q, ...) = %q, want %q", key, got, "custom")
	}

	t.Setenv(key, "")
	if got := env(key, "default"); got != "default" {
		t.Errorf("env(%q, ...) with empty value = %q, want fallback %q", key, got, "default")
	}
}

func TestExists(t *testing.T) {
	dir := t.TempDir()
	present := filepath.Join(dir, "present")

	if exists(present) {
		t.Errorf("exists(%q) = true before file creation", present)
	}

	if err := os.WriteFile(present, nil, 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	if !exists(present) {
		t.Errorf("exists(%q) = false after file creation", present)
	}

	if exists(filepath.Join(dir, "absent")) {
		t.Errorf("exists() reported true for a path that was never created")
	}
}

func TestWriteOK(t *testing.T) {
	dir := t.TempDir()
	if !writeOK(dir) {
		t.Errorf("writeOK(%q) = false for a writable temp dir", dir)
	}

	if writeOK(filepath.Join(dir, "does-not-exist")) {
		t.Errorf("writeOK() = true for a non-existent directory")
	}
}
