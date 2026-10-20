package jog

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:sort"
import "core:strings"

main :: proc() {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	args := os.args[1:]
	if len(args) > 0 && (args[0] == "--help" || args[0] == "-h") {
		fmt.println("Usage: jog [script [--] [args...]]")
		fmt.println("List scripts and commands, or run a script from the nearest package.json.")
		fmt.println("       jog --list-names   List script names only.")
		return
	}
	names_only := len(args) > 0 && args[0] == "--list-names"
	if names_only && len(args) != 1 {
		fail("--list-names does not accept arguments")
	}
	// `--` also permits scripts whose names collide with jog's own options.
	if len(args) > 0 && args[0] == "--" {
		args = args[1:]
	}

	initial_dir, cwd_err := os.get_working_directory(context.allocator)
	if cwd_err != nil {
		fail("cannot get working directory: %v", cwd_err)
	}
	dir := initial_dir
	for !os.exists(fmt.aprintf("%s/package.json", dir)) {
		parent := os.dir(dir)
		if parent == dir {
			fail("no package.json found in this directory or its parents")
		}
		dir = parent
	}
	manifest := fmt.aprintf("%s/package.json", dir)
	data, read_err := os.read_entire_file(manifest, context.allocator)
	if read_err != nil {
		fail("cannot read %s: %v", manifest, read_err)
	}
	validate_tokens(data, manifest)
	parser := json.make_parser(data, spec = .JSON)
	value, parse_err := json.parse_value(&parser)
	if parse_err != .None {
		fail("invalid JSON in %s: %v", manifest, parse_err)
	}
	if parser.curr_token.kind != .EOF {
		fail("unexpected content after JSON in %s", manifest)
	}
	root, root_ok := value.(json.Object)
	if !root_ok {
		fail("%s must contain a JSON object", manifest)
	}
	scripts_value, has_scripts := root["scripts"]
	scripts: json.Object
	if has_scripts {
		var_ok: bool
		scripts, var_ok = scripts_value.(json.Object)
		if !var_ok {
			fail("scripts in %s must be an object", manifest)
		}
	}
	names: [dynamic]string
	for name, script in scripts {
		text, ok := script.(json.String)
		if !ok {
			fail("script %q must be a string", name)
		}
		if strings.contains(name, "\x00") || strings.contains(text, "\x00") {
			fail("script %q contains a NUL byte", name)
		}
		append(&names, name)
	}
	sort.quick_sort(names[:])
	if len(args) == 0 || names_only {
		width := 0
		for name in names {
			width = max(width, len(name))
		}
		for name in names {
			if names_only {
				fmt.println(name)
			} else {
				// Keep multiline commands aligned beneath the command column.
				indent := strings.repeat(" ", width + 2)
				command, _ := strings.replace_all(
					scripts[name].(json.String),
					"\n",
					fmt.aprintf("\n%s", indent),
				)
				fmt.printfln("%-*s  %s", width, name, command)
			}
		}
		return
	}

	_, found := scripts[args[0]]
	if !found {
		fail("script %q not found in %s", args[0], manifest)
	}
	extra := args[1:]
	if len(extra) > 0 && extra[0] == "--" {
		extra = extra[1:]
	}

	// Include ancestor bins for hoisted dependencies, nearest package first.
	path := ""
	for ancestor := dir; true; {
		path = fmt.aprintf("%s%s/node_modules/.bin:", path, ancestor)
		parent := os.dir(ancestor)
		if parent == ancestor {
			break
		}
		ancestor = parent
	}
	path = fmt.aprintf("%s%s", path, os.get_env_alloc("PATH", context.allocator))
	set_env("PATH", path)
	set_env("INIT_CWD", initial_dir)
	set_env("npm_package_json", manifest)
	if err := os.change_directory(dir); err != nil {
		fail("cannot enter %s: %v", dir, err)
	}
	sequence: [dynamic]string
	name := args[0]
	hooks := !strings.has_prefix(name, "pre") && !strings.has_prefix(name, "post")
	if pre := fmt.aprintf("pre%s", name); hooks && pre in scripts {
		append(&sequence, pre)
	}
	append(&sequence, name)
	if post := fmt.aprintf("post%s", name); hooks && post in scripts {
		append(&sequence, post)
	}
	supervisor := make_supervisor()
	for event in sequence {
		original := scripts[event].(json.String)
		command := original
		if event == name {
			command = with_arguments(original, extra)
		}
		set_env("npm_lifecycle_event", event)
		set_env("npm_lifecycle_script", original)
		if status := run_script(&supervisor, command); status != 0 {
			os.exit(status)
		}
	}
}

with_arguments :: proc(original: string, extra: []string) -> string {
	command := original
	for arg in extra {
		command = fmt.aprintf("%s %s", command, shell_quote(arg))
	}
	return command
}

validate_tokens :: proc(data: []byte, manifest: string) {
	tokenizer := json.make_tokenizer(string(data), spec = .JSON)
	previous: json.Token_Kind
	for {
		token, err := json.get_token(&tokenizer)
		if err != .None && err != .EOF {
			fail("invalid JSON in %s: %v", manifest, err)
		}
		if previous == .Comma && (token.kind == .Close_Brace || token.kind == .Close_Bracket) {
			fail("trailing comma in %s", manifest)
		}
		if token.kind == .EOF {
			break
		}
		previous = token.kind
	}
}

shell_quote :: proc(arg: string) -> string {
	escaped, _ := strings.replace_all(arg, "'", "'\\''")
	return fmt.aprintf("'%s'", escaped)
}

set_env :: proc(key, value: string) {
	if err := os.set_env(key, value); err != nil {
		fail("cannot set %s: %v", key, err)
	}
}

fail :: proc(format: string, args: ..any) {
	fmt.eprint("jog: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	os.exit(1)
}
