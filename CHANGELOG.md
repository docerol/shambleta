# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.9] - 2026-09-21

### Added
- Rebirth system (hybrid B+C) with essence economy and attune offline
- Season pass S1 with premium track, missions, auto-claim, deluxe, double XP
- Guilds, auction house, tournament system
- Crafting with item lots, fees, and creator revenue
- 2FA TOTP (S4) with setup/disable for admin/GM accounts
- LGPD compliance: right to erasure (`DeleteAccount`), refund (`RequestRefund`), consent logging
- Device fingerprint (migration 030)
- IP ban table (migration 008)
- Fraud detection (migration 017)
- Backup automation with daily local + offsite + restore probe
- Observability: Sentry opt-in, breadcrumbs, performance tags
- Tests: 1015+ checks, backup restore probe, benchmarks, E2E implementation checks

### Changed
- Idle engine migrated to physics-coupled tick (`_physics_process`, 0.25s interval)
- ZonePolicy for O(1) tick per zone independent of player count
- Multi-transport unified (ENet, WebSocket, WebRTC) via Network.gd RPC layer
- SQLite WAL with busy_timeout=5000 and synchronous=NORMAL
- Web export with PWA, service worker, and COOP/COEP headers

### Fixed
- Settlement idempotency anchor guard
- Boss ladder double-count guard
- Auth hardening anti-bruteforce backoff
- Nested transaction corruption guard in SQL.Transaction()
- Password hash upgrade on login (hash_ver migration)
