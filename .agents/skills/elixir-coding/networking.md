# Networking — TCP, UDP, and Socket Programming

TCP/UDP socket programming patterns for Elixir/Erlang. Covers `:gen_tcp`, `:gen_udp`, active vs passive modes, protocol framing, connection supervision, and production server libraries (Thousand Island, Ranch).

> **Pattern sources:** Mint HTTP client (passive-mode TCP, buffer management), Tortoise MQTT client (gen_statem + binary framing), ExRTP (binary protocol encode/decode), Thousand Island (production socket server), Ranch (Erlang acceptor pools), Elixir's official "Task and gen_tcp" guide.

## Rules for Network Programming (LLM)

1. **NEVER block a GenServer callback with `:gen_tcp.accept/1` or `:gen_tcp.recv/2`.** Accept loops must run in a spawned process or Task. Use `active: :once` mode for non-blocking receive in GenServer `handle_info`.
2. **ALWAYS use `active: :once` for production TCP servers.** It provides per-message flow control. `active: true` risks mailbox overflow from fast senders. `active: false` blocks the process.
3. **ALWAYS re-arm `active: :once` after handling each message** with `:inet.setopts(socket, active: :once)`. Forgetting this silently stops receiving data.
4. **ALWAYS call `:gen_tcp.controlling_process/2`** when handing an accepted socket to a different process. Without it, the new process cannot receive active-mode messages and the socket closes if the acceptor crashes.
5. **ALWAYS handle `{:tcp_closed, socket}` and `{:tcp_error, socket, reason}`** in every process that owns a socket. Connections WILL drop — ignoring these messages leaks sockets.
6. **ALWAYS open TCP listen sockets with `[:binary, active: false, reuseaddr: true]`** as baseline options. Add `{:packet, :raw}` (default) for binary protocols, `{:packet, :line}` for text protocols.
7. **NEVER assume a single `:gen_tcp.recv/2` returns a complete message.** TCP is a byte stream, not a message stream. Implement framing (length-prefix, delimiter, or fixed-size) and buffer incomplete data.
8. **ALWAYS set `{:send_timeout, milliseconds}`** on sockets where slow consumers could block the sender. Without it, `:gen_tcp.send/2` blocks indefinitely when the OS send buffer is full.
9. **PREFER `:gen_tcp.shutdown(socket, :write)`** before `:gen_tcp.close/1` for graceful shutdown. `shutdown(:write)` sends TCP FIN, signaling end-of-stream to the peer while allowing final reads.
10. **PREFER Thousand Island over raw `:gen_tcp`** for production servers. It handles acceptor pools, connection supervision, TLS, and telemetry. Use raw `:gen_tcp` for clients, learning, or embedded (AtomVM).
11. **ALWAYS use `{:packet, N}`** (where N is 1, 2, or 4) when you control both endpoints and need simple framing. Erlang automatically prepends/strips the length header — zero application code needed.
12. **NEVER use `String.to_atom/1` on data received from sockets.** Atom table exhaustion is a denial-of-service vector. Use `String.to_existing_atom/1` or keep data as strings/binaries.

## Active Mode Decision Guide

The single most important TCP decision. This controls how your process receives data from the socket.

| Mode | How data arrives | Flow control | Use when |
|------|-----------------|--------------|----------|
| `{active, false}` | Must call `:gen_tcp.recv/2,3` | Full control (blocking) | Clients, simple protocols, sequential parsing (Mint passive mode) |
| `{active, :once}` | One `{:tcp, socket, data}` message, then pauses | Per-message backpressure | **Most production servers** — Mint default, Thousand Island, Tortoise |
| `{active, N}` | N messages then pauses, sends `{:tcp_passive, socket}` | Batched (N messages at a time) | High-throughput, tunable backpressure (OTP 17+) |
| `{active, true}` | Unlimited `{:tcp, socket, data}` messages | **NONE** — mailbox can overflow | Trusted LAN, short-lived connections, benchmarks |

### active: :once Pattern (Recommended Default)

The standard production pattern. Receive one message, process it, re-arm for the next:

```elixir
# In GenServer init or after accepting connection
:inet.setopts(socket, active: :once)

# handle_info receives exactly one TCP message
@impl true
def handle_info({:tcp, socket, data}, state) do
  state = process_data(data, state)
  :inet.setopts(socket, active: :once)    # Re-arm for next message
  {:noreply, state}
end

def handle_info({:tcp_closed, socket}, state) do
  {:stop, :normal, state}
end

def handle_info({:tcp_error, socket, reason}, state) do
  Logger.warning("TCP error: #{inspect(reason)}")
  {:stop, reason, state}
end
```

**Why `:once` over `true`:** If a client sends data faster than the server processes it, `active: true` fills the process mailbox unboundedly. With `:once`, only one message is queued at a time — natural backpressure.

### active: N Pattern (High Throughput)

Receive N messages before pausing. Re-arm in batches for reduced `:inet.setopts` overhead:

```elixir
# Set initial batch size
:inet.setopts(socket, active: 100)

# After processing a batch, re-arm
def handle_info({:tcp_passive, socket}, state) do
  # Socket has delivered all N messages, now passive
  :inet.setopts(socket, active: 100)    # Re-arm for next batch
  {:noreply, state}
end

# Individual messages still arrive as {:tcp, socket, data}
def handle_info({:tcp, socket, data}, state) do
  {:noreply, process_data(data, state)}
end
```

