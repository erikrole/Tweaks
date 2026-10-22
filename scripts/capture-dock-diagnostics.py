#!/usr/bin/env python3
"""Bounded, private macOS diagnostic capture; performs no device or settings actions."""

import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import threading
import time


PREDICATE = ('process IN {"WindowServer", "ControlCenter", "SystemUIServer", '
             '"MenuBarAgent", "bluetoothd", "coreaudiod", "powerd", "Tweaks"} '
             'OR subsystem == "com.erole.Tweaks"')
CANCELLED = False


def check_cancelled():
    if CANCELLED:
        raise KeyboardInterrupt


def wait_for(process, timeout):
    deadline = time.monotonic() + timeout
    while True:
        check_cancelled()
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(process.args, timeout)
        try:
            return process.wait(timeout=min(0.1, remaining))
        except subprocess.TimeoutExpired:
            pass


class Capture:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.results = []
        self.state = {"incomplete": True}
        self.save_manifest()

    def save_manifest(self, **extra):
        self.state.update(extra)
        data = {"commands": self.results, **self.state}
        temporary = self.directory / "manifest.tmp"
        with temporary.open("w") as output:
            json.dump(data, output, indent=2)
        temporary.chmod(0o600)
        temporary.replace(self.directory / "manifest.json")

    @staticmethod
    def stop(process):
        if process.poll() is None:
            # Only the new process group created by this collector is signalled.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass  # Keep the collector bounded even if a kernel read cannot exit.
        return process.poll() is not None

    def run(self, name, command, timeout=8):
        check_cancelled()
        started = time.monotonic()
        result = {"file": name, "command": command, "timed_out": False}
        with (self.directory / name).open("xb") as output:
            process = None
            try:
                process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                           start_new_session=True)
                result["exit_code"] = wait_for(process, timeout)
            except subprocess.TimeoutExpired:
                result["timed_out"] = True
            except OSError as error:
                result["error"] = str(error)
            finally:
                result["cleanup_complete"] = process is None or self.stop(process)
                result["exit_code"] = process.poll() if process else None
                result["seconds"] = round(time.monotonic() - started, 3)
                self.results.append(result)
                self.save_manifest()
        return result

    def samples(self, index, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        name = f"processes-{index:03}.txt"
        self.run(name, ["/bin/ps", "-axo", "pid,comm"], timeout=min(8, remaining))
        rows = (self.directory / name).read_text().splitlines()
        wanted = {"WindowServer", "ControlCenter", "Tweaks"}
        for row in rows[1:]:
            fields = row.strip().split(None, 1)
            if len(fields) != 2:
                continue
            pid, executable = fields
            target = Path(executable).name
            if target not in wanted or (target == "Tweaks" and executable != "/Applications/Tweaks.app/Contents/MacOS/Tweaks"):
                continue
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            self.run(f"{target}-{pid}-{index:03}.sample.txt",
                     ["/usr/bin/sample", pid, "1", "10", "-file",
                      str(self.directory / f"{target}-{pid}-{index:03}.stack.txt")], timeout=min(5, remaining))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=10,
                        help="record for 1–300 seconds; never reconnects the dock")
    parser.add_argument("--output", type=Path,
                        help="new private directory; existing directories are rejected")
    args = parser.parse_args()
    if sys.platform != "darwin" or os.geteuid() == 0:
        parser.error("Run as the logged-in macOS user, not with sudo.")
    if not 1 <= args.seconds <= 300:
        parser.error("--seconds must be between 1 and 300")
    def interrupted(signum, frame):
        global CANCELLED
        # Do not interrupt Popen before its returned child handle is owned.
        # Cleanup also stays uninterrupted if cancellation is requested again.
        CANCELLED = True
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    os.umask(0o077)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    directory = args.output or Path.home() / "Code Support/Tweaks/diagnostics" / stamp
    try:
        capture = Capture(directory.expanduser().resolve())
    except FileExistsError:
        parser.error("Output directory already exists; nothing was overwritten.")
    folder = capture.directory
    print(f"Private capture: {folder}", flush=True)
    capture.run("preferences-before.plist", ["/usr/bin/defaults", "export", "com.erole.Tweaks", "-"])
    capture.run("os.txt", ["/usr/bin/sw_vers"])
    capture.run("boot.txt", ["/usr/sbin/sysctl", "kern.boottime", "kern.bootsessionuuid"])
    capture.run("power-before.txt", ["/usr/bin/pmset", "-g", "assertions"])
    capture.run("displays.json", ["/usr/sbin/system_profiler", "SPDisplaysDataType", "-json"], timeout=12)
    capture.run("thunderbolt.json", ["/usr/sbin/system_profiler", "SPThunderboltDataType", "-json"], timeout=12)
    with (folder / "live.log").open("xb") as output:
        # A native backup timeout bounds an orphaned stream. One extra second
        # avoids treating the utility's coarse timeout rounding as an early exit.
        stream = None
        started = time.monotonic()
        deadline = started + args.seconds
        command = ["/usr/bin/log", "stream", "--timeout", str(args.seconds + 1), "--style", "ndjson",
                   "--level", "info", "--predicate", PREDICATE]
        ended = {}
        observer = None
        try:
            stream = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                      start_new_session=True)
            def observe_exit():
                stream.wait()
                ended["at"] = time.monotonic()
            observer = threading.Thread(target=observe_exit, daemon=True)
            observer.start()
            index = 0
            while time.monotonic() < deadline:
                check_cancelled()
                if stream.poll() is not None:
                    break
                capture.samples(index, deadline)
                index += 1
                remaining = deadline - time.monotonic()
                if remaining > 0 and stream.poll() is None:
                    # Poll outside the signal handler; it must never acquire locks.
                    next_sample = min(deadline, time.monotonic() + 5)
                    while time.monotonic() < next_sample and stream.poll() is None:
                        check_cancelled()
                        time.sleep(min(0.1, max(0, next_sample - time.monotonic())))
                check_cancelled()
        finally:
            reached_deadline = time.monotonic() >= deadline
            stream_cleanup = stream is None or capture.stop(stream)
            stream_exit = stream.poll() if stream else None
            if observer:
                observer.join(timeout=1)
            ended_early = ended.get("at", float("inf")) < deadline
            capture.results.append({"file": "live.log", "command": command, "exit_code": stream_exit,
                                    "cleanup_complete": stream_cleanup,
                                    "reached_deadline": reached_deadline,
                                    "ended_early": ended_early,
                                    "observed_exit_seconds": round(ended["at"] - started, 3) if "at" in ended else None,
                                    "seconds": round(time.monotonic() - started, 3)})
            capture.save_manifest(incomplete=True)
    capture.run("power-after.txt", ["/usr/bin/pmset", "-g", "assertions"])
    capture.run("preferences-after.plist", ["/usr/bin/defaults", "export", "com.erole.Tweaks", "-"])
    try:
        before = plistlib.loads((folder / "preferences-before.plist").read_bytes())
        after = plistlib.loads((folder / "preferences-after.plist").read_bytes())
        changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
    except (ValueError, plistlib.InvalidFileException):
        changed = None
    unavailable = [r["file"] for r in capture.results
                   if r.get("timed_out") or r.get("ended_early") or not r["cleanup_complete"] or
                   (r["exit_code"] != 0 and not (r["file"] == "live.log" and
                    r["exit_code"] == -signal.SIGKILL and r["reached_deadline"]))]
    capture.save_manifest(preference_keys_changed=changed, unavailable=unavailable,
                          requested_recording_seconds=args.seconds,
                          incomplete=bool(unavailable) or changed != [],
                          note="Protected WindowServer sampling may need separate administrator authorization. "
                               "Do not run this collector as root. Current samples do not reconstruct an earlier freeze.")
    print(f"Preference keys changed: {changed}; unavailable commands: {unavailable}")
    return 1 if unavailable or changed != [] else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Capture cancelled; partial files and cleanup results were retained.", file=sys.stderr)
        raise SystemExit(130)
