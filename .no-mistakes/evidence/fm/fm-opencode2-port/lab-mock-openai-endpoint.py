import json, sys, time, http.server, threading
LOG = sys.argv[2]
lock = threading.Lock()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps({"object":"list","data":[{"id":"m","object":"model"}]}).encode()
        self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length","0")); raw = self.rfile.read(n)
        try: req = json.loads(raw)
        except Exception: req = {"raw": raw.decode("utf-8","replace")}
        with lock:
            with open(LOG,"a") as f: f.write(json.dumps({"t":time.time(),"path":self.path,"body":req})+"\n")
        text = "ack from lab mock"; tool=None
        msgs = req.get("messages", []) if isinstance(req, dict) else []
        last = msgs[-1] if msgs else {}
        def txt(m):
            c=m.get("content")
            if isinstance(c,str): return c
            return " ".join(x.get("text","") for x in (c or []) if isinstance(x,dict))
        lt = txt(last)
        if last.get("role") == "tool": text = "tool step finished"
        elif last.get("role") == "user" and "Reply with only the title" not in lt:
            if "FIRSTMATE_OP: v1 session-start" in lt: tool = "bin/fm-session-start.sh"
            elif "DENYTEST" in lt: tool = "bash bin/fm-watch-arm.sh >/dev/null 2>&1 & touch " + LOG + ".deny-sentinel"
            elif "WAKEPROBE" in lt: text = "wake noted"
        if tool and req.get("stream"):
            self.send_response(200); self.send_header("Content-Type","text/event-stream"); self.end_headers()
            def ev(d): self.wfile.write(("data: "+json.dumps(d)+"\n\n").encode()); self.wfile.flush()
            base={"id":"c2","object":"chat.completion.chunk","created":int(time.time()),"model":"m"}
            ev({**base,"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_"+str(int(time.time()*1000)),"type":"function","function":{"name":"shell","arguments":json.dumps({"command":tool})}}]},"finish_reason":None}]})
            ev({**base,"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13}})
            self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush(); return
        if req.get("stream"):
            self.send_response(200); self.send_header("Content-Type","text/event-stream"); self.end_headers()
            def ev(d): self.wfile.write(("data: "+json.dumps(d)+"\n\n").encode()); self.wfile.flush()
            base={"id":"c1","object":"chat.completion.chunk","created":int(time.time()),"model":"m"}
            ev({**base,"choices":[{"index":0,"delta":{"role":"assistant","content":text},"finish_reason":None}]})
            ev({**base,"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13}})
            self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
        else:
            body=json.dumps({"id":"c1","object":"chat.completion","created":int(time.time()),"model":"m","choices":[{"index":0,"message":{"role":"assistant","content":text},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13}}).encode()
            self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
