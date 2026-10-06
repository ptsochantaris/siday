#!/bin/zsh
# Builds the web player if it needs it, serves this folder on this Mac only, and opens the page.
#
#   ./serve.sh          http://localhost:8000
#   ./serve.sh 8080     another port
#
# Ctrl-C stops the server.
set -e
cd ${0:h}
port=${1:-8000}

# Rebuilt when there is nothing built yet, or when a source is newer than what was built.
sources=(../Package.swift toolset.json ../Sources/SidayKit ../Sources/SidayWeb ../Sources/SidayWebAudio)
if [[ ! -f generated/SidayWeb.wasm || ! -f generated/SidayWebAudio.wasm || -n "$(find $sources -newer generated/SidayWeb.wasm -print -quit)" ]]; then
  ./build.sh
fi

if lsof -ti tcp:$port -sTCP:LISTEN > /dev/null; then
  echo "Port $port is already in use. Try another: ./serve.sh $((port + 1))" >&2
  exit 1
fi

# Served with word that nothing is to be kept: a browser would otherwise go on using its own copies
# of these files for a while after they have changed.
python3 - $port <<'PYTHON' &
import http.server, sys

class Fresh(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Fresh).serve_forever()
PYTHON
server=$!
trap 'kill $server 2> /dev/null' EXIT INT TERM

# The page is opened once the server answers.
until curl -s -o /dev/null http://127.0.0.1:$port/; do
  kill -0 $server 2> /dev/null || exit 1
  sleep 0.2
done
open http://localhost:$port
wait $server
