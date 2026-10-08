-- M-7 (2026-10-07): skill leveling por uso. A coluna `xp` é o contador do
-- progresso DENTRO do nível atual — o teto de nível (`SkillProgress.MaxLevel`)
-- vive no código, não no banco, porque é decisão de produto com régua própria
-- (`tests/IdleTestsFrontier.gd:@SuiteSkillXp`), e o `xp` zerado no teto é a
-- forma honesta de dizer "não há próximo nível" sem linha mágica. O resto do
-- par (nível, xp) desce para o banco pelo MESMO snapshot de `UpdateProgress`
-- que já persiste `skill.level` — nenhum writer novo, nenhuma mutex nova.
ALTER TABLE skill ADD COLUMN xp INTEGER NOT NULL DEFAULT 0;
