-- Tormento (D2) + boss rush: dificuldade opt-in por char (0 = normal) e
-- teto desbloqueado por progressão. Sem wipe, sem reset: só multiplicadores.
ALTER TABLE character ADD COLUMN torment INTEGER NOT NULL DEFAULT 0;
ALTER TABLE character ADD COLUMN torment_max INTEGER NOT NULL DEFAULT 0;
