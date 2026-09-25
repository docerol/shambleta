# TLS Certificate Provisioning

## Overview

The Shambleta game server supports two TLS modes:

1. **Proxy TLS (recommended for Coolify)**: TLS is terminated at the reverse proxy (Coolify/Traefik). The game server binds a plain WebSocket on port 6108. Set `SHAMBLETA_PROXY_TLS=1` in the environment.
2. **Direct TLS**: The game server terminates TLS itself. Requires `server.crt` and `server.key` files in the Godot user data directory (`user://`).

## Mode 1: Proxy TLS (Coolify)

No certificates needed on the game server. Coolify's Traefik proxy handles TLS termination.

### Configuration

In `docker-compose.yml` or Coolify environment variables:

```yaml
environment:
  SHAMBLETA_PROXY_TLS: "1"
```

The server will log:
```
[TLS] TLS terminated upstream (reverse proxy) — binding plain WebSocket
```

## Mode 2: Direct TLS

For direct public binds (without reverse proxy), the server requires a certificate pair.

### Certificate Paths

- Certificate: `user://server.crt`
- Private key: `user://server.key`

In Docker, these map to:
```
/data/.local/share/Shambleta/server.crt
/data/.local/share/Shambleta/server.key
```

### Provisioning Script

Use the provided `provision_tls.sh` script:

```bash
# Generate self-signed certificate (development/testing)
./tools/provision_tls.sh --self-signed --domain your-domain.com

# Or provide existing certificate paths
./tools/provision_tls.sh --cert /path/to/cert.pem --key /path/to/key.pem
```

### Let's Encrypt (Production)

For production, use Let's Encrypt with certbot:

```bash
# Install certbot
sudo apt-get install certbot

# Generate certificate
sudo certbot certonly --standalone -d your-domain.com

# Copy to Godot user data
sudo mkdir -p /data/.local/share/Shambleta
sudo cp /etc/letsencrypt/live/your-domain.com/fullchain.pem /data/.local/share/Shambleta/server.crt
sudo cp /etc/letsencrypt/live/your-domain.com/privkey.pem /data/.local/share/Shambleta/server.key
sudo chown -R 1000:1000 /data/.local/share/
```

### Auto-renewal

Set up a cron job for certbot renewal:

```bash
0 0 * * * /usr/bin/certbot renew --quiet --post-hook "docker restart shambleta-game"
```

## Client-side verification

The client verifies the server certificate. `sources/network/client/Client.gd` builds
its options with `NetworkCommons.ClientTLSOptions()`, which reads the operating system's
CA store (`OS.get_system_ca_certificates()`), loads it as an `X509Certificate` and hands
it to `TLSOptions.client(anchors)`; if the store cannot be read it falls back to
`TLSOptions.client()`. It never uses `TLSOptions.client_unsafe()`, which is what this
file used to rely on — that option turns off both chain and hostname checks on the very
channel carrying the password, the remember-me token and the 2FA code, and the client's
`auth_callback` (`_ValidateServerAuth`) is a bare `complete_auth(peerID)`, so nothing
else covered it. The hostname that gets checked is not an argument here: the transport
derives it from the `wss://` URL in `create_client` and from the address given to
`dtls_client_setup`.

Measured in this repo's toolchain (Godot 4.7.2, Linux/mbedtls), with a loopback
`WebSocketMultiplayerPeer` server presenting an openssl self-signed certificate
(`CN=127.0.0.1`, `SAN IP:127.0.0.1`):

- system anchors passed explicitly → handshake **refused**, `mbedtls`
  `-0x2700` / `-0x7180` (X509 verify failed): verification is live.
- the server's own certificate passed as the anchor → handshake **accepted**: a trusted
  chain still connects, so the refusal above is a verdict, not a broken TLS stack.
- `TLSOptions.client()` with no argument → `SSL module failed to initialize!`
  (`tls_context_mbedtls.cpp:209`, `-0x6C00`) before any handshake. The naive one-line
  fix (`client_unsafe()` → `client()`) would therefore have broken desktop login here;
  passing the store explicitly is what makes the fix both secure and functional.
- `TLSOptions.client_unsafe()` in the same fixture → the same `-0x6C00` init failure.
  Which is also the honest limit of this experiment: on this machine the old code could
  not complete a `wss://` handshake either, so the credential-harvesting path is
  established from the API's meaning and the no-op `auth_callback`, not from a local
  reproduction. Where the engine does initialise the system store (other platforms and
  distro layouts), the old code accepted any certificate.

What this means for each mode above:

- **Proxy TLS (Coolify / cloudflared)** — nothing to do. The edge presents a certificate
  issued by a public CA and the client already carries the matching root in its OS store.
  The Web build is unchanged: `wss://` there is terminated by the browser stack, which
  validates against the browser's own trust store.
- **Direct TLS with Let's Encrypt** — nothing to do, same reason.
- **Direct TLS with `provision_tls.sh --self-signed`** — clients refuse the connection,
  deliberately. To test that bind, issue from a CA the client trusts or add the private
  CA to the *client's* system store. Do not restore `client_unsafe()` on the client to
  work around it; that reopens the credential hole. Local development is unaffected: the
  local URL is plain `ws://` and the handshake was measured to still complete with
  verification options in hand.

Regression guard: `SuiteOpsA2` in `tests/IdleTests.gd` inspects the built
`TLSOptions` (`is_unsafe_client()` false, an `X509Certificate` anchor attached when the
OS store is readable) and sweeps every `.gd` under `sources/` for `client_unsafe`
outside comments.

## Hard-stop Behavior

If direct TLS is required (`RequiresTLS()` returns true) and certificates are missing:

1. Server logs: `FATAL: missing user://server.crt/user://server.key — refusing insecure public bind`
2. Server refuses to start
3. No WebSocket/ENet bind is created

This prevents accidental exposure of credentials in plaintext.

## Verification

After provisioning:

```bash
# Check certificate exists
ls -la /data/.local/share/Shambleta/server.crt
ls -la /data/.local/share/Shambleta/server.key

# Verify certificate validity
openssl x509 -in /data/.local/share/Shambleta/server.crt -text -noout
```

## Docker Volume Mount

In `docker-compose.yml`, mount the certificate directory:

```yaml
volumes:
  game-data:/data
  # For direct TLS mode, uncomment:
  # - ./certs:/data/.local/share/Shambleta
```
