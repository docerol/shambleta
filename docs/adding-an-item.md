# Adicionando um Item

Este guia cobre o processo completo para adicionar um novo item ao Shambleta.

## 1. Definir dados no Game Data Manager

Abra o projeto no Godot Editor e vá em:

```
Game Data -> Item
```

Preencha:
- `id` — identificador único numérico
- `name` — nome do item (chave da translation)
- `description` — descrição (chave da translation)
- `tier` — tier do item (1-5)
- `type` — tipo (consumable, equipment, cosmetic, etc.)
- `stackable` — se empilha
- `max_stack` — tamanho máximo da pilha
- `icon` — ícone na UI
- `stats` — dicionário de stats (se equipment)

## 2. Adicionar tradução

Adicione a chave em `data/i18n/ui.csv`:

```csv
Key,en,pt_BR
item_name_123,Item Name,Nome do Item
item_desc_123,Item description,Descrição do item
```

Gere os arquivos `.translation` com:

```bash
python3 tools/i18n/extract_i18n.py
```

## 3. Adicionar loot table (se aplicável)

Edite `data/conf/migrations/` ou adicione em `data/db/` se for um item de drop.

## 4. Testar

```bash
./scripts/test.sh all
```

Verifique se o item aparece na loja, crafting e loot.
