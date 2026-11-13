// WatchMagic room sensor puck — round, 2.5" (63.5 mm) across, wall mounted.
//
// Two variants share one shell so both sensors look the same on the wall:
//   variant = "radar": HLK-LD2450 (24 GHz people tracking) + ESP32-C3 SuperMini
//   variant = "uwb"  : Ai-Thinker BU03 (DW3000) on a small carrier + ESP32-C3 SuperMini
//
// Two printed parts, no supports:
//   part = "base"  : back plate + side wall, screws to the wall, holds the ESP32.
//                    USB-C goes straight into the ESP32 through the hole at the bottom.
//   part = "cover" : front face (print face-down for a smooth front) with rails
//                    that hold the sensor board behind a thinned 1 mm "window".
//   part = "both"  : assembled preview (cover in place).
//
// Board sizes differ between listings (LD2450: 15 x 44 vs 24 x 30 mm) — measure
// yours with calipers and set the numbers below before printing.
//
// Render: openscad -D 'variant="radar"' -D 'part="base"' -o radar_base.stl watchmagic_puck.scad

variant = "radar";   // "radar" | "uwb"
part    = "both";    // "base" | "cover" | "both"

/* [Shell] */
D          = 63.5;   // outer diameter (2.5")
wall       = 2.0;    // side wall
back_t     = 2.5;    // back plate
front_t    = 2.0;    // front plate
window_t   = 1.0;    // front plate thickness over the sensor (thin = less RF loss)
base_h     = 20.0;   // base height incl. back plate; total depth = base_h + front_t
lip_h      = 4.0;    // cover lip that slides into the base
lip_w      = 1.6;
fit_clr    = 0.15;   // lip clearance per side (raise if too tight)
edge_chamf = 1.2;
$fn        = 160;

/* [ESP32-C3 SuperMini] */
esp_l      = 22.6;   // along USB axis
esp_w      = 18.1;
esp_t      = 1.0;    // PCB
esp_ledge  = 1.5;    // lifts the board off the back plate
usb_hole_w = 14.0;   // must pass your USB-C plug's overmold
usb_hole_h = 8.0;
usb_above_pcb = 1.6; // USB-C port centre above PCB top

/* [Sensor board] */
// radar: LD2450, antenna side facing the window, long side horizontal.
// uwb  : carrier board (e.g. perfboard) with the BU03 soldered on, ceramic antenna end up.
pcb_l   = variant == "radar" ? 44.0 : 30.0;  // horizontal
pcb_w   = variant == "radar" ? 15.0 : 20.0;  // vertical
pcb_t   = variant == "radar" ? 1.0  : 1.6;
gap     = variant == "radar" ? 6.0  : 3.0;   // window → board front face. 6 mm ≈ λ/2 at 24 GHz in air
rail_w  = 2.6;
grip    = 1.2;                                // how far the rail slot reaches over the board edge

/* [Wall screws] */
screw_d    = 3.5;    // #6 / M3.5 wood screw
screw_head = 7.0;
screw_x    = 20.0;
screw_y    = 9.0;

/* [Power] */
// Hardwired 5 V from a mains module in a wall box behind the puck: the two
// wires come through this hole in the back plate to the ESP32's 5V / GND pins.
// (USB-C through the bottom edge still works; tape over whichever is unused.)
rear_wire_d = 6.0;
rear_wire_y = 2.0;   // just above the ESP32

R  = D / 2;
Ri = R - wall;
z_port = back_t + esp_ledge + esp_t + usb_above_pcb;
esp_y0 = -sqrt(Ri*Ri - (esp_w/2)*(esp_w/2)) + 0.6;   // port end sits against the wall

module chamfered_disc(r, h, c_bottom = 0, c_top = 0) {
    hull() {
        translate([0, 0, c_bottom]) cylinder(r = r, h = h - c_bottom - c_top);
        cylinder(r = r - c_bottom, h = h);
        if (c_top > 0) cylinder(r = r - c_top, h = h);
    }
}

