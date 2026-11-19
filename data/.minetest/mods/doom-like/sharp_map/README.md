# Sharp Map

**Version:** 1.4.4 (2026-11-10, test build)

A full-screen map with a waypoint sidebar, and a minimap drawn from the
same map, for **Mineclonia**. Styled to match **Sharp Inventory**.

## Features

- **Full map (`/map`).** Opens centered on you (an arrow showing which way you face) and
  follows you. It moves only when you select a waypoint (it centers on it,
  so you can see where it leads), use the arrows on the map's four edges, or
  click a spot on the map to recenter there. **Back to me** returns to you.
  Five zoom levels, with the scale shown between the - and + buttons.
- **Cave layers.** Caves are mapped as you walk through them, in layers
  16 nodes tall. Go underground (and in the Nether, always) and the minimap
  switches to the caves around you by itself: your own layer first, then
  the layers just below and above, so a tunnel that climbs or drops stays
  on the map, darker where it leads down and lighter where it leads up,
  with the surface faintly underneath. Tunnels are drawn with their walls,
  so you can see their shape. On the map screen, the buttons in the
  top-left corner switch between **Auto** (surface above ground, caves
  below), the **Surface**, and any cave layer with the up and down arrows;
  a cave layer shows 32 nodes of caves over a darkened surface.
  The small **A** square next to the arrows goes back to automatic (the
  layer you are in). The arrows stop at the bottom and top of the
  dimension you are looking at (the Overworld, the Nether or the End).
  Only places you could stand in and walk to are mapped: caves behind
  walls, below the floor or past a long drop stay hidden until someone gets
  there, so the map never gives away what you have not found. Houses,
  forests, oceans and ravines open to the sky stay on the surface view.
- **Caves fill out by themselves.** Once part of a cave is on the map,
  the mod keeps following its passages in the background, a little at a
  time, while you are nearby: tunnels you have only peeked into fill out
  beyond where you walked. It only grows from caves already on the map and
  only into places you could walk to from them, so it never shows a cave
  nobody has opened a way into. `/map caves` shows how it is getting on.
  It can be turned off (`sharp_map.cave_background`).
- **Hover** anywhere on the map to see its biome, coordinates and any
  waypoint there. Biome names work on worlds made with one of Luanti's
  built-in map generators and on worlds made with Mineclonia's own level
  generator (`singlenode`). The name is the one the game gives that spot,
  asked for at the spot's own ground (seabed under water), which the map
  records as it scans. Ground mapped by an older version fills in the next
  time you are near it (about a minute).
- **Relief, like Luanti's own minimap.** Hills and valleys are shaded as
  if lit from the north-west, on the minimap and on the map screen alike,
  worked out from each spot's real height and all eight of its neighbours,
  so ridges and slopes show in fine detail and it is the same across chunk
  edges. Water gets darker the deeper it is, so sea floors, lake beds and
  river channels show their shape. Ground mapped by
  an older version keeps its old look until you are near it again.
- **Minimap from the map.** A square minimap in the top-right corner with a
  slim frame on all four sides (dark with Sharp Inventory's theme,
  Mineclonia gray without), showing the same saved map as the map screen,
  with your waypoint icons. It's fully drawn the moment you rejoin. You're
  an arrow in the middle that turns with you as smoothly as Luanti's own
  (your game turns it every frame; the server does nothing). Every node is
  drawn a whole number of screen pixels wide, so the map stays sharp. The
  wide view blends each 2x2 patch of ground instead of skipping half of it.
  Switch between normal, wide and off with the Minimap selector on the map
  screen or `/minimap normal|wide|off`; your choice is remembered. (V can't
  control it: mods are never told when V is pressed. Prefer Luanti's own
  minimap? Set `sharp_map.minimap_source` to `engine`.)
