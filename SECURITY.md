# Security

Backlit's local bridge is opt-in and uses a Keychain pairing key. It binds only to loopback unless local-network sharing is enabled. Do not expose it directly to the internet. The bridge rejects cross-origin browser requests, duplicate headers, chunked bodies, oversized messages, and unsupported control fields.

Report a security issue privately using the contact route at https://t0nyz.com. Include the app version, OS build, and a minimal reproduction; omit credentials, prompts, transcripts, and personal data. Please do not post working keys or private configuration in public issues.

The preview is not a security guarantee. Undocumented logo/power controls, administrator-authorized preferences, agent configuration, local HTTP transport, and crash recovery are reviewed separately in the validation document.

In-app updates require a bundle-pinned Ed25519 public key, HTTPS signed feed, non-expiring signed-feed policy, and archive verification before extraction. This development build has no trust feed/key and refuses update checks. Checksums served beside an archive are not publisher authentication. Automatic checks/downloads and system profiling are disabled. Actual authenticated update installation, resumed/interrupted installs, and rollback remain unverified.
