# WatchMagic room sensors

Two pucks per room. They let WatchMagic know **where you are** instead of
assuming the fixed "seat", so you can point from anywhere in the room.

| Puck | Inside | Gives |
|---|---|---|
| Radar | HLK-LD2450 + ESP32-S3 dev board | x/y of up to 3 people (body), via ESPHome → Home Assistant |
| UWB | Ai-Thinker BU03 (DW3000) + ESP32-S3 dev board | distance from the puck to the watch (wrist) |

How they combine: the radar says where the people are. The UWB distance picks
the one wearing the watch (distance ± arm length), places the wrist next to
that body, and holds your position when the radar loses you because you're standing still.

## Enclosure

`enclosure/watchmagic_puck.scad`: a round puck, **82.6 mm (3.25") across**,
22 mm deep (USB-C / hardwired 5 V) or 32 mm deep (built-in 230 V supply), the same
shell for both pucks. It's sized around the ESP32-S3 dev board (WROOM module,
two USB-C; PCB 28 × 57 mm plus a 5.7 mm antenna overhang). The board lies flat,
USB end down, with the antenna at the top clear of the sensor and the mains
compartment. Open the file in OpenSCAD with `part = "both"` to see the boards
in place. The console prints fit checks. Ready-made STLs are in `enclosure/stl/`:

| File | What |
|---|---|
| `base.stl` | base for USB-C or hardwired 5 V (22 mm deep puck) |
| `base_mains.stl` + `mains_lid.stl` | base with a built-in 230 V supply (32 mm deep puck) |
| `radar_cover.stl` / `uwb_cover.stl` | front cover (fits either base) |

- **Base**: screws to the wall with two countersunk #6 / M3.5 screws. The ESP32
  lies in a cradle on the left half, hot-glued in. **No pin headers**: solder the
  wires to the pads. If your board has headers soldered pointing down, raise
  `esp_ledge` to about 9 and `base_h` by the same. Power comes from USB-C (the
  hole in the bottom edge lines up with the right-hand port), hardwired 5 V
  through the 6 mm rear hole, or the built-in supply (see Power).
- **Cover**: the flat front. It press-fits into the base, a key tab at the top
  makes it fit one way only, and there's a pry notch at the bottom. The sensor
  board slides into rails on its inside, behind a window thinned to 1 mm.

**Before printing:** board sizes differ between listings, so measure your
boards with calipers and set `pcb_l`, `pcb_w`, `pcb_t` (sensor board) and
`esp_l`, `esp_w` (ESP32) in the .scad file. Then re-render, for example:

    openscad -D 'variant="radar"' -D 'part="cover"' -o stl/radar_cover.stl watchmagic_puck.scad

**Printing (Bambu):**
- PLA or PETG, 0.2 mm layers, 3 walls, 15% infill. No supports needed.
- Print the base back-down and the cover **face-down** so the front is smooth.
- **Radar cover:** don't use metallic, silk-with-metal, carbon-fibre or
  "conductive" filament, and don't paint the front with metallic paint. Any of
  these blocks 24 GHz. Plain matte colours are fine.
- If the cover is too tight or too loose, change `fit_clr` (0.15 mm per side).

**Radar notes:** the LD2450 goes antenna side to the window, long side
horizontal, with a 6 mm air gap (`gap`, about half a wavelength at 24 GHz).
Confirm "up" and the x/y sign from the LD2450 manual once it's running: walk
left and right and watch Target-1 X in Home Assistant.

## Placement (Meghna Room, 5.4 × 4.4 m)

There are two pucks, and each has its own ESP32 inside, so there's nothing else to place.

| Puck | Where | Height | Facing |
|---|---|---|---|
| Radar | Middle of one of the two **short (4.4 m) walls**: the one without the window, looking towards the bed / where you usually are | 1.2–1.5 m (below the fan's beam) | Straight into the room, along the 5.4 m length |
| UWB | Middle of a **long wall** (Tubelight 1's or Tubelight 2's), not right next to the tubelight fitting | 2.0–2.2 m | Into the room; it only needs a clear line of sight |

- The radar sees ±60°. On a short wall it covers the whole room except small
  strips beside its own wall (within about 1.2 m of it, near the corners). The 5.4 m
  length is inside its 6 m range.
- Don't point the radar at the window or curtains (they move, and so does
  whatever is outside), or at the AC. **Check with the ceiling fan on:** moving
  blades can show up as a "person". Mounting lower keeps the fan out of the beam,
  and a zone filter in Home Assistant can hide whatever is left.
