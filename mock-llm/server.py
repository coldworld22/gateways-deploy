"""A stand-in OpenAI-compatible provider for tests: echoes the last user message and remembers
the last request it received (GET /last), so a test can check what actually left the gateway."""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

last = {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self) -> bytes:
        # Java's HttpClient may send the body with chunked transfer encoding and no Content-Length.
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks = []
            while True:
                size = int(self.rfile.readline().strip().split(b";")[0], 16)
                if size == 0:
                    self.rfile.readline()  # blank line after the last chunk
                    return b"".join(chunks)
                chunks.append(self.rfile.read(size))
                self.rfile.readline()  # CRLF after each chunk
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def do_GET(self):
        self._send(200, last if self.path == "/last" else {"status": "up"})

    def do_POST(self):
        body = json.loads(self._read_body())
        last.clear()
        last.update(body)
        text = body["messages"][-1]["content"]
        self._send(200, {
            "id": "mock-1", "object": "chat.completion", "model": body.get("model", "mock"),
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": "You said: " + text}}],
            "usage": {"prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20},
        })


ThreadingHTTPServer(("", 11434), Handler).serve_forever()
