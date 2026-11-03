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


# ---------------------------------------------------------------- renew in place

import json as _json

from claude_swap.credentials import credential_kind

TOKEN2 = "sk-ant-oat01-" + "Zz9_yY-x8" * 10 + "QrsAA"
API_KEY = "sk-ant-api03-" + "k" * 80


def _login_creds(token="sk-ant-oat01-login", refresh="sk-ant-ort01-refresh"):
    return _json.dumps({"claudeAiOauth": {"accessToken": token, "refreshToken": refresh,
                                          "expiresAt": 9_999_999_999_000}})


def test_credential_kind():
    assert credential_kind(_login_creds()) == "login"
    assert credential_kind(_json.dumps({"claudeAiOauth": {"accessToken": TOKEN}})) == "setup_token"
    assert credential_kind(API_KEY) == "api_key"
    assert credential_kind("") is None
    assert credential_kind("{not json") is None
    assert credential_kind(_json.dumps({"claudeAiOauth": {}})) is None


def _switcher_with_org_account(temp_home):
    """A setup-token account in slot 1, then given an organization like a login has."""
    from claude_swap.switcher import ClaudeAccountSwitcher

    sw = ClaudeAccountSwitcher()
    sw.add_account_from_token(TOKEN, email="me@example.com")
    data = sw._get_sequence_data()
    data["accounts"]["1"]["organizationUuid"] = "org-123"
    data["accounts"]["1"]["organizationName"] = "My Org"
    sw._write_json(sw.sequence_file, data)
    sw.set_alias("1", "work")
    return sw


def test_email_match_misses_org_account_and_duplicates(temp_home):
    """The bug renewing hit: matching by email adds a second account."""
    sw = _switcher_with_org_account(temp_home)
    assert sw.add_account_from_token(TOKEN2, email="me@example.com") == "2"
    assert sorted(sw._get_sequence_data()["accounts"]) == ["1", "2"]


def test_replace_renews_the_same_slot(temp_home, capsys):
    sw = _switcher_with_org_account(temp_home)
    assert sw.replace_account_token("1", TOKEN2) == "1"
    data = sw._get_sequence_data()
    assert sorted(data["accounts"]) == ["1"]
    record = data["accounts"]["1"]
    assert record["organizationUuid"] == "org-123"
    assert record.get("alias") == "work"
    stored = _json.loads(sw._read_account_credentials("1", "me@example.com"))
    assert stored["claudeAiOauth"]["accessToken"] == TOKEN2
    assert "Replaced token for Account 1" in capsys.readouterr().out


def test_replace_by_alias_and_stdin(temp_home, monkeypatch):
    import io

    sw = _switcher_with_org_account(temp_home)
    monkeypatch.setattr(sys, "stdin", io.StringIO(TOKEN2 + "\n"))
    assert sw.replace_account_token("work", "-") == "1"


def test_replace_refuses_a_login_account(temp_home):
    from claude_swap.exceptions import ValidationError

    sw = _switcher_with_org_account(temp_home)
    sw._write_account_credentials("1", "me@example.com", _login_creds())
    with pytest.raises(ValidationError, match="Claude Code login"):
        sw.replace_account_token("1", TOKEN2)
    # and nothing was written
    assert credential_kind(sw._read_account_credentials("1", "me@example.com")) == "login"


def test_replace_refuses_kind_changes(temp_home):
    from claude_swap.exceptions import ValidationError
    from claude_swap.switcher import ClaudeAccountSwitcher

    sw = _switcher_with_org_account(temp_home)
    with pytest.raises(ValidationError, match="API key cannot"):
        sw.replace_account_token("1", API_KEY)

    sw2 = ClaudeAccountSwitcher()
    num = sw2.add_account_from_token(API_KEY, email="key@example.com")
    with pytest.raises(ValidationError, match="only another API key"):
        sw2.replace_account_token(num, TOKEN2)
    assert sw2.replace_account_token(num, "sk-ant-api03-" + "n" * 80) == num
    assert sw2._read_account_credentials(num, "key@example.com").endswith("n" * 10)


def test_replace_unknown_account(temp_home):
    from claude_swap.exceptions import ClaudeSwitchError

    sw = _switcher_with_org_account(temp_home)
    with pytest.raises(ClaudeSwitchError):
        sw.replace_account_token("9", TOKEN2)


def test_list_json_reports_credential_kind(temp_home):
    sw = _switcher_with_org_account(temp_home)
    sw.add_account_from_token(API_KEY, email="key@example.com")
    sw._write_account_credentials("1", "me@example.com", _login_creds())
    payload = sw.list_accounts(json_output=True, fetch=set())
    kinds = {row["number"]: row.get("credentialKind") for row in payload["accounts"]}
    assert kinds == {1: "login", 2: "api_key"}


def test_cli_setup_token_replace_dispatch(no_root_guard, monkeypatch):
    from claude_swap.switcher import ClaudeAccountSwitcher

    monkeypatch.setattr(sys.stdin, "isatty", lambda: False, raising=False)
    with patch.object(sys, "argv", ["cswap", "setup-token", "-", "--replace", "3"]), \
            patch.object(ClaudeAccountSwitcher, "replace_account_token", return_value="3") as rep, \
            patch.object(ClaudeAccountSwitcher, "add_account_from_token") as add:
        cli.main()
    rep.assert_called_once_with("3", "-")
    add.assert_not_called()


def test_cli_setup_token_replace_rejects_label_flags(monkeypatch, capsys):
    with patch.object(sys, "argv", ["cswap", "setup-token", "-", "--replace", "3", "--email", "a@b.co"]):
        with pytest.raises(SystemExit) as exc:
            cli.main()
    assert exc.value.code == 2
    assert "--replace" in capsys.readouterr().err


def test_cli_remove_yes_skips_prompt(no_root_guard, monkeypatch):
    from claude_swap.switcher import ClaudeAccountSwitcher

    monkeypatch.setattr(cli, "ClaudeAccountSwitcher", ClaudeAccountSwitcher)
    monkeypatch.setattr(ClaudeAccountSwitcher, "_is_running_in_container", lambda self: True)
    monkeypatch.setattr(cli.os, "geteuid", lambda: 1000, raising=False)
    with patch.object(sys, "argv", ["cswap", "remove", "3", "--yes"]), \
            patch.object(ClaudeAccountSwitcher, "remove_account") as rm:
        cli.main()
    rm.assert_called_once_with("3", assume_yes=True)


def test_cli_yes_only_with_remove(capsys):
    with patch.object(sys, "argv", ["cswap", "list", "--yes"]):
        with pytest.raises(SystemExit) as exc:
            cli.main()
    assert exc.value.code == 2