**Note:** `{active, N}` values are additive — setting `active: 10` when 5 remain makes it 15. Set to `active: 0` to explicitly pause. The `{:tcp_passive, socket}` message fires when the counter reaches 0.

### active: false Pattern (Blocking)

Simplest model — call `recv` when ready. Used by Mint in passive mode:

```elixir
# Blocking read — process blocks until data arrives or timeout
case :gen_tcp.recv(socket, 0, 5_000) do
  {:ok, data} -> process(data)
  {:error, :timeout} -> :retry
  {:error, :closed} -> :disconnected
  {:error, reason} -> {:error, reason}
end

# Read exact number of bytes (for length-prefixed protocols)
{:ok, <<length::32>>} = :gen_tcp.recv(socket, 4, 5_000)
{:ok, payload} = :gen_tcp.recv(socket, length, 5_000)
```

**When passive makes sense:** Sequential request-response protocols where you know exactly when to expect data. Mint uses passive mode for HTTP/1.1 when the caller wants synchronous behavior.

## :gen_tcp API Reference

### Opening a Listener

```elixir
# Standard TCP server listen socket
{:ok, listen_socket} = :gen_tcp.listen(port, [
  :binary,                    # Receive data as binaries (not charlists)
  active: false,              # Start passive, switch to :once after accept
  reuseaddr: true,            # Allow rebinding after restart
  backlog: 128,               # Max pending connections queue (default: 5)
  # nodelay: true,            # Disable Nagle's algorithm (low latency)
  # send_timeout: 10_000,     # Max ms for send to complete
  # send_timeout_close: true, # Close socket on send timeout
  # buffer: 65_536,           # User-level receive buffer size
  # recbuf: 65_536,           # Kernel receive buffer size
  # sndbuf: 65_536,           # Kernel send buffer size
])
```

### Accepting Connections

```elixir
# Blocking accept — returns when a client connects
{:ok, client_socket} = :gen_tcp.accept(listen_socket)
# With timeout (useful in accept loops for clean shutdown)
case :gen_tcp.accept(listen_socket, 1_000) do
  {:ok, client_socket} -> handle_connection(client_socket)
  {:error, :timeout} -> check_shutdown_and_retry()
  {:error, :closed} -> :listener_closed
end
```

### Sending Data

```elixir
# Send binary or IO list — blocks until OS buffer accepts data
:ok = :gen_tcp.send(socket, "hello")
:ok = :gen_tcp.send(socket, ["hello", " ", "world"])   # IO list — no copy
:ok = :gen_tcp.send(socket, <<1::8, 0::8, 5::16, "hello">>)  # Binary protocol

# Error handling
case :gen_tcp.send(socket, data) do
  :ok -> :sent
  {:error, :closed} -> :peer_disconnected
  {:error, :timeout} -> :send_buffer_full      # Only with send_timeout option
  {:error, reason} -> {:error, reason}          # POSIX: :econnreset, :epipe, etc.
end
```

### Closing

```elixir
# Abrupt close — pending data may be lost
:gen_tcp.close(socket)

# Graceful shutdown — send FIN, then close
# Lets peer know we're done sending while still reading their final data
:gen_tcp.shutdown(socket, :write)    # Send TCP FIN
# ... read any remaining data from peer ...
:gen_tcp.close(socket)

# shutdown/2 modes:
# :write — close write side (send FIN), can still read
# :read  — close read side, can still write
# :read_write — close both (equivalent to close/1)
```

### Socket Options

```elixir
# Get current options
{:ok, opts} = :inet.getopts(socket, [:active, :packet, :buffer])

# Set options mid-connection
:ok = :inet.setopts(socket, active: :once)
:ok = :inet.setopts(socket, packet: :raw, active: false)

# Transfer socket ownership to another process
:ok = :gen_tcp.controlling_process(socket, handler_pid)
```

**Common socket options:**

| Option | Values | Default | Purpose |
|--------|--------|---------|---------|
| `:binary` / `:list` | flag | `:list` | Data format (always use `:binary`) |
| `active:` | `false \| true \| :once \| N` | `true` | Message delivery mode |
| `packet:` | `0 \| 1 \| 2 \| 4 \| :raw \| :line` | `0` (`:raw`) | Automatic framing |
| `reuseaddr:` | boolean | `false` | Reuse address after restart |
| `nodelay:` | boolean | `false` | Disable Nagle (low-latency) |
| `backlog:` | integer | `5` | Pending connection queue size |
| `send_timeout:` | ms \| `:infinity` | `:infinity` | Max time for send |
| `send_timeout_close:` | boolean | `false` | Close on send timeout |
| `buffer:` | bytes | OS default | User-space receive buffer |
| `recbuf:` | bytes | OS default | Kernel receive buffer |
| `sndbuf:` | bytes | OS default | Kernel send buffer |
| `ip:` | ip_address | any | Bind to specific interface |
| `keepalive:` | boolean | `false` | TCP keepalive probes |
| `linger:` | `{bool, seconds}` | `{false, 0}` | Linger on close |

### The `packet:` Option — Automatic Framing

When you control both endpoints, let Erlang handle framing automatically:

