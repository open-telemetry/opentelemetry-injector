// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		override     string
		chloggenDir  string
		gitTagOutput string
	)
	flag.StringVar(&override, "override", "auto", "override the auto-derived bump: auto, major, minor, or patch")
	flag.StringVar(&chloggenDir, "chloggen-dir", ".chloggen", "directory containing chloggen entry files")
	flag.StringVar(&gitTagOutput, "git-tag-output", "", "(testing) read the tag list from this file instead of running git")
	flag.Parse()

	tags, err := loadTags(gitTagOutput)
	if err != nil {
		return fmt.Errorf("listing git tags: %w", err)
	}

	latest, hasLatest := LatestStable(tags)
	if !hasLatest {
		fmt.Fprintln(os.Stderr, "No prior stable release tag found; starting from v0.0.0.")
	} else {
		fmt.Fprintf(os.Stderr, "Latest stable release tag: %s\n", latest)
	}

	kind, err := resolveBump(override, chloggenDir)
	if err != nil {
		return err
	}

	next := latest.Apply(kind)
	fmt.Fprintf(os.Stderr, "Next release version (%s bump): %s\n", kind, next)
	fmt.Println(next)

	return writeGitHubOutput(next, kind)
}

func loadTags(fromFile string) ([]string, error) {
	if fromFile != "" {
		data, err := os.ReadFile(fromFile)
		if err != nil {
			return nil, err
		}
		return splitLines(string(data)), nil
	}
	cmd := exec.Command("git", "tag")
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	return splitLines(string(out)), nil
}

func splitLines(s string) []string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

func resolveBump(override, chloggenDir string) (BumpKind, error) {
	if override != "" && override != "auto" {
		kind, err := ParseBumpKind(override)
		if err != nil {
			return BumpNone, err
		}
		fmt.Fprintf(os.Stderr, "Bump overridden to: %s\n", kind)
		return kind, nil
	}

	changeTypes, err := readChloggenChangeTypes(chloggenDir)
	if err != nil {
		return BumpNone, fmt.Errorf("reading chloggen entries from %s: %w", chloggenDir, err)
	}
	kind, err := DeriveBump(changeTypes)
	if err != nil {
		if errors.Is(err, ErrNoEntries) {
			return BumpNone, fmt.Errorf("no chloggen entries in %s -- either add one or pass -override=patch", chloggenDir)
		}
		return BumpNone, err
	}
	fmt.Fprintf(os.Stderr, "Bump derived from %d chloggen entries: %s\n", len(changeTypes), kind)
	return kind, nil
}

// readChloggenChangeTypes loads *.yaml files from dir, skipping the template
// and config files that live alongside the entries, and returns the
// change_type of each entry in file-order.
func readChloggenChangeTypes(dir string) ([]ChangeType, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	if err != nil {
		return nil, err
	}
	var types []ChangeType
	for _, p := range matches {
		base := filepath.Base(p)
		if base == "TEMPLATE.yaml" || base == "config.yaml" {
			continue
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return nil, err
		}
		var entry struct {
			ChangeType string `yaml:"change_type"`
		}
		if err := yaml.Unmarshal(data, &entry); err != nil {
			return nil, fmt.Errorf("%s: %w", p, err)
		}
		if entry.ChangeType == "" {
			return nil, fmt.Errorf("%s: empty change_type", p)
		}
		types = append(types, ChangeType(entry.ChangeType))
	}
	return types, nil
}

func writeGitHubOutput(v Semver, kind BumpKind) error {
	path := os.Getenv("GITHUB_OUTPUT")
	if path == "" {
		return nil
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		return fmt.Errorf("open GITHUB_OUTPUT: %w", err)
	}
	defer f.Close()
	if _, err := fmt.Fprintf(f, "version=%s\nbump=%s\n", v, kind); err != nil {
		return fmt.Errorf("write GITHUB_OUTPUT: %w", err)
	}
	return nil
}
