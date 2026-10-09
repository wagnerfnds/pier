# Pier client protocol

How a client (the Pier app, `Tools/pierctl`, `pierd client`) talks to pierd: pairing links, the client identity,
the pairing handshake and the steady-state connection. What travels on that connection is in [API.md](API.md).

Code: `Server/pierd/internal/{identity,pairing,trust,wire}` on the box,
`Packages/PierKit/Sources/PierKit` (`PairingLink.swift`, `Pairing.swift`, `Identity.swift`, `TLSDial.swift`,
`H2Connection.swift`, `BoxClient.swift`) in the app.

## 0. Summary

* Transport: TCP → **TLS 1.3 only, mutual, Ed25519 certificates**; trust is the **pinned SHA-256 of the peer's
  SubjectPublicKeyInfo** (no certificate authorities). On top: **HTTP/1.1 for pairing, HTTP/2 for everything else**,
  JSON bodies, NDJSON for the event stream. No custom framing.
* Methods are HTTP routes: `GET /v1/sessions`, `POST /v1/sessions/{name}/send`, ...
* Apple's TLS stack (Network.framework, URLSession) cannot talk to pierd: it does not offer Ed25519 signatures in
  TLS. The app uses **swift-nio-ssl (BoringSSL) + swift-nio-http2**, with a small patch exposing the TLS exporter
  (section 7).

## 1. Pairing links

### 1.1 Single-box link (`pierd pair` on the box)

```
pier://HOST:PORT?code=<base32>&fp=<base32>
```

* Scheme `pier` (case-insensitive in the app); no other scheme is accepted. No userinfo, no path (or `/`), no
  fragment. `HOST:PORT` is mandatory: a non-empty host (IPv4, hostname or bracketed IPv6) and a port 1..65535.
* Query keys `fp` and `code`, in any order (pierd prints `code=…&fp=…`).
* Both are RFC 4648 base32 (A-Z2-7), no padding, printed lowercase, parsed case-insensitively; 32 bytes →
  52 characters each.
  * `fp`: SHA-256 of the box's SubjectPublicKeyInfo (2.3).
  * `code`: 32 random bytes, single use. A secret: it is never sent, only used as an HMAC key (section 3). Never
    log a link.
* Lifetime: 10 minutes by default, `pierd pair --ttl` up to 1 hour. The expiry is not in the link: the box enforces
  it. Pending codes live in the box's `pairing.json`.
* Example: `pier://192.0.2.10:7444?code=<52 chars>&fp=<52 chars>`. `pierd pair --json` prints `{"link", "address",
  "fingerprint", "expires"}`; `--address HOST[:PORT]` sets the address put in the link. A QR code is just this
  string.

### 1.2 Join link (several boxes in one link, made by the app)

```
pier://join?v=1&d=<base64url payload, no padding>
```

The app builds it (`JoinLink.encode`, "take to another device") from fresh invites of every box it is paired with
(1.3), so a new device pairs with all of them from one QR code. pierd never sees a join link. `v` must be `1`.
Payload, big-endian, `str` = uint8 length + UTF-8 bytes (≤ 255):

```
uint32  expires (Unix seconds)
str     from        (the inviting device's name, display only)
uint8   count       (1..16)
per box:
  [32]byte fingerprint   (raw, not base32)
  [32]byte code          (raw, not base32)
  str     name           (^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$)
  str     network        ("" = dial the addresses directly; the app writes "")
  str     tailnet        ("")
  uint8   address count (1..4), then str "host:port" each
```

Trailing bytes or short reads make the link invalid. The app rejects it when `now > expires + 1 minute`; each box is
the real judge of its own code. Each box entry pairs exactly like a single-box link. The app finds a link inside pasted text with
``pier://[^\s'"<>`]+`` minus trailing `.,;:)]`.

### 1.3 An invite from a paired client

`POST /v1/pair/invite` with an optional `{"for":"<name>"}` → `{"link":"pier://HOST:PORT?code=…&fp=…","expires":"RFC3339"}`:
the same kind of link as `pierd pair` (single use, 10 minutes). At most 10 invites per 10 minutes from all clients
together (429), gated by `before:pairing.invite` hooks; 404/405 on a box without the route. Details in API.md §10.

## 2. Client identity

### 2.1 Key

* **Ed25519.** The key *is* the identity; the box's `clients.json` maps a name to its fingerprint.
* Stored as PKCS#8 PEM (`-----BEGIN PRIVATE KEY-----`), the same format as the box's `identity.pem`. The app keeps it
  in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so background refresh can connect), under
  `identity.pem`; pierctl in `~/.config/pierctl` (or `$PIERCTL_HOME`). Generated once.
