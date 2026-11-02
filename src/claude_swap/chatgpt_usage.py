"""Read ChatGPT plan usage (the Codex rate limits) for the local Codex login.

ChatGPT itself has no public usage API. What *is* readable is the plan's
Codex quota — the same 5-hour / weekly windows the Codex CLI shows in
``/status`` — from the endpoint the Codex CLI calls for it::

    GET https://chatgpt.com/backend-api/wham/usage
    Authorization: Bearer <access_token>
    chatgpt-account-id: <account_id>

(``codex-rs/backend-client``: ``rate_limit_status_url`` with the ChatGPT path
style; the response is ``RateLimitStatusPayload`` from
``codex-backend-openapi-models``.)

Credentials come from Codex's own file store, ``$CODEX_HOME/auth.json``
(default ``~/.codex/auth.json``), written by ``codex login`` with "Sign in with
ChatGPT". This module only *reads* that file: it never refreshes the token,
because the refresh token is Codex's and rotating it here would sign the Codex
CLI out. An expired access token is reported, and running ``codex`` once
refreshes it.
"""

from __future__ import annotations

import base64
import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from claude_swap import __version__
from claude_swap.exceptions import ClaudeSwitchError

USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
ACCOUNT_ID_HEADER = "chatgpt-account-id"
_ID_TOKEN_AUTH_CLAIM = "https://api.openai.com/auth"
_ID_TOKEN_PROFILE_CLAIM = "https://api.openai.com/profile"


class ChatGPTUsageError(ClaudeSwitchError):
    """ChatGPT usage could not be read (no login, rejected token, network…)."""


@dataclass(frozen=True)
class CodexAuth:
    """The parts of ``auth.json`` the usage request needs (never the refresh token)."""

    access_token: str
    account_id: str | None
    email: str | None
    plan: str | None
    expires_at: float | None  # access-token ``exp`` (epoch seconds), when readable
    path: Path

    def is_expired(self, now: float | None = None) -> bool:
        if self.expires_at is None:
            return False
        return (time.time() if now is None else now) >= self.expires_at


@dataclass(frozen=True)
class UsageWindow:
    label: str  # "5h", "7d", … derived from the window length
    used_percent: float
    window_seconds: int | None
    reset_at: float | None  # epoch seconds

    def to_json(self) -> dict[str, Any]:
        return {
            "label": self.label,
            "usedPercent": self.used_percent,
            "windowSeconds": self.window_seconds,
            "resetsAt": _iso(self.reset_at),
        }


@dataclass(frozen=True)
class LimitGroup:
    """One rate-limit bucket: the main Codex limit or an additional one."""

    name: str
    allowed: bool | None
    limit_reached: bool | None
    windows: list[UsageWindow] = field(default_factory=list)

    def to_json(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "allowed": self.allowed,
            "limitReached": self.limit_reached,
            "windows": [w.to_json() for w in self.windows],
        }


@dataclass(frozen=True)
class ChatGPTUsage:
    plan: str | None
    email: str | None
    limits: list[LimitGroup]
    credits: dict[str, Any] | None
    fetched_at: float

    def to_json(self) -> dict[str, Any]:
        return {
            "provider": "chatgpt",
            "email": self.email,
            "plan": self.plan,
            "limits": [g.to_json() for g in self.limits],
            "credits": self.credits,
            "fetchedAt": _iso(self.fetched_at),
        }


# ---------------------------------------------------------------- auth.json


def codex_home() -> Path:
    """``$CODEX_HOME`` when set, else ``~/.codex`` (the Codex CLI's default)."""
    env = os.environ.get("CODEX_HOME", "").strip()
    return Path(env).expanduser() if env else Path.home() / ".codex"


def _jwt_claims(token: str | None) -> dict[str, Any]:
    """Decode a JWT's payload without verifying it (display metadata only)."""
    if not token or token.count(".") < 2:
        return {}
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    try:
        data = json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
    except (ValueError, UnicodeError):
        return {}
    return data if isinstance(data, dict) else {}


