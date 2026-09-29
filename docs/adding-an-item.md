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

O `.translation` que o `TranslationServer` lê não é gerado por script nenhum: é
produzido pelo importador `csv_translation` do motor a partir do CSV. Depois de
editar a tabela, reimporte e confira que as duas metades continuam dizendo a
mesma coisa:

```bash
godot --headless --editor --import --quit
bash scripts/test.sh one i18n_catalog_test
```

Para saber o que falta traduzir, o extrator compara as fontes do cliente com o
CSV e escreve o relatório em `data/i18n/coverage_report.md`; com `--write-gaps`
ele acrescenta as chaves ausentes com `pt_BR` vazio para o tradutor preencher:

```bash
python3 tools/extract_i18n.py --write-gaps
```

## 3. Adicionar loot table (se aplicável)

Edite `data/conf/migrations/` ou adicione em `data/db/` se for um item de drop.

## 4. Testar

```bash
./scripts/test.sh all
```

Verifique se o item aparece na loja, crafting e loot.
