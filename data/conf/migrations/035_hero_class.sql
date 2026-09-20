-- Hero classes (sem wipe): class_id vazio = sem classe (veteranos mantêm
-- acesso total a skills e equipamentos; só chars novos escolhem classe).
ALTER TABLE character ADD COLUMN class_id TEXT NOT NULL DEFAULT '';
