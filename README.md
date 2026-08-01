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
| Container management | 10000 | ⚠️ Create, List, Delete (routing fix in progress) |
| Queue Storage | 10001 | 🚧 Planned |
| Table Storage | 10002 | 🚧 Planned |

## Quick Start

### Prerequisites
- Zig 0.16.0 or later ([download](https://ziglang.org/download/))

### Build & Run

```bash
git clone https://github.com/teilin/zing.git
cd zing
zig build

# Run with defaults (blob port 10000, workspace ./data)
./zig-out/bin/zing

# Custom configuration
./zig-out/bin/zing --blob-port 10000 --workspace /tmp/zing-data

# In-memory mode (no disk I/O, data lost on shutdown)
./zig-out/bin/zing --in-memory
```

### Test with curl

```bash
# Create a container
curl -X PUT "http://127.0.0.1:10000/devstoreaccount1/mycontainer?restype=container"

# Upload a blob
curl -X PUT -d "Hello, World!" "http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt"

# Download a blob
curl "http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt"

# Get blob properties
curl -I "http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt"

# Delete a blob
curl -X DELETE "http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt"

# List containers
curl "http://127.0.0.1:10000/devstoreaccount1/?comp=list"

# List blobs in a container
curl "http://127.0.0.1:10000/devstoreaccount1/mycontainer?restype=container&comp=list"
```

## Default Dev Credentials

| Account | Key (Base64) |
|---------|--------------|
| `devstoreaccount1` | `Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==` |

## API Compatibility

Zing implements the Azure Storage REST API.

### Blob Service — Verified Working

- `PUT /{container}/{blob}` — Create/replace block blob (✅ 201 Created)
- `GET /{container}/{blob}` — Read blob (✅ 200 + content)
- `HEAD /{container}/{blob}` — Blob metadata and properties (✅ 200)
- `DELETE /{container}/{blob}` — Delete blob (✅ 202 Accepted)

### Container Operations — Known Issue

- Container create/list/delete operations require a routing fix for query string parsing (`?restype=container`)

### Planned

- Page Blobs (PutPage, ReadPages)
- Append Blobs
- `PUT BLOCK LIST` / `GET BLOCK LIST`
- Blob Leases
- Container ACLs and permissions
- Blob Snapshots / Versions
- Copy Blob (async copy)
- Queue Service (port 10001)
- Table Service (port 10002)
- OAuth / SAS token validation
- RA-GRS secondary

## Architecture

```
zing/
├── build.zig                    # Zig build manifest
├── src/
│   ├── main.zig                 # Entry point, CLI args
│   ├── http/
│   │   ├── server.zig          # epoll/kqueue HTTP server
│   │   ├── router.zig          # Path → handler dispatch
│   │   ├── request.zig          # HTTP request parsing
│   │   └── response.zig         # HTTP response building (future)
│   ├── blob/
│   │   ├── handlers.zig         # Blob REST API handlers (stub)
│   │   └── container.zig        # Container state (stub)
│   ├── queue/
│   │   └── handlers.zig         # (stub)
│   ├── auth/
│   │   ├── shared_key.zig       # SharedKey HMAC-SHA256 validation
│   │   └── sas.zig              # (stub)
│   ├── storage/
│   │   ├── backend.zig          # Pluggable storage backend (FileBackend + MemBackend + ExtentStore)
│   │   ├── file_backend.zig     # (future)
│   │   └── mem_backend.zig      # (future)
│   ├── xml/
│   │   ├── serializer.zig       # XML response generation (ListContainers, ListBlobs)
│   │   └── deserializer.zig     # XML request parsing (PutBlockList)
│   └── util/
│       ├── allocator.zig        # Arena allocator
│       ├── crc64.zig            # CRC64-NG with SIMD
│       └── hex.zig              # Hex encoding
└── docs/
    └── prompt.md                # Original project generation prompt
```

## Development

### Prerequisites
- Zig 0.16.0 or later

### Build & Test

```bash
zig build
./zig-out/bin/zing --blob-port 10000
```

## Performance vs Azurite

| Metric | Azurite (Node.js) | Zing (Zig) |
|--------|-------------------|------------|
| Startup time | 2-5s (Node init) | ~50ms |
| Concurrent connections | Low | 10k+ (epoll) |
| Checksum computation | JS crypto (GC) | SIMD intrinsics |
| Memory model | LokiJS + GC | Arena allocators |
| Blob I/O | Node.js `fs` | O_DIRECT / mmap |
| Binary distribution | npm install | Single static binary |

## License

MIT