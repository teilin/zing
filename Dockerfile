# Multi-stage Docker build for Zing
# Stage 1: Build the binary
FROM ziglang/zig:0.16.0 AS builder

WORKDIR /build
COPY . .

# Build with static musl target for a fully static binary
RUN zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

# Stage 2: Minimal runtime image
FROM scratch AS runtime

COPY --from=builder /build/zig-out/bin/zing /zing

EXPOSE 10000 10001 10002

ENTRYPOINT ["/zing"]
CMD ["--blob-port", "10000", "--queue-port", "10001", "--workspace", "/data"]