- **Fits every screen.** The minimap is sized from each player's own screen
  (about 25% of the shorter side, like Luanti's minimap) and follows
  their HUD scaling, so it looks the same on a laptop, a 1080p monitor, a
  4K screen or a phone, and it adjusts when the window is resized. The map
  screen fills the window: wide screens get a wider map, short screens a
  shorter waypoint list.
- **Categories.** Sort waypoints into your own categories with **+ Category**
  and the category picker, and give each category its own color and icon
  (the list shows every category and waypoint with its icon); fold a category with a double click; move
  waypoints and categories with the arrows beside the list. Deleting a
  category keeps its waypoints (they move to General). Your pinned waypoint
  is always listed first.
- **Waypoint sidebar:** add a waypoint where you stand, name it, pick one of
  eight colors and one of 49 icons (markers, tools, blocks and places,
  nature, animals, monsters and villagers) from a scrollable picker,
  teleport, delete. Waypoints show their icon on the map, on the minimap and
  on screen, only in the dimension they were made in.
- **Labels that stay out of the way.** On screen, each waypoint's name and
  distance only appear when they're useful: when you're within 100 nodes,
  when you look toward it, or when it's **pinned** (one at a time, for the
  place you're heading). Far-off waypoints show just their icon. Each
  waypoint can also be set to **Auto**, **Always**, **Icon only** or
  **Hidden** with the button in the sidebar.
- **Death point:** a red skull where you last died.
- **Map button** in the survival inventory, next to the sort buttons, when
  Sharp Inventory is installed. Without this mod, Sharp Inventory is
  unchanged; without Sharp Inventory, use `/map`.

## Old maps get the new look by themselves

After an update that changes how maps are drawn, every map you already
explored is redrawn in the background (when only the look of the pictures
changed, they are simply drawn again from the saved map), a little at a time, nearest to you
first, even where nobody goes. It pauses whenever the server is busy and
carries on after a restart. Each finished map picture is saved in the world
folder, so opening the map afterwards is quick.

- `/map redraw` (or `/map redraw near`): redraw the maps around you first.
- `/map redraw status`: how far it has got.
- `/map redraw all`: redraw every saved map again (server privilege).
- `/map redraw stop`: stop it (server privilege).

## How the map is made, and why it stays light

Luanti's minimap is drawn by your client, and mods can't read it, so the
map is built from the world itself, a little at a time: one 16×16 patch of
ground near each player every quarter second, nearest first. A patch is only
looked at again when something in it changes. Finished map tiles are saved
in the world folder (`<world>/sharp_map/`) and only sent to a player when
they need them.

The minimap is built from small map pieces that are sent once each; moving
only slides them along. The minimap changes all at once: when you join,
switch between caves and the surface, or move to another cave layer, the
old picture stays up until the whole new one is ready, then it swaps in a
single step. The work behind it is spread over many server steps (3 ms at
most each, pictures sent at most four per step), so the game never stalls.
Changes right around you show within a second; changes farther out (such
as caves mapped in the background) are gathered and shown together every
few seconds. Minimap pictures are kept between sessions, so the minimap
appears quickly when you join. Underground, the layers just above and
below you are drawn ahead of time. The view switches between caves and
the surface only when two checks half a second apart agree, so walking
about in a cave mouth does not flip it back and forth. Changed map tiles
are saved one per step, never all at once. The pieces along the minimap's edges are trimmed to
fit inside the frame, which makes a few tiny images per node of new ground
you walk (Luanti keeps every image until you leave the game; walking over
ground you've already seen reuses them).

The surface map shows the surface only: underground it keeps what it
already knows instead of drawing cave ceilings. Caves go into their own
layers. While you're underground, after you move a few nodes (or something nearby
changes), at most once a second, the mod spreads out from your feet
through the places you could walk to, up to 20 nodes to each side and 12
up and down, and maps them. Like the rest of the map it does this a
little at a time: 3 milliseconds per server step at most, reading the
world one 16x16x16 block at a time and only the blocks the cave actually
reaches, pausing whenever the server is busy, and one player's cave after
another. Standing still costs nothing. Background cave mapping follows
the same rules: where a mapping stopped at its edge with the way still
open, it notes the spot, and later carries on from there with the same
walking rules, one mapping of the same size at a time, at most every half
second, only within 64 nodes of a player, never while a player's own
mapping is waiting, and under the same 3 milliseconds per step. Each spot
is used once per session (again if the world there changes), so it always
comes to rest; spots not used yet are kept in
`<world>/sharp_map/caves/frontier.txt`. Each layer is saved and drawn like
the surface. Colors come from Mineclonia's own map colors, so grass
and leaves match each biome.

## Requirements

Luanti 5.10 or newer and Mineclonia (it uses `mcl_maps` for colors and map
art). Tested setup: Luanti 5.18.0, Mineclonia release 39603. Sharp
Inventory is optional.

## Settings

*Settings → All settings → Mods → sharp_map*, or in `minetest.conf`:

| Setting | Default | Meaning |
|---|---|---|
| `sharp_map.minimap` | `true` | Minimap, with each player's mode remembered |
| `sharp_map.minimap_source` | `map` | `map` (drawn from the saved map) or `engine` (Luanti's) |
| `sharp_map.minimap_on_join` | `true` | Minimap on for players who haven't chosen |
| `sharp_map.minimap_size` | `128` | Luanti minimap: normal width in nodes |
| `sharp_map.minimap_wide_size` | `256` | Luanti minimap: wide width in nodes |
| `sharp_map.minimap_screen_percent` | `25` | Map minimap size, % of the screen's shorter side |
| `sharp_map.minimap_update` | `0.1` | Map minimap update interval in seconds |
| `sharp_map.player_arrow` | `true` | Player shown as a turning arrow (off: a figure) |
| `sharp_map.arrow_reverse` | `false` | Turn the minimap arrow the other way round |
| `sharp_map.draw_budget` | `6` | Milliseconds per server step for drawing map pictures |
| `sharp_map.minimap_budget` | `3` | Milliseconds per server step for drawing minimap pieces |
| `sharp_map.debug_slow` | `false` | Log any single piece of Sharp Map's work slower than the threshold |
| `sharp_map.debug_slow_ms` | `20` | Threshold for that log, in milliseconds |
| `sharp_map.redraw_budget` | `3` | Milliseconds per server step for background redrawing |
| `sharp_map.redraw_on_update` | `true` | Redraw old maps by themselves after an update |
| `sharp_map.caves` | `true` | Cave layers |
| `sharp_map.cave_radius` | `20` | Cave mapping radius around an underground player, in nodes |
| `sharp_map.cave_interval` | `1` | Fewest seconds between cave mappings for one player |
| `sharp_map.cave_budget` | `3` | Milliseconds per server step for mapping caves |
| `sharp_map.cave_background` | `true` | Keep mapping caves in the background from mapped caves |
| `sharp_map.cave_background_range` | `64` | Background cave mapping only this many nodes around players |
| `sharp_map.cave_background_interval` | `0.5` | Fewest seconds between background cave mappings |
| `sharp_map.debug` | `false` | Log every map screen click to debug.txt |
| `sharp_map.max_waypoints` | `50` | Waypoints per player |
| `sharp_map.label_distance` | `100` | Waypoint names within this many nodes (Auto) |
| `sharp_map.look_angle` | `6` | Show a waypoint's name when the crosshair is this close, in degrees (0 = off) |
| `sharp_map.death_waypoint` | `true` | Death point waypoint |
| `sharp_map.teleport` | `priv` | Who may teleport: `priv`, `all` or `off` |
| `sharp_map.scan_interval` | `0.25` | Seconds between map scans |
| `sharp_map.scan_radius` | `8` | Map fill radius in 16-node chunks |

## Known limits

- **V can't control the map-drawn minimap.** Mods are never told when V is
  pressed; use the map screen's Minimap selector or `/minimap`. With
  `sharp_map.minimap_source = engine` you get Luanti's own minimap and V back.
- **Cave layers need a way in.** A cave is mapped only where a
  player could stand: two open nodes over something to stand on (or water
  or a ladder), reached by walking, jumping one node, dropping up to three,
  swimming or climbing, from where a player was (background mapping
  follows the same rules from caves already mapped). Crawl spaces one node
  high, long drops and anything behind lava stay unmapped until someone
  gets there another way. Background mapping works only near players and
  uses each spot once per session, so a cave can stay partly mapped until
  you come back.
  Where one layer holds a cave above another, the higher one is shown.
- **Moving between layers** makes new minimap pictures, which your game
  keeps until you leave (like the edge pieces above); the view changes only
  two nodes past a layer's edge, so a step on the edge does not swap it
  back and forth.
- **No map button under the minimap.** HUD elements can't be clicked in
  Luanti; open the map with `/map` or Sharp Inventory's map button.
- **The map shows the surface.** Underground, even deep in a cave system,
  it keeps what it already knows: only ground under open sky is mapped.

- **Biome names on hover** on Mineclonia's own level generator (`singlenode`)
  are read through Mineclonia's `mcl_biome_dispatch`, which only knows ground
  that has been generated; elsewhere you see coordinates only. A biome added
  by another mod shows its id split into words.
- **Biome names on ground mapped by an older version** are asked for at your
  own height until you have been near that ground again, so open sea there
  may be named as a land biome for a while.
- **Client memory:** Luanti keeps every image it receives until you leave the
  game, and mods can't free them. The minimap's edge trimming makes a few tiny
  images per node of new ground you walk (about 5 MB per 1,000 nodes), and
  each click on the map screen builds one map image.
- **Mouse hover** tooltips need a mouse; on touch screens, tap a spot to
  recenter instead.

## Credits

Made for Mineclonia and Luanti, with thanks to their developers. Designed,
tested and maintained by Legacy_Tall_Grass. The code and the textures were made
with AI assistance (Claude, Anthropic); the textures are original pixel art
generated by script, and no Mineclonia art is included. Map colors come from
Mineclonia's own `mcl_maps/colors.json`, read from the installed game at
runtime, not copied.

## License

CC0-1.0 for code and every texture in `textures/` (icons, minimap frames,
background, player figure and arrows), all drawn for this mod. See
`LICENSE.txt`.
