#!/usr/bin/env python3
"""What does this terminal actually send? Run in a BARE Ghostty window,
NOT inside herdr — herdr intercepts bound keys and would confound the result.

Enables the Kitty keyboard protocol exactly the way herdr does (CSI > 7 u),
then prints the raw bytes of every key you press.

Press keys, then Ctrl-] to quit.
"""
import sys, os, tty, termios

KITTY_PUSH = b"\x1b[>7u"
KITTY_POP = b"\x1b[<u"


def describe(data: bytes) -> str:
    # Kitty CSI-u form: ESC [ <codepoint> ; <mods> u   (mods = bitfield + 1)
    if data.startswith(b"\x1b[") and data.endswith(b"u"):
        body = data[2:-1].decode("ascii", "replace")
        parts = body.split(";")
        if len(parts) >= 2:
            try:
                code = int(parts[0])
                mods = int(parts[1].split(":")[0]) - 1
            except ValueError:
                return "CSI-u, unparsed"
            names = [
                (1, "shift"), (2, "alt"), (4, "ctrl"),
                (8, "SUPER/cmd"), (16, "hyper"), (32, "meta"),
            ]
            on = [n for bit, n in names if mods & bit]
            ch = chr(code) if 32 <= code < 127 else f"U+{code:04X}"
            return f"CSI-u  key={ch!r}  mods={mods} [{'+'.join(on) or 'none'}]"
    if len(data) == 1 and data[0] < 32:
        return f"legacy control byte (ctrl+{chr(data[0] + 96)!r})"
    if data.startswith(b"\x1b"):
        return "legacy ESC-prefixed (alt/meta style)"
    return "plain bytes"


def main() -> None:
    fd = sys.stdin.fileno()
    if not os.isatty(fd):
        sys.exit("not a tty")
    saved = termios.tcgetattr(fd)
    os.write(1, KITTY_PUSH)
    print("Kitty keyboard protocol pushed (CSI > 7 u) — same as herdr.\r")
    print("Press Caps+b, Caps+e, then plain b. Ctrl-] quits.\r\n")
    try:
        tty.setraw(fd)
        while True:
            data = os.read(fd, 64)
            if not data:
                break
            # Under the Kitty protocol ctrl+c arrives as CSI-u (ESC[99;5u),
            # NOT as byte 0x03 — check both forms or the probe can't be quit.
            if data in (b"\x1d", b"\x03", b"\x04") or data.startswith(
                (b"\x1b[99;5u", b"\x1b[113;1u")
            ):  # ctrl+c CSI-u, or plain 'q'
                break
            if data == b"q":
                break
            print(f"{data.hex(' '):<28} {data!r:<26} {describe(data)}\r")
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        os.write(1, KITTY_POP)
        print("\nDone.")


if __name__ == "__main__":
    main()
