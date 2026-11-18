# Light Works

**Version:** 1.0.1 (2026-11-15)

Hold a torch, a lantern or any other light-giving block and the world around you
lights up, at that item's own light level (a torch gives full light, 14). Main hand,
offhand and worn armor all count, and the brightest of them sets the light. Any item from
any mod with a light value counts, so the extra torches and lanterns of Ore Works work,
and so will glowing armor or tools added later. A few glowing items that are not blocks
light up too: lava bucket, blaze rod, glowstone dust and magma cream (setting
`glowing_items`, on by default).

## How it works

No hidden light blocks are placed. A torch lights a block face by raising the light
value stored in the air in front of it; Light Works writes those values directly, the
way the engine would spread them from your hand (one level less per step, around
corners, never through walls). The real light of every changed cell is saved first and
put back exactly when your light moves on, so nothing is left behind: nothing for water
to wash away, pistons to push or builders to bump into.

Everyone sees your light, and it counts as real light for the game (for example for
mob spawning).

## Made to feel seamless

- The light comes from one point: exactly where your hand is, not the middle of a block.
  Every lit face gets the level of its distance from that point (along open paths, as the
  engine spreads light), rounded to a whole level. So the light never jumps from block to
  block, there is no trail behind you, and crossing a block corner is nothing special.
- No face ever changes by more than one level in a server step.
- A five-part flicker guard keeps it calm:
  1. Nothing happens until you have moved a tenth of a node.
  2. A face changes level only when it is clearly past the boundary, not when it sits on it.
  3. A face that just changed does not change back the other way for a quarter second.
  4. At most one level per face per update, so lag and teleports never pop.
  5. When you stop, no face starts to get dimmer. Faces already dimming behind you
     finish; everything else holds until you move again. Your position is smoothed
     (bursty updates from your client are evened out), and jumping does not move the
     light up and down.
- The light follows every server step while you move, so it keeps each server's own pace.
  `max_rate` (15) is only a ceiling for servers with a very short step.
- Only map blocks with a face that changed are read and redrawn. Block contents are kept
  in memory between moves.
- Every change is written at once by default; `edge_tolerance` can let the faintest edge
  levels wait to save a little work.
- Nothing happens where it is already as bright as your light, or while you hold nothing
  that glows.

## Safety

- When a block is dug or placed next to your light, the engine relights the area from
  your light as if it were a real torch. Light Works puts the real light back around the
  change, repairs that map block with the engine's own light fix and paints your light
  again, all in the same server step: dug tunnels and caves you break into do not stay
  lit once you move on (fixed in 1.0.1).
- Other changes under the light (pistons, flowing water) are repaired with the same light
  fix once you have moved away.
- The list of lit map blocks is saved, so after a crash they are repaired at the next
  start before anything else.
- On a normal shutdown all light is put back.

## Commands

- `/light_works` shows how many lights and lit cells there are.
- `/light_works debug` reports once a second: how many moves the light made, how many
  map blocks were redrawn, how many changes are waiting and the slowest move.

## For other mods

- `light_works.register_light(item_name, level)`: an item gives this light (1-14) when
  held or worn, for items that cannot carry a `light_source` of their own. Items in the
  group `light_works_glow` (rating = level) count too.
- `light_works.register_source(fn)`: another place a player's light can come from (a
  backpack slot, a trinket, an enchantment). `fn(player)` returns an ItemStack, a list of
  ItemStacks or nil; the brightest item of all sources wins. A source that fails is logged
  once and skipped.
- `light_works.set_light(id, pos, level)` lights an area under a name of your choice
  (level 0 removes it). Meant for later items such as flares and dropped lanterns. These
  lights jump to a new place rather than glide.

## License

CC0-1.0. See LICENSE.txt.
