"""`claude setup-token` capture, the paste fallback, and `cswap setup-token`."""

from __future__ import annotations

import sys
from unittest.mock import patch

import pytest

from claude_swap import cli
from claude_swap import setup_token as st

TOKEN = "sk-ant-oat01-" + "Ab3_dE-f9" * 10 + "XyzAA"


def _ink_words(text: str, indent: int = 2) -> str:
    """Ink positions words with CSI n G instead of printing spaces."""
    out, col = [], indent
    for word in text.split(" "):
        out.append(f"\x1b[{col}G{word}")
        col += len(word) + 1
    return "".join(out)


def _ink_output(token: str, cols: int) -> str:
    """Shape of `claude setup-token`'s success screen as a pty relays it."""
    nl = "\r\r\n"
    parts = [
        "\x1b[?25l\x1b[?2004h",
        _ink_words("Paste code here if prompted >") + nl,
        "\x1b[2K\x1b[1A\x1b[2K\x1b[G",
        "\x1b[32m" + _ink_words("✓ Long-lived authentication token created successfully!") + "\x1b[39m" + nl + nl,
        _ink_words("Your OAuth token (valid for 1 year):") + nl + nl,
    ]
    for i in range(0, len(token), cols):
        parts.append("\x1b[33m" + token[i:i + cols] + "\x1b[39m" + nl)
    parts += [
        nl,
        "\x1b[2m" + _ink_words("Store this token securely. You won't be able to see it again.") + "\x1b[22m" + nl,
        nl,
        "\x1b[2m" + _ink_words("Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=<token>") + "\x1b[22m" + nl,
        "\x1b]8;id=1;https://example.com\x07link\x1b]8;;\x07" + nl,
    ]
    return "".join(parts)


@pytest.mark.parametrize("cols", [40, 80, len(TOKEN), len(TOKEN) + 1, 200])
def test_extract_rejoins_wrapped_token(cols):
    assert st.extract_setup_token(_ink_output(TOKEN, cols)) == TOKEN


def test_extract_takes_last_rendering():
    old = "sk-ant-oat01-" + "OLD" * 20
    text = _ink_output(old, 80) + _ink_output(TOKEN, 80)
    assert st.extract_setup_token(text) == TOKEN


def test_extract_does_not_swallow_following_prose():
    # "Store this token…" with CSI-G spacing must not read as token characters.
    text = "\x1b[33m" + TOKEN + "\x1b[39m\r\r\n" + _ink_words("Store this token") + "\r\r\n"
    assert st.extract_setup_token(text) == TOKEN


def test_extract_none_without_token():
    assert st.extract_setup_token(_ink_words("OAuth error: denied") + "\r\n") is None
    assert st.extract_setup_token("sk-ant-oat01-short\r\n") is None


def test_strip_terminal_codes_keeps_word_breaks():
    assert st.strip_terminal_codes(_ink_words("a bc d")).split() == ["a", "bc", "d"]


def test_prompt_for_token_joins_lines_until_blank(capsys):
    lines = iter([TOKEN[:50], TOKEN[50:], ""])
    assert st.prompt_for_token(lambda _p: next(lines)) == TOKEN


def test_prompt_for_token_skips_leading_blank_lines():
    lines = iter(["", "  " + TOKEN + "  ", ""])
    assert st.prompt_for_token(lambda _p: next(lines)) == TOKEN


def test_mint_requires_a_terminal(monkeypatch):
    monkeypatch.setattr(sys.stdin, "isatty", lambda: False, raising=False)
    with pytest.raises(st.SetupTokenError, match="interactive terminal"):
        st.mint_setup_token("/bin/claude")


def test_mint_uses_captured_token(monkeypatch):
    monkeypatch.setattr(st.sys.stdin, "isatty", lambda: True, raising=False)
    monkeypatch.setattr(st, "_can_relay", lambda: True)
    calls = []

    def fake_run(argv):
        calls.append(argv)
        return 0, _ink_output(TOKEN, 80)

    monkeypatch.setattr(st, "_run_with_capture", fake_run)
    assert st.mint_setup_token("/opt/claude") == TOKEN
    assert calls == [["/opt/claude", "setup-token"]]


def test_mint_falls_back_to_paste_when_not_found(monkeypatch):
    monkeypatch.setattr(st.sys.stdin, "isatty", lambda: True, raising=False)
    monkeypatch.setattr(st, "_can_relay", lambda: True)
    monkeypatch.setattr(st, "_run_with_capture", lambda argv: (0, "garbled"))
    monkeypatch.setattr(st, "prompt_for_token", lambda **_kw: TOKEN)
    assert st.mint_setup_token("/opt/claude") == TOKEN


def test_mint_failed_command_raises(monkeypatch):
    monkeypatch.setattr(st.sys.stdin, "isatty", lambda: True, raising=False)
    monkeypatch.setattr(st, "_can_relay", lambda: True)
    monkeypatch.setattr(st, "_run_with_capture", lambda argv: (1, "OAuth error"))
    with pytest.raises(st.SetupTokenError, match="status 1"):
        st.mint_setup_token("/opt/claude")


