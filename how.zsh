# how - a command-line assistant for zsh
# Source this file from your .zshrc:
#   source /path/to/how.zsh

HOW_DIR="${${(%):-%N}:a:h}"
HOW_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/how-with-copilot"
HOW_STATE_FILE="$HOW_STATE_DIR/last-session.json"

autoload -Uz add-zsh-hook

_how_mkdir_state_dir() {
  mkdir -p "$HOW_STATE_DIR" 2>/dev/null
}

_how_json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  print -r -- "$value"
}

_how_capture_terminal_output() {
  local output tty tmpfile app

  if [[ -n "$TMUX" ]]; then
    output=$(tmux capture-pane -p -S -80 2>/dev/null)
  elif [[ -n "$STY" ]]; then
    tmpfile="/tmp/how_screen_hardcopy.$$"
    screen -X hardcopy "$tmpfile" >/dev/null 2>&1
    [[ -f "$tmpfile" ]] && output=$(<"$tmpfile")
    rm -f "$tmpfile"
  elif [[ "$TERM_PROGRAM" == "iTerm.app" ]]; then
    tty=$(tty 2>/dev/null) || return 1
    for app in iTerm2 iTerm; do
      output=$(osascript <<APPLESCRIPT 2>/dev/null
tell application "$app"
  repeat with aWindow in windows
    repeat with aTab in tabs of aWindow
      repeat with aSession in sessions of aTab
        if tty of aSession is "$tty" then
          return contents of aSession
        end if
      end repeat
    end repeat
  end repeat
end tell
return ""
APPLESCRIPT
)
      [[ -n "$output" ]] && break
    done
  fi

  [[ -n "$output" ]] || return 1
  print -r -- "$output"
}

_how_record_preexec() {
  _how_mkdir_state_dir
  typeset -g HOW_LAST_EXEC_CMD="$1"
}

_how_record_precmd() {
  _how_mkdir_state_dir

  local last_status=$?
  local last_cmd="${HOW_LAST_EXEC_CMD:-}"
  local terminal_output=""

  terminal_output=$(_how_capture_terminal_output 2>/dev/null || true)

  cat >| "$HOW_STATE_FILE" <<JSON
{"pwd":"$(_how_json_escape "$PWD")","last_cmd":"$(_how_json_escape "$last_cmd")","last_status":$last_status,"term_program":"$(_how_json_escape "${TERM_PROGRAM:-}")","terminal_output":"$(_how_json_escape "$terminal_output")"}
JSON
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

  if [[ -n "$HOW_PARSED_MODEL" ]]; then
    HOW_MODEL="$HOW_PARSED_MODEL" _how_run fixit "$PWD" "$last_cmd" -- "${HOW_PARSED_ARGS[@]}"
  else
    _how_run fixit "$PWD" "$last_cmd" -- "${HOW_PARSED_ARGS[@]}"
  fi
}
