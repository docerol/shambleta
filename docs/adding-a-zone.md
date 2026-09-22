# Adicionando uma Zona

Este guia cobre o processo para adicionar uma nova zona de farm ao Shambleta.

## 1. Criar mapa no Tiled

1. Abra o Tiled
2. Crie um novo mapa com tileset do projeto
3. Adicione camadas:
   - `ground` — chão
   - `collision` — colisão
   - `spawns` — pontos de spawn (objetos com propriedades customizadas)
   - `decor` — decoração
4. Salve em `data/maps/zones/zone_XX.tmx`

## 2. Configurar zona no World

Edite `data/db/` ou adicione em `presets/` a configuração da zona:

```gdscript
# Em WorldService ou via dados carregados
{
  "id": 20,
  "name": "Dark Forest",
  "map": "res://data/maps/zones/zone_20.tmx",
  "min_level": 25,
  "max_level": 35,
  "spawns": [...],
  "farm_multiplier": 1.2
}
```

## 3. Adicionar tradução

```csv
Key,en,pt_BR
zone_name_20,Dark Forest,Floresta Sombria
```

## 4. Adicionar mobs e loot

Configure as tabelas de spawn e loot no Game Data Manager.

## 5. Testar

```bash
./scripts/test.sh all
```

Entre na zona e verifique spawns, colisão e loot.
