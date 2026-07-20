// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

// Package main implements a small tool that computes the next release version
// by combining the highest existing stable git tag with a bump kind. The bump
// kind is derived from the change_type field of chloggen entries in .chloggen/
// unless overridden on the command line.
//
// This file contains only pure functions and types; all I/O (git, filesystem,
// GitHub Actions outputs) lives in main.go.
package main

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Semver is a bare-bones vMAJOR.MINOR.PATCH version, optionally carrying a
// SemVer 2.0.0 pre-release suffix (e.g. "rc.1"). Build metadata is not
// modeled. The pre-release field is only ever populated on the *output*
// version; parsed tags always have an empty PreRelease -- LatestStable
// deliberately skips pre-release tags so the next release is computed from
// the last stable base.
type Semver struct {
	Major      int
	Minor      int
	Patch      int
	PreRelease string
}

var stableSemverRe = regexp.MustCompile(`^v(\d+)\.(\d+)\.(\d+)$`)

// ParseStableSemver parses "vX.Y.Z" (no pre-release suffix). Anything else
// returns ok=false so callers can filter tag lists in one pass.
func ParseStableSemver(s string) (Semver, bool) {
	m := stableSemverRe.FindStringSubmatch(strings.TrimSpace(s))
	if m == nil {
		return Semver{}, false
	}
	maj, _ := strconv.Atoi(m[1])
	min, _ := strconv.Atoi(m[2])
	pat, _ := strconv.Atoi(m[3])
	return Semver{Major: maj, Minor: min, Patch: pat}, true
}

func (v Semver) String() string {
	base := fmt.Sprintf("v%d.%d.%d", v.Major, v.Minor, v.Patch)
	if v.PreRelease == "" {
		return base
	}
	return base + "-" + v.PreRelease
}

// WithPreRelease returns a copy of v with the given SemVer 2.0.0 pre-release
// identifier attached. An empty argument clears any existing suffix.
func (v Semver) WithPreRelease(pre string) Semver {
	v.PreRelease = pre
	return v
}

// rcTagRe extracts the rc index from a "vX.Y.Z-rc.N" tag matching the given
// base version. Built dynamically by NextRCIndex so the base X.Y.Z is
// literal, and only rc.N is captured.
func rcTagRe(base Semver) *regexp.Regexp {
	pattern := fmt.Sprintf(`^v%d\.%d\.%d-rc\.(\d+)$`, base.Major, base.Minor, base.Patch)
	return regexp.MustCompile(pattern)
}

// NextRCIndex returns the next rc index for base by scanning tags for
// existing "v<base>-rc.N" entries and taking max(N)+1. Returns 1 when no
// prior rc exists. Ignores rc tags whose numeric part has a leading zero
// (e.g. "-rc.01"), since we never emit those and treating them as valid
// would produce a duplicate tag on the next run.
func NextRCIndex(tags []string, base Semver) int {
	re := rcTagRe(base)
	best := 0
	for _, t := range tags {
		m := re.FindStringSubmatch(strings.TrimSpace(t))
		if m == nil {
			continue
		}
		if len(m[1]) > 1 && m[1][0] == '0' {
			continue
		}
		n, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		if n > best {
			best = n
		}
	}
	return best + 1
}

// Less reports whether v is strictly older than o.
func (v Semver) Less(o Semver) bool {
	if v.Major != o.Major {
		return v.Major < o.Major
	}
	if v.Minor != o.Minor {
		return v.Minor < o.Minor
	}
	return v.Patch < o.Patch
}

// LatestStable picks the highest vX.Y.Z tag from the given list, skipping
// anything that isn't a stable semver tag. Returns ok=false when the input
// contains no stable tags.
func LatestStable(tags []string) (Semver, bool) {
	var best Semver
	found := false
	for _, t := range tags {
		v, ok := ParseStableSemver(t)
		if !ok {
			continue
		}
		if !found || best.Less(v) {
			best = v
			found = true
		}
	}
	return best, found
}

// BumpKind enumerates the semver components in ascending priority order, so
// numeric comparison picks the strongest bump when combining classifications.
type BumpKind int

const (
	BumpNone BumpKind = iota
	BumpPatch
	BumpMinor
	BumpMajor
)

func (b BumpKind) String() string {
	switch b {
	case BumpPatch:
		return "patch"
	case BumpMinor:
		return "minor"
	case BumpMajor:
		return "major"
	default:
		return "none"
	}
}

// ParseBumpKind parses the CLI-facing spelling of a bump kind.
func ParseBumpKind(s string) (BumpKind, error) {
	switch s {
	case "patch":
		return BumpPatch, nil
	case "minor":
		return BumpMinor, nil
	case "major":
		return BumpMajor, nil
	}
	return BumpNone, fmt.Errorf("invalid bump kind %q (want major, minor, or patch)", s)
}

// Apply returns the version resulting from bumping v by kind.
//
// While v is pre-1.0.0, a "major" bump is downgraded to a minor bump per the
// common 0.y.z convention: breaking changes may happen in a minor release
// until the project commits to a stable v1.
func (v Semver) Apply(kind BumpKind) Semver {
	switch kind {
	case BumpMajor:
		if v.Major == 0 {
			return Semver{Major: 0, Minor: v.Minor + 1, Patch: 0}
		}
		return Semver{Major: v.Major + 1, Minor: 0, Patch: 0}
	case BumpMinor:
		return Semver{Major: v.Major, Minor: v.Minor + 1, Patch: 0}
	case BumpPatch:
		return Semver{Major: v.Major, Minor: v.Minor, Patch: v.Patch + 1}
	}
	return v
}

// ChangeType is the string chloggen writes into an entry file's change_type
// field. The known values are enumerated below.
type ChangeType string

const (
	ChangeBreaking     ChangeType = "breaking"
	ChangeDeprecation  ChangeType = "deprecation"
	ChangeNewComponent ChangeType = "new_component"
	ChangeEnhancement  ChangeType = "enhancement"
	ChangeBugFix       ChangeType = "bug_fix"
)

// ClassifyChangeType maps a chloggen change_type to the bump kind it
// warrants. Returns BumpNone for unknown values so callers can flag them.
func ClassifyChangeType(ct ChangeType) BumpKind {
	switch ct {
	case ChangeBreaking:
		return BumpMajor
	case ChangeDeprecation, ChangeNewComponent, ChangeEnhancement:
		return BumpMinor
	case ChangeBugFix:
		return BumpPatch
	}
	return BumpNone
}

// ErrNoEntries is returned when auto-derivation is requested but no chloggen
// entries were provided.
var ErrNoEntries = errors.New("no chloggen entries found")

// DeriveBump picks the strongest bump warranted by the given change types.
// An unknown change type is treated as a fatal error rather than silently
// ignored -- releases should never be classified from partial information.
func DeriveBump(changeTypes []ChangeType) (BumpKind, error) {
	if len(changeTypes) == 0 {
		return BumpNone, ErrNoEntries
	}
	best := BumpNone
	for _, ct := range changeTypes {
		k := ClassifyChangeType(ct)
		if k == BumpNone {
			return BumpNone, fmt.Errorf("unknown change_type %q", string(ct))
		}
		if k > best {
			best = k
		}
	}
	return best, nil
}