* PKCS#8 for a CryptoKit `Curve25519.Signing.PrivateKey`: `30 2e 02 01 00 30 05 06 03 2b 65 70 04 22 04 20 || seed`
  (48 bytes).

### 2.2 Certificate (made on every start, carries no meaning)

Self-signed X.509 with an Ed25519 signature: random serial < 2^127, subject `CN=pier`, valid from now − 1 h to
now + 10 years, key usage digitalSignature, extended key usage serverAuth and clientAuth, no SANs, not a CA. **Neither
side validates chain, hostname, expiry or EKU**: the only requirements are that it parses, carries the Ed25519 SPKI,
and that TLS CertificateVerify is signed with the matching key. Nothing is pinned to the certificate, only to the key.

### 2.3 Fingerprint

```
fp     = SHA256( DER of the certificate's SubjectPublicKeyInfo )      // 32 bytes
string = lowercase( base32_std_nopad(fp) )                            // 52 characters
```

An Ed25519 SPKI is the fixed 12-byte prefix `30 2a 30 05 06 03 2b 65 70 03 21 00` followed by the 32-byte public
key, so for a CryptoKit key `fp = SHA256(prefix || rawPublicKey)`. Same function for box and client. The short form
shown to people is the first 12 characters. Compare fingerprints as raw bytes.

## 3. Pairing handshake

1. Parse the link. Load or create the identity, **and persist it before pairing**.
2. Open TCP to `HOST:PORT` (15 s dial and handshake timeout). TLS: version **1.3 minimum**, ALPN **`http/1.1` only**
   (one connection is one TLS session), present the client certificate, replace normal verification with **the
   pin: the leaf's SPKI SHA-256 must equal the link's `fp`**, else abort. No SNI needed. The box disables session
   tickets (no resumption).
3. Derive the TLS exporter (RFC 5705 / RFC 8446 §7.5):
   `exporter = Export(label = "EXPORTER-pier-pair-v1", context = empty, length = 32)`.
4. `proof = HMAC-SHA256(key = code (the 32 raw bytes), msg = "pier pair v1" (12 ASCII bytes) || exporter (32) ||
   clientFingerprint (raw 32))`. The proof is bound to this TLS session and this client key: replayed on another
   connection or for another key, it fails.

   The label `EXPORTER-pier-pair-v1` and the prefix `pier pair v1` are part of the pairing cryptography that pierd
   and the app compute byte for byte; changing either breaks pairing between any app and any box that did not change
   at the same time. Test vector (both PierKit's `proofVector` and pierd's `TestProofVector`): code = 32 bytes of
   `0x01`, exporter = 32 bytes of `0x02`, clientFingerprint = SHA-256 of the SPKI of RFC 8032 test 1's key
   (`9d61b19d…7f60`) → proof `31031d35b2ec1c3ba97454b216cafb666943195fb24ffd064218a61c8da3caba`.
5. Send on the same connection:

   ```
   POST /v1/pair HTTP/1.1
   Host: 192.0.2.10:7444
   Content-Type: application/json
   Content-Length: N

   {"name":"<client name>","proof":"<standard base64, with padding, of the 32-byte proof>"}
   ```

   * `name`: this client's label. Must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$` and not be `local`
     (case-insensitive), else the box uses `client`; a name already taken gets a suffix (`name-2`, `name-3`). The
     app derives it from the device (`PierName.fromHostname`: lowercase, strip `.local`, other characters → `-`,
     ≤ 63). Body ≤ 16 KB.
6. The box: per-IP rate limit → requires a client certificate → computes the same exporter → under a file lock,
   consumes the unexpired pending code whose proof matches (constant-time compare) → stores `{name, fingerprint,
   paired_at}` in `clients.json` → event `client.paired` →

   ```
   HTTP/1.1 200 OK
   Content-Type: application/json

   {"name":"<box name>"}
   ```

   Failures are deliberately alike: **403** `{"error":"pairing rejected"}` for an unknown, expired or used code, a
   bad proof, a bad body or no certificate; **429** `{"error":"too many pairing attempts; try again in a minute"}`.
   Pairing errors carry no `code` field.
7. The client stores the box: `{name, address: "HOST:PORT", fingerprint (the box's, 52 characters), paired_at}` (the
   app: `BoxRecord`, kept under `boxes.json` in the Keychain). The local name is the box's reported name, made
   unique, or one the person chose. The address is what is dialled again; the pinned fingerprint is the only trust
   anchor. Pairing again with the same box key replaces its entry.
8. Close the connection. API calls use a separate HTTP/2 connection.

The code is consumed on the first accepted attempt. If the app dies after the 200 but before saving the box, the link
cannot be used again: pair with a new code.

## 4. Steady-state connection

