# how - a command-line assistant for zsh
# Source this file from your .zshrc:
#   source /path/to/how.zsh

HOW_DIR="${${(%):-%N}:a:h}"

autoload -Uz add-zsh-hook

# Records the just-executed command for `fix`. Kept intentionally lightweight:
# terminal output is NOT captured here. Capturing it on every precmd ran a
# synchronous osascript (~0.6s per prompt on iTerm) and made the terminal feel
# choppy. `fix` captures the screen live at invocation time via the backend
# (see how-backend.rb: terminal_output_for_fix), so a precmd snapshot is
# redundant.
_how_record_preexec() {
  typeset -g HOW_LAST_EXEC_CMD="$1"
}

# Records the exit status of the previous command so `fix` can short-circuit
# when there is nothing to fix. `how`/`fix` invocations are ignored so the
# status of the real command they operate on is preserved across a `fix` call.
_how_record_precmd() {
  local last_status=$?
  local cmd="$HOW_LAST_EXEC_CMD"

  # Strip leading VAR=value assignments (e.g. `HOW_MODEL=gpt-4.1 fix`).
  while [[ "$cmd" == [A-Za-z_][A-Za-z0-9_]*=* && "$cmd" == *[[:space:]]* ]]; do
    cmd="${cmd#*[[:space:]]}"
  done

  case "${cmd%%[[:space:]]*}" in
    ""|fix|how) ;;
    *) typeset -gi HOW_LAST_EXEC_STATUS=$last_status ;;
  esac
}

add-zsh-hook preexec _how_record_preexec
add-zsh-hook precmd _how_record_precmd

# Run a backend command with a spinner, capturing stdout.
# Explanation (stderr) passes through to the terminal.
# Spinner runs in background; backend runs in foreground.
_how_run() {
  local tmpfile=$(mktemp)
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

  # Suppress job control notifications for the spinner
  setopt local_options no_monitor no_notify

  # Start spinner in background
  (
    local i=0
    while true; do
      printf "\r%s " "${spin:$i:1}" >&2
      (( i = (i + 1) % ${#spin} ))
      sleep 0.1
    done
  ) &
  local spinner_pid=$!

  # Ensure spinner is cleaned up on interrupt
  trap "kill $spinner_pid 2>/dev/null; wait $spinner_pid 2>/dev/null; printf '\r  \r' >&2; rm -f '$tmpfile'; return 130" INT TERM

  # Run backend in foreground, capture stdout
  "$HOW_DIR/how-backend.rb" "$@" > "$tmpfile"
  local exit_code=$?

  # Stop spinner and clear
  kill $spinner_pid 2>/dev/null
  wait $spinner_pid 2>/dev/null
  printf "\r  \r" >&2

  trap - INT TERM

  local result=$(<"$tmpfile")
  rm -f "$tmpfile"

  if [[ $exit_code -ne 0 ]]; then
    return 1
  fi

  if [[ -n "$result" ]]; then
    print -rz -- "$result"
  fi
}

_how_last_history_cmd() {
  local entries cmd i
  entries=("${(@f)$(fc -ln -20 2>/dev/null)}")

  for (( i = ${#entries}; i >= 1; --i )); do
    cmd="${entries[i]}"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    cmd="${cmd%"${cmd##*[![:space:]]}"}"
    [[ -n "$cmd" ]] || continue

    case "$cmd" in
      fix|fix\ *|how|how\ *|[A-Za-z_][A-Za-z0-9_]*=*[\ ]fix|[A-Za-z_][A-Za-z0-9_]*=*[\ ]fix\ *|[A-Za-z_][A-Za-z0-9_]*=*[\ ]how|[A-Za-z_][A-Za-z0-9_]*=*[\ ]how\ *)
        continue
        ;;
    esac

    print -r -- "$cmd"
    return 0
  done

  return 1
}

_how_parse_model_flag() {
  # Parses --model/-m from positional args.
  # Sets HOW_PARSED_MODEL and HOW_PARSED_ARGS as global arrays/scalars.
  typeset -ga HOW_PARSED_ARGS
  HOW_PARSED_ARGS=()
  HOW_PARSED_MODEL=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model|-m)
        if [[ $# -lt 2 ]]; then
          echo "how: --model requires a value" >&2
          return 1
        fi
        HOW_PARSED_MODEL="$2"
        shift 2
        ;;
      --model=*)
        HOW_PARSED_MODEL="${1#--model=}"
        shift
        ;;
      --)
        shift
        HOW_PARSED_ARGS+=("$@")
        break
        ;;
      *)
        HOW_PARSED_ARGS+=("$1")
        shift
        ;;
    esac
  done
  return 0
}

_how_print_usage() {
  local default_model
  default_model=$("$HOW_DIR/how-backend.rb" default-model 2>/dev/null)
  echo "Usage: how [--model MODEL | -m MODEL] <what you want to do>" >&2
  [[ -n "$default_model" ]] && echo "  default model: $default_model" >&2
  echo "  available models: https://docs.github.com/en/copilot/concepts/billing/copilot-requests#model-multipliers" >&2
}

how() {
  case "$1" in
    --version|-v)
      "$HOW_DIR/how-backend.rb" version
      return $?
      ;;
  esac

  _how_parse_model_flag "$@" || return 1

  if [[ ${#HOW_PARSED_ARGS[@]} -eq 0 ]]; then
    _how_print_usage
    return 1
  fi

  if [[ -n "$HOW_PARSED_MODEL" ]]; then
    HOW_MODEL="$HOW_PARSED_MODEL" _how_run how "$PWD" "${HOW_PARSED_ARGS[@]}"
  else
    _how_run how "$PWD" "${HOW_PARSED_ARGS[@]}"
  fi
}

fix() {
  case "$1" in
    --version|-v)
      "$HOW_DIR/how-backend.rb" version
      return $?
      ;;
  esac

  _how_parse_model_flag "$@" || return 1

  local last_cmd
  if ! last_cmd=$(_how_last_history_cmd); then
    echo "fix: no previous command to fix" >&2
    return 1
  fi

  # Nothing to fix: the previous command succeeded and no instructions were
  # given. Hand the command straight back instead of calling Copilot. With
  # instructions, fall through so `fix <instructions>` can still modify it.
  if [[ ${#HOW_PARSED_ARGS[@]} -eq 0 && "${HOW_LAST_EXEC_STATUS:-1}" -eq 0 ]]; then
    print -rz -- "$last_cmd"
    return 0
  fi

  if [[ -n "$HOW_PARSED_MODEL" ]]; then
    HOW_MODEL="$HOW_PARSED_MODEL" _how_run fixit "$PWD" "$last_cmd" -- "${HOW_PARSED_ARGS[@]}"
  else
    _how_run fixit "$PWD" "$last_cmd" -- "${HOW_PARSED_ARGS[@]}"
  fi
}
