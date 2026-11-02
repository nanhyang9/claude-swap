"""ChatGPT (Codex) plan usage: auth.json parsing, the usage request, rendering."""

from __future__ import annotations

import base64
import io
import json
import sys
import urllib.error
from pathlib import Path
from unittest.mock import patch

import pytest

from claude_swap import chatgpt_usage as cu
from claude_swap import cli
from claude_swap.menubar import MenuBarSettings, chatgpt_menu_lines, fetch_chatgpt_for_menu


def _jwt(claims: dict) -> str:
    def enc(obj) -> str:
        return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")

    return f"{enc({'alg': 'none'})}.{enc(claims)}.sig"


def _write_auth(home: Path, *, exp: int = 4_000_000_000, **overrides) -> Path:
    data = {
        "OPENAI_API_KEY": None,
        "tokens": {
            "id_token": _jwt({
                "email": "me@example.com",
                "https://api.openai.com/auth": {
                    "chatgpt_plan_type": "plus",
                    "chatgpt_account_id": "acct-from-claims",
                },
            }),
            "access_token": _jwt({"exp": exp}),
            "refresh_token": "rt-never-sent",
            "account_id": "acct-123",
        },
        "last_refresh": "2026-11-01T00:00:00Z",
    }
    data.update(overrides)
    home.mkdir(parents=True, exist_ok=True)
    path = home / "auth.json"
    path.write_text(json.dumps(data))
    return path


PAYLOAD = {
    "plan_type": "pro",
    "rate_limit": {
        "allowed": True,
        "limit_reached": False,
        "primary_window": {
            "used_percent": 23,
            "limit_window_seconds": 18000,
            "reset_after_seconds": 3600,
            "reset_at": 1_900_000_000,
        },
        "secondary_window": {
            "used_percent": 61,
            "limit_window_seconds": 604800,
            "reset_after_seconds": 86400,
            "reset_at": 1_900_100_000,
        },
    },
    "credits": {"has_credits": True, "unlimited": False, "balance": "12.5"},
    "additional_rate_limits": [
        {
            "limit_name": "GPT-5-Codex-Spark",
            "metered_feature": "codex_spark",
            "rate_limit": {
                "allowed": False,
                "limit_reached": True,
                "primary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 60,
                    "reset_at": 1_900_000_100,
                },
                "secondary_window": None,
            },
        }
    ],
}


class _Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _fake_urlopen(body: bytes, seen: list):
    def urlopen(req, timeout=None):
        seen.append((req, timeout))
        return _Resp(body)

    return urlopen


# ---------------------------------------------------------------- auth.json


def test_codex_home_honours_env(monkeypatch, tmp_path):
    monkeypatch.setenv("CODEX_HOME", str(tmp_path / "cx"))
    assert cu.codex_home() == tmp_path / "cx"
    monkeypatch.delenv("CODEX_HOME")
    assert cu.codex_home() == Path.home() / ".codex"


def test_load_codex_auth_reads_tokens_and_claims(tmp_path):
    _write_auth(tmp_path)
    auth = cu.load_codex_auth(tmp_path)
    assert auth.account_id == "acct-123"  # tokens.account_id wins over the claim
    assert auth.email == "me@example.com"
    assert auth.plan == "plus"
    assert auth.expires_at == 4_000_000_000
    assert not auth.is_expired(now=1)
    assert auth.is_expired(now=4_000_000_001)


def test_load_codex_auth_falls_back_to_claim_account_id(tmp_path):
    path = _write_auth(tmp_path)
    data = json.loads(path.read_text())
    del data["tokens"]["account_id"]
    path.write_text(json.dumps(data))
    assert cu.load_codex_auth(tmp_path).account_id == "acct-from-claims"


def test_load_codex_auth_missing_file(tmp_path):
    with pytest.raises(cu.ChatGPTUsageError, match="codex login"):
        cu.load_codex_auth(tmp_path)


def test_load_codex_auth_api_key_login(tmp_path):
    _write_auth(tmp_path, OPENAI_API_KEY="sk-proj-x", tokens=None)
    with pytest.raises(cu.ChatGPTUsageError, match="API key"):
        cu.load_codex_auth(tmp_path)


