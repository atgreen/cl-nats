# cl-nats 1.0.0

**Release date:** 2026-03-31

This release addresses **8 security findings** identified by the
[CL-SEC initiative](https://github.com/CL-SEC/CL-SEC).

## Security Fixes

### CL-SEC-2026-0121 — Credentials sent in cleartext (HIGH)

Credentials were sent over non-TLS connections without warning.

**Fix:** A warning is now emitted when `user`, `pass`, or `auth-token`
are provided on a non-TLS connection.

### CL-SEC-2026-0122 — No TLS certificate verification configuration (HIGH)

TLS verification behavior depended entirely on pure-tls defaults with
no user control.

**Fix:** Documented TLS posture.  pure-tls verifies certificates by
default.  Future releases will expose `:tls-verify` and `:tls-ca-file`
options.

### CL-SEC-2026-0123 — NATS protocol injection via CRLF in subjects (HIGH)

Subject names, reply-to addresses, and queue groups were interpolated
into wire protocol commands with no validation.  A subject containing
`\r\n` could inject arbitrary NATS commands.

**Fix:** All protocol string parameters are now validated by
`validate-protocol-string`, which rejects CR, LF, null, and tab
characters.

### CL-SEC-2026-0124 — Unbounded memory allocation from server byte counts (HIGH)

A malicious server could send a MSG line with an enormous byte count,
causing the client to allocate gigabytes.

**Fix:** Client-side maximum payload size enforced via
`*max-payload-size*` (default 64MB).  HMSG header-bytes vs total-bytes
relationship is validated.

### CL-SEC-2026-0125 — Credentials in plaintext in connection struct (MEDIUM)

Printing a connection object at the REPL displayed passwords in
cleartext.

**Fix:** `print-object` for `connection` now redacts `pass` and
`auth-token` fields.

### CL-SEC-2026-0126 — Credential leakage in error conditions (MEDIUM)

Error messages during connection failure could include the CONNECT JSON
with credentials.

**Fix:** Error paths no longer include raw CONNECT payloads.

### CL-SEC-2026-0127 — Server-supplied connect_urls enable SSRF (MEDIUM)

A malicious server could redirect the client (with credentials) to
attacker-controlled endpoints.

**Fix:** Added `*allow-discovered-servers*` variable (default T for
backward compatibility).  Set to NIL in security-sensitive environments
to disable server-directed reconnection.

### CL-SEC-2026-0128 — Header injection via CRLF in names/values (MEDIUM)

Header names and values were not validated before serialization.

**Fix:** `serialize-headers` now validates names and values via
`validate-header-name` and `validate-header-value`, rejecting CRLF
and other control characters.

## New Exports

- `*max-payload-size*` — configurable maximum payload (default 64MB)
- `*allow-discovered-servers*` — control server URL discovery
- `validate-protocol-string` — validate strings for wire protocol use

## Acknowledgments

Security issues identified by the CLSEC (Common Lisp Security
Initiative) automated audit.
