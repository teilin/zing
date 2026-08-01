# Zing — A High-Performance Azure Storage Emulator in Zig

## Project Prompt

### 1. Project Name

**Zing** — Fast Azure Storage, Locally.

> "Zing" plays on Zig's name while conveying speed and energy. Alternative: Azurite-Z (direct contrast with Azurite), or Ztable / Zblob if you want a more technical bent.

---

### 2. Problem Statement

Azurite (the current open-source Azure Storage emulator) is slow because:

- **Built on Node.js/TypeScript** — JavaScript runtime overhead, GC pauses, single-threaded event loop bottleneck
- **In-memory storage (LokiJS)** or file-system extents with no native zero-copy I/O
- **No SIMD/vectorization** for checksum computation (MD5, CRC64) — each operation is a function call into JS
- **HTTP parsing and routing** done in JS with middleware chains — O(n) middleware traversal per request
- **No connection pooling** — each request re-warms an HTTP parser
- **Blob extent GC** runs every 10 minutes — deleted content hoards memory
- **Acknowledged scalability ceiling**: "Azurite is not a scalable storage service and does not support many concurrent clients"

Azure developers suffer this daily. CI pipelines, local debugging, and SDK testing all pay the tax.

---

### 3. Solution: Why Zig?

| Feature | Why It Matters for Zing |
|---------|------------------------|
| **Manual memory management** | No GC pauses — predictable latency, no stop-the-world stalls |
| **Zero-cost abstractions** | High-level patterns (HTTP handlers, routing) compile to efficient machine code |
| **Better C interop** | Direct bindings to libuv (async I/O), mimalloc (allocator), wolfSSL (TLS), libz (compression) |
| **SIMD intrinsics** | CRC64-NG (Azure's checksum) can be vectorized across 64-byte blocks |
| **Async I/O via comptime** | Zig's async/suspend model with event-driven I/O (epoll/kqueue) scales to 10k+ connections |
| **Single static binary** | No Node.js runtime needed — `curl -L https://get.zing.dev \| tar xz && ./zing` |
| **Debug-time safety** | `@as()` and `orelse` forced handling — catches omitted error paths at compile time |

Zig is what you'd write if you built Azurite from scratch knowing what you know now.

---

### 4. Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      Zing Server                             │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │ HTTP Server │  │  Blob Store  │  │   Queue Store      │  │
│  │  (epoll/    │  │              │  │                   │  │
│  │   kqueue)   │  │  Block blobs │  │  Messages          │  │
│  └──────┬──────┘  │  Page blobs  │  │  Dequeue/Peek     │  │
│         │         │  Containers  │  │  Update/Delete     │  │
│         └────┬────┴──────────────┴──────────────────────┘  │
│              │                                             │
│  ┌───────────┴────────────────────────────────────────┐   │
│  │              Storage Backend                         │   │
│  │  ┌─────────────┐  ┌──────────────┐  ┌────────────┐  │   │
│  │  │ File-based  │  │  In-memory   │  │ SQLite     │  │   │
│  │  │ Extents     │  │  Arena       │  │ (metadata) │  │   │
│  │  └─────────────┘  └──────────────┘  └────────────┘  │   │
│  └────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Auth Layer (SharedKey, SAS, OAuth token validation) │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

Key design: storage backends are pluggable, not baked in. The HTTP handler layer talks to a `StorageBackend` trait. Swap SQLite for PostgreSQL, file extents for in-memory arenas without touching the protocol layer.

---

### 5. Core Services & API Surface

#### 5.1 Blob Service (Port 10000)

Azure Blob Storage API version 2024-11-04 (latest).

Implement first — highest utility, highest complexity:

- `PUT /{container}/{blob}` — Block/Page blob upload, chunked
- `GET /{container}/{blob}` — Range reads, conditional headers
- `DELETE /{container}/{blob}` — Soft-delete (if enabled)
- `HEAD /{container}/{blob}` — Metadata + size
- `COPY /{container}/{blob}` — Async copy from source
- `PUT BLOCK LIST` — Commit block list to block blob
- `GET BLOCK LIST` — Uncommitted + committed blocks
- `PUT PAGE` / `GET PAGE` — Page blob page I/O (512-byte aligned)
- `APPEND BLOCK` — Append-only blobs
- `LIST CONTAINERS` — Account-level container listing
- `LIST BLOBS` — Container-level blob listing (with prefix, delimiter)
- Container CRUD + metadata — CreateContainer, GetContainerProperties, DeleteContainer

Content validation: Azure uses CRC64-NG for blob content integrity. This is a perfect SIMD target — implement with `__builtin_ctzll` loop + AVX-512 if available.

#### 5.2 Queue Service (Port 10001)

Simpler than blobs — mostly message CRUD with visibility timeout semantics.

- `PUT MESSAGE` — Base64-encoded message, expiry
- `GET MESSAGES` — Dequeue with pop_receipt + visibility timeout
- `PEEK MESSAGES` — Without dequeue
- `DELETE MESSAGE` — Ack after processing
- `UPDATE MESSAGE` — Update content + extend visibility
- `CLEAR QUEUE` — Bulk delete all messages
- `LIST QUEUES` — Account-level queue listing

#### 5.3 Table Service (Port 10002) — Phase 2

Azure Tables uses OData protocol + JSON. Complex query engine. Consider Sstable or RocksDB as backend.

---

### 6. Performance-Focused Design Decisions

#### 6.1 HTTP Layer

- Use `h2o` or raw `libuv` + `http_parser` — not a JS HTTP stack
- Zero-copy request routing: pre-parse the URL path into a struct once, hand off to handler
- HTTP/1.1 keep-alive with a connection pool — avoid re-parsing headers on every request
- Pipeline support (parallel request processing on one connection)

#### 6.2 Storage Backend

- File-based extents: store blob data as aligned 4MB chunks on disk (like Azure's page blobs conceptually). Use `O_DIRECT` for direct I/O bypassing page cache where possible
- Memory-mapped files for hot read paths — `mmap()` + `madvise(MADV_SEQUENTIAL)` for sequential access
- In-memory arena allocator: allocate from a pre-faulted 1GB+ arena, never `malloc()` per write. Free entire arena on snapshot restore — no GC needed
- CRC64 computation in a dedicated thread with SIMD — don't block the I/O thread

#### 6.3 Concurrency Model

- epoll/kqueue event loop for network I/O (single thread handles 10k+ connections)
- Work-stealing thread pool for CPU-bound tasks (checksums, serialization)
- Actor model per container: each container is an actor with its own queue — no cross-container locking
- Lock-free data structures for in-memory metadata (SPSC queues for the queue service)

#### 6.4 What NOT to Emulate (Yet)

- OAuth/JWT validation — skip for MVP; implement SharedKey only
- RA-GRS secondary — not needed for local dev
- Soft delete, versioning, change feed — version 2 features
- Table service — phase 2 or community

---

### 7. Project Structure (Zig)

```
zing/
├── build.zig                    # Zig build manifest
├── src/
│   ├── main.zig                 # Entry point, CLI args
│   ├── http/
│   │   ├── server.zig          # epoll/kqueue HTTP server
│   │   ├── router.zig          # Path → handler dispatch
│   │   ├── request.zig          # HTTP request parsing
│   │   └── response.zig          # HTTP response building
│   ├── blob/
│   │   ├── handlers.zig         # Blob REST API handlers
│   │   ├── container.zig         # Container state + metadata
│   │   ├── block_blob.zig       # Block blob operations
│   │   ├── page_blob.zig        # Page blob operations
│   │   └── crc64.zig            # SIMD CRC64-NG implementation
│   ├── queue/
│   │   ├── handlers.zig
│   │   ├── queue.zig
│   │   └── message.zig
│   ├── auth/
│   │   ├── shared_key.zig       # SharedKey validation
│   │   └── sas.zig              # SAS token parsing + validation
│   ├── storage/
│   │   ├── backend.zig          # StorageBackend trait/interface
│   │   ├── file_backend.zig     # File-based extent store
│   │   ├── mem_backend.zig      # In-memory arena backend
│   │   └── sqlite_meta.zig      # SQLite for metadata (optional)
│   ├── xml/
│   │   ├── serializer.zig        # XML serialization for responses
│   │   └── deserializer.zig      # XML parsing for requests
│   └── util/
│       ├── allocator.zig         # Dedicated arena allocators
│       ├── crc64.zig            # CRC64-NG with SIMD
│       └── hex.zig              # Hex encoding for ETags, checksums
├── tests/
│   ├── blob_test.zig
│   ├── queue_test.zig
│   └── auth_test.zig
├── scripts/
│   └── generate_swagger.zig     # Parse Azure swagger → Zig structs
└── README.md
```

---

### 8. Differentiation from Azurite

| | Azurite | Zing |
|---|---|---|
| **Language** | TypeScript/Node.js | Zig (compiled) |
| **Runtime overhead** | JS VM + GC | Native machine code |
| **Binary distribution** | npm install (needs Node) | Single static ELF/PE |
| **Concurrency model** | JS event loop (single-threaded) | epoll/kqueue + thread pool |
| **Memory model** | LokiJS (in-memory) + GC | Arena allocators, manual |
| **Blob I/O** | Node.js fs stream | O_DIRECT / mmap |
| **Checksums** | JS crypto library | SIMD intrinsics |
| **Connection reuse** | None | HTTP keep-alive + pool |
| **Startup time** | 2-5 seconds (Node init) | 50ms |
| **Max concurrent clients** | Low (noted limitation) | Designed for hundreds |
| **Target users** | General dev/test | Performance-conscious devs, CI |

---

### 9. MVP Scope (v0.1)

Goal: replace Azurite for the most common local dev scenario — blob storage testing.

**What to build first:**

- [ ] HTTP server with blob service endpoint (port 10000)
- [ ] SharedKey authentication (no OAuth, no SAS for MVP)
- [ ] Block blob: PUT + GET + DELETE + HEAD (with ranges)
- [ ] Container: CREATE + LIST + DELETE + GetProperties
- [ ] File-based extent store with 4MB chunk files
- [ ] CRC64-NG validation on upload/download
- [ ] Connection string:
      `DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1/`

**What to skip:** page blobs, append blobs, container ACLs, lease state, copy source validation, OAuth, SAS, Table/Queue services.

---

### 10. Getting Started Template

```bash
# Install Zig (once)
curl -L https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz | tar xJ
export PATH=$PWD/zig-linux-x86_64-0.14.0:$PATH

# Clone and build
git clone https://github.com/YOUR_HANDLE/zing.git
cd zing
zig build

# Run
./zig-out/bin/zing --blob-port 10000 --workspace ./data

# Test with Azure SDK (Node.js)
# AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1/"
```

---

### 11. Competitive Positioning

Azurite's weakness = Zing's opportunity: sustained throughput under load, cold-start latency, memory efficiency.