def test_mint_without_relay_runs_inherited_then_prompts(monkeypatch):
    monkeypatch.setattr(st.sys.stdin, "isatty", lambda: True, raising=False)
    monkeypatch.setattr(st, "_can_relay", lambda: False)
    calls = []
    monkeypatch.setattr(st.subprocess, "call", lambda argv: calls.append(argv) or 0)
    monkeypatch.setattr(st, "prompt_for_token", lambda **_kw: " " + TOKEN + " ")
    assert st.mint_setup_token("/opt/claude") == TOKEN
    assert calls == [["/opt/claude", "setup-token"]]


def test_mint_without_relay_rejects_non_token(monkeypatch):
    monkeypatch.setattr(st.sys.stdin, "isatty", lambda: True, raising=False)
    monkeypatch.setattr(st, "_can_relay", lambda: False)
    monkeypatch.setattr(st.subprocess, "call", lambda argv: 0)
    monkeypatch.setattr(st, "prompt_for_token", lambda **_kw: "hello")
    with pytest.raises(st.SetupTokenError, match="sk-ant-oat"):
        st.mint_setup_token("/opt/claude")


def test_find_claude_missing(monkeypatch):
    monkeypatch.setattr(st.shutil, "which", lambda _n: None)
    with pytest.raises(st.SetupTokenError, match="not found on PATH"):
        st.find_claude()


# ---------------------------------------------------------------- CLI


@pytest.fixture
def no_root_guard(monkeypatch):
    monkeypatch.setattr(cli, "_guard_root", lambda _s: None)


def _run_cli(argv, monkeypatch, *, tty=False, inputs=()):
    from claude_swap.switcher import ClaudeAccountSwitcher

    answers = iter(inputs)
    monkeypatch.setattr(sys.stdin, "isatty", lambda: tty, raising=False)
    monkeypatch.setattr("builtins.input", lambda _p="": next(answers))
    with patch.object(sys, "argv", ["cswap", *argv]), patch.object(
        ClaudeAccountSwitcher, "add_account_from_token", return_value="3"
    ) as add, patch.object(
        ClaudeAccountSwitcher, "set_alias", return_value=("3", "work")
    ) as alias:
        cli.main()
    return add, alias


def test_cli_setup_token_with_given_token(no_root_guard, monkeypatch):
    add, alias = _run_cli(
        ["setup-token", TOKEN, "--email", "me@example.com", "--slot", "3"], monkeypatch
    )
    add.assert_called_once_with(token=TOKEN, email="me@example.com", slot=3)
    alias.assert_not_called()


def test_cli_setup_token_new_captures_and_sets_alias(no_root_guard, monkeypatch):
    import claude_swap.setup_token as mod

    monkeypatch.setattr(mod, "mint_setup_token", lambda: TOKEN)
    add, alias = _run_cli(
        ["setup-token", "--new", "--alias", "work"],
        monkeypatch,
        tty=True,
        inputs=["me@example.com"],
    )
    add.assert_called_once_with(token=TOKEN, email="me@example.com", slot=None)
    alias.assert_called_once_with("3", "work")


def test_cli_setup_token_interactive_choice_existing(no_root_guard, monkeypatch):
    import claude_swap.setup_token as mod

    monkeypatch.setattr(mod, "prompt_for_token", lambda **_kw: TOKEN)
    add, _ = _run_cli(["setup-token"], monkeypatch, tty=True, inputs=["2", ""])
    add.assert_called_once_with(token=TOKEN, email=None, slot=None)


def test_cli_setup_token_interactive_default_is_new(no_root_guard, monkeypatch):
    import claude_swap.setup_token as mod

    minted = []
    monkeypatch.setattr(mod, "mint_setup_token", lambda: minted.append(1) or TOKEN)
    add, _ = _run_cli(["setup-token"], monkeypatch, tty=True, inputs=["", ""])
    assert minted == [1]
    add.assert_called_once_with(token=TOKEN, email=None, slot=None)


def test_cli_setup_token_non_tty_without_token_errors(no_root_guard, monkeypatch, capsys):
    with pytest.raises(SystemExit) as exc:
        _run_cli(["setup-token"], monkeypatch, tty=False)
    assert exc.value.code == 2
    assert "no token given" in capsys.readouterr().err


def test_cli_setup_token_rejects_token_with_new(monkeypatch, capsys):
    with pytest.raises(SystemExit) as exc:
        _run_cli(["setup-token", TOKEN, "--new"], monkeypatch)
    assert exc.value.code == 2


def test_cli_setup_token_mint_error_exits_1(no_root_guard, monkeypatch, capsys):
    import claude_swap.setup_token as mod

    def boom():
        raise mod.SetupTokenError("nope")

    monkeypatch.setattr(mod, "mint_setup_token", boom)
    with pytest.raises(SystemExit) as exc:
        _run_cli(["setup-token", "--new"], monkeypatch, tty=True)
    assert exc.value.code == 1
    assert "nope" in capsys.readouterr().err


def test_add_account_from_token_returns_slot(temp_home):
    from claude_swap.switcher import ClaudeAccountSwitcher

    switcher = ClaudeAccountSwitcher()
    assert switcher.add_account_from_token(TOKEN, email="me@example.com") == "1"
    # Re-adding the same identity refreshes in place and reports the same slot.
    assert switcher.add_account_from_token(TOKEN, email="me@example.com") == "1"