def load_codex_auth(home: Path | None = None) -> CodexAuth:
    """Read the ChatGPT login from Codex's ``auth.json``.

    Raises :class:`ChatGPTUsageError` with a user-facing hint when there is no
    file, when Codex is signed in with an API key instead of ChatGPT, or when
    the file cannot be parsed.
    """
    path = (home or codex_home()) / "auth.json"
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise ChatGPTUsageError(
            f"No Codex login found at {path}. Sign in with `codex login` "
            "(choose 'Sign in with ChatGPT'). If Codex keeps its login in the "
            "OS keyring (cli_auth_credentials_store), cswap cannot read it."
        ) from None
    except OSError as e:
        raise ChatGPTUsageError(f"Could not read {path}: {e}") from None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        raise ChatGPTUsageError(f"{path} is not valid JSON") from None
    if not isinstance(data, dict):
        raise ChatGPTUsageError(f"{path} has an unexpected format")

    tokens = data.get("tokens")
    access = tokens.get("access_token") if isinstance(tokens, dict) else None
    if not isinstance(access, str) or not access:
        if data.get("OPENAI_API_KEY"):
            raise ChatGPTUsageError(
                "Codex is signed in with an OpenAI API key. ChatGPT plan usage "
                "is only available for a 'Sign in with ChatGPT' login "
                "(`codex login`)."
            )
        raise ChatGPTUsageError(
            f"{path} holds no ChatGPT access token. Sign in with `codex login`."
        )

    id_claims = _jwt_claims(tokens.get("id_token"))
    auth_claims = id_claims.get(_ID_TOKEN_AUTH_CLAIM)
    auth_claims = auth_claims if isinstance(auth_claims, dict) else {}
    profile = id_claims.get(_ID_TOKEN_PROFILE_CLAIM)
    profile = profile if isinstance(profile, dict) else {}

    account_id = tokens.get("account_id") or auth_claims.get("chatgpt_account_id")
    email = id_claims.get("email") or profile.get("email")
    plan = auth_claims.get("chatgpt_plan_type")
    exp = _jwt_claims(access).get("exp")
    return CodexAuth(
        access_token=access,
        account_id=account_id if isinstance(account_id, str) and account_id else None,
        email=email if isinstance(email, str) else None,
        plan=plan if isinstance(plan, str) else None,
        expires_at=float(exp) if isinstance(exp, (int, float)) else None,
        path=path,
    )


# ---------------------------------------------------------------- fetch/parse


def fetch_usage_payload(
    auth: CodexAuth,
    *,
    timeout_s: float = 10.0,
    urlopen: Callable[..., Any] | None = None,
) -> dict[str, Any]:
    """GET the usage payload. Raises :class:`ChatGPTUsageError` on any failure."""
    headers = {
        "Authorization": f"Bearer {auth.access_token}",
        "Accept": "application/json",
        "User-Agent": f"claude-swap/{__version__}",
    }
    if auth.account_id:
        headers[ACCOUNT_ID_HEADER] = auth.account_id
    req = urllib.request.Request(USAGE_URL, headers=headers)
    opener = urlopen or urllib.request.urlopen
    try:
        with opener(req, timeout=timeout_s) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            hint = (
                "the access token has expired"
                if auth.is_expired()
                else "the access token was rejected"
            )
            raise ChatGPTUsageError(
                f"ChatGPT usage request failed (HTTP {e.code}): {hint}. "
                "Run `codex` once so it refreshes its login, then retry."
            ) from None
        if e.code == 429:
            raise ChatGPTUsageError(
                "ChatGPT usage request was rate limited (HTTP 429); try again later."
            ) from None
        raise ChatGPTUsageError(f"ChatGPT usage request failed (HTTP {e.code}).") from None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        reason = getattr(e, "reason", e)
        raise ChatGPTUsageError(f"Could not reach chatgpt.com: {reason}") from None
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise ChatGPTUsageError("ChatGPT usage response was not JSON.") from None
    if not isinstance(data, dict):
        raise ChatGPTUsageError("ChatGPT usage response had an unexpected shape.")
    return data


def window_label(seconds: int | None) -> str:
    """``18000`` → ``"5h"``, ``604800`` → ``"7d"``; ``"?"`` when unknown."""
    if not seconds or seconds <= 0:
        return "?"
    if seconds % 86400 == 0:
        return f"{seconds // 86400}d"
    if seconds % 3600 == 0:
        return f"{seconds // 3600}h"
    if seconds % 60 == 0:
        return f"{seconds // 60}m"
    return f"{seconds}s"


