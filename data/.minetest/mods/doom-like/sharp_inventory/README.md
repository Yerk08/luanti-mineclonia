# Sharp Inventory

**Version:** 1.2.2 (2026-11-14)

A dark, sharp look and automatic sorting for **Mineclonia**, built on the
game's own inventory screens rather than replacing them. Inspired by the
i3 inventory mod; no i3 code or art is used.

## Features

- **Dark theme** with the mod's own original textures for panels,
  slots, buttons, creative tabs and the trash slot, drawn to match
  Mineclonia's vanilla look. Labels and text fields switch to light
  text. Resource packs that restyle Mineclonia's GUI don't affect these
  screens; to restyle them, replace the `sharp_inventory_*.png` files.
- **Tidier survival inventory.** Advancements, Help and Player settings
  sit in a column beside the player model, mirroring the armor column.
  The Recipe book sits next to Fill Craft Grid.
- **Auto-sort switches, each next to what it sorts.**
  - **Your inventory:** a switch in the survival inventory and on the
    creative inventory's Survival Inventory tab. When on, your inventory
    is sorted when a screen closes and every few seconds while you aren't
    using it. The hotbar is never touched.
  - **Each chest remembers its own setting**, stored in the chest and
    shared by everyone who opens it. A chest that is on is sorted as it
    opens (a double chest sorts as one 54-slot chest). Breaking the chest
    clears its setting. Changing it needs build rights there
    (protection).
  - **Shulker boxes and the ender chest:** each player has their own
    switch for these, since shulker boxes are picked up and moved and
    ender chest contents are personal. A shulker box that is on is sorted
    when you close it. Opening a box shows its switch with your own
    on/off state.
  - Furnaces, blast furnaces, smokers and kilns have no switch: nothing in
    them is ever sorted. Closing them sorts your inventory if your
    inventory switch is on, like any other screen.
  - Anything not set yet follows the inventory switch of whoever uses it,
    so turning your inventory switch on still sorts every unset chest you
    open. The icon shows on, off, or the neutral icon for "not set yet".
- **Top off button** on furnaces, smokers and blast furnaces, next to
  the input and fuel slots. It refills both with more of what's already
  in them from your main inventory (never the hotbar). Empty slots are
  never filled, and the output is always left for you to collect. It
  uses the furnace's own callbacks, so protection and comparators behave
  exactly as if you'd done it by hand.
- **Sort now buttons** work whether auto-sort is on or off:
  - **Your inventory:** in the survival inventory and the creative
    Survival Inventory tab (next to the inventory switch), and above the inventory
    rows on chests, furnaces, crafting stations and other screens that
    show them. The hotbar is never touched.
  - **The container:** beside the switch on chests, double chests, ender
    chests and shulker boxes. Furnace and station slots are never sorted.
- **Map button in creative.** With the Sharp Map mod installed, the
  creative Survival Inventory tab gets a Map button above the inventory switch, like
  the one Sharp Map adds to the survival inventory.
- **Sort order** follows Mineclonia's creative tabs: blocks, decoration,
  redstone, transport, food, tools, combat, mobs, brewing, materials,
  then miscellaneous. Within a tab, items sort by name, then least worn
  first. Identical items merge into full stacks.

## Requirements

Luanti 5.10 or newer and Mineclonia. Tested against Mineclonia
release 39338; the creative buttons (1.1.0) and the per-container switches
(1.2) were written against release 39603 with Luanti 5.18.0.
Sharp Map is optional (for the creative Map button).

## Settings

All settings are under *Settings → All settings → Mods → sharp_inventory*,
or in `minetest.conf`:

| Setting | Default | Meaning |
|---|---|---|
| `sharp_inventory.theme` | `true` | Dark theme on or off |
| `sharp_inventory.shade` | (empty) | Optional `#RRGGBB` tint for the theme textures |
| `sharp_inventory.text_color` | `#E0E0E0` | Label and field text color |
| `sharp_inventory.relayout` | `true` | Button column and survival inventory switch |
| `sharp_inventory.autosort_default` | `false` | Inventory switch for new players (unset containers follow it) |
| `sharp_inventory.autosort_interval` | `2` | Seconds between player inventory sorts |
| `sharp_inventory.update_stored_formspecs` | `true` | Update furnaces and shulker boxes already in the world |

## Notes

Furnace and shulker box screens are stored in the world. Ones this mod
has updated keep the dark look and inactive buttons if the mod is later
removed. They still work normally. Upgrading from 1.1.0 changes nothing
for anyone: every chest, furnace and switch starts out unset and follows
your existing auto-sort choice.

## License

CC0-1.0 for code and every texture in `textures/`, all drawn for this
mod. See
`LICENSE.txt`.
