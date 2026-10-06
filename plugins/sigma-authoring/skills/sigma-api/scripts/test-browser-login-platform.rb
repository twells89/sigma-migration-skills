#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class BrowserLoginPlatformTest < Minitest::Test
  LIB = File.expand_path('lib/browser-login-platform.sh', __dir__)
  BASH = ENV.fetch('BASH_BIN', 'bash')

  def shell_path(path)
    return path unless Gem.win_platform?

    out, status = Open3.capture2(BASH, '-c', 'cygpath -u "$1"', 'test', path)
    raise "cygpath failed for #{path}" unless status.success?

    out.strip
  end

  def bash(script, *args, env: {})
    Open3.capture3(env, BASH, '-c', script, 'test', shell_path(LIB), *args)
  end

  def write_executable(path, body)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
  end

  def test_base64url_strips_windows_crlf_and_padding
    out, err, status = bash(
      'source "$1"; printf "abc+/=\\r\\n" | sigma_base64url'
    )

    assert status.success?, err
    assert_equal 'abc-_', out
  end

  def test_verifier_removes_crlf_before_length_cap
    out, err, status = bash(
      %(source "$1"; printf "#{'A' * 32}\\r\\n#{'B' * 40}\\r\\n" | sigma_pkce_verifier)
    )

    assert status.success?, err
    verifier = out.chomp
    assert_equal 64, verifier.length
    refute_match(/[\r\n]/, verifier)
    assert_equal("#{'A' * 32}#{'B' * 32}", verifier)
  end

  def test_component_validation_rejects_control_characters
    _out, err, status = bash(
      'source "$1"; sigma_require_component state "$(printf "abc\\r")" "^[A-Za-z0-9_-]+$"'
    )

    refute status.success?
    assert_includes err, 'invalid characters'
  end

  def test_windows_prefers_powershell
    Dir.mktmpdir('browser-open') do |dir|
      log = File.join(dir, 'calls.log')
      write_executable(File.join(dir, 'powershell.exe'), 'printf "powershell:%s\\n" "$*" >> "$LOG"')
      write_executable(File.join(dir, 'cmd.exe'), 'printf "cmd:%s\\n" "$*" >> "$LOG"')
      write_executable(File.join(dir, 'explorer.exe'), 'printf "explorer:%s\\n" "$*" >> "$LOG"')

      _out, err, status = bash(
        'export PATH="$3:$PATH"; source "$1"; sigma_open_system_browser "$2"',
        'https://example.com/auth?a=1&b=2', shell_path(dir),
        env: {'LOG' => shell_path(log), 'SIGMA_UNAME_OVERRIDE' => 'MINGW64_NT'}
      )

      assert status.success?, err
      calls = File.read(log)
      assert_includes calls, 'powershell:'
      assert_includes calls, 'https://example.com/auth?a=1&b=2'
      refute_includes calls, 'cmd:'
      refute_includes calls, 'explorer:'
    end
  end

  def test_windows_falls_back_to_cmd_then_stops
    Dir.mktmpdir('browser-open') do |dir|
      log = File.join(dir, 'calls.log')
      write_executable(File.join(dir, 'powershell.exe'), 'exit 1')
      write_executable(File.join(dir, 'cmd.exe'), 'printf "cmd:%s\\n" "$*" >> "$LOG"')
      write_executable(File.join(dir, 'explorer.exe'), 'printf "explorer:%s\\n" "$*" >> "$LOG"')

      _out, err, status = bash(
        'export PATH="$3:$PATH"; source "$1"; sigma_open_system_browser "$2"',
        'https://example.com/auth', shell_path(dir),
        env: {'LOG' => shell_path(log), 'SIGMA_UNAME_OVERRIDE' => 'MSYS_NT'}
      )

      assert status.success?, err
      calls = File.read(log)
      assert_includes calls, 'cmd://c start'
      refute_includes calls, 'explorer:'
    end
  end

  def test_callback_file_is_private_consumed_and_removed
    Dir.mktmpdir('oauth-callback') do |dir|
      path = File.join(dir, 'callback')
      callback = 'http://127.0.0.1/callback?code=abc&state=xyz'
      out, err, status = bash(
        'source "$1"; sigma_prepare_callback_file "$2"; ' \
        '(sleep 1; printf "%s\\n" "$3" > "$2") & ' \
        'sigma_wait_for_callback_file "$2" 3',
        shell_path(path), callback
      )

      assert status.success?, err
      assert_equal callback, out.strip
      refute File.exist?(path)
    end
  end

  def test_callback_file_is_created_with_mode_0600
    Dir.mktmpdir('oauth-callback') do |dir|
      path = File.join(dir, 'callback')
      _out, err, status = bash(
        'source "$1"; sigma_prepare_callback_file "$2"',
        shell_path(path)
      )

      assert status.success?, err
      mode = File.stat(path).mode & 0o777
      if Gem.win_platform?
        assert_equal 0, mode & 0o022, "callback file must not be group/world writable (got #{mode.to_s(8)})"
      else
        assert_equal 0o600, mode
      end
    end
  end

  def test_callback_file_timeout_cleans_up
    Dir.mktmpdir('oauth-callback') do |dir|
      path = File.join(dir, 'callback')
      _out, _err, status = bash(
        'source "$1"; sigma_prepare_callback_file "$2"; sigma_wait_for_callback_file "$2" 1',
        shell_path(path)
      )

      refute status.success?
      refute File.exist?(path)
    end
  end

  def test_real_windows_uname_selects_native_launcher
    skip 'Windows Git Bash CI only' unless ENV['RUN_WINDOWS_BROWSER_TESTS'] == '1'

    Dir.mktmpdir('browser-open') do |dir|
      log = File.join(dir, 'calls.log')
      write_executable(File.join(dir, 'powershell.exe'), 'printf "powershell:%s\\n" "$*" >> "$LOG"')
      _out, err, status = bash(
        'export PATH="$3:$PATH"; unset SIGMA_UNAME_OVERRIDE; source "$1"; ' \
        'case "$(sigma_uname)" in MINGW*|MSYS*|CYGWIN*) ;; *) exit 9;; esac; ' \
        'sigma_open_system_browser "$2"',
        'https://example.com/auth', shell_path(dir),
        env: {'LOG' => shell_path(log)}
      )

      assert status.success?, err
      assert_includes File.read(log), 'powershell:'
    end
  end
end
