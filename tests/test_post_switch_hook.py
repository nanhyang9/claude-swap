# 전환 후 훅 설정과 실행을 검증한다.
"""Tests for the ``hooks.postSwitch`` setting and its background runner."""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from unittest.mock import patch

import pytest

from claude_swap.hooks import run_post_switch_hook
from claude_swap.settings import (
    HookSettings,
    effective_settings,
    load_hook_settings,
    set_setting,
    settings_path,
)
from claude_swap.switcher import ClaudeAccountSwitcher


def _op(to_number=2, to_email="b@example.com", from_ref=None):
    return {
        "from": from_ref,
        "to": {"number": to_number, "email": to_email},
        "warnings": [],
    }


class TestLoadHookSettings:
    def test_missing_file_gives_none(self, tmp_path: Path):
        assert load_hook_settings(tmp_path) == HookSettings()
        assert load_hook_settings(tmp_path).post_switch is None

    def test_normal_string_is_stripped(self, tmp_path: Path):
        settings_path(tmp_path).write_text(
            json.dumps({"hooks": {"postSwitch": "  echo hi  "}})
        )
        assert load_hook_settings(tmp_path).post_switch == "echo hi"

    def test_empty_and_non_string_give_none(self, tmp_path: Path):
        settings_path(tmp_path).write_text(
            json.dumps({"hooks": {"postSwitch": "   "}})
        )
        assert load_hook_settings(tmp_path).post_switch is None
        settings_path(tmp_path).write_text(
            json.dumps({"hooks": {"postSwitch": 42}})
        )
        assert load_hook_settings(tmp_path).post_switch is None

    def test_non_dict_section_gives_none(self, tmp_path: Path):
        settings_path(tmp_path).write_text(json.dumps({"hooks": ["echo hi"]}))
        assert load_hook_settings(tmp_path).post_switch is None

    def test_set_and_load_through_config(self, tmp_path: Path):
        set_setting(tmp_path, "hooks.postSwitch", "echo hi")
        assert load_hook_settings(tmp_path).post_switch == "echo hi"
        by_key = {
            spec.dotted: is_set for spec, _, is_set in effective_settings(tmp_path)
        }
        assert by_key["hooks.postSwitch"] is True


class TestRunPostSwitchHook:
    def test_no_setting_does_not_spawn(self, tmp_path: Path):
        with patch("claude_swap.hooks.subprocess.Popen") as popen:
            run_post_switch_hook(tmp_path, _op())
        popen.assert_not_called()

    def test_spawns_with_env(self, tmp_path: Path):
        set_setting(tmp_path, "hooks.postSwitch", "echo hi")
        with patch("claude_swap.hooks.subprocess.Popen") as popen:
            run_post_switch_hook(
                tmp_path,
                _op(from_ref={"number": 1, "email": "a@example.com"}),
            )
        popen.assert_called_once()
        args, kwargs = popen.call_args
        assert args[0] == "echo hi"
        assert kwargs["shell"] is True
        env = kwargs["env"]
        assert env["CSWAP_TO_ACCOUNT"] == "2"
        assert env["CSWAP_TO_EMAIL"] == "b@example.com"
        assert env["CSWAP_FROM_ACCOUNT"] == "1"
        assert env["CSWAP_FROM_EMAIL"] == "a@example.com"

    def test_missing_from_becomes_empty(self, tmp_path: Path):
        set_setting(tmp_path, "hooks.postSwitch", "echo hi")
        with patch("claude_swap.hooks.subprocess.Popen") as popen:
            run_post_switch_hook(tmp_path, _op(from_ref=None))
        env = popen.call_args.kwargs["env"]
        assert env["CSWAP_FROM_ACCOUNT"] == ""
        assert env["CSWAP_FROM_EMAIL"] == ""
        assert env["CSWAP_TO_ACCOUNT"] == "2"
        assert env["CSWAP_TO_EMAIL"] == "b@example.com"

    def test_popen_oserror_is_swallowed(self, tmp_path: Path):
        set_setting(tmp_path, "hooks.postSwitch", "echo hi")
        with patch(
            "claude_swap.hooks.subprocess.Popen", side_effect=OSError("boom")
        ):
            run_post_switch_hook(tmp_path, _op())  # must not raise


@pytest.mark.skipif(os.name == "nt", reason="uses POSIX shell syntax")
def test_hook_really_runs_and_receives_env(tmp_path: Path):
    out = tmp_path / "out"
    command = (
        f"printf '%s %s' \"$CSWAP_TO_ACCOUNT\" \"$CSWAP_TO_EMAIL\" > {out}"
    )
    set_setting(tmp_path, "hooks.postSwitch", command)
    run_post_switch_hook(tmp_path, _op())
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if out.exists() and out.read_text():
            break
        time.sleep(0.05)
    assert out.read_text() == "2 b@example.com"


class TestSwitcherWrapper:
    def test_wrapper_fires_hook_after_core(self, tmp_path: Path):
        switcher = ClaudeAccountSwitcher.__new__(ClaudeAccountSwitcher)
        switcher.backup_dir = tmp_path
        op = _op()
        with patch.object(
            switcher, "_perform_switch_core", return_value=op
        ) as core, patch("claude_swap.switcher.run_post_switch_hook") as hook:
            result = switcher._perform_switch("2", emit_output=False)
        assert result is op
        core.assert_called_once_with(
            "2", emit_output=False, force_activate=False, provenance=None
        )
        hook.assert_called_once_with(tmp_path, op)

    def test_core_exception_skips_hook_and_propagates(self, tmp_path: Path):
        switcher = ClaudeAccountSwitcher.__new__(ClaudeAccountSwitcher)
        switcher.backup_dir = tmp_path
        with patch.object(
            switcher, "_perform_switch_core", side_effect=RuntimeError("fail")
        ), patch("claude_swap.switcher.run_post_switch_hook") as hook:
            with pytest.raises(RuntimeError, match="fail"):
                switcher._perform_switch("2")
        hook.assert_not_called()
