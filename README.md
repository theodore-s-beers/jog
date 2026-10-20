# jog

A small native runner for `package.json` scripts, written in Odin.

## Build

Requires Odin (tested with `dev-2026-10`). Supports macOS and Linux.

```sh
odin build . -out:jog -o:speed
```

Put the resulting `jog` binary on your `PATH`.

## Usage

```sh
jog                  # list scripts alphabetically
jog dev              # execute dev script
jog test --watch     # forward arguments
jog test -- --watch  # optional arg separator
jog -- --help        # run a script literally named --help
```

- `jog` finds the nearest `package.json`, starting in the current directory and walking upward.
- Scripts run from that package's directory through `/bin/sh`, regardless of your interactive shell.
- Script names must match exactly.
- Additional args are shell-quoted and appended to the script.

## Lifecycle hooks

`jog test --watch` runs `pretest`, `test --watch`, and `posttest` in order, skipping hooks that are absent.

The first nonzero exit stops the sequence and becomes `jog`'s exit code. Extra args go only to the _requested_ script – not to hook scripts. Scripts whose names start with `pre` or `post` run directly, without hooks. Each stage runs in its own shell: changes to its directory or environment do not leak into the next stage.

`jog` forwards `SIGINT`, `SIGTERM`, `SIGHUP`, and `SIGQUIT` to the current script's process group and cancels remaining hooks. Processes that ignore termination are force-killed after a 2-second grace period. Processes that deliberately detach into another group are outside this cleanup. Signal termination is reported as exit code `128 + signal`.

## Environment contract

The caller's environment is inherited, with these values overridden:

| Variable               | Value                                                                                  |
| ---------------------- | -------------------------------------------------------------------------------------- |
| `PATH`                 | Package and ancestor `node_modules/.bin` dirs, nearest first, then the original `PATH` |
| `INIT_CWD`             | Absolute directory where `jog` was invoked                                             |
| `npm_package_json`     | Absolute path to the selected manifest                                                 |
| `npm_lifecycle_event`  | Name of the current stage, including hook names                                        |
| `npm_lifecycle_script` | Original command for that stage, before extra arguments                                |

`jog` does not read `.npmrc`, select workspaces, install dependencies, or provide npm's implicit scripts and additional environment variables.

## Completion

To enable script-name completion:

- **bash:** source `completions/jog.bash` from `.bashrc`
- **zsh:** put `completions/_jog` in a directory on `$fpath` before `compinit`
- **fish:** copy `completions/jog.fish` to `~/.config/fish/completions/jog.fish`

## Test

Requires Python, bash, zsh, and fish.

```sh
odin build . -out:jog -debug
python3 tests/integration.py
```

To build and test on Linux via Docker:

```sh
docker build -f tests/Dockerfile -t jog-test .
docker run --rm jog-test
```