* One TCP + TLS 1.3 connection per box, same configuration as pairing but **ALPN `h2`**; pin check on every
  handshake; the client certificate is always presented (without one the handshake is refused).
* The box authorises **each request** by the client certificate's fingerprint against `clients.json`. An unknown
  key gets **401** `{"error":"unauthorized"}` (the handshake itself succeeds, so a 401, not a TLS error, says
  "revoked"; a TLS failure means network trouble or a pin mismatch).
* One HTTP/2 connection carries all calls and streams. The app pings every 15 s; pierd pings idle connections every
  30 s (15 s timeout) and closes them after 10 minutes idle. The app drops and redials on foreground and network
  changes (`BoxClient.reset()`). Request timeouts: 45 s for GETs, 3 minutes for the rest.
* URL form `https://HOST:PORT/v1/...`. Headers: `Content-Type: application/json` on bodies; optional
  `X-Pier-Origin: <[a-z0-9][a-z0-9-]{0,31}>` names the calling tool in events (default `pier`; the app sends `ios`).
  No auth header, no request id, no version negotiation: identity is the client certificate, idempotency is
  `idem_key` in send bodies.
* Bodies ≤ 64 KB, ≤ 2 MB for prompts. pierd allows 10 s for the TLS handshake and request headers.

### 4.1 Success and error format

Success: JSON, top-level lists `[]` never `null`. Box routes fail with `{"error":"human message","code":"<code>"}`
(codes in API.md §0.2). Wire-level answers (`/v1/pair`, 401) carry only `{"error": "..."}`; `GET /v1/ping` answers
503 `{"code":"box_stopping"}` while pierd shuts down. Unknown routes answer Go's plain-text `404 page not found`.

### 4.2 Wire routes

* `GET /v1/ping` → `{"name":"<box name>"}`: the cheap liveness and trust check (401 once revoked).
* `POST /v1/pair`: section 3.
* Everything else is the box API (API.md), also reachable by the box's own user on the Unix socket
  `$PIER_HOME/box/pierd.sock`, where pierd's CLI and the agents' hooks talk to it.

## 5. Streaming

Streams are ordinary long-lived HTTP/2 requests: subscribe by opening the request, unsubscribe by cancelling the
stream. The only stream is the event stream, `GET /v1/events[?since=<seq>&max=<n>]` (API.md §7): NDJSON, a bare `\n`
keepalive every 25 s, resumable by `seq` from the box's journal. pierd closes it when the client is revoked; treat any
end as "reconnect with backoff, then check with `GET /v1/ping`".

There is no terminal attach stream and no port stream: the app reads screens and sends text and keys.

## 6. Revocation and rate limits

* Revoke: `pierd revoke NAME|FINGERPRINT` on the box, or `DELETE /v1/clients/{name|fingerprint}` from a paired
  client (a client may remove itself; its connections then close a second after the answer). `pierd clients` lists
  paired clients. pierd re-reads `clients.json` every second (and at once after `pierd revoke`); every open request
  of a revoked key is cancelled and its connections are closed. The app sees streams end and then **401**: it stops
  retrying, marks the box as no longer trusted and offers to pair again.
* An unreadable `clients.json` makes every request 401 (fails closed) without cutting open streams.
* Pairing limits: per source IP 10 per minute (burst 10), overall 60 per minute (burst 30); **only failures count**.
  429 → wait about a minute.