| `packet:` value | Framing | Header size | Max payload |
|----------------|---------|-------------|-------------|
| `0` or `:raw` | None (raw bytes) | 0 | N/A |
| `1` | Length-prefixed | 1 byte | 255 bytes |
| `2` | Length-prefixed | 2 bytes | 65,535 bytes |
| `4` | Length-prefixed | 4 bytes | 2 GB |
| `:line` | Newline-delimited | 0 | `:buffer` size |

```elixir
# With packet: 4, Erlang handles framing transparently
# Sender side — Erlang prepends 4-byte length header
{:ok, socket} = :gen_tcp.connect(~c"localhost", 4000, [:binary, packet: 4])
:gen_tcp.send(socket, "hello")  # Actually sends <<0, 0, 0, 5, "hello">>

# Receiver side — Erlang strips header, delivers complete messages
# {:tcp, socket, "hello"}  — always a complete message, never partial
```

**Use `packet: N` when:** Both endpoints are BEAM (Erlang/Elixir) or you control the protocol. It eliminates all framing code.

**Use `packet: :raw` when:** Implementing a standard protocol (HTTP, MQTT, custom binary), interoperating with non-BEAM systems, or when you need streaming/incremental parsing.

## Active Mode Message Reference

### TCP Messages (in Elixir tuple syntax)

```elixir
# Data received (active modes only)
{:tcp, socket, data}              # data is binary when socket opened with :binary

# Connection closed by peer
{:tcp_closed, socket}

# Socket error
{:tcp_error, socket, reason}      # reason: :etimedout, :econnreset, :econnaborted, etc.

# Passive transition (active: N only, OTP 17+)
{:tcp_passive, socket}            # Counter reached 0, socket now passive
```

### UDP Messages

```elixir
# Datagram received
{:udp, socket, sender_ip, sender_port, data}

# Socket error
{:udp_error, socket, reason}

# Passive transition (active: N only)
{:udp_passive, socket}
```

## TCP Listener/Acceptor Pattern

The standard Elixir pattern for accepting TCP connections. A listen socket is opened once, then an accept loop runs in a separate process, spawning handlers for each connection.

### Minimal Echo Server (Task-Based)

From the official Elixir guide pattern — simplest supervised acceptor:

```elixir
defmodule EchoServer do
  @moduledoc "Supervised TCP echo server using Task.Supervisor for handlers."
  require Logger

  def start_link(port) do
    {:ok, listen_socket} = :gen_tcp.listen(port, [
      :binary, active: false, reuseaddr: true, packet: :line
    ])
    Logger.info("Echo server listening on port #{port}")
    Task.start_link(fn -> accept_loop(listen_socket) end)
  end

  defp accept_loop(listen_socket) do
    {:ok, client} = :gen_tcp.accept(listen_socket)
    {:ok, pid} = Task.Supervisor.start_child(
      EchoServer.TaskSupervisor,
      fn -> serve(client) end
    )
    :ok = :gen_tcp.controlling_process(client, pid)
    accept_loop(listen_socket)
  end

  defp serve(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        :gen_tcp.send(socket, data)
        serve(socket)
      {:error, :closed} ->
        :ok
    end
  end
end

# Supervision tree
children = [
  {Task.Supervisor, name: EchoServer.TaskSupervisor},
  Supervisor.child_spec({Task, fn -> EchoServer.start_link(4000) end}, restart: :permanent)
]
```

