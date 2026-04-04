# how

A command-line assistant for zsh powered by GitHub Copilot. Describe what you want to do in plain English, and `how` generates the shell command for you — ready to execute or edit. When a command fails, `fix` suggests the corrected version.

## Setup

Add the following to your `.zshrc`:

```zsh
source /path/to/how.zsh
```

### Requirements

- zsh
- Ruby
- [GitHub CLI](https://cli.github.com/) (`gh` command)
- [GitHub Copilot in the CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli) (`gh copilot` extension)

To install GitHub CLI and Copilot:

```bash
# Install GitHub CLI
brew install gh  # macOS
# or see https://github.com/cli/cli#installation for other platforms

# Authenticate with GitHub
gh auth login

# Install GitHub Copilot extension
gh extension install github/gh-copilot
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

## Differences from the original

This is a fork of [kazuho/how](https://github.com/kazuho/how) that uses GitHub Copilot instead of OpenAI Codex. The main differences are:

- Uses `gh copilot suggest` command instead of `codex` CLI
- Optimized prompts for GitHub Copilot's interface
- No model selection (uses GitHub Copilot's default model)
- Keeps the original `how` / `fix` workflow and shell-history integration