def test_load_codex_auth_bad_json(tmp_path):
    (tmp_path / "auth.json").write_text("{nope")
    with pytest.raises(cu.ChatGPTUsageError, match="not valid JSON"):
        cu.load_codex_auth(tmp_path)


# ---------------------------------------------------------------- request


def test_fetch_sends_bearer_and_account_header_only(tmp_path):
    _write_auth(tmp_path)
    auth = cu.load_codex_auth(tmp_path)
    seen: list = []
    payload = cu.fetch_usage_payload(
        auth, urlopen=_fake_urlopen(json.dumps(PAYLOAD).encode(), seen)
    )
    assert payload["plan_type"] == "pro"
    req, timeout = seen[0]
    assert req.full_url == "https://chatgpt.com/backend-api/wham/usage"
    assert req.get_method() == "GET"
    headers = {k.lower(): v for k, v in req.header_items()}
    assert headers["authorization"] == f"Bearer {auth.access_token}"
    assert headers["chatgpt-account-id"] == "acct-123"
    assert "rt-never-sent" not in json.dumps(headers)
    assert timeout == 10.0


@pytest.mark.parametrize("code,match", [(401, "codex"), (403, "codex"), (429, "429"), (500, "500")])
def test_fetch_http_errors(tmp_path, code, match):
    _write_auth(tmp_path)
    auth = cu.load_codex_auth(tmp_path)

    def urlopen(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, code, "x", {}, None)

    with pytest.raises(cu.ChatGPTUsageError, match=match):
        cu.fetch_usage_payload(auth, urlopen=urlopen)


def test_fetch_expired_token_says_so(tmp_path):
    _write_auth(tmp_path, exp=1)
    auth = cu.load_codex_auth(tmp_path)

    def urlopen(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 401, "x", {}, None)

    with pytest.raises(cu.ChatGPTUsageError, match="expired"):
        cu.fetch_usage_payload(auth, urlopen=urlopen)


def test_fetch_network_error(tmp_path):
    _write_auth(tmp_path)

    def urlopen(req, timeout=None):
        raise urllib.error.URLError("no route")

    with pytest.raises(cu.ChatGPTUsageError, match="no route"):
        cu.fetch_usage_payload(cu.load_codex_auth(tmp_path), urlopen=urlopen)


def test_fetch_non_json(tmp_path):
    _write_auth(tmp_path)
    with pytest.raises(cu.ChatGPTUsageError, match="not JSON"):
        cu.fetch_usage_payload(
            cu.load_codex_auth(tmp_path), urlopen=_fake_urlopen(b"<html>", [])
        )


# ---------------------------------------------------------------- parsing


def test_window_label():
    assert cu.window_label(18000) == "5h"
    assert cu.window_label(604800) == "7d"
    assert cu.window_label(1800) == "30m"
    assert cu.window_label(None) == "?"


def test_parse_usage_main_and_additional_limits():
    usage = cu.parse_usage(PAYLOAD, now=1_000)
    assert usage.plan == "pro"
    main, extra = usage.limits
    assert main.name == "Codex"
    assert [(w.label, w.used_percent) for w in main.windows] == [("5h", 23), ("7d", 61)]
    assert main.windows[0].reset_at == 1_900_000_000
    assert extra.name == "GPT-5-Codex-Spark"
    assert extra.limit_reached is True
    assert [w.label for w in extra.windows] == ["5h"]
    assert usage.credits == {"hasCredits": True, "unlimited": False, "balance": "12.5"}
    assert cu.tightest_percent(usage) == 100


def test_parse_usage_reset_after_seconds_fallback_and_nulls():
    payload = {
        "plan_type": "free",
        "rate_limit": {
            "allowed": True,
            "limit_reached": False,
            "primary_window": {
                "used_percent": 5,
                "limit_window_seconds": 18000,
                "reset_after_seconds": 120,
            },
            "secondary_window": None,
        },
        "credits": None,
    }
    usage = cu.parse_usage(payload, now=1_000)
    assert usage.limits[0].windows[0].reset_at == 1_120
    assert usage.credits is None


