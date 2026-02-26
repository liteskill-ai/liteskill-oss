# Encryption

Liteskill encrypts sensitive data at rest using AES-256-GCM via `Liteskill.Crypto`.

## How It Works

1. A 32-byte encryption key is derived from the `ENCRYPTION_KEY` config value via SHA-256
2. Each encrypt operation generates a random 12-byte IV
3. Ciphertext format: `IV (12 bytes) || tag (16 bytes) || ciphertext`
4. The result is base64-encoded for storage in string columns

## Key Configuration

Set the `ENCRYPTION_KEY` environment variable:

```bash
# Generate a key
openssl rand -base64 32

# Set it
export ENCRYPTION_KEY="your-generated-key-here"
```

In desktop mode, the encryption key is auto-generated and stored in `desktop_config.json`.

## Validation

On application boot, `Crypto.validate_key!/0` verifies the key is configured. The app will crash on startup if missing, rather than failing on first encrypt/decrypt.

## What's Encrypted

The following fields are encrypted at rest:

- **MCP server API keys** — via `Liteskill.Crypto.EncryptedField` Ecto type
- **LLM provider API keys** — via `Liteskill.Crypto.EncryptedField`
- **Data source credentials** — via `Liteskill.Crypto.EncryptedMap` Ecto type

## Ecto Custom Types

- `Liteskill.Crypto.EncryptedField` — Encrypts/decrypts a single string value
- `Liteskill.Crypto.EncryptedMap` — Encrypts/decrypts a JSON map (for structured credentials)

These types handle encryption transparently at the Ecto layer — data is encrypted before insert and decrypted after load.
