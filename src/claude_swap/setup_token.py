"""Mint a new long-lived OAuth token with ``claude setup-token`` and capture it.

``claude setup-token`` is an interactive Ink app: it prints a sign-in URL,
waits for the user to paste the code from the browser, then prints the token
once ("Your OAuth token (valid for …):" followed by ``sk-ant-oat…``). It does
not store the token anywhere, so the only way to get it is from its output.

On POSIX the command runs under a pseudo-terminal that this process relays to
and from the real terminal, so the user drives it exactly as if it ran
directly while a copy of its output is kept in memory to find the token in.
The copy never touches disk or the log. Where that is not possible (Windows,
or the token cannot be found in the output), the command runs with the
terminal inherited and the user pastes the token at a hidden prompt.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import warnings

from claude_swap.exceptions import ClaudeSwitchError


class SetupTokenError(ClaudeSwitchError):
    """``claude setup-token`` could not be run or produced no token."""


# Escape sequences in captured terminal output. Cursor movement (Ink positions
# words with CSI n G instead of printing spaces) becomes a space so words stay
# separated; colour/mode sequences and OSC strings (hyperlinks) are dropped.
_OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
_CSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*([@-~])")
_NEWLINE_RE = re.compile(r"\r+\n")
_OTHER_ESC_RE = re.compile(r"\x1b[@-Z\\-_]|\x1b[()][0-9A-Za-z]|\x1b[78=>]")

_TOKEN_START = "sk-ant-oat"
_TOKEN_CHARS = re.compile(r"[A-Za-z0-9_\-]+")
_TOKEN_RE = re.compile(r"^sk-ant-oat\d*-[A-Za-z0-9_\-]{20,}$")


def strip_terminal_codes(text: str) -> str:
    """Render captured terminal output as plain lines (best effort)."""
    text = _OSC_RE.sub("", text)
    text = _CSI_RE.sub(lambda m: "" if m.group(1) == "m" else " ", text)
    text = _OTHER_ESC_RE.sub("", text)
    # A pty turns each "\n" into "\r\n", and programs often write "\r\n"
    # themselves, so one line break can arrive as "\r\r\n".
    text = _NEWLINE_RE.sub("\n", text)
    return text.replace("\r", "\n")


def looks_like_setup_token(token: str) -> bool:
    return bool(_TOKEN_RE.match(token))


def extract_setup_token(output: str) -> str | None:
    """Find the token ``claude setup-token`` printed, rejoining wrapped lines.

    Ink wraps the token at the terminal width with hard line breaks, so a
    token longer than the terminal is split over several lines. Starting at
    the last ``sk-ant-oat`` in the output, the token runs to the end of its
    line and continues onto following lines while each one is made only of
    token characters; a blank line or a line of prose ends it.
    """
    lines = strip_terminal_codes(output).split("\n")
    for i in range(len(lines) - 1, -1, -1):
        col = lines[i].rfind(_TOKEN_START)
        if col < 0:
            continue
        head = _TOKEN_CHARS.match(lines[i], col)
        if head is None:
            continue
        token = head.group(0)
        rest_of_line = lines[i][head.end():].strip()
        if not rest_of_line:
            for nxt in lines[i + 1:]:
                piece = nxt.strip()
                if not piece or not _TOKEN_CHARS.fullmatch(piece):
                    break
                token += piece
        if looks_like_setup_token(token):
            return token
    return None


def find_claude() -> str:
    claude_bin = shutil.which("claude")
    if not claude_bin:
        raise SetupTokenError(
            "'claude' was not found on PATH. Install Claude Code first, or pass "
            "an existing token with `cswap add-token <TOKEN>`."
        )
    return claude_bin


def _run_with_capture(argv: list[str]) -> tuple[int, str]:
    """Run ``argv`` on a relayed pseudo-terminal; return (exit status, output)."""
    import errno
    import fcntl
    import pty
    import select
    import signal
    import struct
    import termios
    import tty

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()

    def _winsize() -> bytes | None:
        try:
            return fcntl.ioctl(stdout_fd, termios.TIOCGWINSZ, b"\0" * 8)
        except OSError:
            return None

    sys.stdout.flush()
    with warnings.catch_warnings():
        # Python warns about fork() in a multi-threaded process (the TUI has
        # worker threads); the child only execs, so the warning is noise.
        warnings.simplefilter("ignore", DeprecationWarning)
        pid, master = pty.fork()
    if pid == 0:  # child: exec the command on the slave side
        try:
            os.execv(argv[0], argv)
        finally:
            os._exit(127)

    def _resize(*_):
        size = _winsize()
        if size:
            try:
                fcntl.ioctl(master, termios.TIOCSWINSZ, size)
            except OSError:
                pass

    _resize()
    old_winch = signal.signal(signal.SIGWINCH, _resize)
    old_mode = termios.tcgetattr(stdin_fd)
    captured = bytearray()
    try:
        tty.setraw(stdin_fd)
        fds = [master, stdin_fd]
        while True:
            try:
                ready, _, _ = select.select(fds, [], [])
            except InterruptedError:
                continue
            if master in ready:
                try:
                    data = os.read(master, 65536)
                except OSError as e:
                    if e.errno == errno.EIO:  # child closed the terminal
                        break
                    raise
                if not data:
                    break
                captured += data
                _write_all(stdout_fd, data)
            if stdin_fd in ready:
                data = os.read(stdin_fd, 65536)
                if not data:
                    fds.remove(stdin_fd)
                else:
                    _write_all(master, data)
    finally:
        termios.tcsetattr(stdin_fd, termios.TCSAFLUSH, old_mode)
        signal.signal(signal.SIGWINCH, old_winch)
        os.close(master)
    _, status = os.waitpid(pid, 0)
    code = os.waitstatus_to_exitcode(status)
    return code, captured.decode("utf-8", errors="replace")


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def _can_relay() -> bool:
    if sys.platform == "win32":
        return False
    try:
        import pty  # noqa: F401
        import termios  # noqa: F401
    except ImportError:
        return False
    try:
        return os.isatty(sys.stdin.fileno()) and os.isatty(sys.stdout.fileno())
    except (OSError, ValueError):
        return False


def prompt_for_token(input_fn=None, *, what: str = "your token") -> str:
    """Ask the user to paste a token at a hidden prompt.

    Ink inserts hard line breaks into a wrapped token, so a copied token may
    arrive as several lines: keep reading until an empty line and join them.
    """
    import getpass

    read = input_fn or getpass.getpass
    print(
        f"Paste {what}, then press Enter on an empty line to finish. "
        "Input is hidden."
    )
    parts: list[str] = []
    while True:
        line = read("Token: " if not parts else "")
        piece = "".join(line.split())
        if not piece:
            if parts:
                break
            continue
        parts.append(piece)
    return "".join(parts)


def mint_setup_token(claude_bin: str | None = None) -> str:
    """Run ``claude setup-token`` interactively and return the new token."""
    if not sys.stdin.isatty():
        raise SetupTokenError(
            "`claude setup-token` needs an interactive terminal. Run it yourself "
            "and register the token with `cswap add-token -` (reads stdin)."
        )
    claude_bin = claude_bin or find_claude()
    argv = [claude_bin, "setup-token"]
    print("Running `claude setup-token` — sign in with the account to add.\n")

    if _can_relay():
        code, output = _run_with_capture(argv)
        token = extract_setup_token(output)
        del output
        if token:
            return token
        if code != 0:
            raise SetupTokenError(
                f"`claude setup-token` exited with status {code} without "
                "printing a token."
            )
        print("\nCould not read the token from the output automatically.")
        return _validated(prompt_for_token(what="the token printed above (sk-ant-oat…)"))

    code = subprocess.call(argv)
    if code != 0:
        raise SetupTokenError(f"`claude setup-token` exited with status {code}.")
    return _validated(prompt_for_token(what="the token printed above (sk-ant-oat…)"))


def _validated(token: str) -> str:
    token = token.strip()
    if not token:
        raise SetupTokenError("No token entered.")
    if not token.startswith(_TOKEN_START):
        raise SetupTokenError(
            "That does not look like a setup-token (expected sk-ant-oat…)."
        )
    return token
