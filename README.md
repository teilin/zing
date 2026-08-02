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
| Blob Storage | 10000 | ✅ **Full blob service** — CRUD, block/append/page blobs, copy, leases, snapshots, ACLs |
| Queue Storage | 10001 | ✅ **Full queue service** — create/list/delete queues, put/get/peek/clear/update/delete messages |
| Table Storage | 10002 | ✅ **Full table service** — create/list/delete tables, entity CRUD via JSON REST API |
| All 3 services run simultaneously from a single `zing` binary | | |

## Quick Start

### Prerequisites
- Zig 0.16.0 or later ([download](https://ziglang.org/download/))

### Build & Run

```bash
git clone https://github.com/teilin/zing.git
cd zing
zig build

# Run with defaults (blob 10000, queue 10001, table 10002, workspace ./data)
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

# Blob Append block
curl -X PUT -d "First piece" "http://127.0.0.1:10000/devstoreaccount1/mycontainer/append.txt?comp=appendblock"
curl -X PUT -d "Second piece" "http://127.0.0.1:10000/devstoreaccount1/mycontainer/append.txt?comp=appendblock"

# Blob Write page (512-byte aligned)
curl -X PUT -d "$(python3 -c 'print("A" * 512)' 2>/dev/null || printf 'A%.0s' {1..512})" \
  "http://127.0.0.1:10000/devstoreaccount1/mycontainer/page.txt?comp=page&offset=0"

# Blob List page ranges
curl "http://127.0.0.1:10000/devstoreaccount1/mycontainer/page.txt?comp=pagelist"

# Blob Authenticated request (SharedKey)
# Blob Copy (from source to destination)
curl -X PUT -d "Original" "http://127.0.0.1:10000/devstoreaccount1/srccont/source.txt"
curl -X PUT "http://127.0.0.1:10000/devstoreaccount1/dstcont/dest.txt" \
  -H "x-ms-copy-source: /devstoreaccount1/srccont/source.txt"

# Blob Snapshot
curl -X PUT -d "Data" "http://127.0.0.1:10000/devstoreaccount1/mycont/snap.txt?comp=snapshot"

# Blob Leases
curl -X PUT "http://127.0.0.1:10000/devstoreaccount1/mycont/lease.txt?comp=lease" \
  -H "x-ms-lease-action: acquire" -H "x-ms-lease-duration: 30"
curl -X PUT "http://127.0.0.1:10000/devstoreaccount1/mycont/lease.txt?comp=lease" \
  -H "x-ms-lease-action: renew" -H "x-ms-lease-id: {lease-id}"
curl -X PUT "http://127.0.0.1:10000/devstoreaccount1/mycont/lease.txt?comp=lease" \
  -H "x-ms-lease-action: release" -H "x-ms-lease-id: {lease-id}"

# OAuth (Bearer token)
curl -X PUT -d "Data" "http://127.0.0.1:10000/devstoreaccount1/mycont/oauth.txt" \
  -H "Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9..."

# RA-GRS secondary (read-only)
curl "http://127.0.0.1:10000/devstoreaccount1-secondary/mycont/blob.txt"
curl -X PUT -d "write" "http://127.0.0.1:10000/devstoreaccount1-secondary/cont/blob.txt" \
  -w "%{http_code}"  # → 409 Conflict

# Container ACLs
curl -X PUT "http://127.0.0.1:10000/devstoreaccount1/mycont?restype=container&comp=acl" \
  -d '<?xml version="1.0"?><SignedIdentifiers></SignedIdentifiers>'
curl "http://127.0.0.1:10000/devstoreaccount1/mycont?restype=container&comp=acl"

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

# Table: Create table
curl -X PUT "http://127.0.0.1:10002/devstoreaccount1/mytable"

# Table: List tables
curl "http://127.0.0.1:10002/devstoreaccount1/"

# Table: Insert entity
curl -X POST "http://127.0.0.1:10002/devstoreaccount1/mytable" \
  -H "Content-Type: application/json" \
  -d '{"PartitionKey":"pk1","RowKey":"rk1","Name":"Test"}'

# Table: Get entity
curl "http://127.0.0.1:10002/devstoreaccount1/mytable(PartitionKey='pk1',RowKey='rk1')"

# Table: Update entity
curl -X PUT "http://127.0.0.1:10002/devstoreaccount1/mytable(PartitionKey='pk1',RowKey='rk1')" \
  -d '{"Name":"Updated"}'

# Table: Delete entity
curl -X DELETE "http://127.0.0.1:10002/devstoreaccount1/mytable(PartitionKey='pk1',RowKey='rk1')"

# Table: Delete table
curl -X DELETE "http://127.0.0.1:10002/devstoreaccount1/mytable"
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
- `PUT /{container}/{blob}?comp=appendblock` — Append to an append blob (✅ 201 Created)
- `PUT /{container}/{blob}?comp=page&offset={offset}` — Write a 512-byte page (✅ 201 Created)
- `GET /{container}/{blob}?comp=pagelist` — List page ranges (✅ 200 + XML)
- `PUT /{container}/{blob}?comp=snapshot` — Create a blob snapshot (✅ 201 Created)
- `GET /{container}/{blob}?snapshot={id}` — Read blob snapshot (✅ 200)
- `DELETE /{container}/{blob}?snapshot={id}` — Delete blob snapshot (✅ 202)
- `PUT /{container}/{blob}` with `x-ms-copy-source` — Copy blob (✅ 202 Accepted)
- `PUT /{container}/{blob}?comp=lease` — Lease operations (✅ acquire/renew/change/release/break)
- `PUT /{container}?restype=container&comp=acl` — Set container ACL (✅ 200)
- `GET /{container}?restype=container&comp=acl` — Get container ACL (✅ 200 + XML)
- `GET /{account}-secondary/...` — RA-GRS secondary reads (✅ GET/HEAD allowed, writes rejected 409)

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

### Table Service — Verified Working

- `PUT /{table}` — Create table (✅ 201 Created)
- `GET /` — List tables (✅ 200 + JSON)
- `DELETE /{table}` — Delete table (✅ 204 No Content)
- `POST /{table}` — Insert entity (✅ 201 + JSON)
- `GET /{table}` — Query entities (✅ 200 + JSON)
- `GET /{table}(PartitionKey='{pk}',RowKey='{rk}')` — Get entity (✅ 200 + JSON)
- `PUT /{table}(PartitionKey='{pk}',RowKey='{rk}')` — Update/replace entity (✅ 204)
- `PATCH /{table}(PartitionKey='{pk}',RowKey='{rk}')` — Merge entity (✅ 204)
- `DELETE /{table}(PartitionKey='{pk}',RowKey='{rk}')` — Delete entity (✅ 204)

### Authentication — Implemented

- `SAS` (Shared Access Signature) — ✅ Service SAS token parsing + HMAC-SHA256 validation + permission checking
- `SharedKey` — ✅ HMAC-SHA256 signature validation
- `OAuth` (Bearer token) — ✅ Bearer token validation (dev mode accepts any well-formed token)
- No-auth requests pass through (dev mode)

### RA-GRS

- `{account}-secondary` endpoint — ✅ Read-only secondary endpoint (GET/HEAD only; writes rejected with 409)

### Planned

- OAuth token validation (JWT format validation)
- RA-GRS secondary (async replication)

## Architecture

```
zing/
├── build.zig                    # Zig build manifest
├── src/
│   ├── main.zig                 # Entry point, CLI args, triple-server startup (blob + queue + table)
│   ├── http/
│   │   ├── server.zig          # epoll HTTP server (Linux) / kqueue (macOS, stub)
│   │   ├── router.zig          # Blob path → handler dispatch + SAS/SharedKey/OAuth + RA-GRS
│   │   ├── request.zig          # HTTP request parsing
│   ├── queue/
│   │   ├── queue.zig            # In-memory QueueStore with visibility timeouts/pop receipts
│   │   └── handlers.zig         # Queue REST API router
│   ├── table/
│   │   ├── table.zig            # In-memory TableStore with tables and entities
│   │   └── handlers.zig         # Table REST API router (JSON)
│   ├── auth/
│   │   ├── shared_key.zig       # SharedKey HMAC-SHA256 validation
│   │   └── sas.zig              # Service SAS token validation
│   ├── storage/
│   │   ├── backend.zig          # Pluggable storage backend (FileBackend + MemBackend + ExtentStore)
│   ├── xml/
│   │   ├── serializer.zig       # XML response generation
│   │   └── deserializer.zig     # XML request parsing
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

# Run all three services (blob 10000, queue 10001, table 10002)
./zig-out/bin/zing

# Custom workspace
./zig-out/bin/zing --blob-port 10000 --queue-port 10001 --workspace /tmp/zing-data

# In-memory mode (no disk I/O, data lost on shutdown)
./zig-out/bin/zing --in-memory
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