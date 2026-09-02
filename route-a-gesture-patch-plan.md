# River + flume — Touchpad Gesture → Virtual Key (Route B, per R2)

**Decision.** Adopt Reviewer 2's more-general alternative over the flume-only seat binding:
the compositor **synthesizes a key into its own seat** when a 3/4-finger swipe resolves to a
direction. It reuses river's **entire existing keybinding stack**, so the swipes become bindable
by **any** WM / riverctl / tool — not just flume.

**Zero-permission.** Unchanged: the compositor owns the devices (logind/libseat) and interrupts
the gesture in-process; it never opens `/dev/input` by file permission and never writes
`/dev/uinput`.

## Mechanism

- Swipes already reach **`river/river/Seat.zig::processEvents`** (`pointer_swipe_begin/update/end`,
  `Seat.zig:383-385`), forwarded today to the focused surface via `pg.sendSwipe*`.
- river **consumes at `swipe_begin` by finger count** (niri does exactly this) — direction is only
  knowable at `swipe_end`, so you cannot suppress an already-emitted begin
  (R1/R2 BLOCKER, both).
- On `swipe_end` (with `cancelled` handled), river synthesizes a **key press + release** of a
  mapped keysym through a virtual keyboard into its own `wlr_seat`.
- The synthesized key flows through river's own `matchXkbBinding`:
  - bound ⇒ eaten by river and dispatched to the WM (flume) as a normal keybinding →
    `KeybindingAction::Spawn`, etc.;
  - unbound ⇒ forwarded to the focused client (same as any key — but only if the user left the
    reserved keysym unbound; see mapping).
- Injection path: river creates a `zwlr_virtual_keyboard_v1` through the **already-registered**
  `zwlr_virtual_keyboard_manager_v1` (`river-ed/build.zig:135`), attaches it as a seat keyboard,
  and feeds `key()` events with the mapped keycode. Standard, permission-free.

## Changes

### river (compositor)

1. **Consume at begin by count.** In `Seat.zig::processEvents`, for the configured finger counts,
   take over the gesture at `pointer_swipe_begin` (do NOT call `pg.sendSwipeBegin`); track the
   active (seat, fingers, accumulated dx/dy).
2. **Resolve direction at end.** On `pointer_swipe_end`, if `!cancelled` and accumulated delta
   exceeds a small threshold, map `(fingers, direction)` → keysym; inject press+release. On
   `cancelled=true`: fire nothing (and, for the taken-over count, do not forward — the app never
   saw a begin, so no end is owed).
3. **Mapping table (minimal config).** River needs a `(fingers,direction)→keysym` map + an enable
   flag in **river's own config/control** (the one honest cost R2 glossed: river has no config
   system; keybindings live WM-side). Keep it a compact table, e.g.:
   - 3f: up=F13 down=F14 left=F15 right=F16; 4f: up=F17 down=F18 left=F19 right=F20.
   Users then bind those keysyms in flume (or riverctl / any WM).
4. **Virtual keyboard setup** in `InputManager`/`Seat`: create the internal virtual keyboard once
   per seat; send per-gesture key events.
5. **Natural-scroll sense** honored when resolving direction (per-device setting as niri).

### flume (WM client)

1. **No new protocol, no new config key, no new Dispatch impl** (R2): the user just adds a normal
   keybinding whose keysym is one of the reserved gesture keysyms:
   ```toml
   [[keybindings]]
   keysyms = ["F13"]                 # 3-finger swipe up
   action = { spawn = ["/path/to/script.sh"] }
   ```
   Existing `KeybindingAction::Spawn` parse + `spawn_detached` are reused as-is.

## Edge cases / keeps (both reviewers)

- **Sub-threshold / unbound reserved keysym:** a taken-over finger count is **consumed**, never
  forwarded — so apps lose 3/4-finger gestures for configured counts. Mitigation: the enable flag
  and the reserved table are the opt-in; if a reserved keysym is unbound, the best we can do is
  not inject (but the gesture is still consumed for that count). Document this trade-off.
- **`cancelled=true`:** matched count — do not inject, do not forward.
- **Multi-seat / multiple touchpads:** one accumulator per seat (each `Seat` runs its own
  `processEvents`).
- **`zwlr_virtual_keyboard` already generated** ⇒ both sides regenerate from existing files; no new
  protocol XML. (The reserved-table option keeps flume from touching generated bindings at all.)
- **Security:** only the compositor decides the injected key; a tool binding it has the same
  trust as binding any key. No injection of attacker bytes.

## Success criteria

- 3/4-finger swipe (up/down/left/right, natural-scroll-aware) synthesizes the mapped key, which
  fires flume's bound `Spawn` (or any WM's binding on that keysym).
- Unmatched finger counts / disabled feature forward to the focused app exactly as today.
- No `input` or `seat` group requirement.

## Open question (small)

- Direction table: hardcode in river vs expose via river config/control once. **Lazy default:**
  hardcode the reserved table now; add a river control only if remapping is actually requested.
  (`ponytail:` reserved keysyms + flag, per-gesture mapping if users need to customize.)
