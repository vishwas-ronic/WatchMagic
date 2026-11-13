// WatchMagic room sensor puck: round, 3.25" (82.6 mm) across, wall mounted.
//
// Built around the ESP32-S3 dev board (WROOM module, two USB-C):
// PCB 28 x 57 mm, plus the module antenna sticking out 5.7 mm at the far end.
//
// One shell, two sensors, so both pucks look the same:
//   variant = "radar": HLK-LD2450 (24 GHz people tracking) on the cover
//   variant = "uwb"  : Ai-Thinker BU03 (DW3000) on a small carrier on the cover
//
// mains = true: built-in 230 V -> 5 V supply (Hi-Link HLK-PM01, 34 x 20 x 15 mm)
// in its own closed compartment beside the ESP32. The mains cable comes through
// the back into that compartment only; 5 V leaves through a notch to the
// board's 5Vin. Print the base and lid in PETG or ASA, not PLA. The fuse stays
// in the wall box.
// mains = false: power over USB-C (hole in the bottom edge) or hardwired 5 V
// through the rear hole.
//
// Parts (no supports):
//   part = "base"  : back plate + wall, screws to the wall, holds the ESP32 (+ PM01)
//   part = "cover" : flat front (print face-down) with rails holding the sensor
//                    board behind a window thinned to 1 mm
//   part = "lid"   : closes the mains compartment (mains = true)
//   part = "both"  : assembled preview with ghost boards
//
// Sizes come from listings / the seller's drawing. Measure your boards and set
// the numbers below before printing. Boards are hot-glued in place.
//
// Render: openscad -D 'mains=true' -D 'part="base"' -o base_mains.stl watchmagic_puck.scad

variant = "radar";   // "radar" | "uwb"
part    = "both";    // "base" | "cover" | "lid" | "both"
mains   = false;

/* [Shell] */
D          = 82.55;  // 3.25"
wall       = 2.0;
back_t     = 2.5;
front_t    = 2.0;
window_t   = 1.0;    // front thickness over the sensor (thin = less RF loss)
base_h     = mains ? 30.0 : 20.0;   // total depth = base_h + front_t (32 / 22 mm)
lip_h      = 4.0;
lip_w      = 1.6;
fit_clr    = 0.15;   // cover lip clearance per side
edge_chamf = 1.2;
$fn        = 180;

/* [ESP32-S3 dev board] */
esp_w      = 28.0;   // PCB width
esp_l      = 57.0;   // PCB length (USB end to module end)
esp_t      = 1.6;
ant_l      = 5.74;   // module antenna beyond the PCB
ant_w      = 18.0;
esp_cx     = -8.0;   // PCB centre in the puck
esp_cy     = -2.9;
esp_ledge  = 1.5;    // no pin headers assumed (wires soldered to the pads).
                     // Headers pointing down? raise to ~9 and base_h by the same.
usb_dx     = 5.6;    // the two USB-C ports sit about +/- this from the PCB centre
usb_use    = 1;      // +1 right port, -1 left port gets the hole
usb_hole_w = 14.0;   // must pass your USB-C plug's overmold
usb_hole_h = 8.0;

/* [Sensor board on the cover] */
// radar: LD2450, antenna side to the window, long side horizontal.
// uwb  : carrier (perfboard) with the BU03 soldered on, ceramic antenna end up.
pcb_l   = variant == "radar" ? 44.0 : 30.0;
pcb_w   = variant == "radar" ? 15.0 : 20.0;
pcb_t   = variant == "radar" ? 1.0  : 1.6;
gap     = variant == "radar" ? 6.0  : 3.0;   // window -> board. 6 mm ~ half wavelength at 24 GHz
rail_w  = 2.6;
grip    = 1.2;

/* [Built-in mains supply] */
pm_l     = 34.0;     // HLK-PM01, stands with its long side vertical
pm_w     = 20.0;
pm_h     = 15.0;
pm_clr   = 0.3;
cw       = 1.6;      // compartment wall
cx0      = 7.0;      // compartment outer box
cx1      = cx0 + pm_w + 2*pm_clr + 2*cw;
cy0      = -(pm_l + 2*pm_clr)/2 - cw;
cy1      =  (pm_l + 2*pm_clr)/2 + cw;
bay_x1   = 24.0;     // wiring bay above the module (mains cable enters here)
bay_y1   = 28.0;
cwall_top = back_t + pm_h + 0.8;
lid_t    = 1.2;
mains_hole   = [15.5, 23.0];
mains_hole_d = 7.0;

