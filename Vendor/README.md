# Vendor

## swift-nio-ssl

Upstream: https://github.com/apple/swift-nio-ssl at commit `223204805d42a3af2716b1dab660068d6a44afec` (2026-10-07).
Copied without `.git`; everything is upstream except the patch below, marked in the code.

### Patch: TLS keying material exporter (grep "PIER PATCH")

Files: `Sources/NIOSSL/SSLConnection.swift`, `Sources/NIOSSL/NIOSSLHandler.swift`. Wraps `SSL_export_keying_material`.
Public API added:

```swift
NIOSSLHandler.exportKeyingMaterial(label: String, context: [UInt8]? = nil, length: Int) throws -> [UInt8]   // event loop only
Channel.nioSSL_exportKeyingMaterial(label:context:length:) -> EventLoopFuture<[UInt8]>
ChannelPipeline.SynchronousOperations.nioSSL_exportKeyingMaterial(label:context:length:) throws -> [UInt8]
public struct NIOSSLKeyingMaterialExportError: Error   // thrown on failure (e.g. handshake incomplete)
```
`context == nil` means no context (use_context = 0); pierd uses nil.
