#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "json"
require "tempfile"

module How
  module_function

  VERSION = "0.0.1"

  ITERM_APP_NAMES = ["iTerm2", "iTerm"].freeze
  DEFAULT_MODEL = "gpt-5-mini"

  def selected_model
    value = ENV["HOW_MODEL"].to_s.strip
    value.empty? ? DEFAULT_MODEL : value
  end

  def shell_env
    shell = File.basename(ENV["SHELL"] || "sh")
    os = `uname -sr 2>/dev/null`.strip
    "#{shell} on #{os}"
  end

  def privilege_context
    uid = `id -u 2>/dev/null`.strip
    if uid == "0"
      "Running as root."
    else
      user = ENV["USER"] || `whoami 2>/dev/null`.strip
      privesc = %w[sudo doas].find { |cmd| system("which #{cmd} >/dev/null 2>&1") }
      if privesc
        "Running as #{user}. Use `#{privesc}` for commands that require root."
      else
        "Running as #{user}. Use `su -c '...'` for commands that require root."
      end
    end
  end

  def capture_terminal_output(lines: 50)
    if ENV["TMUX"]
      output = normalize_terminal_output(`tmux capture-pane -p -S -#{lines} 2>/dev/null`)
      return output unless output.empty?
    elsif ENV["STY"]
      tmpfile = "/tmp/how_screen_hardcopy.#{$$}"
      system("screen", "-X", "hardcopy", tmpfile)
      if File.exist?(tmpfile)
        output = normalize_terminal_output(File.binread(tmpfile))
        File.delete(tmpfile)
        return output unless output.empty?
      end
    elsif iterm?
      output = capture_iterm_output
      return output unless output.nil? || output.empty?
    end
    nil
  end

  def iterm?
    ENV["TERM_PROGRAM"] == "iTerm.app"
  end

  def current_tty
    tty, status = Open3.capture2("tty")
    return nil unless status.success?

    tty = tty.strip
    tty.empty? ? nil : tty
  end

  def capture_iterm_output
    tty = current_tty
    return nil if tty.nil?

    ITERM_APP_NAMES.each do |app_name|
      output = run_iterm_contents_script(app_name, tty)
      return output unless output.nil? || output.empty?
    end

    nil
  end

  def run_iterm_contents_script(app_name, tty)
    script = <<~APPLESCRIPT
      tell application "#{app_name}"
        repeat with aWindow in windows
          repeat with aTab in tabs of aWindow
            repeat with aSession in sessions of aTab
              if tty of aSession is "#{tty}" then
                return contents of aSession
              end if
            end repeat
          end repeat
        end repeat
      end tell
      return ""
    APPLESCRIPT

    stdout, _stderr, status = Open3.capture3("osascript", stdin_data: script)
    return nil unless status.success?

    normalize_terminal_output(stdout)
  rescue Errno::ENOENT
    nil
  end

  def normalize_terminal_output(output)
    output.dup.force_encoding(Encoding::UTF_8).scrub.strip
  end

  def shell_state_file
    state_home = ENV["XDG_STATE_HOME"] || File.join(Dir.home, ".local", "state")
    File.join(state_home, "how-with-copilot", "last-session.json")
  end

  def shell_state
    path = shell_state_file
    return nil unless File.exist?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError, Errno::ENOENT
    nil
  end

  def shell_state_terminal_output
    output = shell_state&.dig("terminal_output")
    return nil if output.nil? || output.empty?

    normalize_terminal_output(output)
  end

  def terminal_output_for_fix
    capture_terminal_output || shell_state_terminal_output
  end

  def build_how_prompt(cwd:, prompt:)
    <<~PROMPT
      Generate one shell command for the user's request.

      Environment: #{shell_env}
      Current directory: #{cwd}
      #{privilege_context}

      Requirements:
      - Output a command suitable for the current environment.
      - Prefer concise, practical commands over long scripts.
      - If multiple steps are required, combine them into a single shell command using &&, ;, or pipes.
      - Return only the command text, with no explanation before or after it.
      - Do not include markdown fences, backticks, bullets, or prose.
      - If the request is underspecified, return a usable command template with placeholders like <user>, <host>, or <path> instead of only a bare command name.
      - Assume the command will be inserted directly into the user's shell prompt.

      User request: #{prompt}
    PROMPT
  end

  def build_fix_prompt(cwd:, failed_cmd:, user_hint: "", terminal_output: nil)
    prompt = <<~PROMPT
      Generate one corrected shell command based on the previous command and its result.

      Environment: #{shell_env}
      Current directory: #{cwd}
      #{privilege_context}

      Requirements:
      - Fix the command, or modify it according to the user's instructions.
      - Prefer concise, practical commands over long scripts.
      - Return only the command text, with no explanation before or after it.
      - Do not include markdown fences, backticks, bullets, or prose.
      - If the corrected command still needs missing values, keep them as clear placeholders like <path> rather than dropping required arguments.
      - Assume the command will be inserted directly into the user's shell prompt.

      Previous command: #{failed_cmd}
    PROMPT

    prompt += "User instructions: #{user_hint}\n" unless user_hint.empty?
    prompt += "\nRecent terminal output:\n#{terminal_output}\n" if terminal_output
    prompt
  end

  def copilot_command(prompt)
    cmd = [
      "copilot",
      "-p", prompt,
      "--model", selected_model,
      "--allow-all-tools",
      "--output-format", "json",
      "--no-custom-instructions",
      "--silent"
    ]

    stdout, stderr, status = Open3.capture3(*cmd)
    command, explanation = parse_copilot_jsonl(stdout)
    [status.success?, command, [explanation, stderr].reject(&:empty?).join("\n").strip]
  rescue Errno::ENOENT
    [false, "", "how: `copilot` command not found"]
  end

  def parse_copilot_jsonl(output)
    command_parts = []
    diagnostics = []

    output.each_line do |line|
      line = line.strip
      next if line.empty?

      event = JSON.parse(line)
      case event["type"]
      when "assistant.message_delta"
        command_parts << event.dig("data", "deltaContent").to_s
      when "session.error"
        diagnostics << event.dig("data", "message").to_s
      when "session.warning", "session.info"
        message = event.dig("data", "message").to_s
        diagnostics << message unless message.empty?
      when "result"
        diagnostics << "copilot exit code: #{event["exitCode"]}" if event["exitCode"].to_i != 0
      end
    end

    [command_parts.join.strip, diagnostics.join("\n").strip]
  rescue JSON::ParserError => e
    ["", "how: failed to parse copilot output: #{e.message}"]
  end

  def sanitize_command_output(text)
    value = text.to_s.strip
    return nil if value.empty?

    fenced = extract_fenced_code_block(value)
    value = fenced unless fenced.nil?
    value = strip_inline_backticks(value)

    lines = value.lines.map(&:strip).reject(&:empty?)
    return nil if lines.empty?

    shell_lines = lines.select { |line| shell_command_like?(line) }
    candidate = choose_best_command_line(shell_lines, lines)
    candidate = strip_inline_backticks(candidate).strip

    return nil if candidate.empty?
    return nil if suspicious_non_command?(candidate)

    candidate
  end

  def choose_best_command_line(shell_lines, lines)
    return best_scored_command_line(shell_lines) unless shell_lines.empty?

    lines.last
  end

  def best_scored_command_line(lines)
    lines.max_by { |line| command_line_score(line) }
  end

  def command_line_score(line)
    score = 0
    score += 5 if line.include?(" ")
    score += 4 if line.match?(/[<>\[\]]/)
    score += 3 if line.match?(%r{[@/:]})
    score += 2 if line.match?(/[|&;$]/)
    score += [line.length, 80].min / 20
    score -= 3 if line.match?(/\A[A-Za-z0-9_.-]+\z/)
    score
  end

  def extract_fenced_code_block(text)
    match = text.match(/\A```(?:[^\n`]*)\n(?<body>.*?)\n```\z/m)
    return nil unless match

    match[:body].strip
  end

  def strip_inline_backticks(text)
    text.gsub(/\A`+|`+\z/, "")
  end

  def shell_command_like?(line)
    return false if line.empty?
    return false if line.start_with?("#", ">", "-", "*")
    return false if line.include?("```")
    return false if line.match?(/\A(?:replace|use|run|example|here(?:'s| is)|this|that)\b/i)
    return false if line.match?(/\A[a-z][a-z0-9 _-]*:\z/i)

    line.match?(/[|&;<>()$]/) ||
      line.match?(%r{\A(?:\./|/|~/)}) ||
      line.match?(/\A[A-Za-z0-9_.-]+(?:\s|$)/)
  end

  def suspicious_non_command?(line)
    return true if line.include?("```")
    return true if line.match?(/\A(?:replace|use|run|example|here(?:'s| is)|this|that)\b/i)
    return true if line.match?(/[.?!]\s+[A-Z]/)
    return true if line.split(/\s+/).length > 20

    false
  end

  def generate(full_prompt)
    ok, command, explanation = copilot_command(full_prompt)

    unless ok
      $stderr.puts explanation unless explanation.empty?
      $stderr.puts "how: copilot CLI failed"
      exit 1
    end

    if command.empty?
      $stderr.puts explanation unless explanation.empty?
      $stderr.puts "how: no command returned by copilot CLI"
      exit 1
    end

    command = sanitize_command_output(command)
    if command.nil?
      $stderr.puts explanation unless explanation.empty?
      $stderr.puts "how: could not sanitize copilot output into a shell command"
      exit 1
    end

    $stderr.puts explanation unless explanation.empty?
    puts command
  end

  def run_how(args)
    if args.length < 2
      $stderr.puts "Usage: how-backend.rb how <cwd> <prompt...>"
      exit 1
    end

    cwd = args[0]
    prompt = args[1..].join(" ")
    generate(build_how_prompt(cwd: cwd, prompt: prompt))
  end

  def run_fixit(args)
    if args.length < 2
      $stderr.puts "Usage: how-backend.rb fixit <cwd> <previous_command>"
      exit 1
    end

    cwd = args[0]
    sep = args[1..].index("--")
    if sep
      failed_cmd = args[1, sep].join(" ")
      user_hint = args[(sep + 2)..].join(" ")
    else
      failed_cmd = args[1..].join(" ")
      user_hint = ""
    end

    generate(build_fix_prompt(
      cwd: cwd,
      failed_cmd: failed_cmd,
      user_hint: user_hint,
      terminal_output: terminal_output_for_fix
    ))
  end
end

if __FILE__ == $PROGRAM_NAME
  mode = ARGV.shift

  case mode
  when "how"
    How.run_how(ARGV)
  when "fixit"
    How.run_fixit(ARGV)
  when "version", "--version", "-v"
    puts How::VERSION
  when "default-model"
    puts How::DEFAULT_MODEL
  else
    warn "Usage: how-backend.rb {how|fixit|version|default-model} ..."
    exit 1
  end
end
