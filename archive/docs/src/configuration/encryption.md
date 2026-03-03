# Encryption

Liteskill can optionally encrypt sensitive data at rest using AES-256-GCM via `Liteskill.Crypto`. Encryption is **off by default** and must be explicitly enabled.

## Enabling Encryption

Set both environment variables:

```bash
export LITESKILL_ENCRYPTION=true
export ENCRYPTION_KEY="$(openssl rand -base64 32)"
```

When `LITESKILL_ENCRYPTION` is not set to `true`, the `Crypto` module is a passthrough — values are stored and returned as-is with no encryption overhead.

## How It Works

When enabled:

1. A 32-byte encryption key is derived from the `ENCRYPTION_KEY` config value via SHA-256
2. Each encrypt operation generates a random 12-byte IV
3. Ciphertext format: `IV (12 bytes) || tag (16 bytes) || ciphertext`
4. The result is base64-encoded for storage in string columns

## Validation

On application boot, `Crypto.validate_key!/0` checks the configuration. If encryption is enabled but no key is set, the app will crash on startup rather than failing on first encrypt/decrypt. If encryption is not enabled, this is a no-op.

## What's Encrypted (When Enabled)

The following fields use encryption-aware Ecto types:

- **MCP server API keys** — via `Liteskill.Crypto.EncryptedField` Ecto type
- **LLM provider API keys** — via `Liteskill.Crypto.EncryptedField`
- **Data source credentials** — via `Liteskill.Crypto.EncryptedMap` Ecto type

When encryption is off, these types store values as plaintext.

## Ecto Custom Types

- `Liteskill.Crypto.EncryptedField` — Encrypts/decrypts a single string value
- `Liteskill.Crypto.EncryptedMap` — Encrypts/decrypts a JSON map (for structured credentials)

These types handle encryption transparently at the Ecto layer — data is encrypted before insert and decrypted after load.
