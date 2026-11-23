# 계정 전환이 끝난 뒤 사용자가 설정한 훅 명령을 백그라운드로 실행한다.
"""Post-switch hooks.

The hook configured as ``hooks.postSwitch`` is a shell command started in the
background after a switch has already succeeded. It must never affect the
switch: every failure (bad setting, spawn error, timeout, exception) is logged
and swallowed, and the child's output is discarded.
"""

from __future__ import annotations

import logging
import os
import subprocess
import threading
from pathlib import Path

from claude_swap.settings import load_hook_settings

HOOK_TIMEOUT_SECONDS = 60

_logger = logging.getLogger("claude-swap")


def _reap(proc: subprocess.Popen) -> None:
    """Wait for the hook, killing it after the timeout; never raises."""
    try:
        proc.wait(timeout=HOOK_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
        except Exception:
            pass
        try:
            proc.wait()
        except Exception:
            pass
    except Exception:
        pass


def run_post_switch_hook(backup_root: Path, op: dict) -> None:
    """Start the configured post-switch hook in the background, if any.

    ``op`` is the switch result dict with ``from``/``to`` identity refs. This
    function deliberately never raises and never writes to stdout/stderr.
    """
    try:
        command = load_hook_settings(backup_root).post_switch
        if command is None:
            return
        to_ref = op.get("to") or {}
        from_ref = op.get("from") or {}
        env = os.environ.copy()
        env["CSWAP_TO_ACCOUNT"] = (
            str(to_ref.get("number")) if to_ref.get("number") is not None else ""
        )
        env["CSWAP_TO_EMAIL"] = to_ref.get("email") or ""
        env["CSWAP_FROM_ACCOUNT"] = (
            str(from_ref.get("number"))
            if from_ref.get("number") is not None
            else ""
        )
        env["CSWAP_FROM_EMAIL"] = from_ref.get("email") or ""
        proc = subprocess.Popen(
            command,
            shell=True,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            start_new_session=(os.name != "nt"),
        )
        threading.Thread(
            target=_reap,
            args=(proc,),
            daemon=True,
            name="cswap-post-switch-hook",
        ).start()
    except Exception as e:
        _logger.warning("Post-switch hook failed to start: %r", e)
