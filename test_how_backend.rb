#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "how-backend"

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
end

class TestTerminalOutputRequiredForFix < Minitest::Test
  def test_exits_when_no_tmux_screen_or_iterm
    original_tmux = ENV.delete("TMUX")
    original_sty = ENV.delete("STY")
    original_term_program = ENV.delete("TERM_PROGRAM")

    err = assert_raises(SystemExit) { How.terminal_output_required_for_fix }
    assert_equal 1, err.status
  ensure
    ENV["TMUX"] = original_tmux if original_tmux
    ENV["STY"] = original_sty if original_sty
    ENV["TERM_PROGRAM"] = original_term_program if original_term_program
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
end
