// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"testing"
)

func TestParseStableSemver(t *testing.T) {
	cases := []struct {
		in     string
		want   Semver
		wantOK bool
	}{
		{"v0.9.2", Semver{Major: 0, Minor: 9, Patch: 2}, true},
		{"v1.0.0", Semver{Major: 1, Minor: 0, Patch: 0}, true},
		{"v10.20.30", Semver{Major: 10, Minor: 20, Patch: 30}, true},
		{"  v1.2.3  ", Semver{Major: 1, Minor: 2, Patch: 3}, true},
		{"v0.9.2-rc1", Semver{}, false},
		{"v0.9.2-20260101", Semver{}, false},
		{"0.9.2", Semver{}, false},
		{"random-tag", Semver{}, false},
		{"", Semver{}, false},
	}
	for _, c := range cases {
		got, ok := ParseStableSemver(c.in)
		if ok != c.wantOK || got != c.want {
			t.Errorf("ParseStableSemver(%q) = (%v, %v); want (%v, %v)", c.in, got, ok, c.want, c.wantOK)
		}
	}
}

func TestSemverLess(t *testing.T) {
	cases := []struct {
		a, b Semver
		want bool
	}{
		{Semver{Major: 0, Minor: 9, Patch: 2}, Semver{Major: 0, Minor: 10, Patch: 0}, true},
		{Semver{Major: 0, Minor: 10, Patch: 0}, Semver{Major: 0, Minor: 9, Patch: 2}, false},
		{Semver{Major: 1, Minor: 0, Patch: 0}, Semver{Major: 0, Minor: 99, Patch: 99}, false},
		{Semver{Major: 0, Minor: 9, Patch: 2}, Semver{Major: 0, Minor: 9, Patch: 2}, false},
		{Semver{Major: 0, Minor: 9, Patch: 2}, Semver{Major: 0, Minor: 9, Patch: 3}, true},
	}
	for _, c := range cases {
		if got := c.a.Less(c.b); got != c.want {
			t.Errorf("(%s).Less(%s) = %v; want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestLatestStable(t *testing.T) {
	cases := []struct {
		name   string
		tags   []string
		want   Semver
		wantOK bool
	}{
		{
			name:   "picks highest stable",
			tags:   []string{"v0.9.0", "v0.9.2", "v0.9.1", "v0.8.0"},
			want:   Semver{Major: 0, Minor: 9, Patch: 2},
			wantOK: true,
		},
		{
			name:   "ignores pre-release tags",
			tags:   []string{"v0.9.2", "v1.0.0-rc1", "v0.9.3-20260101", "v2.0.0-beta"},
			want:   Semver{Major: 0, Minor: 9, Patch: 2},
			wantOK: true,
		},
		{
			name:   "ignores non-semver tags",
			tags:   []string{"random-tag", "v0.2.0", "not-a-tag", "v0.3.0"},
			want:   Semver{Major: 0, Minor: 3, Patch: 0},
			wantOK: true,
		},
		{
			name:   "picks highest not most-recent",
			tags:   []string{"v2.0.0", "v0.9.2", "v1.9.9"},
			want:   Semver{Major: 2, Minor: 0, Patch: 0},
			wantOK: true,
		},
		{
			name:   "empty input",
			tags:   nil,
			wantOK: false,
		},
		{
			name:   "only pre-release tags",
			tags:   []string{"v1.0.0-rc1", "v0.5.0-beta"},
			wantOK: false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := LatestStable(c.tags)
			if ok != c.wantOK {
				t.Fatalf("ok = %v; want %v", ok, c.wantOK)
			}
			if ok && got != c.want {
				t.Errorf("got %s; want %s", got, c.want)
			}
		})
	}
}

func TestApply(t *testing.T) {
	cases := []struct {
		name string
		base Semver
		kind BumpKind
		want Semver
	}{
		{"patch bump", Semver{Major: 0, Minor: 9, Patch: 2}, BumpPatch, Semver{Major: 0, Minor: 9, Patch: 3}},
		{"minor bump resets patch", Semver{Major: 0, Minor: 9, Patch: 2}, BumpMinor, Semver{Major: 0, Minor: 10, Patch: 0}},
		{"minor bump double-digit", Semver{Major: 1, Minor: 9, Patch: 9}, BumpMinor, Semver{Major: 1, Minor: 10, Patch: 0}},
		{"major on 0.x demotes to minor", Semver{Major: 0, Minor: 9, Patch: 2}, BumpMajor, Semver{Major: 0, Minor: 10, Patch: 0}},
		{"major on 1.x resets minor/patch", Semver{Major: 1, Minor: 4, Patch: 5}, BumpMajor, Semver{Major: 2, Minor: 0, Patch: 0}},
		{"major on 1.99.99 wraps to 2.0.0", Semver{Major: 1, Minor: 99, Patch: 99}, BumpMajor, Semver{Major: 2, Minor: 0, Patch: 0}},
		{"patch double-digit", Semver{Major: 1, Minor: 9, Patch: 9}, BumpPatch, Semver{Major: 1, Minor: 9, Patch: 10}},
		{"none returns identity", Semver{Major: 0, Minor: 9, Patch: 2}, BumpNone, Semver{Major: 0, Minor: 9, Patch: 2}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.base.Apply(c.kind); got != c.want {
				t.Errorf("(%s).Apply(%s) = %s; want %s", c.base, c.kind, got, c.want)
			}
		})
	}
}

func TestParseBumpKind(t *testing.T) {
	cases := []struct {
		in      string
		want    BumpKind
		wantErr bool
	}{
		{"major", BumpMajor, false},
		{"minor", BumpMinor, false},
		{"patch", BumpPatch, false},
		{"MAJOR", BumpNone, true},
		{"", BumpNone, true},
		{"bogus", BumpNone, true},
	}
	for _, c := range cases {
		got, err := ParseBumpKind(c.in)
		if (err != nil) != c.wantErr {
			t.Errorf("ParseBumpKind(%q) err = %v; wantErr = %v", c.in, err, c.wantErr)
		}
		if got != c.want {
			t.Errorf("ParseBumpKind(%q) = %v; want %v", c.in, got, c.want)
		}
	}
}

func TestClassifyChangeType(t *testing.T) {
	cases := []struct {
		in   ChangeType
		want BumpKind
	}{
		{ChangeBreaking, BumpMajor},
		{ChangeDeprecation, BumpMinor},
		{ChangeNewComponent, BumpMinor},
		{ChangeEnhancement, BumpMinor},
		{ChangeBugFix, BumpPatch},
		{ChangeType("unknown"), BumpNone},
		{ChangeType(""), BumpNone},
	}
	for _, c := range cases {
		if got := ClassifyChangeType(c.in); got != c.want {
			t.Errorf("ClassifyChangeType(%q) = %v; want %v", c.in, got, c.want)
		}
	}
}

func TestDeriveBump(t *testing.T) {
	cases := []struct {
		name    string
		in      []ChangeType
		want    BumpKind
		wantErr error
	}{
		{
			name: "single bug_fix -> patch",
			in:   []ChangeType{ChangeBugFix},
			want: BumpPatch,
		},
		{
			name: "single enhancement -> minor",
			in:   []ChangeType{ChangeEnhancement},
			want: BumpMinor,
		},
		{
			name: "single breaking -> major",
			in:   []ChangeType{ChangeBreaking},
			want: BumpMajor,
		},
		{
			name: "picks strongest across many",
			in:   []ChangeType{ChangeBugFix, ChangeEnhancement, ChangeBugFix},
			want: BumpMinor,
		},
		{
			name: "breaking dominates enhancement and bug_fix",
			in:   []ChangeType{ChangeBugFix, ChangeBreaking, ChangeEnhancement},
			want: BumpMajor,
		},
		{
			name: "deprecation and new_component are minor",
			in:   []ChangeType{ChangeDeprecation, ChangeNewComponent, ChangeBugFix},
			want: BumpMinor,
		},
		{
			name:    "empty input errors with ErrNoEntries",
			in:      nil,
			wantErr: ErrNoEntries,
		},
		{
			name:    "unknown change_type errors",
			in:      []ChangeType{ChangeBugFix, ChangeType("wild")},
			wantErr: errUnknown{},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := DeriveBump(c.in)
			switch want := c.wantErr.(type) {
			case nil:
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				if got != c.want {
					t.Errorf("got %v; want %v", got, c.want)
				}
			case errUnknown:
				_ = want
				if err == nil || !containsSubstring(err.Error(), "unknown change_type") {
					t.Errorf("want unknown change_type error, got: %v", err)
				}
			default:
				if !errors.Is(err, c.wantErr) {
					t.Errorf("want error %v, got %v", c.wantErr, err)
				}
			}
		})
	}
}

