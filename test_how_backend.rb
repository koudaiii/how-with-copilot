#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "how-backend"

class TestVersion < Minitest::Test
  def test_version_is_semver
    assert_match(/\A\d+\.\d+\.\d+\z/, How::VERSION)
  end

  def test_version_subcommand_prints_version
    output = `ruby #{File.expand_path("how-backend.rb", __dir__)} version`
    assert_equal "#{How::VERSION}\n", output
    assert_equal 0, $?.exitstatus
  end

  def test_version_flag_prints_version
    output = `ruby #{File.expand_path("how-backend.rb", __dir__)} --version`
    assert_equal "#{How::VERSION}\n", output
    assert_equal 0, $?.exitstatus
  end

  def test_short_version_flag_prints_version
    output = `ruby #{File.expand_path("how-backend.rb", __dir__)} -v`
    assert_equal "#{How::VERSION}\n", output
    assert_equal 0, $?.exitstatus
  end
end

class TestBuildHowPrompt < Minitest::Test
  def test_includes_cwd
    prompt = How.build_how_prompt(cwd: "/home/user", prompt: "list files")
    assert_includes prompt, "/home/user"
  end

  def test_includes_user_request
    prompt = How.build_how_prompt(cwd: "/tmp", prompt: "find large files")
    assert_includes prompt, "find large files"
  end

  def test_mentions_shell_prompt_behavior
    prompt = How.build_how_prompt(cwd: "/tmp", prompt: "list files")
    assert_includes prompt, "inserted directly into the user's shell prompt"
  end
end

class TestBuildFixPrompt < Minitest::Test
  def test_includes_failed_command
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "gti status")
    assert_includes prompt, "gti status"
  end

  def test_includes_user_hint
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "ls", user_hint: "sort by size")
    assert_includes prompt, "sort by size"
  end

  def test_no_user_hint
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "ls")
    refute_includes prompt, "User instructions:"
  end

  def test_includes_terminal_output
    prompt = How.build_fix_prompt(
      cwd: "/tmp",
      failed_cmd: "gcc foo.c",
      terminal_output: "foo.c:3: error: expected ';'"
    )
    assert_includes prompt, "foo.c:3: error: expected ';'"
    assert_includes prompt, "Recent terminal output:"
  end

  def test_no_terminal_output
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "ls")
    refute_includes prompt, "Recent terminal output:"
  end
end

class TestCaptureTerminalOutput < Minitest::Test
  def test_no_tmux_no_screen
    original_tmux = ENV.delete("TMUX")
    original_sty = ENV.delete("STY")
    original_term_program = ENV.delete("TERM_PROGRAM")
    assert_nil How.capture_terminal_output
  ensure
    ENV["TMUX"] = original_tmux if original_tmux
    ENV["STY"] = original_sty if original_sty
    ENV["TERM_PROGRAM"] = original_term_program if original_term_program
  end

  def test_normalize_terminal_output_scrubs_invalid_bytes
    output = How.normalize_terminal_output("ok\xFFng".b)
    assert_equal "ok\ufffdng", output
  end

  def test_iterm_detection
    original_term_program = ENV["TERM_PROGRAM"]
    ENV["TERM_PROGRAM"] = "iTerm.app"
    assert How.iterm?
  ensure
    ENV["TERM_PROGRAM"] = original_term_program
  end

  def test_capture_iterm_output_uses_matching_session_contents
    original_term_program = ENV["TERM_PROGRAM"]
    ENV["TERM_PROGRAM"] = "iTerm.app"

    How.stub :current_tty, "/dev/ttys001" do
      How.stub :run_iterm_contents_script, "line 1\nline 2" do
        assert_equal "line 1\nline 2", How.capture_iterm_output
      end
    end
  ensure
    ENV["TERM_PROGRAM"] = original_term_program
  end

  def test_capture_iterm_output_truncates_to_last_lines
    original_term_program = ENV["TERM_PROGRAM"]
    ENV["TERM_PROGRAM"] = "iTerm.app"

    huge = (1..1000).map { |n| "line #{n}" }.join("\n")
    How.stub :current_tty, "/dev/ttys001" do
      How.stub :run_iterm_contents_script, huge do
        output = How.capture_iterm_output(lines: 50)
        assert_equal 50, output.lines.length
        assert_equal "line 1000", output.lines.last
      end
    end
  ensure
    ENV["TERM_PROGRAM"] = original_term_program
  end
