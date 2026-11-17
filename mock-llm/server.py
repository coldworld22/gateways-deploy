import json
from http.server import BaseHTTPRequestHandler, HTTPServer

last = {}

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._send(200, last if self.path == "/last" else {"status": "up"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        last.clear()
        last.update(body)
        text = body["messages"][-1]["content"]
        self._send(200, {
            "id": "mock-1", "object": "chat.completion", "model": body.get("model", "mock"),
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": "You said: " + text}}],
            "usage": {"prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20},
        })

HTTPServer(("", 11434), Handler).serve_forever()