func TestWithPreReleaseAppendsSuffix(t *testing.T) {
	got := Semver{Major: 0, Minor: 10, Patch: 0}.WithPreRelease("rc.1").String()
	if got != "v0.10.0-rc.1" {
		t.Errorf("got %q; want v0.10.0-rc.1", got)
	}
}

func TestWithPreReleaseEmptyIsStable(t *testing.T) {
	got := Semver{Major: 0, Minor: 10, Patch: 0}.WithPreRelease("").String()
	if got != "v0.10.0" {
		t.Errorf("got %q; want v0.10.0", got)
	}
}

func TestNextRCIndex(t *testing.T) {
	base := Semver{Major: 0, Minor: 10, Patch: 0}
	cases := []struct {
		name string
		tags []string
		want int
	}{
		{
			name: "no rc tags -> 1",
			tags: []string{"v0.9.0", "v0.9.1", "v0.9.2"},
			want: 1,
		},
		{
			name: "picks max+1",
			tags: []string{"v0.10.0-rc.1", "v0.10.0-rc.3", "v0.10.0-rc.2"},
			want: 4,
		},
		{
			name: "ignores rc tags for other versions",
			tags: []string{"v0.9.0-rc.7", "v0.11.0-rc.5", "v0.10.0-rc.1"},
			want: 2,
		},
		{
			name: "ignores rc tags with leading zeros",
			tags: []string{"v0.10.0-rc.01", "v0.10.0-rc.02"},
			want: 1,
		},
		{
			name: "ignores non-rc pre-release tags",
			tags: []string{"v0.10.0-beta.1", "v0.10.0-alpha", "v0.10.0-rc"},
			want: 1,
		},
		{
			name: "handles surrounding whitespace",
			tags: []string{"  v0.10.0-rc.2  ", "v0.10.0-rc.5\n"},
			want: 6,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := NextRCIndex(c.tags, base); got != c.want {
				t.Errorf("NextRCIndex = %d; want %d", got, c.want)
			}
		})
	}
}

// errUnknown is a marker type used by TestDeriveBump to assert on
// unknown-change-type error text without pinning the exact string.
type errUnknown struct{}

func (errUnknown) Error() string { return "" }

func containsSubstring(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
