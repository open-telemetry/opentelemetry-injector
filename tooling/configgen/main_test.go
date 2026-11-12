// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const exampleCatalog = `- id: agent_path
  type: string
  default: ""
  description: Path to an agent.
  file:
    key: agent_path
  env:
    name: AGENT_PATH
  empty_value: Disable the agent.
  examples: [/app/agent.jar]
`

func TestDecodeValidation(t *testing.T) {
	tests := []struct {
		name, catalog, want string
	}{
		{"nested root", "options:\n" + exampleCatalog, "cannot unmarshal"},
		{"empty root", "[]", "non-empty array"},
		{"extra document", exampleCatalog + "---\n[]", "one YAML document"},
		{"unknown field", exampleCatalog + "  typo: true\n", "field typo"},
		{"unknown nested field", strings.Replace(exampleCatalog, "key: agent_path", "key: agent_path\n    typo: true", 1), "field typo"},
		{"missing id", strings.Replace(exampleCatalog, "- id: agent_path\n  ", "- ", 1), "invalid or duplicate id"},
		{"invalid id", strings.Replace(exampleCatalog, "id: agent_path", "id: AgentPath", 1), "invalid or duplicate id"},
		{"duplicate id", exampleCatalog + strings.ReplaceAll(strings.Replace(exampleCatalog, "key: agent_path", "key: other_path", 1), "name: AGENT_PATH", "name: OTHER_PATH"), "invalid or duplicate id"},
		{"unknown type", strings.Replace(exampleCatalog, "type: string", "type: path", 1), "unknown type"},
		{"missing documentation", strings.Replace(exampleCatalog, "description: Path to an agent.", "description: ''", 1), "description, empty_value, and examples"},
		{"missing empty behavior", strings.Replace(exampleCatalog, "empty_value: Disable the agent.", "empty_value: ''", 1), "description, empty_value, and examples"},
		{"missing examples", strings.Replace(exampleCatalog, "examples: [/app/agent.jar]", "examples: []", 1), "description, empty_value, and examples"},
		{"missing default", strings.Replace(exampleCatalog, "  default: \"\"\n", "", 1), "string default"},
		{"wrong default type", strings.Replace(exampleCatalog, "default: \"\"", "default: 1", 1), "string default"},
		{"uint32 overflow", strings.Replace(strings.Replace(exampleCatalog, "type: string", "type: uint32", 1), "default: \"\"", "default: 4294967296", 1), "integer in range"},
		{"invalid boolean", strings.Replace(exampleCatalog, "type: string", "type: boolean", 1), "boolean default"},
		{"invalid log level", strings.Replace(exampleCatalog, "type: string", "type: log_level", 1), "log_level default"},
		{"unsupported list default", strings.Replace(strings.Replace(exampleCatalog, "type: string", "type: glob_list", 1), "default: \"\"", "default: [/app/*]", 1), "empty arrays"},
		{"duplicate file key", exampleCatalog + strings.Replace(exampleCatalog, "name: AGENT_PATH", "name: OTHER_PATH", 1), "duplicate file.key"},
		{"duplicate environment name", exampleCatalog + strings.Replace(exampleCatalog, "key: agent_path", "key: other_path", 1), "duplicate env.name"},
		{"reserved file method", strings.Replace(exampleCatalog, "key: agent_path", "key: deinit", 1), "field name collision"},
		{"reserved file map", strings.Replace(exampleCatalog, "key: agent_path", "key: all_auto_instrumentation_agents_env_vars", 1), "field name collision"},
		{"reserved generated parameter", strings.Replace(exampleCatalog, "id: agent_path", "id: allocator", 1), "name collision"},
		{"reserved document title anchor", strings.Replace(exampleCatalog, "id: agent_path", "id: configuration", 1), "documentation anchor collision"},
		{"reserved options anchor", strings.Replace(exampleCatalog, "id: agent_path", "id: options", 1), "documentation anchor collision"},
		{"generated name collision", exampleCatalog + "- id: support\n  type: string\n  env: {name: AGENT_PATH_ONLY}\n  file: {key: support}\n", "name collision"},
		{"unknown repetition", strings.Replace(exampleCatalog, "key: agent_path", "key: agent_path\n    repeated: union", 1), "file.repeated policy"},
		{"unsupported append", strings.Replace(exampleCatalog, "key: agent_path", "key: agent_path\n    repeated: append", 1), "requires glob_list"},
		{"unknown empty policy", strings.Replace(exampleCatalog, "name: AGENT_PATH", "name: AGENT_PATH\n    empty: ignore", 1), "env.empty policy"},
		{"invalid mapping", exampleCatalog + "  resource_attribute: service.name\n", "environment-only string"},
		{"unhandled environment-only option", strings.Replace(exampleCatalog, "  file:\n    key: agent_path\n", "", 1), "handwritten loader and allowlist entry"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := decode([]byte(tt.catalog))
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("decode error = %v, want %q", err, tt.want)
			}
		})
	}
}

func TestZigNames(t *testing.T) {
	for _, name := range []string{"test", "error", "type", "bool", "u32"} {
		for _, field := range []string{"id", "key"} {
			t.Run(field+"/"+name, func(t *testing.T) {
				catalog := strings.Replace(exampleCatalog, field+": agent_path", field+": "+name, 1)
				if _, err := decode([]byte(catalog)); err == nil || !strings.Contains(err.Error(), "reserved Zig name") {
					t.Fatalf("decode error = %v, want reserved Zig name", err)
				}
			})
		}
	}
}

func TestGenerate(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "config"), 0755); err != nil {
		t.Fatal(err)
	}
	catalog := exampleCatalog + `  details: |
    First paragraph.

    Second paragraph.
