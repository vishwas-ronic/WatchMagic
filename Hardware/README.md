# WatchMagic room sensors

Two pucks per room. They let WatchMagic know **where you are** instead of
assuming the fixed "seat", so you can point from anywhere in the room.

| Puck | Inside | Gives |
|---|---|---|
| Radar | HLK-LD2450 + ESP32-C3 SuperMini | x/y of up to 3 people (body), via ESPHome → Home Assistant |
| UWB | Ai-Thinker BU03 (DW3000) + ESP32-C3 SuperMini | distance from the puck to the watch (wrist) |

How they combine: the radar says where the people are. The UWB distance picks
the one wearing the watch (distance ± arm length), places the wrist next to
that body, and holds your position when the radar loses you because you're standing still.

## Enclosure

`enclosure/watchmagic_puck.scad`: a round puck, **63.5 mm (2.5") across, 22 mm
deep**, the same shell for both pucks. Ready-made STLs are in `enclosure/stl/`
(`radar_base`, `radar_cover`, `uwb_base`, `uwb_cover`).

- **Base**: screws to the wall with two countersunk #6 / M3.5 screws. The ESP32
  sits in a pocket at the bottom. Power comes either from USB-C, plugged straight
  into it through the hole in the bottom edge, or from hardwired 5 V through the
  6 mm rear hole (see Power).
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
- **Never put the mains module inside the printed puck.** PLA/PETG isn't
  flame-rated and the puck has no room for safe clearances. Turn the breaker off
  while wiring, and use an electrician if you're unsure, per local code.

## Wiring

**Radar puck** (see `esphome/watchmagic-radar.yaml`):

| LD2450 | ESP32-C3 SuperMini |
|---|---|
| 5V | 5V |
| GND | GND |
| TX | GPIO4 |
| RX | GPIO5 |

**UWB puck:** the BU03 is a 23 × 13 mm SMD module (DW3000 + ceramic antenna,
no microcontroller), so it talks SPI to the ESP32. Solder it to a small carrier
(perfboard, default 30 × 20 mm in the .scad) with the **antenna end clear of
copper, wires and the ESP32**. Take the pin numbers from Ai-Thinker's BU03
specification (V1.1.0, "Pin definition").

| BU03 signal | ESP32-C3 SuperMini |
|---|---|
| VCC 3.3 V | 3V3 |
| GND | GND |
| SPI CLK | GPIO6 |
| SPI MOSI | GPIO7 |
| SPI MISO | GPIO10 |
| SPI CS | GPIO1 |
| IRQ | GPIO3 |
| RSTn | GPIO0 |

Avoid GPIO2, 8 and 9 (boot strapping pins) and GPIO20/21 (serial console).

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
