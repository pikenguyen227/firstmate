import os, sys, pty, fcntl, termios, struct, select, time, signal
# usage: ptydrv.py <rawlog> <ctlfifo> <cwd> -- cmd...
raw, ctl, cwd = sys.argv[1:4]; cmd = sys.argv[sys.argv.index("--")+1:]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 150, 0, 0))
os.kill(pid, signal.SIGWINCH)
out = open(raw, "ab")
cfd = os.open(ctl, os.O_RDONLY | os.O_NONBLOCK)
buf = b""
while True:
    r,_,_ = select.select([fd, cfd], [], [], 0.2)
    if fd in r:
        try: d = os.read(fd, 65536)
        except OSError: break
        if not d: break
        out.write(d); out.flush()
    if cfd in r:
        d = os.read(cfd, 4096)
        if not d:
            os.close(cfd); cfd = os.open(ctl, os.O_RDONLY | os.O_NONBLOCK); continue
        buf += d
        while b"\n" in buf:
            line, buf = buf.split(b"\n",1)
            line=line.decode()
            if line.startswith("text "): 
                for ch in line[5:]: os.write(fd, ch.encode()); time.sleep(0.02)
            elif line == "enter": os.write(fd, b"\r")
            elif line == "ctrlc": os.write(fd, b"\x03")
            elif line == "esc": os.write(fd, b"\x1b")
            elif line == "kill": os.kill(pid, signal.SIGTERM)
    try:
        wp, st = os.waitpid(pid, os.WNOHANG)
        if wp: 
            out.write(f"\n[ptydrv: child exited status={st}]\n".encode()); break
    except ChildProcessError: break
out.close()
