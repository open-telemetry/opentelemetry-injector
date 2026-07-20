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
		{"v0.9.2", Semver{0, 9, 2}, true},
		{"v1.0.0", Semver{1, 0, 0}, true},
		{"v10.20.30", Semver{10, 20, 30}, true},
		{"  v1.2.3  ", Semver{1, 2, 3}, true},
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
		{Semver{0, 9, 2}, Semver{0, 10, 0}, true},
		{Semver{0, 10, 0}, Semver{0, 9, 2}, false},
		{Semver{1, 0, 0}, Semver{0, 99, 99}, false},
		{Semver{0, 9, 2}, Semver{0, 9, 2}, false},
		{Semver{0, 9, 2}, Semver{0, 9, 3}, true},
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
			want:   Semver{0, 9, 2},
			wantOK: true,
		},
		{
			name:   "ignores pre-release tags",
			tags:   []string{"v0.9.2", "v1.0.0-rc1", "v0.9.3-20260101", "v2.0.0-beta"},
			want:   Semver{0, 9, 2},
			wantOK: true,
		},
		{
			name:   "ignores non-semver tags",
			tags:   []string{"random-tag", "v0.2.0", "not-a-tag", "v0.3.0"},
			want:   Semver{0, 3, 0},
			wantOK: true,
		},
		{
			name:   "picks highest not most-recent",
			tags:   []string{"v2.0.0", "v0.9.2", "v1.9.9"},
			want:   Semver{2, 0, 0},
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
		{"patch bump", Semver{0, 9, 2}, BumpPatch, Semver{0, 9, 3}},
		{"minor bump resets patch", Semver{0, 9, 2}, BumpMinor, Semver{0, 10, 0}},
		{"minor bump double-digit", Semver{1, 9, 9}, BumpMinor, Semver{1, 10, 0}},
		{"major on 0.x demotes to minor", Semver{0, 9, 2}, BumpMajor, Semver{0, 10, 0}},
		{"major on 1.x resets minor/patch", Semver{1, 4, 5}, BumpMajor, Semver{2, 0, 0}},
		{"major on 1.99.99 wraps to 2.0.0", Semver{1, 99, 99}, BumpMajor, Semver{2, 0, 0}},
		{"patch double-digit", Semver{1, 9, 9}, BumpPatch, Semver{1, 9, 10}},
		{"none returns identity", Semver{0, 9, 2}, BumpNone, Semver{0, 9, 2}},
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
