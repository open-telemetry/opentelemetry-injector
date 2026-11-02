// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	_ "embed"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"text/template"

	"gopkg.in/yaml.v3"
)

type optionType string

const (
	stringType      optionType = "string"
	uint32Type      optionType = "uint32"
	booleanType     optionType = "boolean"
	logLevelType    optionType = "log_level"
	globListType    optionType = "glob_list"
	runtimeListType optionType = "runtime_list"
)

type fileOption struct {
	Key      string `yaml:"key"`
	Repeated string `yaml:"repeated"`
}

type envOption struct {
	Name  string `yaml:"name"`
	Trim  *bool  `yaml:"trim"`
	Empty string `yaml:"empty"`
}

type option struct {
	ID                string      `yaml:"id"`
	Type              optionType  `yaml:"type"`
	Default           yaml.Node   `yaml:"default"`
	Description       string      `yaml:"description"`
	File              *fileOption `yaml:"file"`
	Env               *envOption  `yaml:"env"`
	EmptyValue        string      `yaml:"empty_value"`
	Details           string      `yaml:"details"`
	Examples          []string    `yaml:"examples"`
	ResourceAttribute string      `yaml:"resource_attribute"`
}

func (o option) Name() string {
	if o.File != nil {
		return o.File.Key
	}
	return o.Env.Name
}

func (o option) ZigName() string { return o.ID }

func (o option) Heading() string {
	if o.File != nil && o.Env != nil {
		return inline(o.File.Key) + " / " + inline(o.Env.Name)
	}
	return inline(o.Name())
}

func (o option) DisplayDefault() string {
	switch o.Type {
	case stringType:
		return strconv.Quote(o.Default.Value)
	case globListType, runtimeListType:
		return "[]"
	default:
		return o.Default.Value
	}
}

func (o option) ZigType() string {
	switch o.Type {
	case stringType:
		return "[]u8"
	case uint32Type:
		return "u32"
	case booleanType:
		return "bool"
	case logLevelType:
		return "support.LogLevel"
	case globListType:
		return "[][]const u8"
	case runtimeListType:
		return "support.RuntimeSet"
	default:
		panic("unvalidated option type")
	}
}

func (o option) ZigDefault() string {
	switch o.Type {
	case stringType:
		return zigQuote(o.Default.Value)
	case logLevelType:
		return "." + strings.ToUpper(o.Default.Value[:1]) + o.Default.Value[1:]
	case globListType:
		return "&.{}"
	case runtimeListType:
		return ".{}"
	default:
		return o.Default.Value
	}
}

func (o option) Trim() bool { return o.Env == nil || o.Env.Trim == nil || *o.Env.Trim }
func (o option) Empty() string {
	if o.Env != nil && o.Env.Empty != "" {
		return o.Env.Empty
	}
	return "value"
}
func (o option) Repeated() string {
	if o.File != nil && o.File.Repeated != "" {
		return o.File.Repeated
	}
	return "replace"
}