end

class TestTerminalOutputForFix < Minitest::Test
  def test_returns_nil_when_no_capture_available
    How.stub :capture_terminal_output, nil do
      How.stub :shell_state_terminal_output, nil do
        assert_nil How.terminal_output_for_fix
      end
    end
  end

  def test_uses_shell_state_output_as_fallback
    How.stub :capture_terminal_output, nil do
      How.stub :shell_state_terminal_output, "saved output" do
        assert_equal "saved output", How.terminal_output_for_fix
      end
    end
  end

  def test_shell_state_terminal_output_reads_saved_file
    Dir.mktmpdir do |dir|
      old_xdg = ENV["XDG_STATE_HOME"]
      ENV["XDG_STATE_HOME"] = dir
      FileUtils.mkdir_p(File.join(dir, "how-with-copilot"))
      File.write(
        File.join(dir, "how-with-copilot", "last-session.json"),
        %({"terminal_output":"line 1\\nline 2"})
      )

      assert_equal "line 1\nline 2", How.shell_state_terminal_output
    ensure
      ENV["XDG_STATE_HOME"] = old_xdg
    end
  end

  def test_shell_state_terminal_output_truncates_stale_full_scrollback
    Dir.mktmpdir do |dir|
      old_xdg = ENV["XDG_STATE_HOME"]
      ENV["XDG_STATE_HOME"] = dir
      FileUtils.mkdir_p(File.join(dir, "how-with-copilot"))
      huge = (1..1000).map { |n| "line #{n}" }.join("\n")
      File.write(
        File.join(dir, "how-with-copilot", "last-session.json"),
        JSON.generate("terminal_output" => huge)
      )

      output = How.shell_state_terminal_output(lines: 50)
      assert_equal 50, output.lines.length
      assert_equal "line 1000", output.lines.last
    ensure
      ENV["XDG_STATE_HOME"] = old_xdg
    end
  end
end

class TestPrivilegeContext < Minitest::Test
  def test_returns_string
    ctx = How.privilege_context
    assert_kind_of String, ctx
    refute_empty ctx
  end

  def test_mentions_running_as
    ctx = How.privilege_context
    assert_includes ctx, "Running as"
  end

  def test_prompt_includes_privilege_info
    prompt = How.build_how_prompt(cwd: "/tmp", prompt: "list files")
    assert_includes prompt, "Running as"
  end

  def test_fix_prompt_includes_privilege_info
    prompt = How.build_fix_prompt(cwd: "/tmp", failed_cmd: "ls")
    assert_includes prompt, "Running as"
  end
end

