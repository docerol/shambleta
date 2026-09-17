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
/data/.local/share/godot/app_userdata/Shambleta/server.crt
/data/.local/share/godot/app_userdata/Shambleta/server.key
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
sudo mkdir -p /data/.local/share/godot/app_userdata/Shambleta
sudo cp /etc/letsencrypt/live/your-domain.com/fullchain.pem /data/.local/share/godot/app_userdata/Shambleta/server.crt
sudo cp /etc/letsencrypt/live/your-domain.com/privkey.pem /data/.local/share/godot/app_userdata/Shambleta/server.key
sudo chown -R 1000:1000 /data/.local/share/godot/app_userdata/
```

### Auto-renewal

Set up a cron job for certbot renewal:

```bash
0 0 * * * /usr/bin/certbot renew --quiet --post-hook "docker restart shambleta-game"
```

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
ls -la /data/.local/share/godot/app_userdata/Shambleta/server.crt
ls -la /data/.local/share/godot/app_userdata/Shambleta/server.key

# Verify certificate validity
openssl x509 -in /data/.local/share/godot/app_userdata/Shambleta/server.crt -text -noout
```

## Docker Volume Mount

In `docker-compose.yml`, mount the certificate directory:

```yaml
volumes:
  game-data:/data
  # For direct TLS mode, uncomment:
  # - ./certs:/data/.local/share/godot/app_userdata/Shambleta
```
