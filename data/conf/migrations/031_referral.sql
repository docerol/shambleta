-- SOM-IDLE R1 (COMMUNITY_ROADMAP): referral por código + marco.
-- referral_code é gerado lazy (username#NNNN); referred_by guarda o inviter;
-- referral_bonus_claimed marca o bônus já pago (idempotência além do ledger).
ALTER TABLE account ADD COLUMN referral_code TEXT NOT NULL DEFAULT '';
ALTER TABLE account ADD COLUMN referred_by INTEGER NOT NULL DEFAULT 0;
ALTER TABLE account ADD COLUMN referral_bonus_claimed INTEGER NOT NULL DEFAULT 0;
-- Sem UNIQUE: contas antigas nascem com '' e o código deriva do username
-- (único), logo é único por construção após gerado; lookup nunca casa ''.
CREATE INDEX IF NOT EXISTS idx_account_referral_code ON account(referral_code);