- UWB is blocked by bodies and furniture. Mounting it high over the bed / sofa
  keeps the wrist in view.
- Note each one's position (which wall, distance from a corner, height) so it
  can go into the house model.

## Power

Each puck needs **5 V, under 0.5 A** (LD2450 about 0.1 A, ESP32 up to about 0.35 A
on Wi-Fi peaks, DW3000 about 0.1 A).

**A. USB-C (simplest):** any 5 V phone charger and a cable into the hole in the
bottom edge.

**C. Built into the puck (`base_mains.stl`, 32 mm deep):** the HLK-PM01 stands
in a closed compartment on the right half of the base, beside the ESP32, with a
wiring bay above it. The sensor board is on the cover in front.
1. Run the mains cable (L + N, already fused in the wall box) out of the wall
   and through the 7 mm hole into the compartment. No other opening leads there.
2. Turn the PM01 pins-up in the compartment, AC pins at the top beside the
   cable bay. Solder L and N to the AC pins and cover each joint with heat-shrink.
   Hot glue holds the module down.
3. Solder 5 V wires to +Vo / −Vo and lead them out through the notch in the
   compartment wall facing the ESP32 (low end) to the board's 5Vin / GND.
4. Close the compartment with `mains_lid.stl` (hot glue around the edge), then
   fit the ESP32 (hot glue), wire the sensor, and press the cover on.
- Print the base and lid in **PETG or ASA, not PLA**. PLA softens at about 55 °C,
  and the module and hot glue run warm.
- The fuse stays in the wall box, not in the puck.
- Mains inside a printed enclosure is your call. Switch the breaker off while
  working, and have an electrician check it if unsure.

**B. Hardwired from 230 V (no visible cable):**
- Fit a small certified mains-to-5 V module, e.g. Hi-Link **HLK-PM01** (230 V
  AC → 5 V, 0.6 A, 34 × 20 × 15 mm), in a **flush electrical back box behind
  the puck**, or in the nearest switchboard box, with a short 5 V run to the puck.
- Mains side: L and N from a switched or always-on circuit, with a **0.5 A
  slow-blow fuse on L**. Use proper terminal blocks or ferrules, and keep all
  230 V parts inside the electrical box.
- 5 V side: two-core wire through the wall and into the puck through the
  **rear hole** (6 mm, centre of the back plate), to the ESP32's **5V** and
  **GND** pins. On the radar puck, the LD2450's 5V comes from the same 5V pin.
- Turn the breaker off while wiring, and use an electrician if you're unsure,
  per local code. To put the module inside the puck instead, use option C
  (its closed compartment); never loose in the 22 mm puck.

## Wiring

**Radar puck** (see `esphome/watchmagic-radar.yaml`):

| LD2450 | ESP32-S3 board |
|---|---|
| 5V | 5Vin |
| GND | GND |
| TX | GPIO18 |
| RX | GPIO17 |

**UWB puck:** the BU03 is a 23 × 13 mm SMD module (DW3000 + ceramic antenna,
no microcontroller), so it talks SPI to the ESP32. Solder it to a small carrier
(perfboard, default 30 × 20 mm in the .scad) with the **antenna end clear of
copper and wires**. Take the pin numbers from Ai-Thinker's BU03 specification
(V1.1.0, "Pin definition").

| BU03 signal | ESP32-S3 board |
|---|---|
| VCC 3.3 V | 3V3 |
| GND | GND |
| SPI CLK | GPIO12 |
| SPI MOSI | GPIO11 |
| SPI MISO | GPIO13 |
| SPI CS | GPIO10 |
| IRQ | GPIO4 |
| RSTn | GPIO5 |

Avoid GPIO0, 3, 45 and 46 (boot strapping pins), GPIO19/20 (USB), GPIO43/44
(serial console), and GPIO35–37 on boards with octal PSRAM (e.g. N16R8).

## Status / risks

- **UWB with Apple Watch is unproven with the BU03.** The watch only measures
  distance to accessories that implement Apple's Nearby Interaction accessory
  protocol: Bluetooth on the ESP32 for setup, and a UWB session on the DW3000
  configured from what the watch sends. Qorvo ships that firmware only for its
  own boards (DWM3001CDK). For the BU03 it has to be written for ESP32 +
  DW3000, which is the biggest piece of work here. First milestone: the ESP32
  reads the DW3000 device ID over SPI. Second: the watch reports a distance.
- The radar puck works without the UWB one: with one person in the room,
  pointing from anywhere should already work.
- Apple documents distance-only UWB on Apple Watch (no direction), which is
  all this design needs.
