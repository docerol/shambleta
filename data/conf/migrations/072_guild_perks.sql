-- M-2 (2026-10-07): a loja de perks da guilda — pontos que hoje são só placar
-- viram moeda. Uma linha por (guilda, perk): tier comprado, nunca vendido, e
-- NUNCA devolvido pelo leave/disband (o gasto de pontos é consumo, não depósito).
-- Os consumidores do tier moram ao lado do catálogo: `GuildService` (cofre,
-- bênção de settle) e `GuildRoster` (teto da fileira) — o número aqui é estado,
-- a política é `GuildPerkCatalog.gd`.
CREATE TABLE IF NOT EXISTS guild_perk (
	guild_id INTEGER NOT NULL,
	perk_id TEXT NOT NULL,
	tier INTEGER NOT NULL DEFAULT 1,
	updated_at INTEGER NOT NULL,
	PRIMARY KEY (guild_id, perk_id)
);
