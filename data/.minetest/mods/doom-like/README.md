# Сборка Doom-like

Модпак для Mineclonia (Luanti). Внутри:

| Папка | Что это |
|---|---|
| `rifles/` | оружие (дробовик, гранаты и т.д.) |
| `light_works/` | свет от предметов в руке |
| `accuracy/` | библиотека, обязательная для `rifles` |
| `sharp_map/` | полноэкранная карта, миникарта и точки-метки |
| `sharp_inventory/` | тёмный инвентарь и автосортировка для Mineclonia |
| `ambience/` | звуки окружения, воды и пещер |
| `vein_miner/` | добыча всей жилы за раз (шифт + копание) |
| `x3_dmg/` | всплывающие цифры урона (это не x3 урон) |
| `doomlike/` | кастомный мод: скорость, выбор оружия, стартовый набор, сытость, больше монстров |

## Куда положить

Сборка должна лежать **целиком одной папкой** внутри `mods`:

- на ноуте: `<проект>/minetest/mods/doom-like`
- на сервере: `<проект>/server/minetest/mods/doom-like`

Из корня проекта:

```bash
# для ноута
mkdir -p minetest/mods
cp -r doom-like minetest/mods/

# для сервера
mkdir -p server/minetest/mods
cp -r doom-like server/minetest/mods/
```

Если папка уже скопирована и нужно обновить сборку, не создавай
`doom-like/doom-like`, а перезапиши содержимое:

```bash
cp -r doom-like/. minetest/mods/doom-like/
cp -r doom-like/. server/minetest/mods/doom-like/
```

В контейнере это будет `/data/mods/doom-like`. Папку `doom-like` не
переименовывай — внутри неё лежит `modpack.conf` с именем сборки.

## Как включить в мире

При создании мира в Luanti открой вкладку **«Моды» / Mods** и включи
сборку **Doom-like** (или все моды по отдельности).

Если мир уже создан, добавь в файл
`worlds/<имя_мира>/world.mt`:

```ini
load_mod_accuracy = true
load_mod_ambience = true
load_mod_light_works = true
load_mod_rifles = true
load_mod_sharp_inventory = true
load_mod_sharp_map = true
load_mod_vein_miner = true
load_mod_x3_dmg = true
load_mod_doomlike = true
```

- Sharp Map открывается командой `/map`, миникарта — `/minimap`.
- Vein Miner работает при копании с зажатым Shift.
- `x3_dmg` показывает цифры урона, но **не** увеличивает урон.
- Sharp Inventory добавляет тёмный интерфейс и автосортировку.

## Настройки кастомного мода

В `minetest.conf` (клиента или сервера):

```ini
doomlike_speed_multiplier = 1.6
doomlike_jump_multiplier = 1.4
doomlike_mob_cap_multiplier = 2.0
doomlike_shell_target = 50
doomlike_ammo_refill_interval = 10
```

- `doomlike_speed_multiplier` — множитель скорости ходьбы.
- `doomlike_jump_multiplier` — множитель высоты прыжка.
- `doomlike_mob_cap_multiplier` — во сколько раз поднять лимит монстров.
- `doomlike_shell_target` — сколько патронов держать у SPAS-12/Jackhammer (50).
- `doomlike_ammo_refill_interval` — как часто добивать патроны всех стволов, секунды (10).

Стартовый набор: **Glock 17** (по умолчанию у всех) + основное оружие
на выбор — **SPAS-12, Jackhammer, M79 (по умолчанию), RPG-7 или AK-47**.
Меню выбора открывается при первом входе, сменить можно командой `/weapon`.
Плюс 3 ручные гранаты, 5 золотых яблок, ведро воды, железная кирка,
полный сет кольчуги (сразу надет), «Кольчужная каска с фонариком»
с бесконечным Night Vision (лежит в инвентаре — надень сам) и стак
факелов в левой руке.

Патроны для текущего оружия и Glock пополняются автоматически.
Сытость всегда держится на 20 — голод не мешает. Гранаты и золотые
яблоки конечны. Все предметы набора помечены и не выпадают при смерти;
после респавна набор выдаётся заново с тем же основным оружием.