/* [Wall screws, hardwired 5 V] */
screw_d    = 3.5;
screw_head = 7.0;
screws     = [[-30, 2], [19, -28]];
rear5v     = [-30, -14];   // hardwired 5 V in (mains = false)
rear5v_d   = 6.0;

R  = D / 2;
Ri = R - wall;
pcb_y0 = esp_cy - esp_l/2;            // USB end
z_port = back_t + esp_ledge + esp_t + 1.6;

module chamfered_disc(r, h, c_bottom = 0) {
    hull() {
        translate([0, 0, c_bottom]) cylinder(r = r, h = h - c_bottom);
        cylinder(r = r - c_bottom, h = h);
    }
}

// ---------- mains compartment ----------
module comp_outline(grow = 0) {
    offset(delta = grow) union() {
        translate([cx0, cy0]) square([cx1 - cx0, cy1 - cy0]);
        translate([cx0, cy1 - 0.01]) square([bay_x1 - cx0, bay_y1 - cy1]);
    }
}

module mains_compartment() {
    translate([0, 0, back_t - 0.01]) difference() {
        linear_extrude(cwall_top - back_t) comp_outline();
        translate([0, 0, -1]) linear_extrude(cwall_top) comp_outline(-cw);
        // 5 V out: notch in the wall facing the ESP32, low end
        translate([cx0 - 1, cy0 + cw + 2, cwall_top - back_t - 3.5]) cube([cw + 2, 4, 4.5]);
    }
}

module mains_lid() {
    linear_extrude(lid_t) comp_outline(-0.2);   // rests on the walls; glue the edge
}

// ---------- base ----------
module base() {
    difference() {
        union() {
            difference() {
                chamfered_disc(R, base_h, c_bottom = 0.8);
                translate([0, 0, back_t]) cylinder(r = Ri, h = base_h);
            }
            // ESP32 cradle: low side walls + ledges under the long edges; hot glue holds it
            for (s = [-1, 1]) translate([esp_cx + s * (esp_w/2 + 0.3) - (s > 0 ? 0 : 1.6), pcb_y0 + 2, back_t - 0.01])
                cube([1.6, esp_l - 4, esp_ledge + esp_t + 1.5]);
            for (s = [-1, 1]) translate([esp_cx + s * (esp_w/2 - 1.5) - (s > 0 ? 1.5 : 0), pcb_y0 + 4, back_t - 0.01])
                cube([1.5, esp_l - 8, esp_ledge]);
            if (mains) mains_compartment();
        }
        // USB-C into the chosen port
        translate([esp_cx + usb_use * usb_dx - usb_hole_w/2, -R - 1, z_port - usb_hole_h/2])
            cube([usb_hole_w, R + 1 + pcb_y0 + 0.01 + 2, usb_hole_h]);
        // wall screws (countersunk)
        for (p = screws) translate([p[0], p[1], 0]) {
            translate([0, 0, -1]) cylinder(d = screw_d, h = back_t + 2);
            translate([0, 0, back_t - (screw_head - screw_d)/2 + 0.01])
                cylinder(d1 = screw_d, d2 = screw_head, h = (screw_head - screw_d)/2);
        }
        // rear entry
        if (mains) translate([mains_hole[0], mains_hole[1], -1]) cylinder(d = mains_hole_d, h = back_t + 2);
        else translate([rear5v[0], rear5v[1], -1]) cylinder(d = rear5v_d, h = back_t + 2);
        // vents (left half only; the mains side stays closed)
        for (a = [105, 120, 135, 215, 230, 245]) rotate([0, 0, a])
            translate([Ri - 1, -0.8, back_t + 5]) cube([wall + 2, 1.6, 9]);
        // key slot (top): the cover fits one way up
        translate([-2.2, Ri - 0.5, base_h - lip_h - 0.5]) cube([4.4, 1.6, lip_h + 1]);
        // pry notch (bottom right)
        rotate([0, 0, -60]) translate([Ri - 1, -3, base_h - 1.0]) cube([wall + 2, 6, 2]);
        // "UP" mark
        translate([-22, 30, back_t - 0.6]) linear_extrude(1) text("UP", size = 4, halign = "center", valign = "center");
    }
}

