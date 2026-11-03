"""The JSON contract the native macOS app (macos/CswapBar) decodes.

The Swift app reads `cswap list --json`, `cswap chatgpt --json` and the error
envelope. Its Decodable structs (macos/CswapBar/Sources/CswapBar/Models.swift)
fail the whole decode when a *required* field is missing or has another type,
so these tests pin exactly those fields. Optional fields may come and go.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from claude_swap import chatgpt_usage as cu
from claude_swap.json_output import account_row, error_envelope
from claude_swap.exceptions import ClaudeSwitchError

MODELS_SWIFT = (
    Path(__file__).resolve().parent.parent
    / "macos" / "CswapBar" / "Sources" / "CswapBar" / "Models.swift"
)

# Swift's ISODate.parse: strips fractional seconds, then RFC 3339 with "Z" or ±hh:mm.
_SWIFT_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$")


def _swift_parses(text: str) -> bool:
    return bool(_SWIFT_ISO.match(re.sub(r"\.\d+", "", text)))


def _is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _is_num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _check_window(w: dict) -> None:
    assert _is_num(w["pct"])
    if w.get("resetsAt") is not None:
        assert _swift_parses(w["resetsAt"]), w["resetsAt"]


def _check_account(row: dict) -> None:
    assert _is_int(row["number"])
    assert isinstance(row["email"], str)
    assert isinstance(row["active"], bool)
    assert isinstance(row["usageStatus"], str)
    for key in ("usage", "lastGoodUsage"):
        usage = row.get(key)
        if usage is None:
            continue
        for name in ("fiveHour", "sevenDay"):
            if name in usage:
                _check_window(usage[name])
        for w in usage.get("scoped", []):
            _check_window(w)
            assert isinstance(w["name"], str)
    if "alias" in row:
        assert isinstance(row["alias"], str)
    if "disabled" in row:
        assert isinstance(row["disabled"], bool)


USAGE = {
    "five_hour": {"pct": 25.0, "resets_at": "2026-06-22T23:29:59.512340+00:00"},
    "seven_day": {"pct": 61.0, "resets_at": "2026-06-26T17:59:59Z"},
    "scoped": [{"name": "Fable", "pct": 100.0, "resets_at": "2026-06-26T17:59:59+00:00"}],
}


def test_account_rows_match_swift_account():
    rows = [
        account_row(1, "a@example.com", "", "", True, USAGE, usage_fetched_at=1_750_000_000.0,
                    usage_age_s=12.0, alias="work", disabled=True),
        account_row(2, "b@example.com", "Org", "org-uuid", False, "token expired",
                    usage_fetched_at=1_750_000_000.0, last_good_usage=USAGE),
        account_row(3, "c@example.com", "", "", False, None, last_error="http-429"),
    ]
    payload = json.loads(json.dumps({"activeAccountNumber": 1, "accounts": rows}))
    for row in payload["accounts"]:
        _check_account(row)
    assert payload["accounts"][1]["usage"] is None
    assert "lastGoodUsage" in payload["accounts"][1]


def test_usage_statuses_are_ones_the_app_names():
    swift = MODELS_SWIFT.read_text(encoding="utf-8")
    for entry in ("token expired", "api key", "keychain unavailable", "re-login needed",
                  "foreign credential", "no credentials", None):
        status = account_row(1, "a@example.com", "", "", False, entry)["usageStatus"]
        if status != "unavailable":  # the Swift `default:` branch covers it
            assert f'case "{status}"' in swift, status


def test_chatgpt_json_matches_swift_chatgpt_usage():
    payload = {
        "plan_type": "plus",
        "rate_limit": {
            "allowed": True,
            "limit_reached": False,
            "primary_window": {"used_percent": 23, "limit_window_seconds": 18000,
                               "reset_after_seconds": 60, "reset_at": 1_900_000_000},
            "secondary_window": {"used_percent": 61.5, "limit_window_seconds": 604800,
                                 "reset_after_seconds": 60, "reset_at": 1_900_100_000},
        },
        "credits": {"has_credits": True, "unlimited": False, "balance": "3.5"},
    }
    out = json.loads(json.dumps(cu.parse_usage(payload, now=1_000.5).to_json()))
    assert isinstance(out["limits"], list)
    for limit in out["limits"]:
        assert isinstance(limit["name"], str)
        assert isinstance(limit["windows"], list)
        for w in limit["windows"]:
            assert isinstance(w["label"], str)
            assert _is_num(w["usedPercent"])
            assert w["windowSeconds"] is None or _is_int(w["windowSeconds"])
            assert w["resetsAt"] is None or _swift_parses(w["resetsAt"])
    credits = out["credits"]
    assert credits["balance"] is None or isinstance(credits["balance"], str)
    assert out["email"] is None or isinstance(out["email"], str)
    assert out["plan"] is None or isinstance(out["plan"], str)


def test_error_envelope_matches_swift_cli_error_envelope():
    env = error_envelope(ClaudeSwitchError("boom"))
    assert isinstance(env["error"]["message"], str)
    assert env["error"]["message"] == "boom"


def test_swift_models_declare_the_pinned_fields():
    swift = MODELS_SWIFT.read_text(encoding="utf-8")
    for decl in (
        "let number: Int", "let email: String", "let active: Bool",
        "let usageStatus: String", "let accounts: [Account]", "let pct: Double",
        "let label: String", "let usedPercent: Double", "let windows: [ChatGPTWindow]",
        "let limits: [ChatGPTLimit]", "let message: String",
    ):
        assert decl in swift, decl


def test_credential_kinds_are_ones_the_app_knows():
    import json as _json

    from claude_swap.credentials import credential_kind

    swift = MODELS_SWIFT.read_text(encoding="utf-8")
    views = (MODELS_SWIFT.parent / "Views.swift").read_text(encoding="utf-8")
    samples = [
        _json.dumps({"claudeAiOauth": {"accessToken": "a", "refreshToken": "r"}}),
        _json.dumps({"claudeAiOauth": {"accessToken": "a"}}),
        "sk-ant-api03-" + "k" * 40,
    ]
    for creds in samples:
        kind = credential_kind(creds)
        assert kind in ("login", "setup_token", "api_key")
        assert f'"{kind}"' in swift + views, kind
    row = account_row(1, "a@example.com", "", "", False, None,
                      last_error="http-403", credential_kind="setup_token")
    assert row["credentialKind"] == "setup_token"
    assert row["usageError"] == "http-403"
    assert "let credentialKind: String?" in swift
    assert "let usageError: String?" in swift
