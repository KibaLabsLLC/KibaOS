import json, socket, sys, time

def run(path, args, tries=20):
    for _ in range(tries):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(3)
        try:
            s.connect("qga.sock")
            f = s.makefile("rw")
            def rpc(cmd):
                f.write(json.dumps(cmd) + "\n"); f.flush()
                return json.loads(f.readline())
            sid = int(time.time() * 1000) & 0x7fffffff
            if rpc({"execute": "guest-sync", "arguments": {"id": sid}}).get("return") != sid:
                continue
            pid = rpc({"execute": "guest-exec", "arguments": {
                "path": path, "arg": args, "capture-output": True}})["return"]["pid"]
            while True:
                st = rpc({"execute": "guest-exec-status", "arguments": {"pid": pid}})["return"]
                if st["exited"]:
                    return st.get("exitcode")
                time.sleep(0.2)
        except (OSError, ValueError, KeyError):
            time.sleep(3)
        finally:
            s.close()
    raise SystemExit("guest agent never answered")

rc = run("/usr/bin/pkill", ["-TERM", "-f", "kibaos-installer-gui"])
print("pkill exit code:", rc, "(1 = no installer running -> assume login screen)")
sys.exit(0 if rc == 0 else 1)