class TestCopilotCommand < Minitest::Test
  def test_parse_copilot_jsonl
    output = <<~JSONL
      {"type":"assistant.message_delta","data":{"deltaContent":"ls "}}
      {"type":"assistant.message_delta","data":{"deltaContent":"-la"}}
      {"type":"result","exitCode":0}
    JSONL

    command, explanation = How.parse_copilot_jsonl(output)

    assert_equal "ls -la", command
    assert_equal "", explanation
  end

  def test_parse_copilot_jsonl_collects_errors
    output = <<~JSONL
      {"type":"session.error","data":{"message":"something failed"}}
      {"type":"result","exitCode":1}
    JSONL

    command, explanation = How.parse_copilot_jsonl(output)

    assert_equal "", command
    assert_includes explanation, "something failed"
    assert_includes explanation, "copilot exit code: 1"
  end

  def test_returns_command_and_explanation
    status = Struct.new(:success?).new(true)
    capture3 = lambda do |*args|
      [
        %({"type":"assistant.message_delta","data":{"deltaContent":"ls -la"}}\n{"type":"result","exitCode":0}\n),
        "",
        status
      ]
    end

    Open3.stub :capture3, capture3 do
      ok, command, explanation = How.copilot_command("prompt")

      assert ok
      assert_equal "ls -la", command
      assert_equal "", explanation
    end
  end

  def test_passes_model_flag_to_copilot
    captured_args = nil
    status = Struct.new(:success?).new(true)
    capture3 = lambda do |*args|
      captured_args = args
      [%({"type":"result","exitCode":0}\n), "", status]
    end

    original_model = ENV.delete("HOW_MODEL")
    Open3.stub :capture3, capture3 do
      How.copilot_command("prompt")
    end

    assert_includes captured_args, "--model"
    model_index = captured_args.index("--model")
    assert_equal How::DEFAULT_MODEL, captured_args[model_index + 1]
  ensure
    ENV["HOW_MODEL"] = original_model if original_model
  end

  def test_passes_env_var_model_to_copilot
    captured_args = nil
    status = Struct.new(:success?).new(true)
    capture3 = lambda do |*args|
      captured_args = args
      [%({"type":"result","exitCode":0}\n), "", status]
    end

    original_model = ENV["HOW_MODEL"]
    ENV["HOW_MODEL"] = "gpt-4.1"
    Open3.stub :capture3, capture3 do
      How.copilot_command("prompt")
    end

    model_index = captured_args.index("--model")
    assert_equal "gpt-4.1", captured_args[model_index + 1]
  ensure
    ENV["HOW_MODEL"] = original_model
  end
end

class TestSelectedModel < Minitest::Test
  def test_default_when_env_unset
    original = ENV.delete("HOW_MODEL")
    assert_equal How::DEFAULT_MODEL, How.selected_model
  ensure
    ENV["HOW_MODEL"] = original if original
  end

  def test_default_when_env_empty
    original = ENV["HOW_MODEL"]
    ENV["HOW_MODEL"] = ""
    assert_equal How::DEFAULT_MODEL, How.selected_model
  ensure
    ENV["HOW_MODEL"] = original
  end

  def test_default_when_env_whitespace
    original = ENV["HOW_MODEL"]
    ENV["HOW_MODEL"] = "   "
    assert_equal How::DEFAULT_MODEL, How.selected_model
  ensure
    ENV["HOW_MODEL"] = original
  end

  def test_uses_env_var_when_set
    original = ENV["HOW_MODEL"]
    ENV["HOW_MODEL"] = "gpt-4.1"
    assert_equal "gpt-4.1", How.selected_model
  ensure
    ENV["HOW_MODEL"] = original
  end

  def test_default_is_non_premium_model
    refute_equal "claude-sonnet-4.5", How::DEFAULT_MODEL
    assert_match(/\Agpt-/, How::DEFAULT_MODEL)
  end
end

class TestSanitizeCommandOutput < Minitest::Test
  def test_accepts_plain_command
    assert_equal "ssh user@example.com", How.sanitize_command_output("ssh user@example.com")
  end

  def test_extracts_single_fenced_command
    output = <<~TEXT
      ```sh
      ssh user@hostname
      ```
    TEXT

    assert_equal "ssh user@hostname", How.sanitize_command_output(output)
  end

  def test_ignores_explanation_and_uses_command_line
    output = <<~TEXT
      Replace `user` with your username.
      ssh user@hostname
    TEXT

    assert_equal "ssh user@hostname", How.sanitize_command_output(output)
  end

  def test_rejects_prose_only_output
    assert_nil How.sanitize_command_output("Here is how to use ssh command.")
  end

  def test_prompt_mentions_no_markdown
    prompt = How.build_how_prompt(cwd: "/tmp", prompt: "use ssh")
    assert_includes prompt, "no explanation before or after it"
    assert_includes prompt, "Do not include markdown fences"
    assert_includes prompt, "usable command template with placeholders"
  end

  def test_prefers_template_over_bare_command_name
    output = <<~TEXT
      ssh
      ssh <user>@<host>
    TEXT

    assert_equal "ssh <user>@<host>", How.sanitize_command_output(output)
  end
end