// ---------- cover (own coordinates: front face on z = 0) ----------
module cover() {
    lip_ro = Ri - fit_clr;
    board_z = window_t + gap;
    rail_top = board_z + pcb_t + 1.6;
    difference() {
        union() {
            chamfered_disc(R, front_t, c_bottom = edge_chamf);
            translate([0, 0, front_t - 0.01]) difference() {
                cylinder(r = lip_ro, h = lip_h);
                translate([0, 0, -1]) cylinder(r = lip_ro - lip_w, h = lip_h + 2);
            }
            // key tab (top)
            translate([-2.0, lip_ro - 0.3, front_t]) cube([4.0, 1.3, lip_h - 0.6]);
            // sensor rails; the board slides in from the left
            for (s = [-1, 1]) {
                y_edge = s * pcb_w / 2;
                translate([-pcb_l/2 - 1, s > 0 ? y_edge - grip : y_edge - rail_w + grip, front_t - 0.01])
                    difference() {
                        cube([pcb_l + 1, rail_w, rail_top - front_t]);
                        translate([-1, s > 0 ? -0.01 : rail_w - grip - 0.3, board_z - front_t - 0.15])
                            cube([pcb_l + 3, grip + 0.31, pcb_t + 0.3]);
                    }
            }
            translate([pcb_l/2, -pcb_w/2 - rail_w + grip, front_t - 0.01])
                cube([1.6, pcb_w + 2*rail_w - 2*grip, rail_top - front_t]);
        }
        // thin window (inside only; the front stays flat)
        translate([-(pcb_l - 4)/2, -(pcb_w - 2*grip - 1)/2, window_t]) cube([pcb_l - 4, pcb_w - 2*grip - 1, front_t]);
    }
}

// ---------- ghost boards for the preview ----------
module ghosts() {
    color("green", 0.5) translate([esp_cx - esp_w/2, pcb_y0, back_t + esp_ledge]) {
        cube([esp_w, esp_l, esp_t]);
        translate([(esp_w - ant_w)/2, 25, esp_t]) cube([ant_w, esp_l - 25 + ant_l, 3.2]);   // WROOM module
        for (s = [-1, 1]) translate([esp_w/2 + s*usb_dx - 4.5, -0.5, esp_t]) cube([9, 7.5, 3.2]); // USB-C
    }
    if (mains) color("black", 0.5) translate([cx0 + cw + pm_clr, cy0 + cw + pm_clr, back_t]) cube([pm_w, pm_l, pm_h]);
    color("blue", 0.5) translate([-pcb_l/2, -pcb_w/2, base_h + front_t - window_t - gap - pcb_t]) cube([pcb_l, pcb_w, pcb_t]);
}

if (part == "base") base();
else if (part == "cover") cover();
else if (part == "lid") mains_lid();
else {
    base();
    ghosts();
    if (mains) color("orange", 0.7) translate([0, 0, cwall_top]) mains_lid();
    color("lightgray", 0.35) translate([0, 0, base_h + front_t]) mirror([0, 0, 1]) cover();
}

// ---------- fit checks (printed in the console) ----------
function rr(x, y) = sqrt(x*x + y*y);
echo(str("CHECK inside wall r = ", Ri));
echo(str("CHECK ESP32 PCB far corners r = ", rr(esp_cx - esp_w/2, pcb_y0), " / ", rr(esp_cx - esp_w/2, pcb_y0 + esp_l)));
echo(str("CHECK antenna corner r = ", rr(esp_cx - ant_w/2, pcb_y0 + esp_l + ant_l)));
echo(str("CHECK compartment corner r = ", rr(cx1, cy0), ", bay corner r = ", rr(bay_x1, bay_y1)));
echo(str("CHECK ESP32 cradle right x = ", esp_cx + esp_w/2 + 1.9, ", compartment left x = ", cx0));
