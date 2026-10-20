package jog

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:time"

Supervisor :: struct {
	signals:  posix.sigset_t,
	old_mask: posix.sigset_t,
	tty:      posix.FD,
	group:    posix.pid_t,
}

SUPERVISED_SIGNALS :: [?]posix.Signal {
	.SIGCHLD,
	.SIGINT,
	.SIGTERM,
	.SIGHUP,
	.SIGQUIT,
	.SIGTSTP,
	.SIGCONT,
	.SIGTTOU,
	.SIGALRM,
}

make_supervisor :: proc() -> Supervisor {
	s := Supervisor {
		tty   = -1,
		group = posix.getpgrp(),
	}
	posix.sigemptyset(&s.signals)
	for sig in SUPERVISED_SIGNALS {
		posix.sigaddset(&s.signals, sig)
	}
	// Consume signals synchronously, avoiding allocation or Odin runtime calls
	// from an asynchronous signal handler. Block before fork to avoid races.
	if posix.sigprocmask(.BLOCK, &s.signals, &s.old_mask) != .OK {
		fail("cannot block supervisor signals")
	}
	for sig in SUPERVISED_SIGNALS {
		posix.signal(sig, auto_cast posix.SIG_DFL)
	}
	// Darwin may discard default-ignored SIGCHLD instead of waking sigwait.
	posix.signal(.SIGCHLD, child_changed)
	s.tty = posix.open("/dev/tty", {.RDWR})
	return s
}

run_script :: proc(s: ^Supervisor, command: string) -> int {
	if sig := pending_termination(); sig != nil {
		return 128 + int(sig)
	}
	argv := []cstring{"sh", "-c", strings.clone_to_cstring(command), nil}
	gate: [2]posix.FD
	if posix.pipe(&gate) != .OK {
		fail("cannot create process startup pipe")
	}
	pid := posix.fork()
	if pid < 0 {
		posix.close(gate[0])
		posix.close(gate[1])
		fail("cannot fork script process")
	}
	if pid == 0 {
		// Only POSIX calls between fork and exec. The parent opens the gate
		// after assigning the process group and handing over the terminal.
		posix.close(gate[1])
		if posix.setpgid(0, 0) != .OK {
			posix._exit(126)
		}
		byte: u8
		if posix.read(gate[0], &byte, 1) != 1 {
			posix._exit(126)
		}
		posix.close(gate[0])
		if s.tty >= 0 {
			posix.close(s.tty)
		}
		posix.sigprocmask(.SETMASK, &s.old_mask, nil)
		posix.execv("/bin/sh", raw_data(argv))
		posix._exit(127)
	}
	posix.close(gate[0])
	if posix.setpgid(pid, pid) != .OK {
		posix.close(gate[1])
		posix.kill(pid, .SIGKILL)
		posix.waitpid(pid, nil, {})
		fail("cannot create script process group")
	}
	foreground := s.tty >= 0 && posix.tcgetpgrp(s.tty) == s.group
	if foreground && posix.tcsetpgrp(s.tty, pid) != .OK {
		posix.close(gate[1])
		posix.killpg(pid, .SIGKILL)
		posix.waitpid(pid, nil, {})
		fail("cannot give script terminal access")
	}
	defer if foreground {
		posix.tcsetpgrp(s.tty, s.group)
	}
	ready: u8 = 1
	posix.write(gate[1], &ready, 1)
	posix.close(gate[1])
	defer posix.alarm(0)

	cancelled: posix.Signal
	forwarded := false
	status: c.int
	for {
		waited := posix.waitpid(pid, &status, {.NOHANG, .UNTRACED})
		if waited < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			posix.killpg(pid, .SIGKILL)
			fail("cannot wait for script process")
		}
		if waited == pid {
			// The Linux WIFSTOPPED/WIFSIGNALED helpers in Odin dev-2026-10
			// mishandle signed arithmetic. Decode the wait status directly;
			// these fields have the same layout on our macOS/Linux targets.
			if status & 0xff == 0x7f {
				if cancelled != nil {
					posix.killpg(pid, .SIGCONT)
					continue
				}
				// Mirror job-control stops to our launching shell. On `fg`,
				// return the terminal to the child before continuing it.
				if foreground {
					posix.tcsetpgrp(s.tty, s.group)
				}
				posix.kill(posix.getpid(), .SIGSTOP)
				foreground = s.tty >= 0 && posix.tcgetpgrp(s.tty) == s.group
				if foreground {
					posix.tcsetpgrp(s.tty, pid)
				}
				posix.killpg(pid, .SIGCONT)
				continue
			}
			break
		}
		sig: posix.Signal
		if posix.sigwait(&s.signals, &sig) != nil {
			continue
		}
		#partial switch sig {
		case .SIGINT, .SIGTERM, .SIGHUP, .SIGQUIT:
			if cancelled == nil {
				cancelled = sig
				posix.alarm(2)
			}
			posix.killpg(pid, sig)
			forwarded = true
			posix.killpg(pid, .SIGCONT)
		case .SIGALRM:
			if cancelled != nil {
				posix.killpg(pid, .SIGKILL)
			}
		case .SIGTSTP:
			posix.killpg(pid, .SIGTSTP)
		case .SIGCONT:
			posix.killpg(pid, .SIGCONT)
		case:
		}
	}
	code := int((status >> 8) & 0xff)
	if cancelled == nil {
		cancelled = pending_termination()
	}
	termination_signal := posix.Signal(status & 0x7f)
	if termination_signal != nil {
		if cancelled == nil {
			cancelled = termination_signal
		}
		code = 128 + int(termination_signal)
	}
	// A shell may translate a terminal signal into 128+signal. It has already
	// received that signal, but surviving members of the group still need cleanup.
	if cancelled == nil {
		switch code {
		case 130:
			cancelled = .SIGINT
		case 131:
			cancelled = .SIGQUIT
		case 143:
			cancelled = .SIGTERM
		case 129:
			cancelled = .SIGHUP
		}
	}
	if cancelled != nil {
		posix.alarm(0)
		if !forwarded {
			posix.killpg(pid, cancelled)
		}
		posix.killpg(pid, .SIGCONT)
		// Give descendants time to finish their handlers, then terminate any
		// that ignored the signal. Detached sessions are outside this group.
		for _ in 0 ..< 200 {
			if posix.killpg(pid, nil) != .OK {
				break
			}
			time.sleep(10 * time.Millisecond)
		}
		posix.killpg(pid, .SIGKILL)
		return 128 + int(cancelled)
	}
	return code
}

child_changed :: proc "c" (sig: posix.Signal) {}

pending_termination :: proc() -> posix.Signal {
	pending: posix.sigset_t
	posix.sigpending(&pending)
	signals := [?]posix.Signal{.SIGINT, .SIGTERM, .SIGHUP, .SIGQUIT}
	for sig in signals {
		if posix.sigismember(&pending, sig) == 1 {
			return sig
		}
	}
	return nil
}
