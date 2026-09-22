# Adicionando uma Skill

Este guia cobre o processo para adicionar uma nova skill ao Shambleta.

## 1. Definir dados no Game Data Manager

Abra o projeto no Godot Editor:

```
Game Data -> Skill
```

Preencha:
- `id` — identificador único
- `name` — nome da skill
- `description` — descrição
- `element` — elemento (fire, water, earth, air, neutral)
- `cost_type` — tipo de custo (mana, stamina, essence)
- `cost_value` — valor do custo
- `cooldown` — cooldown em segundos
- `target_type` — alvo (self, enemy, ally, area)
- `effects` — lista de efeitos

## 2. Adicionar tradução

Edite `data/i18n/ui.csv`:

```csv
Key,en,pt_BR
skill_name_45,Fireball,Bola de Fogo
skill_desc_45,Throws a fireball at the target,Lança uma bola de fogo no alvo
```

## 3. Implementar lógica (se necessário)

Skills simples usam o sistema genérico de combat. Skills customizadas precisam de script em `sources/scripts/`.

Crie um script em `sources/scripts/generic/` se a skill precisar de comportamento especial.

## 4. Testar

```bash
./scripts/test.sh all
```

Teste em combate real e verifique balanceamento.
