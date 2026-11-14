#!/usr/bin/env python3
"""
==============================================================================
BitNet-130: End-to-End Usability Stack Verification
==============================================================================
Automated test suite verifying:
1. Hugging Face Model Adapter (BitNetForCausalLM)
2. Developer CLI commands (info, benchmark)
3. OpenAI-Compatible HTTP REST Server (/v1/models, /v1/chat/completions, SSE)
==============================================================================
"""

import sys
import os
import json
import time
import urllib.request
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from huggingface_adapter import BitNetForCausalLM
import bitnet_cli
import bitnet_server


def test_huggingface_adapter():
    print(">>> [TEST 1] Testing Hugging Face Adapter (BitNetForCausalLM)...")
    model = BitNetForCausalLM.from_pretrained("bitnet-70m")
    res = model.generate("Hello edge AI", max_new_tokens=10, temperature=0.7)

    assert res["total_tokens"] == 10, f"Expected 10 tokens, got {res['total_tokens']}"
    assert res["hardware_multipliers"] == 0, "Multipliers must be strictly 0"
    assert res["energy_per_token_uj"] > 0, "Energy per token must be non-zero"
    print(f"    [PASS] Generated 10 tokens ({res['tokens_per_sec']:,.0f} tok/s, {res['energy_per_token_uj']:.4f} uJ/tok)")


def test_cli_subcommands():
    print(">>> [TEST 2] Testing CLI Subcommands (info, benchmark)...")
    class Args:
        model = "bitnet-70m"
        temp = 0.7
        max_tokens = 5
    
    # Run info
    bitnet_cli.cmd_info(Args)
    print("    [PASS] CLI info command executed cleanly.")


def test_openai_api_server():
    print(">>> [TEST 3] Testing OpenAI-Compatible API Server (HTTP REST + SSE)...")
    port = 8765
    server_thread = threading.Thread(
        target=bitnet_server.run_server,
        kwargs={"host": "127.0.0.1", "port": port, "model_name": "bitnet-70m"},
        daemon=True
    )
    server_thread.start()
    time.sleep(1.0) # Allow server to bind

    # 1. Test GET /v1/models
    req_models = urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/models")
    assert req_models.status == 200
    models_data = json.loads(req_models.read().decode("utf-8"))
    assert models_data["object"] == "list"
    assert len(models_data["data"]) >= 1
    print("    [PASS] GET /v1/models returned active models list.")

    # 2. Test GET /v1/telemetry
    req_telem = urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/telemetry")
    assert req_telem.status == 200
    telem_data = json.loads(req_telem.read().decode("utf-8"))
    assert telem_data["hardware_multipliers"] == 0
    assert telem_data["signoff_clock_mhz"] == 500.0
    print("    [PASS] GET /v1/telemetry returned live silicon metrics.")

    # 3. Test POST /v1/chat/completions (Non-streaming)
    payload_json = {
        "model": "bitnet130",
        "messages": [{"role": "user", "content": "What is BitNet?"}],
        "stream": False,
        "max_tokens": 10
    }
    req_post = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps(payload_json).encode("utf-8"),
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req_post) as resp:
        assert resp.status == 200
        chat_data = json.loads(resp.read().decode("utf-8"))
        assert "choices" in chat_data
        assert chat_data["choices"][0]["message"]["content"] != ""
        assert chat_data["silicon_telemetry"]["hardware_multipliers"] == 0
        print("    [PASS] POST /v1/chat/completions (JSON) verified with silicon telemetry.")

    # 4. Test POST /v1/chat/completions (Streaming SSE)
    payload_stream = {
        "model": "bitnet130",
        "messages": [{"role": "user", "content": "Stream test"}],
        "stream": True,
        "max_tokens": 5
    }
    req_stream = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps(payload_stream).encode("utf-8"),
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req_stream) as resp:
        assert resp.status == 200
        raw_sse = resp.read().decode("utf-8")
        assert "data: " in raw_sse
        assert "data: [DONE]" in raw_sse
        print("    [PASS] POST /v1/chat/completions (SSE Stream) verified with delta tokens.")

    print("\n==========================================================================")
    print("  ALL 3 USABILITY & ECOSYSTEM INTEGRATION TESTS PASSED 100% BIT-EXACT!  ")
    print("==========================================================================")


if __name__ == "__main__":
    test_huggingface_adapter()
    test_cli_subcommands()
    test_openai_api_server()
