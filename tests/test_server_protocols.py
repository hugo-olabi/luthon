"""Tests for hosting server protocols and simulating clients (WebSockets, raw TCP sockets, HTTP).

Verifies full client-server communication in standard mode and with the --pure flag.
"""

import unittest
import tempfile
import subprocess
import os
from pathlib import Path

from luthon.transpiler import transpile_ir


class TestServerProtocolsAndClients(unittest.TestCase):
    """Test suite for server hosting and client simulation across multiple protocols."""

    @classmethod
    def setUpClass(cls):
        cls.root_src = str(Path(__file__).parent.parent / "src")
        cls.env = os.environ.copy()
        cls.env["LUA_PATH"] = f"{cls.root_src}/luthon/lua/?.lua;{cls.root_src}/luthon/lua/native/?.lua;;{cls.root_src}/?.lua;;"

    def _execute_lua(self, py_code: str, pure: bool = False, optimize: bool = True, timeout: int = 10):
        lua_code = transpile_ir(py_code, optimize=optimize)
        if pure:
            lua_code = "_G.__LUTHON_PURE__ = true\n" + lua_code

        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write(lua_code)
            f_path = Path(f.name)

        try:
            env = self.env.copy()
            if pure:
                env["LUTHON_PURE"] = "1"
            res = subprocess.run(["luajit", str(f_path)], capture_output=True, text=True, env=env, timeout=timeout)
            return res
        finally:
            if f_path.exists():
                f_path.unlink()

    def test_websocket_server_hosting_and_client_simulation(self):
        """Test hosting a WebSocket echo server and connecting with an async WebSocket client."""
        py_code = """
import asyncio
import websockets

async def echo_handler(websocket):
    for i in range(3):
        msg = await websocket.recv()
        await websocket.send(f"ECHO_{msg}")

async def main():
    port = 39801
    async with websockets.serve(echo_handler, "127.0.0.1", port):
        async with websockets.connect(f"ws://127.0.0.1:{port}") as client:
            # Round 1
            await client.send("Hello")
            r1 = await client.recv()
            assert r1 == "ECHO_Hello", f"Got: {r1}"

            # Round 2
            await client.send("Luthon")
            r2 = await client.recv()
            assert r2 == "ECHO_Luthon", f"Got: {r2}"

            # Round 3
            await client.send("HighSpeed")
            r3 = await client.recv()
            assert r3 == "ECHO_HighSpeed", f"Got: {r3}"

    return "WEBSOCKET_HOSTING_OK"

res = asyncio.run(main())
assert res == "WEBSOCKET_HOSTING_OK"
print(res)
"""
        proc = self._execute_lua(py_code)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("WEBSOCKET_HOSTING_OK", proc.stdout)

    def test_socket_tcp_server_hosting_and_client_standard_mode(self):
        """Test raw TCP socket server and client communication in standard mode."""
        py_code = """
import socket

port = 39802

# Server setup
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', port))
server.listen(5)

# Client setup and connection
client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
client.connect(('127.0.0.1', port))

# Server accepts connection
conn, addr = server.accept()

# Client -> Server
client.send(b"CLIENT_PAYLOAD_123")
req = conn.recv(1024)
assert req == "CLIENT_PAYLOAD_123", f"Server received: {req}"

# Server -> Client
conn.send(b"SERVER_REPLY_456")
resp = client.recv(1024)
assert resp == "SERVER_REPLY_456", f"Client received: {resp}"

conn.close()
client.close()
server.close()
print("TCP_SOCKET_STANDARD_OK")
"""
        proc = self._execute_lua(py_code, pure=False)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("TCP_SOCKET_STANDARD_OK", proc.stdout)

    def test_socket_tcp_server_hosting_and_client_pure_mode(self):
        """Test raw TCP socket server and client communication under --pure mode."""
        py_code = """
import socket

port = 39803

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', port))
server.listen(1)

client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
client.connect(('127.0.0.1', port))

conn, addr = server.accept()

client.send(b"PING_PURE_TCP")
data = conn.recv(1024)
assert data == "PING_PURE_TCP", f"Server got: {data}"

conn.send(b"PONG_PURE_TCP")
reply = client.recv(1024)
assert reply == "PONG_PURE_TCP", f"Client got: {reply}"

conn.close()
client.close()
server.close()
print("TCP_SOCKET_PURE_OK")
"""
        proc = self._execute_lua(py_code, pure=True)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed (pure mode): {proc.stderr}")
        self.assertIn("TCP_SOCKET_PURE_OK", proc.stdout)

    def test_http_server_and_client_simulation_standard_and_pure(self):
        """Test simulating an HTTP 1.1 server and client over sockets in standard and pure modes."""
        py_code = """
import socket

port = 39804

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', port))
server.listen(1)

# Client requests /api/health
client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
client.connect(('127.0.0.1', port))
http_get = b"GET /api/health HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\n\\r\\n"
client.send(http_get)

# Server handles request and responds
conn, addr = server.accept()
req_data = conn.recv(4096)
assert "GET /api/health" in req_data

http_resp = (
    b"HTTP/1.1 200 OK\\r\\n"
    b"Content-Type: application/json\\r\\n"
    b"Content-Length: 15\\r\\n"
    b"\\r\\n"
    b"{\\"status\\":\\"ok\\"}"
)
conn.send(http_resp)

# Client verifies response
response = client.recv(4096)
assert "200 OK" in response
assert "{\\"status\\":\\"ok\\"}" in response

conn.close()
client.close()
server.close()
print("HTTP_SIMULATION_OK")
"""
        # Test in standard mode
        proc1 = self._execute_lua(py_code, pure=False)
        self.assertEqual(proc1.returncode, 0, f"Standard HTTP simulation failed: {proc1.stderr}")
        self.assertIn("HTTP_SIMULATION_OK", proc1.stdout)

        # Test in pure mode (--pure)
        proc2 = self._execute_lua(py_code, pure=True)
        self.assertEqual(proc2.returncode, 0, f"Pure HTTP simulation failed: {proc2.stderr}")
        self.assertIn("HTTP_SIMULATION_OK", proc2.stdout)


if __name__ == "__main__":
    unittest.main()