* Invites: 10 per 10 minutes (429).
* No limit on authenticated API calls.
* A pin mismatch (the box's key changed) is a hard, visible error. Never re-pin automatically.

## 7. TLS on Apple platforms

### 7.1 What pierd demands

TLS 1.3 minimum, a client certificate required, **only an Ed25519 server certificate**, the TLS 1.3 default suites,
no resumption. A Go TLS 1.3 server picks its certificate by the client's `signature_algorithms`; a client that does not
offer `ed25519` (0x0807) gets `handshake_failure`. The client's Ed25519 key also signs CertificateVerify, and pairing
needs the TLS exporter.

### 7.2 Why not Network.framework or URLSession

Apple's TLS stack does not offer Ed25519 signature schemes, so the handshake fails at the hello, before any custom
verify block runs (`NWConnection` reports `-9824 handshake failure`; LibreSSL's `s_client` the same alert).
`SecCertificate` / `SecIdentity` do not handle Ed25519 keys either. CryptoKit's Curve25519 is fine for generating and
signing, but not inside Apple's TLS. Supporting Apple's stack would need a second identity type (ECDSA P-256) and
fingerprint scheme on the box, which pierd does not have.

### 7.3 What PierKit does: userspace TLS 1.3 with swift-nio-ssl

* `swift-nio`, `swift-nio-ssl` (BoringSSL), `swift-nio-http2`, `swift-certificates` / `swift-asn1` for the
  certificate, CryptoKit for keys and HMAC. `ClientBootstrap` over plain TCP (not NIOTransportServices). Raw sockets
  need `NSLocalNetworkUsageDescription` for boxes on the local network, and iOS suspends sockets in the background
  (reconnect when the scene becomes active).
* `TLSConfiguration.makeClientConfiguration()`: `minimumTLSVersion = .tlsv13`,
  `certificateVerification = .noHostnameVerification` plus a `customVerificationCallback` that hashes the leaf's
  SPKI and compares it with the pin (with `.none` the callback is never called), `applicationProtocols = ["h2"]` (or
  `["http/1.1"]` for pairing), the client certificate and its PKCS#8 key. Do not pass `serverHostname` for IP boxes.
* **Advertise ed25519**: BoringSSL's default verify algorithms do not include it, so set
  `verifySignatureAlgorithms = [.ed25519]`, else pierd answers `handshake_failure`. Signing with an Ed25519 client key
  works by default.
* **TLS exporter**: swift-nio-ssl does not expose `SSL_export_keying_material`. `Vendor/swift-nio-ssl` carries a small
  patch (see `Vendor/README.md`) calling `SSL_export_keying_material(ssl, out, 32, "EXPORTER-pier-pair-v1", 21, NULL,
  0, 0)`. Needed for pairing only; without it pairing is impossible (the proof is mandatory).
* HTTP: pairing is one hand-written HTTP/1.1 request on the pinned connection; the steady state is `NIOHTTP2` (a
  stream multiplexer) over the same TLS handler with ALPN `h2`, one stream per request, a long-lived stream for
  `/v1/events`, and a PING every 15 s.
* Verified: the exporter BoringSSL computes matches Go's on both ends of a loopback TLS 1.3 connection (unit test),
  and real boxes accept the proof.

## 8. End to end

```
BOX:     pierd pair --address 192.0.2.10:7444
         -> pier://192.0.2.10:7444?code=<52 b32 chars>&fp=<52 b32 chars>

APP  1.  parse -> addr=192.0.2.10:7444, boxFP (32 B), code (32 B)
     2.  load/create the Ed25519 key; myFP = SHA256(SPKI); certificate per 2.2
     3.  TCP; TLS 1.3 ClientHello, ALPN [http/1.1], signature_algorithms includes ed25519, client cert
         verify: SHA256(SPKI(server leaf)) == boxFP, else abort
     4.  exp = ExportKeyingMaterial("EXPORTER-pier-pair-v1", empty, 32)
         proof = HMAC_SHA256(code, "pier pair v1" || exp || myFP)
     5.  >> POST /v1/pair HTTP/1.1   {"name":"iphone-octocat","proof":"<base64(proof)>"}
         << 200 {"name":"devbox"}
     6.  save {name:"devbox", address:"192.0.2.10:7444", fingerprint:<boxFP b32>, paired_at:<now>}; close

APP  7.  new TLS connection, ALPN h2, same pin check and client cert
     8.  >> GET /v1/ping           << 200 {"name":"devbox"}       (401 {"error":"unauthorized"} = revoked)
     9.  >> GET /v1/sessions       << 200 [{"name":"api-fix","dir":"/home/octocat/code/api-fix","created":"…",
                                           "attached":0,"exited":false,"agent":"claude","agent_state":"waiting"}]
    10.  >> POST /v1/sessions/api-fix/send   {"text":"yes, continue","when":"now","idem_key":"3F2A…"}
         << 200 {"sent":true,"turn":"api-fix#4","seq":1234,"at":"2026-10-07T21:14:03Z"}
    11.  >> GET /v1/events?since=1234   << 200 application/x-ndjson
         << {"seq":1235,"type":"agent.finished","time":"…","box":"devbox","origin":"claude","data":{"session":"api-fix",…}}
         << \n   (keepalive every 25 s)
```

## 9. Tools

* On the box: `pierd pair [--address HOST[:PORT]] [--ttl 10m] [--json]` prints a link; `pierd clients` lists paired
  clients; `pierd revoke NAME|FINGERPRINT` removes one. `pierd client pair LINK` then `pierd client GET /v1/sessions`
  is a paired client for scripts.
* On a Mac: `Tools/pierctl`, a small CLI on PierKit that pairs and calls a box the way the app does:

  ```sh
  pierctl pair '<pier://link>' --name <client-name>    # identity and boxes in ~/.config/pierctl, or $PIERCTL_HOME
  pierctl info
  pierctl get /v1/sessions
  pierctl events --seconds 30
  pierctl selftest
  ```

  `$PIERCTL_HOME` gives it a separate identity and set of boxes (for example to test another box side by side).
  `pierctl` takes single-box links only.