**Key points:**
- `controlling_process/2` transfers the socket from the acceptor to the handler
- Without it, the socket closes if the acceptor moves on (it's the "owner")
- Handler tasks are `:temporary` (don't restart on crash) — connection loss is expected
- Acceptor task is `:permanent` — must always be running

### GenServer-Based Handler (active: :once)

For stateful connection handling — track connection state, buffer data, handle timeouts:

```elixir
defmodule MyApp.ConnectionHandler do
  @moduledoc "Stateful TCP connection handler using active: :once."
  use GenServer
  require Logger

  defstruct [:socket, :peer, buffer: <<>>]

  def start_link(socket) do
    GenServer.start_link(__MODULE__, socket)
  end

  @impl true
  def init(socket) do
    # Get peer info before switching to active mode
    {:ok, {ip, port}} = :inet.peername(socket)
    :inet.setopts(socket, active: :once)
    {:ok, %__MODULE__{socket: socket, peer: {ip, port}}}
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    state = handle_data(data, state)
    :inet.setopts(socket, active: :once)    # Re-arm
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.debug("Connection closed by #{inspect(state.peer)}")
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.warning("TCP error from #{inspect(state.peer)}: #{inspect(reason)}")
    {:stop, reason, state}
  end

  defp handle_data(new_data, state) do
    # Accumulate buffer, parse complete frames
    buffer = state.buffer <> new_data
    {frames, remaining} = parse_frames(buffer)
    Enum.each(frames, &process_frame/1)
    %{state | buffer: remaining}
  end

  # Length-prefixed framing: 4-byte header + payload
  defp parse_frames(buffer, acc \\ [])
  defp parse_frames(<<length::32, payload::binary-size(length), rest::binary>>, acc) do
    parse_frames(rest, [payload | acc])
  end
  defp parse_frames(remaining, acc), do: {Enum.reverse(acc), remaining}

  defp process_frame(frame) do
    # Application-specific frame processing
    Logger.debug("Received frame: #{byte_size(frame)} bytes")
  end
end
```

### Supervised Acceptor with DynamicSupervisor

Production pattern — each connection gets a supervised handler process:

```elixir
defmodule MyApp.TCPServer do
  @moduledoc "Production TCP server with supervised connection handlers."
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)

    children = [
      {DynamicSupervisor, name: MyApp.ConnectionSupervisor, strategy: :one_for_one},
      {Task, fn -> accept_loop(port) end}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp accept_loop(port) do
    {:ok, listen_socket} = :gen_tcp.listen(port, [
      :binary,
      active: false,
      reuseaddr: true,
      backlog: 128
    ])
    do_accept(listen_socket)
  end

  defp do_accept(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        {:ok, pid} = DynamicSupervisor.start_child(
          MyApp.ConnectionSupervisor,
          {MyApp.ConnectionHandler, client_socket}
        )
        :gen_tcp.controlling_process(client_socket, pid)
        do_accept(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("Accept error: #{inspect(reason)}")
        do_accept(listen_socket)
    end
  end
end
```

### Error Kernel Pattern — Expendable Linked Handlers

From the BeamMesh pattern — spawn_link handlers from a core GenServer. If a handler crashes, the GenServer receives `{:EXIT, pid, reason}` and cleans up:

```elixir
defmodule MyApp.Node do
  use GenServer

  defstruct [:listen_socket, connections: %{}]

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, listen_socket} = :gen_tcp.listen(opts[:port], [:binary, active: false, reuseaddr: true])

    # Accept loop runs as a linked process — expendable
    me = self()
    spawn_link(fn -> accept_loop(listen_socket, me) end)

    {:ok, %__MODULE__{listen_socket: listen_socket}}
  end

  @impl true
  def handle_info({:new_connection, socket}, state) do
    # Spawn a linked handler — expendable, crash is expected
    me = self()
    pid = spawn_link(fn -> connection_loop(socket, me) end)
    :gen_tcp.controlling_process(socket, pid)
    connections = Map.put(state.connections, pid, socket)
    {:noreply, %{state | connections: connections}}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    # Handler crashed or connection closed — clean up
    {_socket, connections} = Map.pop(state.connections, pid)
    {:noreply, %{state | connections: connections}}
  end

  defp accept_loop(listen_socket, node_pid) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        send(node_pid, {:new_connection, socket})
        accept_loop(listen_socket, node_pid)
      {:error, :closed} -> :ok
      {:error, _reason} ->
        accept_loop(listen_socket, node_pid)
    end
  end

  defp connection_loop(socket, node_pid) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        process_data(data)
        connection_loop(socket, node_pid)
      {:error, :closed} ->
        send(node_pid, {:connection_closed, self()})
    end
  end
end
```

**Architecture:**
```
Node GenServer (error kernel — must survive)
  |-- spawn_link --> accept_loop (expendable)
  |-- spawn_link --> connection_loop for peer A (expendable)
  |-- spawn_link --> connection_loop for peer B (expendable)
```

## TCP Client Pattern

### Simple Client (Passive Mode)

```elixir
defmodule MyApp.TCPClient do
  def connect(host, port, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    :gen_tcp.connect(to_charlist(host), port, [
      :binary,
      active: false,
      packet: :raw,
      send_timeout: 10_000
    ], timeout)
  end

  def send_and_recv(socket, data, timeout \\ 5_000) do
    with :ok <- :gen_tcp.send(socket, data),
         {:ok, response} <- :gen_tcp.recv(socket, 0, timeout) do
      {:ok, response}
    end
  end

  def close(socket), do: :gen_tcp.close(socket)
end
```

### GenServer Client with Reconnection

Pattern from Mint's connection state machine concept:

```elixir
defmodule MyApp.PersistentClient do
  use GenServer
  require Logger

  defstruct [:host, :port, :socket, :buffer, backoff: 1_000, max_backoff: 30_000]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      host: Keyword.fetch!(opts, :host),
      port: Keyword.fetch!(opts, :port),
      buffer: <<>>
    }
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case :gen_tcp.connect(
      to_charlist(state.host), state.port,
      [:binary, active: :once, packet: :raw],
      5_000
    ) do
      {:ok, socket} ->
        Logger.info("Connected to #{state.host}:#{state.port}")
        {:noreply, %{state | socket: socket, backoff: 1_000}}

      {:error, reason} ->
        Logger.warning("Connect failed: #{inspect(reason)}, retrying in #{state.backoff}ms")
        Process.send_after(self(), :reconnect, state.backoff)
        new_backoff = min(state.backoff * 2, state.max_backoff)
        {:noreply, %{state | backoff: new_backoff}}
    end
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    buffer = state.buffer <> data
    {messages, remaining} = parse_messages(buffer)
    Enum.each(messages, &handle_message/1)
    :inet.setopts(socket, active: :once)
    {:noreply, %{state | buffer: remaining}}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.info("Connection closed, reconnecting...")
    Process.send_after(self(), :reconnect, state.backoff)
    {:noreply, %{state | socket: nil, buffer: <<>>}}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("TCP error: #{inspect(reason)}")
    Process.send_after(self(), :reconnect, state.backoff)
    {:noreply, %{state | socket: nil, buffer: <<>>}}
  end

  defp parse_messages(buffer), do: {[], buffer}  # Application-specific
  defp handle_message(_msg), do: :ok              # Application-specific
end
```

## Protocol Framing

TCP is a byte stream — it delivers data in arbitrary chunks. You must frame messages yourself.

### Framing Strategy Decision Guide

| Strategy | How it works | Use when | Examples |
|----------|-------------|----------|----------|
| Length-prefix (N bytes) | Header contains payload size | Binary protocols, known max size | MQTT, HTTP/2, gRPC |
| Delimiter-based | Special byte/sequence ends each message | Text protocols, simple line protocols | HTTP/1.1 headers, Redis, SMTP |
| Type-Length-Value (TLV) | Tag + length + value per field | Extensible binary formats | DNS, TLS, BER encoding |
| Fixed-size | Every message is N bytes | Simple sensors, hardware protocols | CAN bus frames |
| `{packet, N}` | Erlang auto-frames with N-byte header | Both endpoints are BEAM | Distributed Erlang, internal APIs |

### Length-Prefixed Framing (Manual)

When you can't use `{packet, N}` (e.g., interoperating with non-BEAM systems):

```elixir
defmodule LengthFramed do
  @header_size 4  # 4-byte (32-bit) length prefix

  @doc "Send a length-prefixed frame over TCP."
  def send_frame(socket, payload) when is_binary(payload) do
    length = byte_size(payload)
    :gen_tcp.send(socket, [<<length::32>>, payload])  # IO list — no copy
  end

  @doc "Receive a single length-prefixed frame (passive mode)."
  def recv_frame(socket, timeout \\ 5_000) do
    with {:ok, <<length::32>>} <- :gen_tcp.recv(socket, @header_size, timeout),
         {:ok, payload} <- :gen_tcp.recv(socket, length, timeout) do
      {:ok, payload}
    end
  end

  @doc "Parse complete frames from a buffer, return remaining bytes."
  def parse_frames(buffer, acc \\ [])

  def parse_frames(<<length::32, payload::binary-size(length), rest::binary>>, acc) do
    parse_frames(rest, [payload | acc])
  end

  def parse_frames(remaining, acc) do
    {Enum.reverse(acc), remaining}
  end
end
```

### Buffer Management in GenServer State

Pattern from Mint and Tortoise — accumulate partial reads, parse when complete:

```elixir
defmodule BufferedHandler do
  use GenServer

  defstruct [:socket, buffer: <<>>]

  @impl true
  def handle_info({:tcp, socket, new_data}, %{socket: socket} = state) do
    # Concatenate new data with existing buffer
    buffer = state.buffer <> new_data

    # Parse as many complete frames as possible
    {frames, remaining} = LengthFramed.parse_frames(buffer)

    # Process each complete frame
    state = Enum.reduce(frames, %{state | buffer: remaining}, fn frame, s ->
      process_frame(frame, s)
    end)

    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end
end
```

**Key insight:** Each `{:tcp, socket, data}` message may contain:
- A partial frame (not enough bytes yet)
- Exactly one frame
- Multiple complete frames
- Multiple frames plus a partial frame at the end

The `parse_frames` + `remaining` pattern handles all cases.

### Delimiter-Based Framing

For text protocols (Redis, SMTP, custom line-based):

```elixir
defmodule LineFramed do
  @doc "Parse complete lines from buffer. Returns {lines, remaining}."
  def parse_lines(buffer, acc \\ []) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] -> parse_lines(rest, [line | acc])
      [_incomplete] -> {Enum.reverse(acc), buffer}
    end
  end
end
```

**Shortcut:** If your protocol is line-based, use `{packet, :line}` — Erlang handles framing automatically. Each `{:tcp, socket, data}` delivers exactly one line (up to `:buffer` size).

### Type-Length-Value (TLV) Parsing

For extensible binary formats with tagged fields:

```elixir
defmodule TLV do
  @doc "Parse TLV records from binary. Returns {records, remaining}."
  def parse(binary, acc \\ [])

  def parse(<<type::8, length::16, value::binary-size(length), rest::binary>>, acc) do
    parse(rest, [{type, value} | acc])
  end

  def parse(remaining, acc), do: {Enum.reverse(acc), remaining}

  @doc "Encode a list of {type, value} tuples as TLV binary."
  def encode(records) do
    # IO list for zero-copy construction
    for {type, value} <- records do
      [<<type::8, byte_size(value)::16>>, value]
    end
    |> IO.iodata_to_binary()
  end
end
```

## :gen_udp — Datagram Sockets

UDP is message-oriented (each send/recv is a complete datagram). No connection, no framing needed.

### UDP Basics

```elixir
# Open a UDP socket
{:ok, socket} = :gen_udp.open(port, [:binary, active: :once])

# Send a datagram
:ok = :gen_udp.send(socket, {192, 168, 1, 100}, 5000, "hello")
# Or with hostname
:ok = :gen_udp.send(socket, ~c"example.com", 5000, "hello")

# Receive (passive mode)
{:ok, {sender_ip, sender_port, data}} = :gen_udp.recv(socket, 0, 5_000)

# Active mode messages
# {:udp, socket, sender_ip, sender_port, data}

# Close
:gen_udp.close(socket)
```

### UDP Broadcast — Discovery Pattern

Send to all devices on a LAN subnet:

```elixir
defmodule Discovery do
  @broadcast_port 9999
  @beacon_interval 5_000

  def start_link do
    GenServer.start_link(__MODULE__, [])
  end

  @impl true
  def init(_) do
    {:ok, socket} = :gen_udp.open(@broadcast_port, [
      :binary,
      active: :once,
      broadcast: true,           # Enable broadcast sends
      reuseaddr: true            # Multiple processes can bind same port
    ])
    send(self(), :send_beacon)
    {:ok, %{socket: socket, peers: MapSet.new()}}
  end

  @impl true
  def handle_info(:send_beacon, state) do
    beacon = encode_beacon()
    :gen_udp.send(state.socket, {255, 255, 255, 255}, @broadcast_port, beacon)
    Process.send_after(self(), :send_beacon, @beacon_interval)
    {:noreply, state}
  end

  def handle_info({:udp, socket, ip, port, data}, state) do
    state = handle_beacon(ip, port, data, state)
    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  defp encode_beacon, do: <<"DISCOVER:", node()::binary>>

  defp handle_beacon(ip, port, <<"DISCOVER:", node_name::binary>>, state) do
    %{state | peers: MapSet.put(state.peers, {ip, port, node_name})}
  end
  defp handle_beacon(_, _, _, state), do: state
end
```

### UDP Multicast — Group Communication

Join a multicast group to receive messages sent to a group address:

```elixir
defmodule MulticastListener do
  @multicast_group {239, 1, 2, 3}   # Multicast address (239.x.x.x = organization-local)
  @port 5000

  def start_link do
    GenServer.start_link(__MODULE__, [])
  end

  @impl true
  def init(_) do
    {:ok, socket} = :gen_udp.open(@port, [
      :binary,
      active: :once,
      reuseaddr: true,
      multicast_ttl: 4,                              # Hops (1 = LAN only, default)
      multicast_loop: false,                          # Don't receive own messages
      add_membership: {@multicast_group, {0, 0, 0, 0}}  # Join group on all interfaces
    ])
    {:ok, %{socket: socket}}
  end

  @impl true
  def handle_info({:udp, socket, ip, port, data}, state) do
    Logger.debug("Multicast from #{:inet.ntoa(ip)}:#{port}: #{inspect(data)}")
    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end
end

# Sending to a multicast group (from any UDP socket with multicast_ttl set)
{:ok, sender} = :gen_udp.open(0, [:binary, multicast_ttl: 4])
:gen_udp.send(sender, {239, 1, 2, 3}, 5000, "multicast message")
```

**Multicast address ranges:**

| Range | Scope | Use |
|-------|-------|-----|
| `224.0.0.0/24` | Link-local | Router protocols (OSPF, etc.) |
| `239.0.0.0/8` | Organization-local | Application multicast (use this) |
| `224.0.1.0 - 238.255.255.255` | Global | Internet-wide (requires registration) |

## Connection Supervision

### Supervision Tree for TCP Server

```
MyApp.Supervisor (:one_for_one)
├── MyApp.ConnectionSupervisor (DynamicSupervisor)
│   ├── ConnectionHandler (GenServer) — peer A
│   ├── ConnectionHandler (GenServer) — peer B
│   └── ConnectionHandler (GenServer) — peer C
└── MyApp.Acceptor (Task, :permanent restart)
    └── accept_loop/1 (recursive)
```

**Key:** Use `:rest_for_one` if the acceptor depends on the DynamicSupervisor being alive (it does — `DynamicSupervisor.start_child` must succeed). If the DynamicSupervisor crashes, the acceptor should restart too.

### Graceful Shutdown

```elixir
defmodule MyApp.ConnectionHandler do
  use GenServer

  @impl true
  def init(socket) do
    Process.flag(:trap_exit, true)    # Required for terminate/2 callback
    :inet.setopts(socket, active: :once)
    {:ok, %{socket: socket}}
  end

  @impl true
  def terminate(_reason, %{socket: socket}) do
    # Graceful close — send FIN before closing
    :gen_tcp.shutdown(socket, :write)
    :gen_tcp.close(socket)
  end
end
```

## Thousand Island — Production Socket Server

Thousand Island is a pure-Elixir socket server used by Bandit (Phoenix's default HTTP server). Use it for production TCP/TLS servers instead of raw `:gen_tcp`.

### Why Thousand Island Over Raw gen_tcp

| Concern | Raw gen_tcp | Thousand Island |
|---------|------------|-----------------|
| Acceptor pool | Manual (1 process) | 100 acceptors (configurable) |
| Connection supervision | Manual DynamicSupervisor | Built-in, per-acceptor |
| TLS | Manual `:ssl` wrapping | `ThousandIsland.Socket` abstraction |
| Telemetry | Manual | Built-in `:telemetry` events |
| Shutdown | Manual drain | Graceful drain with timeout |
| Active mode | Manual `:inet.setopts` | Handled internally |

### ThousandIsland.Handler Behaviour

Implement the `ThousandIsland.Handler` behaviour for each connection:

```elixir
defmodule MyApp.EchoHandler do
  use ThousandIsland.Handler

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    # Called once after accept + optional TLS handshake
    {:ok, peer} = ThousandIsland.Socket.peername(socket)
    {:continue, Map.put(state, :peer, peer)}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    # Called for each chunk of data received
    ThousandIsland.Socket.send(socket, data)
    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    Logger.debug("Connection closed: #{inspect(state.peer)}")
  end

  @impl ThousandIsland.Handler
  def handle_error(reason, _socket, state) do
    Logger.warning("Connection error: #{inspect(reason)}")
  end

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, state) do
    Logger.debug("Connection timed out")
    {:close, state}
  end
end

# Start the server
{:ok, pid} = ThousandIsland.start_link(
  port: 4000,
  handler_module: MyApp.EchoHandler,
  handler_options: %{},       # Initial state passed to handle_connection
  # num_acceptors: 100,       # Default
  # read_timeout: 60_000,     # ms before handle_timeout
  # num_connections: 16_384,  # Max simultaneous connections
  # shutdown_timeout: 15_000, # Grace period for drain on stop
  # transport_module: ThousandIsland.Transports.TCP,  # or SSL
  # transport_options: [...]  # SSL: certfile, keyfile, etc.
)
```

### Handler Callback Reference

| Callback | Signature | Called when | Return |
|----------|-----------|------------|--------|
| `handle_connection/2` | `(socket, state)` | After accept + handshake | `{:continue, state}` or `{:close, state}` |
| `handle_data/3` | `(data, socket, state)` | Data received | `{:continue, state}` or `{:close, state}` |
| `handle_close/2` | `(socket, state)` | Peer closed connection | ignored |
| `handle_error/3` | `(reason, socket, state)` | Socket error | ignored |
| `handle_timeout/2` | `(socket, state)` | No activity within `read_timeout` | `{:close, state}` |
| `handle_shutdown/2` | `(socket, state)` | Server shutting down | ignored |

**All callbacks are optional** — `use ThousandIsland.Handler` provides defaults.

**Return types for handle_connection and handle_data:**
- `{:continue, state}` — keep connection open
- `{:continue, state, timeout}` — keep open with custom timeout (overrides `read_timeout`)
- `{:continue, state, {:persistent, timeout}}` — timeout survives across messages
- `{:close, state}` — close the connection
- `{:error, reason, state}` — close with error (triggers `handle_error`)
- `{:switch_transport, {module, opts}, state}` — TLS upgrade (STARTTLS)

### Thousand Island with TLS

```elixir
{:ok, pid} = ThousandIsland.start_link(
  port: 4443,
  handler_module: MyApp.SecureHandler,
  transport_module: ThousandIsland.Transports.SSL,
  transport_options: [
    certfile: "priv/cert.pem",
    keyfile: "priv/key.pem",
    # versions: [:"tlsv1.3"],
    # alpn_preferred_protocols: ["h2", "http/1.1"]
  ]
)
```

### Thousand Island Architecture

```
ThousandIsland.Server (Supervisor, :rest_for_one)
├── Listener (opens listen socket)
├── AcceptorPoolSupervisor (DynamicSupervisor)
│   ├── AcceptorSupervisor #1 (:rest_for_one)
│   │   ├── Acceptor (Task — calls accept)
│   │   └── DynamicSupervisor (manages handler GenServers)
│   ├── AcceptorSupervisor #2
│   │   ├── Acceptor
│   │   └── DynamicSupervisor
│   └── ... (100 by default)
└── ShutdownListener
```

Each acceptor has its own DynamicSupervisor for handler processes. This distributes connection supervision across acceptors — no single bottleneck.

## Ranch — Erlang Acceptor Pool

Ranch is the mature Erlang socket server used by Cowboy (and historically by Phoenix via Cowboy). Still maintained and widely used.

### Ranch vs Thousand Island

| Aspect | Ranch | Thousand Island |
|--------|-------|-----------------|
| Language | Erlang | Elixir |
| Used by | Cowboy, many Erlang projects | Bandit, Phoenix (default since 1.7.10) |
| Transport | `ranch_tcp`, `ranch_ssl` | `ThousandIsland.Transports.TCP/SSL` |
| Handler | `ranch_protocol` behaviour | `ThousandIsland.Handler` behaviour |
| Socket handoff | `ranch:handshake/1` (Ranch 2.0+) | Automatic in handler callbacks |
| Acceptors | Configurable pool | 100 per listener (configurable) |
| Dependencies | None | `:telemetry` only |

### Ranch Protocol Behaviour

```elixir
defmodule MyApp.RanchHandler do
  @behaviour :ranch_protocol

  @impl true
  def start_link(ref, transport, opts) do
    pid = spawn_link(__MODULE__, :init, [ref, transport, opts])
    {:ok, pid}
  end

  def init(ref, transport, _opts) do
    # Ranch 2.0+: obtain socket via handshake (NOT passed as argument)
    {:ok, socket} = :ranch.handshake(ref)
    transport.setopts(socket, active: :once)
    loop(socket, transport)
  end

  defp loop(socket, transport) do
    receive do
      {:tcp, ^socket, data} ->
        transport.send(socket, data)
        transport.setopts(socket, active: :once)
        loop(socket, transport)
      {:tcp_closed, ^socket} ->
        :ok
    end
  end
end

# Start a Ranch listener
{:ok, _} = :ranch.start_listener(:echo,
  :ranch_tcp,
  %{num_acceptors: 100, socket_opts: [port: 4000]},
  MyApp.RanchHandler,
  []
)
```

## Common Mistakes (BAD/GOOD)

**1. Blocking accept in GenServer:**
```elixir
# BAD — GenServer.init blocks forever waiting for first connection
def init(opts) do
  {:ok, listen} = :gen_tcp.listen(4000, [:binary, active: false])
  {:ok, client} = :gen_tcp.accept(listen)  # BLOCKS HERE
  {:ok, %{socket: client}}
end

# GOOD — accept runs in a separate process
def init(opts) do
  {:ok, listen} = :gen_tcp.listen(4000, [:binary, active: false])
  me = self()
  spawn_link(fn -> accept_loop(listen, me) end)
  {:ok, %{listen: listen}}
end
```

**2. active: true with untrusted connections:**
```elixir
# BAD — fast client overwhelms process mailbox
:inet.setopts(socket, active: true)
# If client sends 1GB of data, process mailbox grows unboundedly

# GOOD — active: :once provides per-message backpressure
:inet.setopts(socket, active: :once)
# Process receives one message, must explicitly re-arm
```

**3. Forgetting to re-arm active: :once:**
```elixir
# BAD — socket stops receiving after first message
def handle_info({:tcp, socket, data}, state) do
  process(data)
  # Forgot :inet.setopts(socket, active: :once) — silent data loss!
  {:noreply, state}
end

# GOOD — always re-arm
def handle_info({:tcp, socket, data}, state) do
  process(data)
  :inet.setopts(socket, active: :once)
  {:noreply, state}
end
```

**4. Missing controlling_process:**
```elixir
# BAD — handler can't receive messages, socket closes if acceptor loops
{:ok, client} = :gen_tcp.accept(listen)
{:ok, pid} = start_handler(client)
# Acceptor still owns the socket — handler gets nothing

# GOOD — transfer ownership before handler starts receiving
{:ok, client} = :gen_tcp.accept(listen)
{:ok, pid} = start_handler(client)
:gen_tcp.controlling_process(client, pid)
# Now handler receives {:tcp, ...} messages
```

**5. Treating TCP as message-oriented:**
```elixir
# BAD — assumes recv returns exactly one complete message
{:ok, data} = :gen_tcp.recv(socket, 0)
message = decode_message(data)   # CRASH if data is partial or multiple messages

# GOOD — buffer and frame
buffer = state.buffer <> data
{messages, remaining} = parse_frames(buffer)
state = %{state | buffer: remaining}
```

**6. String concatenation in receive loop:**
```elixir
# BAD — O(n^2) binary copies
def handle_info({:tcp, socket, data}, %{buffer: buffer} = state) do
  buffer = buffer <> data  # Copies entire buffer every time!
  {:noreply, %{state | buffer: buffer}}
end

# GOOD for small protocols — binary concat is fine under ~64KB
# GOOD for high-throughput — use IO list accumulation
def handle_info({:tcp, socket, data}, %{buffer_parts: parts} = state) do
  parts = [data | parts]
  # Only flatten when parsing:
  buffer =
    parts
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  {frames, remaining} = parse_frames(buffer)
  {:noreply, %{state | buffer_parts: [remaining]}}
end
```

> **Note:** For most protocols, `buffer <> data` is fine — Erlang's binary GC handles this efficiently
> for sub-heap binaries. Only optimize to IO lists when profiling shows binary copying as a bottleneck.

**7. Ignoring TCP close/error messages:**
```elixir
# BAD — socket leaks, process hangs, peer thinks connection is alive
def handle_info({:tcp, socket, data}, state) do
  # Only handles data, ignores close and error
end

# GOOD — handle all three TCP message types
def handle_info({:tcp, socket, data}, state), do: ...
def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
def handle_info({:tcp_error, _socket, reason}, state), do: {:stop, reason, state}
```

## Network Programming Decision Guide

| Need | Use | NOT this |
|------|-----|----------|
| Production TCP server | Thousand Island | Raw `:gen_tcp.listen/accept` |
| TCP client | Raw `:gen_tcp.connect` | Thousand Island (it's server-only) |
| Both endpoints are BEAM | `{packet, 4}` auto-framing | Manual length-prefix parsing |
| Non-BEAM binary protocol | `packet: :raw` + manual framing | `{packet, N}` |
| Line-based text protocol | `{packet, :line}` | Manual delimiter splitting |
| LAN device discovery | UDP broadcast | TCP (too many connections) |
| Group communication | UDP multicast | UDP broadcast (less efficient) |
| Reliable delivery | TCP | UDP (no guarantees) |
| Low-latency, loss-tolerant | UDP | TCP (head-of-line blocking) |
| AtomVM / embedded | Raw `:gen_tcp` + `spawn_link` | Thousand Island (not available) |
| HTTP server | Bandit (uses Thousand Island) | Raw TCP (reinventing HTTP) |
| HTTP client | Req / Finch (uses Mint) | Raw TCP |

## Related Patterns

- **gen_statem TCP connection:** [otp-examples.md](otp-examples.md) — state machine for TCP client with connect/connected/disconnected states, exponential backoff
- **Binary protocol parsing:** [data-structures.md](data-structures.md) — binary pattern matching, variable-length fields, TLV parsing, encode/decode round-trips
- **Raw process patterns:** [otp-reference.md](otp-reference.md) — spawn_link + receive loops, trap_exit, links vs monitors
- **Production HTTP clients:** [production.md](production.md) — Req, Finch, middleware, retry patterns
- **Supervision trees:** [otp-reference.md](otp-reference.md) — DynamicSupervisor, :rest_for_one strategy, Registry patterns
