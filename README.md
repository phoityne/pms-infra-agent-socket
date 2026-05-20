# pms-infra-agent-socket

----
## ⚠️ Caution

**Do not grant unrestricted control to AI.**  
Unsupervised use or misuse may lead to unintended consequences.  
All AI systems must remain strictly under human oversight and control.  
Use responsibly, with full awareness and at your own risk.  

----
## 📘 Overview

**`pms-infra-agent-socket`** is a Haskell infrastructure library that provides AI agents with direct, low-level control over socket-based communication endpoints.

Unlike higher-level abstractions, this library exposes raw byte-stream access over both TCP/IP and Unix Domain Sockets, allowing agents to handle protocol-specific exchanges such as Telnet IAC negotiation, binary protocol framing, and real-time I/O monitoring with fine-grained control.

The library is a core component of the [`pty-mcp-server`](https://github.com/phoityne/pty-mcp-server) ecosystem and implements the `agent-socket-*` family of MCP tools.

---

## 🔧 Provided MCP Tools

### `agent-socket-open`
Opens a socket connection for subsequent read/write operations.  
Supports both **TCP** (`host` + `port`) and **Unix Domain Socket** (`file`) connections via a single tool.

- `host` — TCP host name or IP address  
- `port` — TCP service name or port number  
- `file` — Unix domain socket path (absolute path required on Windows)  

Only one socket connection can be active at a time.

### `agent-socket-close`
Closes the active socket connection and releases all associated resources.

### `agent-socket-read`
Reads up to the specified number of bytes from the active socket connection and returns the data as a **UTF-8 string**.  
Returns an empty string if no data is available before timeout.

- `length` — Maximum number of bytes to read  

> ⚠️ If the received data contains non-UTF-8 bytes (e.g., binary protocols, IAC bytes), use `agent-socket-read-byte` instead.

### `agent-socket-read-byte`
Reads up to the specified number of bytes from the active socket connection and returns the data as an **uppercase hex string** (e.g., `FF0A1B41`).  
Use this for binary protocols or when precise byte-level inspection is required.

- `length` — Maximum number of bytes to read  

### `agent-socket-write`
Writes the specified **UTF-8 string** to the active socket connection.

- `data` — Text data to write  

> ⚠️ Escape sequences such as `\r\n` in the string are sent as literal characters. To send exact byte sequences (e.g., CR+LF = `0D0A`), use `agent-socket-write-byte`.

### `agent-socket-write-byte`
Decodes the specified **hex string** and writes the resulting bytes to the active socket connection.  
Use this for binary protocols or when precise byte-level control is required.

- `data` — Uppercase hex string to decode and write (e.g., `DEADBEEF0D0A`)  

---

## 💡 Usage Notes

### IAC / Telnet negotiation
Telnet IAC processing is the **responsibility of the agent**, not the library.  
Use `agent-socket-read-byte` and `agent-socket-write-byte` to handle IAC sequences at the byte level.

Example negotiation flow:
```
← FFFD18FFFD20FFFD23FFFD27   (Server: IAC DO TERMINAL-TYPE/SPEED/X-DISPLAY/NEW-ENVIRON)
→ FFFC18FFFC20FFFC23FFFC27   (Agent:  IAC WONT x4)
← FFFB03FFFD01FFFD1FFFFB05   (Server: IAC WILL SGA / DO ECHO / DO NAWS / WILL STATUS)
→ FFFD03FFFB01FFFC1FFFFD05   (Agent:  IAC DO SGA / WILL ECHO / WONT NAWS / DO STATUS)
← "localhost login: "         (Login prompt — read as UTF-8 string)
→ "phoityne\r\n"              (Username — send as bytes: 70686F6974796E650D0A)
← "Password: "                (Password prompt)
```

### Unix Domain Socket on Windows
Unix Domain Socket (`file` parameter) is supported on **Windows 10 build 1803 and later** at the OS level.  
However, the socket server side must be implemented in a runtime that supports `AF_UNIX` on Windows.

- **Python 3.13.7 (Windows)**: `socket.AF_UNIX` is unavailable unless **Developer Mode** is enabled.
- **PowerShell / .NET**: `System.Net.Sockets.UnixDomainSocketEndPoint` works without Developer Mode.
- **pty-mcp-server (Haskell)**: Confirmed working on Windows 11 via `Network.Socket` with `AF_UNIX`.

---

## 🏗️ Architecture

### Module Structure

```
PMS.Infra.Agent.Socket
├── DM.Type        -- Data type definitions (SocketData, AppData, tool parameter types)
├── DM.Constant    -- Constants
├── DS.Core        -- Core domain service logic
├── DS.Utility     -- Utility functions (TCP connect, Unix Domain Socket connect)
└── App.Control    -- Application control: tool dispatch and socket lifecycle management
```

### Key Design Points

- **Single active connection**: Only one socket can be open at a time per server instance. State is managed via `STM.TMVar`.
- **Dual connection mode**: `agent-socket-open` supports both TCP (`host`/`port`) and Unix Domain Socket (`file`) via a single unified interface.
- **Non-blocking reads**: Read operations return immediately with available data, allowing the agent to poll at its own pace.
- **Byte-level I/F**: In addition to UTF-8 string I/F, hex string I/F is provided for binary protocol handling. IAC processing and protocol framing are delegated to the agent.

---

## 📦 Dependencies

- [`pms-domain-model`](https://github.com/phoityne/pms-domain-model)

---

## 📜 Credits & License

- **Execution & Process Lead:** Claude Sonnet 4.6, Gemini 3 Flash, GPT-5.5
- **Direction & Policy:** phoityne
- **License:** Apache-2.0 — see [LICENSE](./LICENSE)

---
