# how

A command-line assistant for zsh powered by GitHub Copilot. Describe what you want to do in plain English, and `how` generates the shell command for you — ready to execute or edit. When a command fails, `fix` suggests the corrected version.

This project was created with respect and appreciation for [kazuho/how](https://github.com/kazuho/how). Inspired by that original work, this repository adapts the idea for GitHub Copilot CLI.

## Setup

Add the following to your `.zshrc`:

```zsh
source /path/to/how.zsh
```

### Requirements

- zsh
- Ruby
- [GitHub CLI](https://cli.github.com/) (`gh` command)
- [GitHub Copilot CLI](https://github.com/github/copilot-cli) (`copilot` command)

To install GitHub CLI and Copilot CLI:

```bash
# Install GitHub CLI
brew install gh  # macOS
# or see https://github.com/cli/cli#installation for other platforms

# Authenticate with GitHub
gh auth login

# Install GitHub Copilot CLI
brew install copilot-cli
# or: npm install -g @github/copilot
```

## Usage

### how

```
how <what you want to do>
```

The generated command appears at your prompt. Press Enter to run it, or edit it first.

```
how do I find all TODO comments in this project
how do I list files sorted by size
how do I compress this directory into a tar.gz
```

### fix

```
fix [optional instructions]
```

Fixes or modifies the previous command from shell history. It inspects recent terminal output using [tmux](https://github.com/tmux/tmux), [GNU screen](https://www.gnu.org/software/screen/), or iTerm on macOS. With arguments, it modifies the command as instructed (e.g., `fix sort by date`).

```
$ gti status
zsh: command not found: gti
$ fix
# `gti` is a typo — replacing with `git`.
git status             # ← appears at your prompt, ready to run
```

`fix` exits with an error unless it can capture recent terminal output from [tmux](https://github.com/tmux/tmux), [GNU screen](https://www.gnu.org/software/screen/), or iTerm.

## Model selection

By default, `how` and `fix` use `gpt-5-mini`, which currently has a **0× premium request multiplier** on paid GitHub Copilot plans (effectively free). For translating natural language to a single shell command, this is more than capable, and avoids consuming a premium request on every invocation.

You can override the model in two ways (CLI flag takes precedence over the environment variable):

```zsh
# 1) Per-invocation flag
how --model gpt-4.1 list files sorted by size
fix -m gpt-4.1

# 2) Environment variable
export HOW_MODEL=gpt-4.1
how list files sorted by size
```

Any model accepted by `copilot --model` works. See [GitHub Copilot model multipliers](https://docs.github.com/en/copilot/concepts/billing/copilot-requests#model-multipliers) for which models cost premium requests.

## Differences from the original

This is a fork of [kazuho/how](https://github.com/kazuho/how) that uses GitHub Copilot instead of OpenAI Codex. The main differences are:

- Uses `copilot -p` in non-interactive JSON mode instead of `codex` CLI
- Optimized prompts for GitHub Copilot's interface
- Defaults to a non-premium model (`gpt-5-mini`) and supports `--model` / `HOW_MODEL`
- Keeps the original `how` / `fix` workflow and shell-history integration