- id: disabled
  type: boolean
  default: false
  description: Disable injection.
  env:
    name: OTEL_INJECTOR_DISABLED
    trim: false
  empty_value: Remain enabled.
  examples: ["true"]
`
	if err := os.WriteFile(filepath.Join(root, "config/options.yaml"), []byte(catalog), 0644); err != nil {
		t.Fatal(err)
	}
	document := "# Configuration\n\nHandwritten introduction.\n\n" + beginMarker + "\nstale content\n" + endMarker + "\n\nHandwritten conclusion.\n"
	if err := os.WriteFile(filepath.Join(root, "configuration.md"), []byte(document), 0644); err != nil {
		t.Fatal(err)
	}
	if err := run(root); err != nil {
		t.Fatal(err)
	}
	for _, output := range []struct {
		path string
		want []string
	}{
		{"src/config_generated.zig", []string{"pub const agent_path = support.Option(.string)", `.file_key = "agent_path"`, `.env_name = "AGENT_PATH"`, "agent_path: []u8,", "pub fn initEmpty(allocator: std.mem.Allocator) Configuration", `.agent_path = ""`, "pub const disabled = support.Option(.boolean)", ".trim = false"}},
		{"configuration.md", []string{"# Configuration", "Handwritten introduction.", "Handwritten conclusion.", "## Options", "AGENT_PATH", "Path to an agent.", "Disable the agent.", "First paragraph.\n\nSecond paragraph.", "agent_path=/app/agent.jar"}},
	} {
		path := filepath.Join(root, output.path)
		first, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, want := range output.want {
			if !bytes.Contains(first, []byte(want)) {
				t.Errorf("%s missing %q", output.path, want)
			}
		}
		if err := run(root); err != nil {
			t.Fatal(err)
		}
		second, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(first, second) {
			t.Errorf("%s generation is not deterministic", output.path)
		}
	}
}

func TestDocsNavigation(t *testing.T) {
	options, err := decode([]byte(exampleCatalog))
	if err != nil {
		t.Fatal(err)
	}
	options[0].ID = "agent"
	docs := string(generateDocs(options))
	for _, want := range []string{"- [`agent_path` / `AGENT_PATH`](#agent)", `<a id="agent"></a>`, "### `agent_path` / `AGENT_PATH`", "[Back to options](#options)"} {
		if !strings.Contains(docs, want) {
			t.Errorf("documentation missing %q", want)
		}
	}
}

func TestDocsIntegerTrimming(t *testing.T) {
	catalog := strings.Replace(strings.Replace(exampleCatalog, "type: string", "type: uint32", 1), `default: ""`, "default: 8", 1)
	options, err := decode([]byte(catalog))
	if err != nil {
		t.Fatal(err)
	}
	trim := false
	options[0].Env.Trim = &trim
	docs := string(generateDocs(options))
	for _, want := range []string{"Environment pre-trim: false", "Type-specific whitespace trimming: spaces, tabs, CR, and LF around the integer"} {
		if !strings.Contains(docs, want) {
			t.Errorf("documentation missing %q", want)
		}
	}
}

func TestUpdateDocs(t *testing.T) {
	prefix := "Handwritten before.\r\n" + beginMarker
	suffix := endMarker + "\r\nHandwritten after."
	updated, err := updateDocs([]byte(prefix+"\nold\n"+suffix), []byte("generated\n"))
	if err != nil {
		t.Fatal(err)
	}
	if want := prefix + "\n\ngenerated\n\n" + suffix; string(updated) != want {
		t.Fatalf("updated document = %q, want %q", updated, want)
	}
	for _, existing := range []string{"", beginMarker, beginMarker + beginMarker + endMarker, beginMarker + endMarker + endMarker, endMarker + beginMarker} {
		if _, err := updateDocs([]byte(existing), nil); err == nil {
			t.Errorf("accepted invalid generation markers in %q", existing)
		}
	}
}

func TestZigQuote(t *testing.T) {
	if got, want := zigQuote("a\"\\\n\x00é"), `"a\"\\\n\x00é"`; got != want {
		t.Fatalf("zigQuote = %q, want %q", got, want)
	}
}
