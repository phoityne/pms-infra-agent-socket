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

### AI-to-AI communication

Any two AI agents that each have a `pty-mcp-server` instance can communicate with each other directly over TCP — no shared infrastructure, message broker, or custom integration required.

One agent uses the `agent-server-*` tools to act as a TCP server; the other uses the `agent-socket-*` tools (this library) to act as a TCP client. The agents exchange messages using a lightweight text protocol, and each agent interprets and responds to the other's messages autonomously.

```
┌─────────────────────────────┐         ┌─────────────────────────────┐
│        AI Agent A           │         │        AI Agent B           │
│  (e.g. Claude on Machine A) │         │  (e.g. GPT on Machine B)    │
│                             │         │                             │
│  pty-mcp-server             │  TCP    │  pty-mcp-server             │
│  agent-server-listen :19999 │◄───────►│  agent-socket-open          │
│  agent-server-write         │         │  agent-socket-read          │
│  agent-server-events        │         │  agent-socket-write         │
└─────────────────────────────┘         └─────────────────────────────┘
         Server role                              Client role
```

#### What this enables

- **Collaborative task solving** — Agent A breaks down a problem and delegates subtasks to Agent B, collecting results over the socket.
- **Cross-model review** — One model generates code or text; another model on a different machine reviews it and sends back comments.
- **Heterogeneous agent pipelines** — Chain agents of different models or specialisations (Claude, GPT, Gemini, …) into a processing pipeline across machines.
- **Autonomous negotiation** — Agents can exchange proposals, counter-proposals, and decisions without human involvement in each round-trip.
- **Distributed tool use** — Agent B may have access to tools (databases, sensors, local files) that Agent A does not. Agent A requests operations from Agent B over the socket.

#### Communication protocol

The `pty-mcp-server` ecosystem ships a lightweight handshake and messaging protocol for AI-to-AI sessions. Prompt skills (`skill_agent_server.md` / `skill_agent_client.md`) are provided so each agent knows exactly how to play its role.

**Handshake sequence:**
```
Server → Client : HELLO? name?\r\n
Server ← Client : NAME: <name>\r\n
Server → Client : RULES: MSG:<content>\r\n | REPLY:<content>\r\n | BYE\r\n | HEX:<hex>\r\n
Server ← Client : ACK\r\n
```

**Conversation:**
```
Server → Client : MSG: <content>\r\n
Server ← Client : REPLY: <content>\r\n
```

**Graceful shutdown (server-initiated):**
```
Server → Client : BYE\r\n
Server ← Client : ACK\r\n    ← server waits for this before closing
Server           : agent-server-close
```

#### Full session example

The following shows a complete exchange where Agent A (server role) delegates a task to Agent B (client role).

**Agent A — server side**
```
agent-server-listen host=172.16.0.43 port=19999
  → "listening."

--- Agent B connects ---

agent-server-events
  → [{ "tag": "ClientConnected" }]

agent-server-write-byte  "48454C4C4F3F206E616D653F0D0A"   ("HELLO? name?\r\n")

agent-server-events  (poll until BytesReceived)
  → bytes: "4E414D453A20416765742D420D0A"   ("NAME: Agent-B\r\n")

agent-server-write-byte  "<hex of RULES: MSG:... | REPLY:... | BYE\r\n>"

agent-server-events  (poll for ACK)
  → bytes: "41434B0D0A"   ("ACK\r\n")

--- handshake complete ---

agent-server-write-byte  "<hex of MSG: Please summarise this text: ...\r\n>"

agent-server-events  (poll for REPLY)
  → bytes: "<hex of REPLY: Here is the summary: ...\r\n>"

agent-server-write-byte  "<hex of BYE\r\n>"

agent-server-events  (poll for ACK)
  → bytes: "41434B0D0A"   ("ACK\r\n")

agent-server-close
```

**Agent B — client side**
```
agent-socket-open host=172.16.0.43 port=19999
  → socket connected to 172.16.0.43:19999

agent-socket-read length=256
  → "HELLO? name?\r\n"

agent-socket-write-byte  "<hex of NAME: Agent-B\r\n>"

agent-socket-read length=256
  → "RULES: MSG:<content>\r\n | REPLY:<content>\r\n | BYE\r\n | HEX:<hex>\r\n"

agent-socket-write-byte  "<hex of ACK\r\n>"

--- handshake complete ---

agent-socket-read length=1024
  → "MSG: Please summarise this text: ...\r\n"

--- Agent B processes the request autonomously ---

agent-socket-write-byte  "<hex of REPLY: Here is the summary: ...\r\n>"

agent-socket-read length=256
  → "BYE\r\n"

agent-socket-write-byte  "<hex of ACK\r\n>"

agent-socket-close
```

> 💡 Always use `agent-socket-write-byte` (not `agent-socket-write`) to ensure `\r\n` is sent as correct CRLF bytes.  
> Generate hex strings with: `python3 -c "print('your message\r\n'.encode().hex())"`

---

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

Full login session example (confirmed with a real Linux Telnet server):
```
agent-socket-open host=172.16.0.171 port=23
  → socket connected to 172.16.0.171:23

← FFFD18FFFD20FFFD23FFFD27
    (IAC DO TERMINAL-TYPE / DO TERMINAL-SPEED / DO X-DISPLAY / DO NEW-ENVIRON)
→ FFFC18FFFC20FFFC23FFFC27
    (IAC WONT x4)

← FFFB03FFFD01FFFD1FFFFB05FFFD21
    (IAC WILL SGA / DO ECHO / DO NAWS / WILL STATUS / DO REMOTE-FLOW-CONTROL)
→ FFFD03FFFB01FFFC1FFFFD05FFFC21
    (IAC DO SGA / WILL ECHO / WONT NAWS / DO STATUS / WONT REMOTE-FLOW-CONTROL)

← FFFE01FFFB01 + "Kernel 6.12.0-...\r\nlocalhost login: "
→ 61692D6167656E740D0A   ("ai-agent\r\n"  — username as bytes)

← "ai-agent\r\nPassword: "
→ 61692D6167656E740D0A   ("ai-agent\r\n"  — password as bytes)

← "Last login: ...\r\n[ai-agent@localhost ~]$ "

→ 686F73746E616D650D0A   ("hostname\r\n")
← "hostname\r\nlocalhost.localdomain\r\n[ai-agent@localhost ~]$ "

→ 657869740D0A   ("exit\r\n")
← "exit\r\nlogout\r\n"

agent-socket-close
  → socket is closed.
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
