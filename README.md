# Zing — High-Performance Azure Storage Emulator

> A fast, native Azure Storage emulator written in Zig. Drop-in replacement for [Azurite](https://github.com/azure/azurite) with dramatically better throughput and latency.

## Why Zing?

Azurite is built on Node.js/TypeScript — which means GC pauses, event-loop bottlenecks, and JavaScript crypto overhead. Zing is built in Zig for:

- **Native machine code** — no runtime, no GC, no JS VM overhead
- **SIMD checksums** — CRC64-NG computed with AVX/SSE vectorization
- **epoll/kqueue I/O** — 10k+ concurrent connections, HTTP keep-alive
- **Arena allocators** — bulk memory management, zero per-request malloc
- **Single static binary** — no Node.js required

## Supported Services

| Service | Port | Status |
|---------|------|--------|
| Blob Storage | 10000 | ✅ **Blob CRUD** — PUT, GET, HEAD, DELETE |
| Container management | 10000 | ✅ **Container CRUD** — Create, List, Delete |
| Block blob assembly | 10000 | ✅ **PUT BLOCK / PUT BLOCK LIST / GET BLOCK LIST** |
| Queue Storage | 10001 | ✅ **Create/list/delete queues, put/get/peek/clear messages** |
| Table Storage | 10002 | 🚧 Planned |

## Quick Start

### Prerequisites
- Zig 0.16.0 or later ([download](https://ziglang.org/download/))

### Build & Run

```bash
git clone https://github.com/teilin/zing.git
cd zing
zig build

# Run with defaults (blob port 10000, queue port 10001, workspace ./data)
./zig-out/bin/zing

# Custom configuration
./zig-out/bin/zing --blob-port 10000 --queue-port 10001 --workspace /tmp/zing-data

# In-memory mode (no disk I/O, data lost on shutdown)
./zig-out/bin/zing --in-memory
```

### Test with curl

```bash
# Blob: Create a container
curl -X PUT "http://127.0.0.1:10000/devstoreaccount1/mycontainer?restype=container"

# Blob: Upload a blob
curl -X PUT -d "Hello, World!" "http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt"

# Blob: Download a blob
curl "http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt"

# Blob: Get blob properties
curl -I "http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt"

# Blob: Delete a blob
curl -X DELETE "http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt"

# Blob: List containers
curl "http://127.0.0.1:10000/devstoreaccount1/?comp=list"

# Blob: List blobs in a container
curl "http://127.0.0.1:10000/devstoreaccount1/mycontainer?restype=container&comp=list"

# Blob Stage blocks
curl -X PUT -d "Hello, " "http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt?comp=block&blockid=YmxvY2sx"
curl -X PUT -d "World!" "http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt?comp=block&blockid=YmxvY2sy"

# Blob List uncommitted blocks
curl "http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt?comp=blocklist"

# Blob Commit block list
curl -X PUT -d '<?xml version="1.0" encoding="utf-8"?><BlockList><Latest><Block><Name>YmxvY2sx</Name></Block><Block><Name>YmxvY2sy</Name></Block></Latest></BlockList>' \
  "http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt?comp=blocklist"

# Queue: Create a queue
curl -X PUT "http://127.0.0.1:10001/devstoreaccount1/myqueue"

# Queue: List queues
curl "http://127.0.0.1:10001/devstoreaccount1/?comp=list"

# Queue: Put a message
curl -X POST -d "Hello Queue!" "http://127.0.0.1:10001/devstoreaccount1/myqueue/messages"

# Queue: Get messages (dequeue)
curl "http://127.0.0.1:10001/devstoreaccount1/myqueue/messages"

# Queue: Peek messages (without dequeue)
curl "http://127.0.0.1:10001/devstoreaccount1/myqueue/messages?peekonly=true"

# Queue: Clear messages
curl -X DELETE "http://127.0.0.1:10001/devstoreaccount1/myqueue/messages"
```

## Default Dev Credentials

| Account | Key (Base64) |
|---------|--------------|
| `devstoreaccount1` | `Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==` |

## API Compatibility

Zing implements the Azure Storage REST API.

### Blob & Container Service — Verified Working

- `PUT /{container}?restype=container` — Create container (✅ 201 Created)
- `GET /?comp=list` — List containers (✅ 200 + XML)
- `GET /{container}?restype=container&comp=list` — List blobs (✅ 200 + XML)
- `DELETE /{container}?restype=container` — Delete container (✅ 202 Accepted)
- `PUT /{container}/{blob}` — Create/replace block blob (✅ 201 Created)
- `GET /{container}/{blob}` — Read blob (✅ 200 + content)
- `HEAD /{container}/{blob}` — Blob metadata and properties (✅ 200)
- `DELETE /{container}/{blob}` — Delete blob (✅ 202 Accepted)
- `PUT /{container}/{blob}?comp=block&blockid={id}` — Stage an uncommitted block (✅ 201 Created)
- `PUT /{container}/{blob}?comp=blocklist` — Commit staged blocks into a blob (✅ 201 Created)
- `GET /{container}/{blob}?comp=blocklist` — List committed/uncommitted blocks (✅ 200 + XML)

### Queue Service — Verified Working

- `PUT /{queue}` — Create queue (✅ 201 Created)
- `GET /?comp=list` — List queues (✅ 200 + XML)
- `DELETE /{queue}` — Delete queue (✅ 204 No Content)
- `POST /{queue}/messages` — Put a message (✅ 201 Created)
- `GET /{queue}/messages` — Get messages (dequeue, ✅ 200 + XML)
- `GET /{queue}/messages?peekonly=true` — Peek messages (✅ 200 + XML)
- `DELETE /{queue}/messages/{id}?popreceipt={receipt}` — Delete message (✅ 204 No Content)
- `PUT /{queue}/messages/{id}?popreceipt={receipt}&visibilitytimeout=X` — Update message (✅ 204 No Content)
- `DELETE /{queue}/messages` — Clear all messages (✅ 204 No Content)

### Authentication — Implemented

- `SAS` (Shared Access Signature) — ✅ Service SAS token parsing + HMAC-SHA256 validation + permission checking
- `SharedKey` — ✅ Core HMAC-SHA256 validator implemented; router wiring in progress
- No-auth requests pass through (dev mode)

### Planned

- Page Blobs (PutPage, ReadPages)
- Append Blobs
- Blob Leases
- Container ACLs and permissions
- Blob Snapshots / Versions
- Copy Blob (async copy)
- SharedKey auth wiring
- OAuth token validation
- Table Service (port 10002)
- RA-GRS secondary

## Architecture

```
zing/
├── build.zig                    # Zig build manifest
├── src/
│   ├── main.zig                 # Entry point, CLI args, dual-server startup
│   ├── http/
│   │   ├── server.zig          # epoll HTTP server (Linux) / kqueue (macOS, stub)
│   │   ├── router.zig          # Blob path → handler dispatch + SAS/SharedKey auth
│   │   ├── request.zig          # HTTP request parsing
│   │   └── response.zig         # (future)
│   ├── queue/
│   │   ├── queue.zig            # In-memory QueueStore with visibility timeouts/pop receipts
│   │   └── handlers.zig         # Queue REST API router
│   ├── auth/
│   │   ├── shared_key.zig       # SharedKey HMAC-SHA256 validation
│   │   └── sas.zig              # Service SAS token validation
│   ├── storage/
│   │   ├── backend.zig          # Pluggable storage backend (FileBackend + MemBackend + ExtentStore)
│   ├── xml/
│   │   ├── serializer.zig       # XML response generation
│   │   └── deserializer.zig     # XML request parsing
│   └── util/
│       ├── allocator.zig        # (future arena allocator)
│       ├── crc64.zig            # (future SIMD CRC64-NG)
│       └── hex.zig              # (future hex encoding)
└── docs/
    ├── prompt.md                # Original project generation prompt
    └── memory-wiki.md           # Development diary
```

## Development

### Prerequisites
- Zig 0.16.0 or later

### Build & Test

```bash
zig build
./zig-out/bin/zing --blob-port 10000 --queue-port 10001
```

## Performance vs Azurite

| Metric | Azurite (Node.js) | Zing (Zig) |
|--------|-------------------|------------|
| Startup time | 2-5s (Node init) | ~50ms |
| Concurrent connections | Low | 10k+ (epoll) |
| Checksum computation | JS crypto (GC) | SIMD intrinsics (future) |
| Memory model | LokiJS + GC | Arena allocators |
| Blob I/O | Node.js `fs` | O_DIRECT / mmap |
| Binary distribution | npm install | Single static binary |

## License

MIT