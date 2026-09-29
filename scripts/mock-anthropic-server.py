#!/usr/bin/env python3
"""The mock server now answers OpenAI and Ollama too; see mock-llm-server.py. This name is kept so old commands still work."""
import os
import sys

script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock-llm-server.py")
os.execv(sys.executable, [sys.executable, script] + sys.argv[1:])
