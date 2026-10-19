# Draws Claude Code 2.1.30x's question about a repository's MCP servers and
# answers keys as it does: Space or Enter on a row ticks it, Enter on
# "Enable selected" answers, Esc turns them all down. Then it prints what was
# picked and waits, as Claude Code goes on to its prompt.
import os, sys, termios, tty

servers = [["laravel-boost", True], ["herd", True]]
cursor = 0

def draw():
    out = ["\033[2J\033[H", "  2 new MCP servers found in this project\r\n", "  Select any you wish to enable.\r\n\r\n"]
    for i, (name, on) in enumerate(servers):
        out.append("  %s [%s] %s\r\n" % ("❯" if i == cursor else " ", "✔" if on else " ", name))
    out.append("  %s    Enable selected\r\n" % ("❯" if cursor == len(servers) else " "))
    out.append(" Space to select · Esc to reject all\r\n")
    sys.stdout.write("".join(out)); sys.stdout.flush()

def done(picked):
    sys.stdout.write("\033[2J\033[HPICKED:%s\r\n" % ",".join(picked) if picked is not None else "\033[2J\033[HREJECTED\r\n")
    sys.stdout.flush()
    os.read(0, 1)
    sys.exit(0)

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    draw()
    while True:
        b = os.read(fd, 8)
        if b == b"\x1b[B":
            cursor = min(cursor + 1, len(servers))
        elif b == b"\x1b[A":
            cursor = max(cursor - 1, 0)
        elif b == b" " or (b in (b"\r", b"\n") and cursor < len(servers)):
            if cursor < len(servers):
                servers[cursor][1] = not servers[cursor][1]
        elif b in (b"\r", b"\n"):
            done([n for n, on in servers if on])
        elif b == b"\x1b":
            done(None)
        draw()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
