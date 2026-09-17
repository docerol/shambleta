-- SOM-IDLE Fase D: entitlements de cosméticos (MONETIZATION §2.4/§2.7).
-- cosmetic_grant (023) guarda a posse; cosmetic_equip guarda um equipado por
-- slot (= tipo: title, frame, formation_skin, drop_fx, emote, guild_banner,
-- rebirth_fx). Catálogo vive em código (EconomyService.COSMETIC_CATALOG).
CREATE TABLE IF NOT EXISTS cosmetic_equip (
  account_id INTEGER NOT NULL REFERENCES account(account_id),
  slot TEXT NOT NULL,
  cosmetic_id TEXT NOT NULL,
  PRIMARY KEY (account_id, slot)
);
