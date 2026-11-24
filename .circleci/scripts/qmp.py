import json, os, socket, sys

ABS_MAX = 0x7fff

def command(payload):
    sock = socket.socket(socket.AF_UNIX)
    sock.connect("qmp.sock")
    stream = sock.makefile("rw")
    stream.readline()
    def send(cmd):
        stream.write(json.dumps(cmd) + "\n")
        stream.flush()
        while True:
            response = json.loads(stream.readline())
            if "return" in response or "error" in response:
                return response
    result = send({"execute": "qmp_capabilities"})
    if "error" in result:
        raise RuntimeError(result["error"])
    result = send(payload)
    sock.close()
    if "error" in result:
        raise RuntimeError(result["error"])
    return result

def click(px, py, width, height):
    ax = int(px * ABS_MAX / max(width - 1, 1))
    ay = int(py * ABS_MAX / max(height - 1, 1))
    events = [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
        {"type": "btn", "data": {"button": "left", "down": True}},
        {"type": "btn", "data": {"button": "left", "down": False}},
    ]
    command({"execute": "input-send-event", "arguments": {"events": events}})

if sys.argv[1] == "screendump":
    command({"execute": "screendump", "arguments": {
        "filename": os.path.abspath(sys.argv[2]), "format": "png"
    }})
elif sys.argv[1] == "click":
    click(int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]))
elif sys.argv[1] == "reset":
    command({"execute": "system_reset"})
else:
    raise SystemExit("Usage: qmp.py screendump FILE | click X Y WIDTH HEIGHT | reset")
