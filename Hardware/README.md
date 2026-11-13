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
  sits in a pocket at the bottom, and the USB-C cable plugs straight into it
  through the hole in the bottom edge.
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

## Placement (Meghna Room)

- **Radar:** in the middle of a wall, about 1.5–2 m high, facing straight into
  the room. Its ±60° view covers everything except small strips beside its own
  wall (within about 1.2 m of that wall, near the corners). Its range is 6 m;
  the room is 5.4 × 4.4 m.
- **UWB:** on a different wall, high up, with a clear line of sight across the room.
- Note where each one is (wall, distance from a corner, height) so it can be
  placed in the house model. The radar's facing direction is that wall's normal.

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
