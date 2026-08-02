# Zing Development Diary 🗓️

*A day-by-day chronicle of building Zing — the high-performance Azure Storage emulator in Zig.*

---

## Day 1 — August 1, 2026

### Goal
Teis wanted a prompt for an open-source project. The prompt described **Zing** — a fast Azure Storage emulator in Zig, meant to replace Azurite (which is slow due to Node.js/GC/event-loop bottlenecks).

### What happened
1. Generated the full project prompt (11 sections: name, problem, why Zig, architecture, API surface, performance design, project structure, Azurite comparison, MVP scope, getting started, positioning)
2. Pushed the prompt to **`docs/prompt.md`** in the existing [github.com/teilin/zing](https://github.com/teilin/zing) repo
3. Inspected the existing scaffold — had a `build.zig`, `src/` directory tree with module stubs, and a README

### Key decisions
- Started tackling compile errors for Zig **0.14.0** (the version already installed)
- `@alignStack` doesn't exist in Zig 0.14 — changed to `@alignCast`
- The vtable-based `StorageBackend` was missing a `ptr` field — added it for proper dispatch

### Build status
❌ 23+ compile errors → after fixes: ❌ 7 errors → ❌ 3 errors

---

## Day 2 — August 1, 2026 (cont.)

### Fixed for Zig 0.14
Wired up the HTTP server with a working router:
- `src/http/request.zig` — full HTTP request parser (method, path, query, headers, body)
- `src/http/router.zig` — blob/container routing with XML response generation
- `src/http/server.zig` — epoll event loop handling connections, wired to router
- `src/main.zig` — creates Router, passes to Server
- Fixed all compile errors in `src/storage/backend.zig` (shadowing, API mismatches)

### Build status
✅ **Zig 0.14** — clean compile, server starts and listens on port 10000

### Then: port to Zig 0.16.0
Teis requested a move to Zig 0.16.0. This kicked off a **massive API migration** that consumed the rest of the session.

---

## Day 3 — August 1, 2026 (Zig 0.16.0 migration)

### The 0.16.0 grind
Zig 0.16.0 removed almost everything we were using:

| What broke | Replacement |
|-----------|-------------|
| `std.fs.cwd()` | Gone — use `std.os.linux.openat/mkdirat/unlinkat` |
| `std.posix.socket/bind/listen/accept` | Moved to `std.c.*` (libc bindings) |
| `std.posix.O.*`, `std.posix.S.*`, `std.posix.AT.*` | All gone — `std.c.O` packed struct |
| `std.posix.epoll_create1/epoll_ctl/epoll_wait` | `std.c.epoll*` |
| `std.heap.GeneralPurposeAllocator` | Replaced by `std.heap.DebugAllocator(.{}){}` |
| `std.process.argsAlloc` | Use `pub fn main(init: std.process.Init.Minimal)` |
| `std.ArrayList` | `std.array_list.Managed` |
| `std.posix.socket_t` | `std.c.fd_t` (just `i32`) |
| `std.os.linux.epoll_event` | `std.c.epoll_event` |
| `std.time.timestamp()` | `std.os.linux.clock_gettime(.REALTIME, &ts).sec` |
| `c.Stat` | 👻 **Is void on Linux** — must define custom extern struct |
| `c.fstat / c.fstatat` | 👻 **Also void** — use `extern "c" fn` directly |
| `timespec.tv_sec` | `timespec.sec` |
| `dirent64.d_ino` | `dirent64.ino` |

### Failed attempts
- **Take 1**: Try to use `std.posix.*` replacements within posix — ❌ they're all gone
- **Take 2**: Migrate to `std.c.*` — ❌ 10 errors (paths need null-termination, `c.O` is a struct)
- **Take 3**: Null-terminate paths + fix `c.O` struct syntax — ❌ `c.Stat` is void
- **Take 4**: Custom `OsStat` extern struct — ❌ alignment issues
- **Take 5**: `@alignCast(@ptrCast(...))` workarounds — ❌ corrupted code from sed
- **Take 6**: Complete backend rewrite using `std.os.linux.*` syscalls — ❌ ArrayList API issues
- **Take 7-10**: Iterative fixes (6 subagents total) — finally ✅ **clean compile**

### The fix that worked
Combined approach:
- **Socket ops**: `std.c.socket/bind/listen/accept4/setsockopt/epoll*` — all return `c_int` (-1=error)
- **File ops**: `std.os.linux.openat/mkdirat/unlinkat/read/write/lseek/getdents64` — return `usize` (negative=errno)
- **Stat**: Custom `extern struct Stat` + raw `extern "c" fn fstat/fstatat` declarations
- **Errno**: Raw integer comparisons (`EEXIST=17`, `ENOENT=2`, etc.)
- **ArrayList**: `std.array_list.Managed(u8)` with `.init(gpa)` and `.writer()`

### End-to-end verification
Server starts, responds to HTTP requests. Verified:
- ✅ `PUT /devstoreaccount1/container/blob` — **201 Created**
- ✅ `GET /devstoreaccount1/container/blob` — **200 + content "Hello, Zing!"**
- ✅ `HEAD /devstoreaccount1/container/blob` — **200 OK**
- ✅ `DELETE /devstoreaccount1/container/blob` — **202 Accepted**
- ⚠️ Container operations (`?restype=container&comp=list`) — routing bug: query string leaks into path before segment parsing

### Final commit
Pushed to `main` and `dev` branches. README updated to reflect current state.

---

## Future Work 🚀

### Immediate
- [ ] Fix container operation routing (query string handling in path segment parser)
- [ ] Add `zig build test` step to build.zig
- [ ] Unit tests for backend, router, request parser, CRC64, serializer

### MVP v0.2
- [ ] Page Blobs (PutPage, ReadPages)
- [ ] Append Blobs
- [ ] PUT BLOCK LIST / GET BLOCK LIST (block blob assembly)
- [ ] Copy Blob
- [ ] OAuth/SAS token validation

### Phase 2
- [ ] Queue Service (port 10001) — message CRUD with visibility timeout
- [ ] Table Service (port 10002) — OData protocol, query engine

### Performance
- [ ] Switch from `makePath` allocator-based helper to stack-based path construction
- [ ] Memory-mapped file reads (`mmap` + `madvise(MADV_SEQUENTIAL)`)
- [ ] Work-stealing thread pool for checksum computation
- [ ] Lock-free SPSC queues for Queue service

---

## Tech Stack

- **Language**: Zig 0.16.0
- **IO**: epoll (Linux) / kqueue (macOS — stub)
- **Storage**: File-based (disk extents) / In-memory (arena)
- **Auth**: SharedKey (HMAC-SHA256)
- **Checksums**: CRC64-NG (ECMA-182) with SSE4.2 path
- **XML**: Custom streaming parser + serializer
- **Allocator**: Arena (bump allocator) for bulk operations
- **Build**: Single static binary via `zig build` (links libc + pthread + m)

## Repo

**GitHub**: [github.com/teilin/zing](https://github.com/teilin/zing)

Branches: `main` and `dev` are synced.
