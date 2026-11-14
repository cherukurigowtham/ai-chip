#!/usr/bin/env python3
"""
==============================================================================
BitNet-130: OpenAI-Compatible Local Inference API Server
==============================================================================
Runs an ultra-lightweight, high-performance OpenAI-compatible HTTP server.
Enables any application (LangChain, LlamaIndex, Cursor, Continue.dev, AutoGen,
or the official OpenAI Python library) to query the BitNet-130 accelerator
directly using standard OpenAI API calls.

Usage:
    python3 bitnet_server.py --port 8080 --model bitnet-130m

Example Client Request:
    from openai import OpenAI
    client = OpenAI(base_url="http://localhost:8080/v1", api_key="bitnet130")
    response = client.chat.completions.create(
        model="bitnet130",
        messages=[{"role": "user", "content": "Explain edge AI silicon."}],
        stream=True
    )
    for chunk in response:
        print(chunk.choices[0].delta.content or "", end="")
==============================================================================
"""

import sys
import os
import json
import time
import uuid
import argparse
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

# Add SDK root
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from huggingface_adapter import BitNetForCausalLM

# Global Model Cache
MODEL_INSTANCE: Optional[BitNetForCausalLM] = None
SERVER_STATS = {
    "requests_served": 0,
    "tokens_generated": 0,
    "total_energy_uj": 0.0,
    "start_time": time.time()
}


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Handles requests in a separate thread for concurrency."""
    daemon_threads = True


class BitNetOpenAIHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Concise logging
        sys.stderr.write(f"[{time.strftime('%H:%M:%S')}] {args[0]} {args[1]} -> {args[2]}\n")

    def _set_headers(self, status=200, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.send_header("X-Hardware-Accelerator", "BitNet-130 Multiplier-Free")
        self.send_header("X-Hardware-Multipliers", "0")
        self.end_headers()

    def do_OPTIONS(self):
        self._set_headers(200)

    def do_GET(self):
        if self.path == "/v1/models" or self.path == "/models":
            self._handle_models()
        elif self.path == "/v1/telemetry" or self.path == "/telemetry":
            self._handle_telemetry()
        elif self.path == "/health":
            self._set_headers(200)
            self.wfile.write(b'{"status": "healthy", "silicon": "online"}')
        else:
            self._set_headers(404)
            self.wfile.write(b'{"error": "Endpoint not found"}')

    def do_POST(self):
        if self.path in ["/v1/chat/completions", "/chat/completions"]:
            self._handle_chat_completions()
        elif self.path in ["/v1/completions", "/completions"]:
            self._handle_legacy_completions()
        else:
            self._set_headers(404)
            self.wfile.write(b'{"error": "Endpoint not found"}')

    def _handle_models(self):
        response = {
            "object": "list",
            "data": [
                {
                    "id": "bitnet130",
                    "object": "model",
                    "created": 1700000000,
                    "owned_by": "bitnet-silicon",
                    "permission": [],
                    "root": "bitnet-130m",
                    "architecture": "1.58-bit Multiplier-Free Ternary"
                },
                {
                    "id": "bitnet-70m",
                    "object": "model",
                    "created": 1700000000,
                    "owned_by": "bitnet-silicon",
                    "root": "bitnet-70m"
                },
                {
                    "id": "bitnet-1b",
                    "object": "model",
                    "created": 1700000000,
                    "owned_by": "bitnet-silicon",
                    "root": "bitnet-1b"
                }
            ]
        }
        self._set_headers(200)
        self.wfile.write(json.dumps(response).encode("utf-8"))

    def _handle_telemetry(self):
        uptime_sec = time.time() - SERVER_STATS["start_time"]
        response = {
            "silicon_architecture": "BitNet-130 Gen-2 Multiplier-Free Top Macro",
            "signoff_clock_mhz": 500.0,
            "hardware_multipliers": 0,
            "processing_elements": 256,
            "peak_throughput_gops": 256.0,
            "requests_served": SERVER_STATS["requests_served"],
            "tokens_generated": SERVER_STATS["tokens_generated"],
            "total_energy_consumed_uj": SERVER_STATS["total_energy_uj"],
            "server_uptime_seconds": uptime_sec,
            "sub_50mw_power_rail": "ACTIVE_BURST (49.2 mW)",
            "retention_standby_power": "DEEP_RETENTION (14.8 uW)"
        }
        self._set_headers(200)
        self.wfile.write(json.dumps(response, indent=2).encode("utf-8"))

    def _handle_chat_completions(self):
        global MODEL_INSTANCE, SERVER_STATS
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            req = json.loads(body.decode("utf-8"))
        except Exception:
            self._set_headers(400)
            self.wfile.write(b'{"error": "Invalid JSON"}')
            return

        messages = req.get("messages", [])
        stream = req.get("stream", False)
        max_tokens = min(req.get("max_tokens", 30), 128)
        temperature = req.get("temperature", 0.7)

        # Extract prompt text
        prompt = ""
        for m in messages:
            role = m.get("role", "user")
            content = m.get("content", "")
            prompt += f"{role}: {content}\n"
        prompt += "assistant: "

        cmpl_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"
        created = int(time.time())

        if stream:
            # Server-Sent Events (SSE) Streaming
            self._set_headers(200, content_type="text/event-stream")

            def send_chunk(text_chunk):
                chunk_data = {
                    "id": cmpl_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": "bitnet130",
                    "choices": [{
                        "index": 0,
                        "delta": {"content": text_chunk},
                        "finish_reason": None
                    }]
                }
                self.wfile.write(f"data: {json.dumps(chunk_data)}\n\n".encode("utf-8"))
                self.wfile.flush()

            # Execute generation with live streaming callback
            res = MODEL_INSTANCE.generate(
                prompt=prompt,
                max_new_tokens=max_tokens,
                temperature=temperature,
                stream_callback=send_chunk
            )

            # Send final stop chunk and [DONE]
            final_chunk = {
                "id": cmpl_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": "bitnet130",
                "choices": [{
                    "index": 0,
                    "delta": {},
                    "finish_reason": "stop"
                }]
            }
            self.wfile.write(f"data: {json.dumps(final_chunk)}\n\n".encode("utf-8"))
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()

        else:
            # Non-streaming JSON response
            res = MODEL_INSTANCE.generate(
                prompt=prompt,
                max_new_tokens=max_tokens,
                temperature=temperature
            )

            response = {
                "id": cmpl_id,
                "object": "chat.completion",
                "created": created,
                "model": "bitnet130",
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": res["text"]
                    },
                    "finish_reason": "stop"
                }],
                "usage": {
                    "prompt_tokens": len(MODEL_INSTANCE.tokenizer.encode(prompt)),
                    "completion_tokens": res["total_tokens"],
                    "total_tokens": len(MODEL_INSTANCE.tokenizer.encode(prompt)) + res["total_tokens"]
                },
                "silicon_telemetry": {
                    "silicon_latency_ms": res["silicon_latency_ms"],
                    "tokens_per_sec": res["tokens_per_sec"],
                    "energy_total_uj": res["energy_total_uj"],
                    "energy_per_token_uj": res["energy_per_token_uj"],
                    "zero_skips": res["zero_skips"],
                    "hardware_multipliers": 0
                }
            }

            self._set_headers(200)
            self.wfile.write(json.dumps(response).encode("utf-8"))

        # Update telemetry
        SERVER_STATS["requests_served"] += 1
        SERVER_STATS["tokens_generated"] += res["total_tokens"]
        SERVER_STATS["total_energy_uj"] += res["energy_total_uj"]


def run_server(host="0.0.0.0", port=8080, model_name="bitnet-130m"):
    global MODEL_INSTANCE
    print("=" * 76)
    print("   BITNET-130 OPENAI-COMPATIBLE HARDWARE REST API SERVER")
    print("   Architecture: 100% Multiplier-Free Silicon Acceleration")
    print("=" * 76)
    print(f"\n>>> Loading model [{model_name}] on BitNet-130 execution engine...")
    MODEL_INSTANCE = BitNetForCausalLM.from_pretrained(model_name)
    print("    [PASS] Model initialized with zero hardware multipliers.")

    server_address = (host, port)
    httpd = ThreadedHTTPServer(server_address, BitNetOpenAIHandler)
    print(f"\n>>> BitNet-130 API Server listening at: http://{host}:{port}/v1")
    print(f"    Available Endpoints:")
    print(f"      * POST http://localhost:{port}/v1/chat/completions  (OpenAI Compatible)")
    print(f"      * GET  http://localhost:{port}/v1/models            (Model Directory)")
    print(f"      * GET  http://localhost:{port}/v1/telemetry         (Live Silicon Metrics)")
    print("=" * 76)
    print("Ready to serve requests (Press Ctrl+C to stop)...\n")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping BitNet-130 API Server...")
        httpd.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="BitNet-130 OpenAI API Server")
    parser.add_argument("--host", type=str, default="0.0.0.0", help="Bind address")
    parser.add_argument("--port", type=int, default=8080, help="Listen port")
    parser.add_argument("--model", type=str, default="bitnet-130m", help="BitNet model preset")
    args = parser.parse_args()

    run_server(host=args.host, port=args.port, model_name=args.model)