var fileKey = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
var envName = regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`)
var reservedIDs = map[string]bool{"file_options": true, "resource_mappings": true, "support": true, "std": true, "deinit": true, "allocator": true, "self": true, "option": true, "it": true, "entry": true}
var reservedFields = map[string]bool{"deinit": true, "all_auto_instrumentation_agents_env_vars": true}
var manualEnvOptions = map[string]bool{"disabled": true, "log_level": true, "config_file": true, "config_dir": true, "resource_attributes": true}
var zigIntegerType = regexp.MustCompile(`^[iu][0-9]+$`)
var zigReservedNames = func() map[string]bool {
	result := map[string]bool{}
	for _, name := range strings.Fields(`
		addrspace align allowzero and anyframe anytype asm break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline noalias noinline nosuspend opaque or orelse packed pub resume return linksection struct suspend switch test threadlocal try union unreachable var volatile while
		anyerror anyopaque bool c_int c_long c_longdouble c_longlong c_char c_short c_uint c_ulong c_ulonglong c_ushort comptime_float comptime_int f128 f16 f32 f64 f80 false isize noreturn null true type undefined usize void
	`) {
		result[name] = true
	}
	return result
}()

func reservedZigName(name string) bool {
	return zigReservedNames[name] || zigIntegerType.MatchString(name)
}

func decode(data []byte) ([]option, error) {
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	var options []option
	if err := decoder.Decode(&options); err != nil {
		return nil, err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, fmt.Errorf("expected exactly one YAML document")
	}
	if len(options) == 0 {
		return nil, fmt.Errorf("catalog must be a non-empty array")
	}
	files, envs, names := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for i, o := range options {
		fail := func(message string) ([]option, error) { return nil, fmt.Errorf("entry %d: %s", i+1, message) }
		if o.File == nil && o.Env == nil {
			return fail("file.key or env.name is required")
		}
		if o.File != nil {
			if !fileKey.MatchString(o.File.Key) || files[o.File.Key] {
				return fail("invalid or duplicate file.key")
			}
			if reservedFields[o.File.Key] {
				return fail("generated field name collision")
			}
			if reservedZigName(o.File.Key) {
				return fail("reserved Zig name in file.key")
			}
			files[o.File.Key] = true
			if o.Repeated() != "replace" && o.Repeated() != "append" {
				return fail("unknown file.repeated policy")
			}
			if o.Repeated() == "append" && o.Type != globListType {
				return fail("file.repeated append requires glob_list")
			}
		}
		if o.Env != nil {
			if !envName.MatchString(o.Env.Name) || envs[o.Env.Name] {
				return fail("invalid or duplicate env.name")
			}
			envs[o.Env.Name] = true
			if o.Empty() != "value" && o.Empty() != "default" {
				return fail("unknown env.empty policy")
			}
		}
		if !fileKey.MatchString(o.ID) || names[o.ID] {
			return fail("invalid or duplicate id")
		}
		if reservedIDs[o.ID] {
			return fail("generated name collision")
		}
		if reservedZigName(o.ID) {
			return fail("reserved Zig name in id")
		}
		if o.ID == "configuration" || o.ID == "options" {
			return fail("documentation anchor collision")
		}
		names[o.ID] = true
		if strings.TrimSpace(o.Description) == "" || strings.TrimSpace(o.EmptyValue) == "" || len(o.Examples) == 0 {
			return fail("description, empty_value, and examples are required")
		}
		if o.ResourceAttribute != "" && (o.Type != stringType || o.File != nil || o.Env == nil || o.Trim() || o.Empty() != "value") {
			return fail("resource_attribute requires an untrimmed environment-only string")
		}
		if o.File == nil && o.ResourceAttribute == "" && !manualEnvOptions[o.ID] {
			return fail("environment-only option requires a handwritten loader and allowlist entry")
		}
		switch o.Type {
		case stringType:
			if o.Default.Tag != "!!str" {
				return fail("string default must be a string")
			}
		case uint32Type:
			if o.Default.Tag != "!!int" {
				return fail("uint32 default must be an integer")
			}
			if _, err := strconv.ParseUint(o.Default.Value, 10, 32); err != nil {
				return fail("uint32 default must be a decimal integer in range")
			}
		case booleanType:
			if o.Default.Tag != "!!bool" || (o.Default.Value != "true" && o.Default.Value != "false") {
				return fail("boolean default must be true or false")
			}
		case logLevelType:
			if o.Default.Tag != "!!str" {
				return fail("invalid log_level default")
			}
			switch o.Default.Value {
			case "debug", "info", "warn", "error", "none":
			default:
				return fail("invalid log_level default")
			}
		case globListType, runtimeListType:
			if o.Default.Kind != yaml.SequenceNode || len(o.Default.Content) != 0 {
				return fail("list defaults must be empty arrays")
			}
		default:
			return fail("unknown type: " + string(o.Type))
		}
	}
	return options, nil
}

func zigQuote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, c := range []byte(s) {
		switch c {
		case '"', '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 32 || c == 127 {
				fmt.Fprintf(&b, `\x%02x`, c)
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

//go:embed configuration.zig.tmpl
var zigTemplate string

func generateZig(options []option) ([]byte, error) {
	t, err := template.New("configuration").Funcs(template.FuncMap{"quote": zigQuote}).Parse(zigTemplate)
	if err != nil {
		return nil, err
	}
	var b bytes.Buffer
	err = t.Execute(&b, options)
	return b.Bytes(), err
}

func inline(s string) string {
	delimiter := "`"
	for strings.Contains(s, delimiter) {
		delimiter += "`"
	}
	if strings.HasPrefix(s, "`") || strings.HasSuffix(s, "`") {
		s = " " + s + " "
	}
	return delimiter + s + delimiter
}