// ---------- base ----------
module base() {
    difference() {
        union() {
            difference() {
                chamfered_disc(R, base_h, c_bottom = 0.8);
                translate([0, 0, back_t]) cylinder(r = Ri, h = base_h);
            }
            // ESP32 pocket: ledge + low side walls (a dab of glue or tape holds it).
            translate([-esp_w/2 - 1.6, esp_y0, back_t])
                difference() {
                    cube([esp_w + 3.2, esp_l + 1.6, esp_ledge + esp_t + 1.2]);
                    translate([1.6 - 0.2, -1, esp_ledge]) cube([esp_w + 0.4, esp_l + 1.0 + 1, 10]);
                    translate([3.5, -1, -0.01]) cube([esp_w + 3.2 - 7, esp_l - 2, esp_ledge + 0.02]); // airflow under board
                }
        }
        // USB-C straight into the ESP32
        translate([-usb_hole_w/2, -R - 1, z_port - usb_hole_h/2]) cube([usb_hole_w, wall + 3, usb_hole_h]);
        // rear entry for hardwired 5 V
        translate([0, rear_wire_y, -1]) cylinder(d = rear_wire_d, h = back_t + 2);
        // countersunk wall screws
        for (sx = [-1, 1]) translate([sx * screw_x, screw_y, 0]) {
            translate([0, 0, -1]) cylinder(d = screw_d, h = back_t + 2);
            translate([0, 0, back_t - (screw_head - screw_d)/2 + 0.01]) cylinder(d1 = screw_d, d2 = screw_head, h = (screw_head - screw_d)/2);
        }
        // vents: top of the side wall (warm air out) and low on the sides
        for (a = [60, 75, 105, 120]) rotate([0, 0, a]) translate([Ri - 1, -0.8, back_t + 6]) cube([wall + 2, 1.6, 8]);
        for (a = [215, 325])  rotate([0, 0, a]) translate([Ri - 1, -0.8, back_t + 4]) cube([wall + 2, 1.6, 8]);
        // key slot (top) so the cover only fits one way up
        translate([-2.2, Ri - 0.5, base_h - lip_h - 0.5]) cube([4.4, 1.6, lip_h + 1]);
        // pry notch (bottom, beside the USB hole)
        translate([usb_hole_w/2 + 3, -R - 1, base_h - 1.0]) cube([6, wall + 2, 2]);
        // "UP" mark inside the back plate
        translate([0, 20, back_t - 0.6]) linear_extrude(1) text("UP", size = 4, halign = "center", valign = "center");
    }
}

// ---------- cover (own coordinates: front face on z = 0) ----------
module cover() {
    lip_ro = Ri - fit_clr;
    board_z = window_t + gap;               // board front face
    rail_top = board_z + pcb_t + 1.6;
    difference() {
        union() {
            chamfered_disc(R, front_t, c_bottom = edge_chamf);
            // lip
            translate([0, 0, front_t - 0.01]) difference() {
                cylinder(r = lip_ro, h = lip_h);
                translate([0, 0, -1]) cylinder(r = lip_ro - lip_w, h = lip_h + 2);
            }
            // key tab
            translate([-2.0, lip_ro - 0.3, front_t]) cube([4.0, 1.3, lip_h - 0.6]);
            // sensor rails along the long (horizontal) edges; board slides in from the side
            for (s = [-1, 1]) {
                y_edge = s * pcb_w / 2;
                translate([-pcb_l/2 - 1, s > 0 ? y_edge - grip : y_edge - rail_w + grip, front_t - 0.01])
                    difference() {
                        cube([pcb_l + 1, rail_w, rail_top - front_t]);
                        // slot for the board edge
                        translate([-1, s > 0 ? -0.01 : rail_w - grip - 0.3,
                                   board_z - front_t - 0.15])
                            cube([pcb_l + 3, grip + 0.31, pcb_t + 0.3]);
                    }
            }
            // end stop on the right
            translate([pcb_l/2, -pcb_w/2 - rail_w + grip, front_t - 0.01]) cube([1.6, pcb_w + 2*rail_w - 2*grip, rail_top - front_t]);
        }
        // thin window over the sensor (inside face only; the front stays flat)
        translate([-(pcb_l - 4)/2, -(pcb_w - 2*grip - 1)/2, window_t]) cube([pcb_l - 4, pcb_w - 2*grip - 1, front_t]);
    }
}

if (part == "base") base();
else if (part == "cover") cover();
else {
    base();
    color("lightgray", 0.6) translate([0, 0, base_h + front_t]) mirror([0, 0, 1]) cover();
}
