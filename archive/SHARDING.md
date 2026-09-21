# Sharding Plan — Scaling Beyond 128 CCU

## Current Limit

The current server implementation has a hardcoded maximum of 128 concurrent players per server instance. This limit comes from:

- `NetworkCommons.MaxPeers = 128` (or equivalent constant)
- ENet/WebSocket peer slot allocation
- Single-threaded game loop processing all entities

For a beta closed launch, 128 CCU is sufficient. For commercial launch, we need a path to scale.

## Sharding Strategies

### Strategy A: Zone-Based Sharding (Recommended for Idle RPG)

**Concept:** Each server instance handles a subset of farm zones. Players on different zones are on different servers.

**Pros:**
- Natural fit for idle gameplay (most time is spent in one zone)
- Simple routing: zone ID → server address
- Low cross-server communication
- Easy to add zones without rebalancing

**Cons:**
- Guild/social features need cross-server sync
- Global leaderboard requires aggregation
- Trading between zones is complex

**Implementation:**
1. Zone routing table: `zone_id → server_address`
2. Client queries zone server on zone change
3. Cross-zone chat via companion relay
4. Global leaderboard computed nightly (batch job)

**Estimated cost per shard:** ~50-80 CCU (most players in 3-4 zones)

### Strategy B: Population-Based Sharding

**Concept:** Multiple server instances with dynamic load balancing. Players are distributed based on population.

**Pros:**
- More flexible than zone-based
- Better load distribution

**Cons:**
- Requires lobby/matchmaking service
- More complex state migration
- Higher cross-server traffic

**Estimated cost per shard:** ~100-120 CCU

### Strategy C: Hybrid (Zone + Overflow)

**Concept:** Primary zone-based sharding, with overflow instances for popular zones.

**Pros:**
- Best of both worlds
- Hot zones get more capacity

**Cons:**
- Most complex to implement
- Requires zone popularity tracking

## Recommended Path

1. **Phase 1 (Current):** Single server, 128 CCU cap
2. **Phase 2 (Beta Open):** Zone-based sharding, 3-4 shards, ~300-400 CCU total
3. **Phase 3 (Commercial Scale):** Add overflow instances + global services

## Technical Requirements

### Zone Routing

```
Client → Lobby Service → Zone Server Assignment
```

- Lobby service is lightweight (HTTP/WebSocket)
- Stores `zone_id → server_list` mapping
- Returns server address with lowest population

### Cross-Server Communication

- **Guilds:** Companion database as source of truth
- **Global Chat:** Relay through companion
- **Leaderboard:** Nightly batch computation
- **Trading:** Escrow on companion, atomic settlement

### Data Consistency

- Each shard has its own SQLite WAL file
- Companion holds shared state (guilds, global chat)
- Periodic reconciliation jobs

## Migration Path

1. Add zone server list to `data/conf/zones.cfg`
2. Implement `ZoneRouter` service (can be in companion)
3. Add `GetZoneServer()` RPC to Network
4. Client reconnects to zone server on zone change
5. Add cross-zone relay for guild/chat

## Cost Estimate

| CCU Target | Shards Needed | Servers | Monthly Cost |
|------------|---------------|---------|--------------|
| 128 | 1 | 1 | $5 (VPS) |
| 400 | 4 | 4 | $20 |
| 1000 | 10 | 10 | $50 |
| 5000 | 40 | 40 | $200 |

## Risks

1. **Guild fragmentation:** Members on different shards can't interact in real-time
2. **Leaderboard fairness:** Cross-shard comparison requires consistent metrics
3. **Complexity:** Sharding adds operational overhead

Mitigation: Start with zone-based sharding, keep social features companion-mediated.