func generateDocs(options []option) []byte {
	var b strings.Builder
	b.WriteString("## Options\n\nGenerated from `config/options.yaml` using `make generate-config`. Defaults below are library defaults, not package-provided settings.\n\n")
	for _, o := range options {
		fmt.Fprintf(&b, "- [%s](#%s)\n", o.Heading(), o.ID)
	}
	for _, o := range options {
		fmt.Fprintf(&b, "\n<a id=\"%s\"></a>\n\n### %s\n\n%s\n\n- Type: %s\n- Default: %s\n", o.ID, o.Heading(), o.Description, inline(string(o.Type)), inline(o.DisplayDefault()))
		if o.File != nil {
			fmt.Fprintf(&b, "- File key: %s\n- Repeated file keys: %s\n", inline(o.File.Key), inline(o.Repeated()))
		}
		if o.Env != nil {
			fmt.Fprintf(&b, "- Environment variable: %s\n- Environment pre-trim: %t\n- Empty environment policy: %s\n", inline(o.Env.Name), o.Trim(), inline(o.Empty()))
			if o.Type == uint32Type {
				b.WriteString("- Type-specific whitespace trimming: spaces and tabs around the integer\n")
			}
			if o.File != nil {
				b.WriteString("- Environment override: replaces file values when successfully parsed\n")
			}
		}
		fmt.Fprintf(&b, "\n**Empty value:** %s\n", o.EmptyValue)
		if o.Type == logLevelType {
			b.WriteString("\n**Allowed values:** `debug`, `info`, `warn`, `error`, `none`.\n")
		}
		if o.Type == runtimeListType {
			b.WriteString("\n**Runtime names:** `dotnet`, `jvm`, `nodejs`, `python`, `ruby`.\n")
		}
		if o.Type == globListType {
			b.WriteString("\nComma-separated glob patterns. Items are trimmed and empty items are ignored. `*` matches any sequence and `?` matches one character.\n")
		}
		if o.ResourceAttribute != "" {
			fmt.Fprintf(&b, "\n**Resource attribute:** %s. See [resource-attribute precedence](#resource_attributes) for interactions with other inputs.\n", inline(o.ResourceAttribute))
		}
		if details := strings.TrimSpace(o.Details); details != "" {
			fmt.Fprintf(&b, "\n%s\n", details)
		}
		b.WriteString("\n**Examples:**\n\n")
		for _, example := range o.Examples {
			fmt.Fprintf(&b, "- %s\n", inline(o.Name()+"="+example))
		}
		b.WriteString("\n[Back to options](#options)\n")
	}
	return []byte(b.String())
}

const beginMarker = "<!-- BEGIN GENERATED CONFIGURATION -->"
const endMarker = "<!-- END GENERATED CONFIGURATION -->"

func updateDocs(existing, generated []byte) ([]byte, error) {
	if bytes.Count(existing, []byte(beginMarker)) != 1 || bytes.Count(existing, []byte(endMarker)) != 1 {
		return nil, fmt.Errorf("configuration document must contain exactly one pair of generation markers")
	}
	start := bytes.Index(existing, []byte(beginMarker)) + len(beginMarker)
	end := bytes.Index(existing, []byte(endMarker))
	if end < start {
		return nil, fmt.Errorf("configuration generation markers are reversed")
	}
	var b bytes.Buffer
	b.Write(existing[:start])
	b.WriteString("\n\n")
	b.Write(generated)
	b.WriteString("\n")
	b.Write(existing[end:])
	return b.Bytes(), nil
}

func run(root string) error {
	data, err := os.ReadFile(filepath.Join(root, "config/options.yaml"))
	if err != nil {
		return err
	}
	options, err := decode(data)
	if err != nil {
		return err
	}
	zig, err := generateZig(options)
	if err != nil {
		return err
	}
	existing, err := os.ReadFile(filepath.Join(root, "configuration.md"))
	if err != nil {
		return err
	}
	docs, err := updateDocs(existing, generateDocs(options))
	if err != nil {
		return err
	}
	for _, output := range []struct {
		path string
		data []byte
	}{{"src/config_generated.zig", zig}, {"configuration.md", docs}} {
		path := filepath.Join(root, output.path)
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			return err
		}
		if err := os.WriteFile(path, output.data, 0644); err != nil {
			return err
		}
	}
	return nil
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: configgen <repository-root>")
		os.Exit(1)
	}
	if err := run(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
