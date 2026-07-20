// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestLoadTagsFromFile(t *testing.T) {
	dir := t.TempDir()
	tags := "v0.9.2\nv0.9.1\nv1.0.0-rc1\nrandom-tag\n"
	path := filepath.Join(dir, "tags")
	if err := os.WriteFile(path, []byte(tags), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := loadTags(path)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"v0.9.2", "v0.9.1", "v1.0.0-rc1", "random-tag"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("loadTags = %v; want %v", got, want)
	}
}

func TestLoadTagsFromFileEmpty(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tags")
	if err := os.WriteFile(path, []byte("\n\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := loadTags(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Errorf("loadTags on empty file = %v; want nil", got)
	}
}

func TestReadChloggenChangeTypes(t *testing.T) {
	dir := t.TempDir()

	// Files that should be skipped by name.
	writeFile(t, filepath.Join(dir, "TEMPLATE.yaml"), "change_type: enhancement\n")
	writeFile(t, filepath.Join(dir, "config.yaml"), "entries_dir: .\n")
	// A markdown file that must not be picked up.
	writeFile(t, filepath.Join(dir, "notes.md"), "not yaml\n")

	// Actual entries.
	writeFile(t, filepath.Join(dir, "a-fix.yaml"), "change_type: bug_fix\ncomponent: injector\n")
	writeFile(t, filepath.Join(dir, "b-feature.yaml"), "change_type: enhancement\ncomponent: injector\n")

	got, err := readChloggenChangeTypes(dir)
	if err != nil {
		t.Fatal(err)
	}
	want := []ChangeType{ChangeBugFix, ChangeEnhancement}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("readChloggenChangeTypes = %v; want %v", got, want)
	}
}

func TestReadChloggenChangeTypesMissingChangeType(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "bad.yaml"), "component: injector\n")

	_, err := readChloggenChangeTypes(dir)
	if err == nil {
		t.Fatal("expected error for missing change_type; got nil")
	}
	if !strings.Contains(err.Error(), "empty change_type") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestReadChloggenChangeTypesMalformedYAML(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "bad.yaml"), ": : : not-yaml\n")

	_, err := readChloggenChangeTypes(dir)
	if err == nil {
		t.Fatal("expected error for malformed yaml; got nil")
	}
}

func TestReadChloggenChangeTypesEmptyDirIsNoEntries(t *testing.T) {
	dir := t.TempDir()

	got, err := readChloggenChangeTypes(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Errorf("expected no entries; got %v", got)
	}

	// And DeriveBump on an empty slice yields ErrNoEntries -- covered in
	// nextversion_test.go, but reconfirm the composed behavior here.
	if _, err := DeriveBump(got); err == nil {
		t.Fatal("DeriveBump on empty entries should error")
	}
}

func TestResolveBumpOverride(t *testing.T) {
	// override wins even if chloggen dir does not exist.
	got, err := resolveBump("patch", filepath.Join(t.TempDir(), "does-not-exist"))
	if err != nil {
		t.Fatal(err)
	}
	if got != BumpPatch {
		t.Errorf("got %v; want BumpPatch", got)
	}
}

func TestResolveBumpAutoDerives(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "a.yaml"), "change_type: breaking\ncomponent: x\n")

	got, err := resolveBump("auto", dir)
	if err != nil {
		t.Fatal(err)
	}
	if got != BumpMajor {
		t.Errorf("got %v; want BumpMajor", got)
	}
}

func TestResolveBumpAutoNoEntriesWrapsError(t *testing.T) {
	dir := t.TempDir()
	_, err := resolveBump("auto", dir)
	if err == nil {
		t.Fatal("expected error; got nil")
	}
	if !strings.Contains(err.Error(), "no chloggen entries") {
		t.Errorf("expected 'no chloggen entries' hint, got: %v", err)
	}
}

func TestWriteGitHubOutput(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "out")
	t.Setenv("GITHUB_OUTPUT", path)

	if err := writeGitHubOutput(Semver{Major: 0, Minor: 10, Patch: 0}, BumpMinor); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := "version=v0.10.0\nbump=minor\n"
	if string(data) != want {
		t.Errorf("got %q; want %q", string(data), want)
	}
}

func TestWriteGitHubOutputAppends(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "out")
	if err := os.WriteFile(path, []byte("previous=value\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GITHUB_OUTPUT", path)

	if err := writeGitHubOutput(Semver{Major: 1, Minor: 0, Patch: 0}, BumpMajor); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := "previous=value\nversion=v1.0.0\nbump=major\n"
	if string(data) != want {
		t.Errorf("got %q; want %q", string(data), want)
	}
}

func TestWriteGitHubOutputEmptyEnvIsNoop(t *testing.T) {
	t.Setenv("GITHUB_OUTPUT", "")
	if err := writeGitHubOutput(Semver{Major: 0, Minor: 1, Patch: 0}, BumpMinor); err != nil {
		t.Fatal(err)
	}
}

func writeFile(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
}
