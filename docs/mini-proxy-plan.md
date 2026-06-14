# Mini Proxy Plan

## Goal

Replace the external `tinyproxy` dependency with a purpose-built Swift proxy
that implements only the features required for exam mode.

The intent is not to port `tinyproxy`, but to build a small, auditable, and
fully notarizable local proxy service that fits the existing daemon model.

## Scope for Phase 1

The first implementation should support only:

1. listening on `127.0.0.1:8888`
2. accepting plain HTTP proxy requests
3. accepting `CONNECT host:port` requests for HTTPS tunneling
4. checking the destination host against the existing allowlist
5. denying everything by default
6. returning a local block page for denied HTTP requests
7. rejecting denied `CONNECT` requests cleanly
8. structured logging for startup, shutdown, allow, deny, and transport errors

## Explicitly Out of Scope

These `tinyproxy` features should not be replicated unless there is a concrete
exam-mode requirement later:

1. upstream proxy support
2. reverse proxy support
3. SOCKS support
4. generic ACL engine beyond local loopback binding
5. transparent proxying
6. configuration language parsing
7. URL filtering beyond the current host/domain allowlist model
8. authentication
9. statistics endpoints

## Architecture Proposal

### `ExamProxyConfiguration`

Holds runtime parameters:

1. bind host
2. bind port
3. allowlist entries
4. connect port policy
5. block-page file URL
6. timeouts

### `ExamProxyServer`

Owns the server lifecycle:

1. start
2. stop
3. reload configuration
4. report health / status

### `ExamProxyConnectionHandler`

Handles one accepted client connection:

1. read request preface
2. classify request as HTTP or CONNECT
3. resolve target host and port
4. ask allowlist whether the target is permitted
5. either proxy or deny

### `ExamProxyRequestParser`

Parses only the minimum required request forms:

1. proxy-style HTTP requests like `GET http://example.org/...`
2. `CONNECT example.org:443`

### `ExamProxyAllowlist`

Encapsulates the current matching rules and existing allowlist file format.

Planned canonical path after the tinyproxy removal:

1. current legacy path: `/Library/Management/lib/tinyproxy/whitelist`
2. future built-in proxy path: `/Library/Management/whitelist`

Migration strategy:

1. if the future path does not exist
2. and the legacy tinyproxy path does exist
3. copy the existing whitelist once during first built-in-proxy startup
4. from then on, treat `/Library/Management/whitelist` as canonical

### `ExamProxyTunnel`

Creates and maintains the bidirectional byte-forwarding bridge for `CONNECT`.

## Recommended Implementation Order

1. server lifecycle and configuration models
2. request parser with test fixtures
3. allowlist matcher
4. denied HTTP response writer
5. denied CONNECT handling
6. basic CONNECT tunneling
7. plain HTTP forwarding
8. integration into `ExamModeController`
9. removal of `tinyproxy` runtime dependency
10. one-time whitelist migration away from the tinyproxy-specific path

## Estimated Effort

### Prototype

About 5 to 10 focused workdays for:

1. a local listener
2. host allowlist checks
3. basic HTTP proxying
4. basic CONNECT tunneling
5. local denial responses

### Production-Ready Version

About 2 to 4 weeks for:

1. robust error handling
2. connection lifecycle cleanup
3. integration tests
4. logging and diagnostics
5. configuration reload behavior
6. operational hardening

## Risks

1. HTTP parsing edge cases
2. browser / app compatibility for proxy-style requests
3. handling abrupt disconnects cleanly
4. avoiding accidental fail-open behavior
5. ensuring denied HTTPS requests fail fast and predictably

## Current Scaffold

The repository now contains the first runnable proxy stage:

1. a local listener can bind on `127.0.0.1:8888`
2. accepted client connections are parsed as minimal HTTP / CONNECT requests
3. requests are evaluated against the allowlist
4. denied HTTP requests return the bundled local block page
5. allowed `CONNECT host:443` requests open a real TCP tunnel to the destination
6. allowed plain HTTP requests are forwarded upstream with origin-form request rewriting

This beta implementation is now the default backend in the Swift development
branch. `tinyproxy` remains available as an explicit compatibility override.
