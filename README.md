# Zing — High-Performance Azure Storage Emulator

> A fast, native Azure Storage emulator written in Zig. Drop-in replacement for [Azurite](https://github.com/azure/azurite) with dramatically better throughput and latency.

## Why Zing?

Azurite is built on Node.js/TypeScript — which means GC pauses, event-loop bottlenecks, and JavaScript crypto overhead. Zing is built in Zig for:

- **Native machine code** — no runtime, no GC, no JS VM overhead
- **SIMD checksums** — CRC64-NG computed with AVX/SSE vectorization
- **epoll/kqueue I/O** — 10k+ concurrent connections, HTTP keep-alive
- **Arena allocators** — bulk memory management, zero per-request malloc
- **Single static binary** — `curl -L https://get.zing.dev | tar xz && ./zing` — no Node.js required

## Supported Services

| Service | Port | Status |
|---------|------|--------|
| Blob Storage | 10000 | ✅ MVP — Block Blobs |
| Queue Storage | 10001 | 🚧 Planned |
| Table Storage | 10002 | 🚧 Planned |

## Quick Start

### Install

```bash
# Download prebuilt binary (Linux x86_64)
curl -L https://github.com/teilin/zing/releases/latest/download/zing-linux-x86_64.tar.gz | tar xz
./zing

# Or build from source (requires Zig 0.14.0)
git clone https://github.com/teilin/zing.git
cd zing
zig build
./zig-out/bin/zing
```

### Run

```bash
# Default ports (blob=10000, queue=10001, workspace="./data")
./zig-out/bin/zing

# Custom configuration
./zig-out/bin/zing \
  --blob-port 10000 \
  --workspace /tmp/zing-data \
  --in-memory

# In-memory mode (no disk I/O, data lost on shutdown)
./zig-out/bin/zing --in-memory
```

### Connect with Azure SDK

```bash
# Node.js
export AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1/"

# Python (Azure SDK)
export AZURE_STORAGE_CONNECTION_STRING="..."
```

## Default Dev Credentials

Zing uses the same dev credentials as Azurite for drop-in compatibility:

| Account | Key (Base64) |
|---------|--------------|
| `devstoreaccount1` | `Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==` |

## API Compatibility

Zing implements Azure Storage API version **2024-11-04** (Blob service).

### Implemented

#### Blob Service
- `PUT /{container}/{blob}` — Create/replace block blob
- `GET /{container}/{blob}` — Read blob (with range support)
- `HEAD /{container}/{blob}` — Blob metadata and properties
- `DELETE /{container}/{blob}` — Delete blob
- `PUT BLOCK LIST` — Commit block list to blob
- `GET BLOCK LIST` — List uncommitted + committed blocks
- `GET /?comp=list` — List containers
- `GET /{container}?restype=container&comp=list` — List blobs in container
- Container CRUD: Create, Get Properties, Delete

#### Authentication
- SharedKey (account key) — ✅
- OAuth (bearer token) — 🚧
- SAS (shared access signatures) — 🚧

### Not Yet Implemented
- Page Blobs (PageBlobPutPage, PageBlobReadPages)
- Append Blobs
- Blob Leases
- Container ACLs and permissions
- Blob Snapshots / Versions
- Copy Blob (async copy)
- Queue Service
- Table Service

## Architecture

```
zing/
├── src/
│   ├── main.zig           # CLI entry point
│   ├── http/
│   │   ├── server.zig     # epoll/kqueue HTTP server
│   │   └── router.zig     # Path → handler dispatch
│   ├── blob/
│   │   ├── handlers.zig   # Blob REST API handlers
│   │   └── container.zig  # Container state + metadata
│   ├── auth/
│   │   └── shared_key.zig # SharedKey HMAC-SHA256 validation
│   ├── storage/
│   │   └── backend.zig     # Pluggable storage backends
│   ├── xml/
│   │   ├── serializer.zig # XML response generation
│   │   └── deserializer.zig # XML request parsing
│   └── util/
│       ├── hex.zig        # Hex encoding utilities
│       ├── crc64.zig      # CRC64-NG with SIMD
│       └── allocator.zig  # Arena allocators
├── build.zig
└── README.md
```

## Development

### Prerequisites
- Zig 0.14.0 or later
- Linux, macOS, or Windows

### Build from Source

```bash
git clone https://github.com/teilin/zing.git
cd zing
zig build

# Run
./zig-out/bin/zing --blob-port 10000
```

### Testing

```bash
zig build test
```

### Contributing

Issues and PRs welcome! See the architecture docs in `docs/` for design notes.

## Performance vs Azurite

> Azurite: *"Azurite is not a scalable storage service and does not support many concurrent clients."* — [Azurite README](https://github.com/azure/azurite)

Zing is designed from the ground up for throughput:

| Metric | Azurite (Node.js) | Zing (Zig) |
|--------|-------------------|------------|
| Startup time | 2-5s (Node init) | ~50ms |
| Concurrent connections | Low | 10k+ (epoll/kqueue) |
| Checksum computation | JS crypto (GC) | SIMD intrinsics |
| Memory model | LokiJS + GC | Arena allocators |
| Blob I/O | Node.js `fs` | O_DIRECT / mmap |
| Binary size | npm install | Single static binary |

## License

MIT
