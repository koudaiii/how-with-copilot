# The `how` zsh extension

`how` is a command-line assistant for zsh powered by GitHub Copilot CLI. It implements the `how` command:

* The command interprets the entire argument and generates a command line that does that.
* But instead of executing it, it sets up the next command line of the shell as such, so that the user can execute it just by hitting return, or edit the command line as necessary.
* Before setting up the command line, how command may emit explanations, clarifying its understanding of the user's intent and how the generated command line is organized.

The command uses GitHub Copilot CLI (via `copilot -p`) as the backend for interpreting the user input and generating the command line. The backend provides context about the current directory and shell environment to help Copilot generate appropriate commands.

This repository also implements `fix`, which takes the previous shell command from history, optionally captures recent terminal output from `tmux` or GNU `screen`, and asks Copilot for a corrected command.

## Implementation using GitHub Copilot CLI

GitHub Copilot CLI provides a non-interactive prompt mode. We use this as the backend instead of the OpenAI Codex API.

The backend calls:

```bash
copilot -p "<prompt>" --allow-all-tools --output-format json --no-custom-instructions --silent
```

This produces JSONL events. The backend then:

1. Builds a prompt that includes the shell, OS, current directory, and privilege context.
2. Collects `assistant.message_delta` events and joins them into the generated command.
3. Surfaces warnings and errors to stderr and prints the command to stdout so `how.zsh` can push it into the next prompt.