def test_parse_usage_plan_falls_back_to_token_claim(tmp_path):
    _write_auth(tmp_path)
    auth = cu.load_codex_auth(tmp_path)
    usage = cu.parse_usage({"rate_limit": None}, auth, now=1)
    assert usage.plan == "plus"
    assert usage.email == "me@example.com"
    assert usage.limits == []
    assert cu.format_usage_lines(usage) == ["no rate limits reported for this plan"]


def test_format_usage_lines_and_json():
    usage = cu.parse_usage(PAYLOAD, now=1_000)
    lines = cu.format_usage_lines(usage)
    assert lines[0] == "Codex"
    assert lines[1].startswith("  5h:  23%   resets ")
    assert lines[2].startswith("  7d:  61%   resets ")
    assert "GPT-5-Codex-Spark" in lines
    assert "  (limit reached)" in lines
    assert lines[-1] == "credits: 12.5"
    blob = usage.to_json()
    assert blob["provider"] == "chatgpt"
    assert blob["limits"][0]["windows"][0]["resetsAt"].startswith("2030-")
    json.dumps(blob)  # serialisable


# ---------------------------------------------------------------- CLI


def test_cli_chatgpt_json(tmp_path, capsys, monkeypatch):
    _write_auth(tmp_path)
    monkeypatch.setattr(
        cu.urllib.request, "urlopen", _fake_urlopen(json.dumps(PAYLOAD).encode(), [])
    )
    with patch.object(sys, "argv", ["cswap", "chatgpt", "--json", "--codex-home", str(tmp_path)]):
        cli.main()
    out = json.loads(capsys.readouterr().out)
    assert out["plan"] == "pro"
    assert out["email"] == "me@example.com"
    assert out["limits"][0]["windows"][1]["usedPercent"] == 61


def test_cli_chatgpt_text(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("CODEX_HOME", str(tmp_path))
    _write_auth(tmp_path)
    monkeypatch.setattr(
        cu.urllib.request, "urlopen", _fake_urlopen(json.dumps(PAYLOAD).encode(), [])
    )
    with patch.object(sys, "argv", ["cswap", "codex"]):
        cli.main()
    out = capsys.readouterr().out
    assert "me@example.com" in out
    assert "5h:  23%" in out


def test_cli_chatgpt_error_exits_1(tmp_path, capsys):
    with patch.object(sys, "argv", ["cswap", "chatgpt", "--codex-home", str(tmp_path)]):
        with pytest.raises(SystemExit) as exc:
            cli.main()
    assert exc.value.code == 1
    assert "codex login" in capsys.readouterr().err


def test_cli_chatgpt_error_json_envelope(tmp_path, capsys):
    with patch.object(
        sys, "argv", ["cswap", "chatgpt", "--json", "--codex-home", str(tmp_path)]
    ):
        with pytest.raises(SystemExit):
            cli.main()
    out = json.loads(capsys.readouterr().out)
    assert "codex login" in json.dumps(out)


# ---------------------------------------------------------------- menu bar


def test_menubar_section_hidden_without_codex_login(tmp_path):
    assert fetch_chatgpt_for_menu(tmp_path) is None
    assert chatgpt_menu_lines(None) == []


def test_menubar_section_shows_error_text(tmp_path):
    _write_auth(tmp_path, OPENAI_API_KEY="sk-x", tokens=None)
    result = fetch_chatgpt_for_menu(tmp_path)
    assert isinstance(result, str) and "API key" in result
    assert len(result) <= 90
    assert chatgpt_menu_lines(result)[0] == "ChatGPT"


def test_menubar_section_lines(tmp_path):
    usage = cu.parse_usage(PAYLOAD, now=1_000)
    lines = chatgpt_menu_lines(usage)
    assert lines[0] == "ChatGPT · ChatGPT [pro]"
    assert any("5h:  23%" in line for line in lines)


def test_menubar_setting_defaults_on_and_round_trips(tmp_path):
    path = tmp_path / "s.json"
    assert MenuBarSettings().show_chatgpt is True
    MenuBarSettings(show_chatgpt=False).save(path)
    assert MenuBarSettings.load(path).show_chatgpt is False
