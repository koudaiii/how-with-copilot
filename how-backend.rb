#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "tempfile"

module How
  module_function

  ITERM_APP_NAMES = ["iTerm2", "iTerm"].freeze

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

  def terminal_output_required_for_fix
    output = capture_terminal_output
    return output if output

    $stderr.puts "fix: requires tmux, GNU screen, or iTerm so recent terminal output can be captured"
    exit 1
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
      - Do not include markdown fences or backticks in the command.
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
      - Do not include markdown fences or backticks in the command.
      - Assume the command will be inserted directly into the user's shell prompt.

      Previous command: #{failed_cmd}
    PROMPT

    prompt += "User instructions: #{user_hint}\n" unless user_hint.empty?
    prompt += "\nRecent terminal output:\n#{terminal_output}\n" if terminal_output
    prompt
  end

  def copilot_command(prompt)
    file = Tempfile.new("how-command")
    begin
      cmd = ["gh", "copilot", "suggest", "-t", "shell", "--shell-out", file.path, prompt]
      stdout, stderr, status = Open3.capture3(*cmd)
      explanation = [stdout, stderr].reject(&:empty?).join("\n").strip
      [status.success?, File.read(file.path).strip, explanation]
    ensure
      file.close
      file.unlink
    end
  end

  def generate(full_prompt)
    ok, command, explanation = copilot_command(full_prompt)

    unless ok
      $stderr.puts explanation unless explanation.empty?
      $stderr.puts "how: gh copilot suggest failed"
      exit 1
    end

    if command.empty?
      $stderr.puts explanation unless explanation.empty?
      $stderr.puts "how: no command returned by gh copilot suggest"
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
      terminal_output: terminal_output_required_for_fix
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
  else
    warn "Usage: how-backend.rb {how|fixit} ..."
    exit 1
  end
end