def _num(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _parse_window(raw: Any, now: float) -> UsageWindow | None:
    if not isinstance(raw, dict):
        return None
    used = _num(raw.get("used_percent"))
    if used is None:
        return None
    seconds = _num(raw.get("limit_window_seconds"))
    reset_at = _num(raw.get("reset_at"))
    if reset_at is None:
        after = _num(raw.get("reset_after_seconds"))
        reset_at = now + after if after is not None else None
    win_s = int(seconds) if seconds is not None else None
    return UsageWindow(
        label=window_label(win_s),
        used_percent=used,
        window_seconds=win_s,
        reset_at=reset_at,
    )


def _parse_limit(name: str, raw: Any, now: float) -> LimitGroup | None:
    if not isinstance(raw, dict):
        return None
    windows = [
        w
        for w in (
            _parse_window(raw.get("primary_window"), now),
            _parse_window(raw.get("secondary_window"), now),
        )
        if w is not None
    ]
    allowed = raw.get("allowed")
    reached = raw.get("limit_reached")
    return LimitGroup(
        name=name,
        allowed=allowed if isinstance(allowed, bool) else None,
        limit_reached=reached if isinstance(reached, bool) else None,
        windows=windows,
    )


def parse_usage(
    payload: dict[str, Any], auth: CodexAuth | None = None, now: float | None = None
) -> ChatGPTUsage:
    """Turn the ``/wham/usage`` payload into :class:`ChatGPTUsage`."""
    now = time.time() if now is None else now
    limits: list[LimitGroup] = []
    main = _parse_limit("Codex", payload.get("rate_limit"), now)
    if main is not None:
        limits.append(main)
    for extra in payload.get("additional_rate_limits") or []:
        if not isinstance(extra, dict):
            continue
        name = extra.get("limit_name") or extra.get("metered_feature") or "Additional"
        group = _parse_limit(str(name), extra.get("rate_limit"), now)
        if group is not None:
            limits.append(group)

    credits_raw = payload.get("credits")
    credits = None
    if isinstance(credits_raw, dict):
        credits = {
            "hasCredits": credits_raw.get("has_credits"),
            "unlimited": credits_raw.get("unlimited"),
            "balance": credits_raw.get("balance"),
        }

    plan = payload.get("plan_type")
    return ChatGPTUsage(
        plan=plan if isinstance(plan, str) else (auth.plan if auth else None),
        email=auth.email if auth else None,
        limits=limits,
        credits=credits,
        fetched_at=now,
    )


def get_chatgpt_usage(
    home: Path | None = None,
    *,
    timeout_s: float = 10.0,
    urlopen: Callable[..., Any] | None = None,
) -> ChatGPTUsage:
    """Load the Codex login and fetch its ChatGPT plan usage."""
    auth = load_codex_auth(home)
    payload = fetch_usage_payload(auth, timeout_s=timeout_s, urlopen=urlopen)
    return parse_usage(payload, auth)


# ---------------------------------------------------------------- rendering


def _iso(ts: float | None) -> str | None:
    if ts is None:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def format_window_line(window: UsageWindow, width: int = 3) -> str:
    """``"5h:  23%   resets 20:39         in 2h 14m"`` (the ``cswap list`` layout)."""
    from claude_swap import oauth

    label = f"{window.label}:"
    body = f"{window.used_percent:>3.0f}%"
    if window.reset_at is not None:
        countdown, clock = oauth.format_reset(_iso(window.reset_at))
        body += f"   resets {clock:<12}  in {countdown}"
    return f"{label:<{width + 1}} {body}"


def format_usage_lines(usage: ChatGPTUsage) -> list[str]:
    """Plain-text lines (no colour) for the CLI and the menu bar."""
    lines: list[str] = []
    multiple = len(usage.limits) > 1
    for group in usage.limits:
        prefix = "  " if multiple else ""
        if multiple:
            lines.append(group.name)
        if not group.windows:
            lines.append(f"{prefix}no usage windows reported")
        width = max((len(w.label) for w in group.windows), default=2)
        for w in group.windows:
            lines.append(prefix + format_window_line(w, width))
        if group.limit_reached:
            lines.append(f"{prefix}(limit reached)")
    if not usage.limits:
        lines.append("no rate limits reported for this plan")
    credits = usage.credits
    if credits and credits.get("unlimited"):
        lines.append("credits: unlimited")
    elif credits and credits.get("balance") not in (None, ""):
        lines.append(f"credits: {credits['balance']}")
    return lines


def tightest_percent(usage: ChatGPTUsage) -> float | None:
    """Highest used percentage across every window (for compact titles)."""
    pcts = [w.used_percent for g in usage.limits for w in g.windows]
    return max(pcts) if pcts else None
