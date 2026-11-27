#!/usr/bin/env bash
# Verify that GCS dependencies with output_file set to a tarball are extracted.
#
# Chromium's DEPS delivers third_party/node/node_modules as a GCS tarball with
# an explicit output_file name. The resolver must extract that archive into the
# destination directory, not leave the tarball sitting next to the expected
# contents.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="${SCRIPT_DIR}/resolve-deps.py"

fail() {
  echo "resolve-deps gcs test: $1" >&2
  exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/kibaos-resolver-gcs-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

root="${tmp}/root"
mkdir -p "${root}/src"

# Stand up a tiny HTTP server that serves the tarball from a bucket path.
port_file="${tmp}/port"
python3 - "${tmp}" "${port_file}" <<'PY' &
import http.server
import os
import sys
import tarfile
import io

root = sys.argv[1]
port_file = sys.argv[2]
bucket_dir = os.path.join(root, "chromium-nodejs")
os.makedirs(bucket_dir, exist_ok=True)
archive = os.path.join(bucket_dir, "node_modules.tar.gz")
with tarfile.open(archive, "w:gz") as tar:
    content = b"// test protobuf create.js\n"
    info = tarfile.TarInfo(name="@bufbuild/protobuf/dist/cjs/create.js")
    info.size = len(content)
    tar.addfile(info, fileobj=io.BytesIO(content))

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)
    def log_message(self, format, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
server_pid=$!
trap 'kill "${server_pid}" 2>/dev/null || true; rm -rf "${tmp}"' EXIT

# Wait for the server to write its port.
for _ in $(seq 1 50); do
  [[ -f "${port_file}" ]] && break
  sleep 0.1
done
[[ -f "${port_file}" ]] || fail "GCS mock server did not start"
port="$(cat "${port_file}")"

# Compute the tarball's sha256 and size.
archive="${tmp}/chromium-nodejs/node_modules.tar.gz"
size="$(stat -c %s "${archive}" 2>/dev/null || stat -f %z "${archive}")"
sha256="$(sha256sum "${archive}" | cut -d' ' -f1)"

cat > "${root}/src/DEPS" <<EOF
vars = {}
deps = {
  'src/third_party/node/node_modules': {
    'bucket': 'chromium-nodejs',
    'dep_type': 'gcs',
    'objects': [
      {
        'object_name': 'node_modules.tar.gz',
        'output_file': 'node_modules.tar.gz',
        'sha256sum': '${sha256}',
        'size_bytes': ${size},
      },
    ],
  },
}
EOF

# Point the resolver at the mock server.
KIBAOS_GCS_BASE="http://127.0.0.1:${port}" \
  python3 "${RESOLVER}" --root "${root}" --jobs 1 --skip-hooks \
  > "${tmp}/resolver.log"

extracted="${root}/src/third_party/node/node_modules/@bufbuild/protobuf/dist/cjs/create.js"
[[ -f "${extracted}" ]] || fail "tarball was not extracted; missing ${extracted}"

archive_leftover="${root}/src/third_party/node/node_modules/node_modules.tar.gz"
[[ ! -f "${archive_leftover}" ]] || fail "tarball archive was left behind after extraction"

echo "resolve-deps gcs test passed"
