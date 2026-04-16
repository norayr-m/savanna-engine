#include <metal_stdlib>
using namespace metal;

// ── Entity codes ──────────────────────────────────────────
constant int8_t EMPTY = 0;
constant int8_t GRASS = 1;
constant int8_t ZEBRA = 2;
constant int8_t LION  = 3;
constant int8_t WATER = 4;

// ══════════════════════════════════════════════════════════
// DIGITAL SERENGETI — 1 hex = 100m, 1 tick = 6 hours
// Serengeti: 300K zebras, 3K lions, 14,750 km²
// ══════════════════════════════════════════════════════════

constant int MAX_AGE_ZEBRA   = 32000;  // ~22 years
constant int MAX_AGE_LION    = 18000;  // ~12 years
constant int MAX_AGE_GRASS   = 1460;   // 1 year
constant int REPRO_AGE_ZEBRA      = 730;    // 6 months
constant int REPRO_COOLDOWN_ZEBRA = 365;    // 3 months between foals
constant int FOOD_ENERGY     = 150;    // energy from mature grass
constant int SPRINT_COST     = 5;      // lion sprint tax

// ── Zebra metabolism (individual) ────────────────────────
constant int BMR_ZEBRA_ACTIVE   = 4;
constant int BMR_ZEBRA_RESTING  = 2;
constant int BMR_ZEBRA_STRESSED = 7;

// ── Lion/Pride metabolism (Super-Individual: 1 cell = 1 pride) ──
// Deep Think directive: pride as composite macro-agent
constant int BMR_LION_ACTIVE    = 3;   // per-pride per-tick
constant int BMR_LION_RESTING   = 1;
constant int BMR_LION_TORPOR    = 0;
constant int TORPOR_DRAIN_PERIOD = 128;

constant int HUNGRY_THRESH   = 80;
constant int STARVING_THRESH = 40;

// ── Kill energy: one zebra feeds a pride ─────────────────
constant int KILL_ENERGY     = 2000;   // realistic: one zebra = ~300kg meat

// ── Pride Mitosis (Deep Think: no birthday window) ───────
// When pride energy hits SPLIT_ENERGY → cell divides into two prides
// Each daughter gets half. Natural territorial repulsion after.
constant int SPLIT_ENERGY    = 6000;   // years of successful hunting

// ── Zebra reproduction (birthday-window, unchanged) ──────
constant int REPRO_ENERGY_ZEBRA = 120;
constant int BIRTH_ENERGY_ZEBRA = 50;
constant int REPRO_THERMO_LOSS  = 30;

// ── Max energy (per-species) ─────────────────────────────
constant int MAX_ENERGY_ZEBRA = 500;
constant int MAX_ENERGY_LION  = 8000;  // pride caloric pool

// ── Satiation ────────────────────────────────────────────
constant int SATIATION_THRESH = 4000;  // pride stops hunting at half-full

// ── River crossing ───────────────────────────────────────
constant int RIVER_CROSSING_COST = 50;    // energy to swim
constant int RIVER_DEATH_CHANCE  = 5;     // % chance of croc/drowning

// ── Sensing ranges ────────────────────────────────────────
// Hearing: omnidirectional, radius 1 (6 neighbors)
// Sight: directional cone from facing, radius 2 (zebra wide) or 3 (lion narrow)
// Smell: via scent diffusion buffers, effectively radius 3-5

// Zebra vision: 5 of 6 directions (340° — eyes on sides, blind spot behind)
// Lion vision: 3 of 6 directions (120° — eyes in front, forward cone)

constant float SCENT_DECAY    = 0.95;  // scent persists long — reaches ~20 hexes
constant float SCENT_SPREAD   = 0.85;  // strong spread — lion can track from far
constant float SCENT_EMIT_ZEBRA = 1.0; // zebras emit scent (lions track this)
constant float SCENT_EMIT_GRASS = 0.5; // grass emits scent (zebras track this)
constant float SCENT_EMIT_LION  = 0.8; // lions emit scent (zebras flee from this)
constant float SCENT_EMIT_WATER = 15.0; // strong water refugia — survival hubs during trough

// ── Thirst ───────────────────────────────────────────────
// ALL animals need water. Thirst is a PULL toward water, not a death sentence.
// At low water scent: gentle drain. At zero: stronger drain. Near water: nothing.
// Water scent field = memory map of watering holes (low decay, reaches far).
constant float WATER_DRINK_THRESH = 0.001;  // very faint water scent = hydrated enough
constant int   THIRST_ACCEL_PERIOD = 40;    // minimal: 1 energy per 40 ticks when fully dry
constant float WATER_GRASS_BOOST = 3.0;     // grass growth multiplier near water

// MAX_ENERGY_ZEBRA and MAX_ENERGY_LION defined in Serengeti constants above
inline int16_t clamp_z(int x) { return int16_t(clamp(x, 0, MAX_ENERGY_ZEBRA)); }
inline int16_t clamp_l(int x) { return int16_t(clamp(x, 0, MAX_ENERGY_LION)); }
inline int16_t clamp16(int x) { return int16_t(clamp(x, 0, 8000)); }  // fallback for grass

// Hex direction vectors for flocking alignment (screen coords: y-down, scaled ×10)
// Consistent with HexGrid neighbor ordering across even/odd columns.
//   Dir 0: NE (-30°)    Dir 3: SW (+150°)   — opposite pair
//   Dir 1: N  (-90°)    Dir 4: S  (+90°)    — opposite pair
//   Dir 2: NW (-150°)   Dir 5: SE (+30°)    — opposite pair
// Three axes at 120° apart. (d+3)%6 = opposite direction.
constant int dir_x[6] = { 9,  0, -9, -9,  0,  9};
constant int dir_y[6] = {-5,-10, -5,  5, 10,  5};

// ── Scent diffusion kernel with Serengeti wind ──────────
// Wind-biased diffusion: scent drifts downwind.
// Real seasonal pattern: NE monsoon (Nov-Mar), SE trades (May-Oct).
// wind_dir 0-5 maps to hex directions. Rotates with seasons.
kernel void diffuse_scent(
    device float*         scent      [[ buffer(0) ]],
    device const float*   scent_prev [[ buffer(1) ]],
    device const int8_t*  entity     [[ buffer(2) ]],
    device const int32_t* neighbors  [[ buffer(3) ]],
    constant int8_t&      source_type[[ buffer(4) ]],
    constant float&       emit_str   [[ buffer(5) ]],
    constant uint32_t&    node_count [[ buffer(6) ]],
    constant uint32_t&    wind_dir   [[ buffer(7) ]],  // 0-5 hex dir, 6+ = no wind
    constant float&       wind_str   [[ buffer(8) ]],  // 0=isotropic, 1=fully directional
    uint                  gid        [[ thread_position_in_grid ]]
) {
    if (gid >= node_count) return;

    float decay = SCENT_DECAY;
    if (source_type == WATER) decay = 0.995;
    if (source_type == ZEBRA) decay = 0.98;
    float s = scent_prev[gid] * decay;

    // Wind-biased neighbor spread
    // wind_dir 0-5 = hex direction, 6+ = no wind (isotropic diffusion)
    bool hasWind = (wind_dir < 6);
    int upwind = hasWind ? (int(wind_dir) + 3) % 6 : 0;
    float nb_weighted = 0; float weight_total = 0;
    for (int d = 0; d < 6; d++) {
        int32_t nb = neighbors[gid * 6 + d];
        if (nb < 0) continue;
        // Angular distance from upwind direction (0=upwind, 3=downwind)
        int angle = abs(d - upwind);
        if (angle > 3) angle = 6 - angle;
        // Upwind neighbor contributes most (w=1+WIND), downwind least (w=1-WIND*0.5)
        // If no wind: all neighbors equal weight (angle ignored)
        float w = hasWind ? 1.0 + wind_str * (1.0 - float(angle) / 3.0) : 1.0;
        nb_weighted += scent_prev[nb] * w;
        weight_total += w;
    }
    if (weight_total > 0) {
        s = max(s, nb_weighted / weight_total * SCENT_SPREAD);
    }

    if (entity[gid] == source_type) {
        s = max(s, emit_str);
    }

    scent[gid] = s;
}

// ── Main tick phase kernel ────────────────────────────────
// Three senses: hearing (r=1 omni), sight (r=2 directional), smell (scent field)
// Each animal has orientation (0-5 facing direction)

kernel void tick_phase(
    device int8_t*        entity      [[ buffer(0) ]],
    device int16_t*       energy      [[ buffer(1) ]],
    device int8_t*        ternary     [[ buffer(2) ]],
    device int16_t*       gauge       [[ buffer(3) ]],
    device int8_t*        orientation [[ buffer(4) ]],
    device const int32_t* neighbors   [[ buffer(5) ]],  // N×6 flat
    device const uint32_t* group      [[ buffer(6) ]],
    device const float*   scent_zebra [[ buffer(7) ]],   // lions track this
    device const float*   scent_grass [[ buffer(8) ]],   // zebras track this
    device const float*   scent_lion  [[ buffer(9) ]],   // zebras flee this
    device const float*   scent_water [[ buffer(10) ]],  // everyone needs water
    constant uint32_t&    tick        [[ buffer(11) ]],
    constant uint32_t&    is_day      [[ buffer(12) ]],
    constant uint32_t&    group_size  [[ buffer(13) ]],
    constant uint32_t&    main_tile_n [[ buffer(14) ]],  // Halo Protocol: cells beyond this are read-only
    uint                  gid         [[ thread_position_in_grid ]]
) {
    if (gid >= group_size) return;
    uint node = group[gid];
    int8_t my_entity = entity[node];

    // Empty or water: skip (water is permanent terrain)
    if (my_entity == EMPTY || my_entity == WATER) return;

    // Grass: stays forever unless eaten. Gauge tracks maturity for food value.
    if (my_entity == GRASS) {
        if (is_day && (tick % 4u == 0u)) gauge[node] = clamp16(int(gauge[node]) + 1);
        return;
    }

    int16_t my_energy = energy[node];
    int16_t my_age = gauge[node];
    int my_max_e = (my_entity == ZEBRA) ? MAX_ENERGY_ZEBRA : MAX_ENERGY_LION;
    int8_t my_facing = orientation[node];

    // ── BASE ANIMAL: age + death ──────────────────────────
    my_age += 1;
    gauge[node] = my_age;

    int max_age = (my_entity == ZEBRA) ? MAX_AGE_ZEBRA : MAX_AGE_LION;
    if (my_age >= max_age) {
        entity[node] = EMPTY; energy[node] = 0; ternary[node] = 0;
        gauge[node] = 0; orientation[node] = 0;
        return;
    }
    if (my_energy <= 0) {
        entity[node] = EMPTY; energy[node] = 0; ternary[node] = 0;
        gauge[node] = 0; orientation[node] = 0;
        return;
    }

    // ── THIRST ────────────────────────────────────────────
    // Animals near water (water_scent > threshold) are hydrated.
    // Animals far from water dehydrate: extra energy drain.
    // ALL animals need water equally. Lions drink too — they're not camels.
    // Water scent field acts as a memory map: once you've smelled water, follow the gradient back.
    float my_water_scent = scent_water[node];
    bool hydrated = my_water_scent > WATER_DRINK_THRESH;
    if (!hydrated && tick % THIRST_ACCEL_PERIOD == 0) {
        // Dehydration: lose extra energy (gentle pull, not death sentence)
        my_energy -= 1;
        energy[node] = int16_t(clamp(int(my_energy), 0, my_max_e));
        if (my_energy <= 0) {
            entity[node] = EMPTY; energy[node] = 0; ternary[node] = 0;
            gauge[node] = 0; orientation[node] = 0;
            return;
        }
    }

    // ── BMR: fires EVERY tick, no exceptions ───────────────
    // Uses CURRENT ternary state (from last tick's behavior).
    // This is the main energy drain. Applied before any behavior.
    {
        int8_t ts = ternary[node];
        int bmr;
        if (my_entity == ZEBRA) {
            bmr = (ts == 1) ? BMR_ZEBRA_ACTIVE :
                  (ts == 0) ? BMR_ZEBRA_RESTING : BMR_ZEBRA_STRESSED;
        } else {
            bmr = (ts == 1) ? BMR_LION_ACTIVE :
                  (ts == 0) ? BMR_LION_RESTING : BMR_LION_TORPOR;
            // Gemini: no free lunch. Torpor has fractional drain.
            if (ts == -1 && tick % TORPOR_DRAIN_PERIOD == 0) bmr = 1;
        }
        my_energy -= int16_t(bmr);
        energy[node] = int16_t(clamp(int(my_energy), 0, my_max_e));
        if (my_energy <= 0) {
            entity[node] = EMPTY; energy[node] = 0; ternary[node] = 0;
            gauge[node] = 0; orientation[node] = 0;
            return;
        }
    }

    // ── REPRODUCTION ──────────────────────────────────────────
    uint dir_off = (uint(node) * 2654435761u ^ tick) % 6u;

    if (my_entity == ZEBRA) {
        // ZEBRA: Birthday-window reproduction (unchanged)
        bool breed_window = (my_age > REPRO_AGE_ZEBRA) && (int(my_age) % REPRO_COOLDOWN_ZEBRA == 0);
        if (breed_window && my_energy >= (BIRTH_ENERGY_ZEBRA + REPRO_THERMO_LOSS)) {
            int32_t birth_cell = -1;
            // Radius 1
            for (int dd = 0; dd < 6; dd++) {
                int32_t nb = neighbors[node * 6 + int((dd + dir_off) % 6u)];
                if (nb >= 0 && (entity[nb] == EMPTY || entity[nb] == GRASS)) {
                    birth_cell = nb; break;
                }
            }
            // Radius 2
            if (birth_cell < 0) {
                for (int dd = 0; dd < 6; dd++) {
                    int32_t nb1 = neighbors[node * 6 + int((dd + dir_off) % 6u)];
                    if (nb1 < 0) continue;
                    for (int dd2 = 0; dd2 < 6; dd2++) {
                        int32_t nb2 = neighbors[nb1 * 6 + int((dd2 + dir_off) % 6u)];
                        if (nb2 >= 0 && nb2 != int32_t(node) && (entity[nb2] == EMPTY || entity[nb2] == GRASS)) {
                            birth_cell = nb2; break;
                        }
                    }
                    if (birth_cell >= 0) break;
                }
            }
            if (birth_cell >= 0 && uint32_t(birth_cell) < main_tile_n) {
                entity[birth_cell] = ZEBRA;
                energy[birth_cell] = int16_t(BIRTH_ENERGY_ZEBRA);
                ternary[birth_cell] = 1;
                gauge[birth_cell] = 0;
                orientation[birth_cell] = int8_t((int(my_facing) + 1) % 6);
                my_energy -= int16_t(BIRTH_ENERGY_ZEBRA + REPRO_THERMO_LOSS);
                energy[node] = int16_t(clamp(int(my_energy), 0, my_max_e));
            }
        }
    } else if (my_entity == LION) {
        // LION PRIDE: Mitosis (Deep Think directive)
        // When energy >= SPLIT_ENERGY, pride divides into two daughter prides.
        // Each gets half energy. Natural territorial repulsion after split.
        // No birthday window. No litter count. Thermodynamic reproduction.
        if (my_energy >= SPLIT_ENERGY) {
            int32_t split_cell = -1;
            // Find adjacent empty/grass cell for daughter pride
            for (int dd = 0; dd < 6; dd++) {
                int32_t nb = neighbors[node * 6 + int((dd + dir_off) % 6u)];
                if (nb >= 0 && (entity[nb] == EMPTY || entity[nb] == GRASS)
                    && uint32_t(nb) < main_tile_n) {
                    split_cell = nb; break;
                }
            }
            if (split_cell >= 0) {
                int16_t split_e = int16_t(my_energy / 2);
                // Daughter pride
                entity[split_cell] = LION;
                energy[split_cell] = split_e;
                ternary[split_cell] = 1;
                gauge[split_cell] = 0;  // new pride, age 0
                // Daughter faces AWAY (territorial repulsion from birth)
                int8_t away_dir = int8_t((int(my_facing) + 3) % 6);
                orientation[split_cell] = away_dir;
                // Mother pride keeps half
                my_energy = split_e;
                energy[node] = split_e;
            }
        }
    }

    // ── SENSE 1: HEARING (omnidirectional, r=1) ──────────
    int hear_pred = 0, hear_food = 0, hear_zebra = 0, hear_empty = 0, hear_lion = 0;
    // Murmur3 avalanche: shatter Morton geometric signature before modulo
    // Without this, lowest bit of Morton code = column parity → even columns
    // always check even directions first → deterministic chiral ratchet → NW drift
    // Fix by Gemini Deep Think, 2026-04-15
    uint _dh = uint(node) ^ (tick * 374761393u);
    _dh *= 0x85ebca6bu;
    _dh ^= _dh >> 13;
    _dh *= 0xc2b2ae35u;
    _dh ^= _dh >> 16;
    uint dir_offset = _dh % 6u;

    for (int dd = 0; dd < 6; dd++) {
        int d = int((dd + dir_offset) % 6u);
        int32_t nb = neighbors[node * 6 + d];
        if (nb < 0) continue;
        int8_t e = entity[nb];
        if (e == LION)  { hear_pred++; hear_lion++; }
        if (e == GRASS) hear_food++;
        if (e == ZEBRA) hear_zebra++;
        if (e == EMPTY) hear_empty++;
    }

    // ── SENSE 2: SIGHT (directional, r=2, cone from facing) ──
    // Visible directions: zebra sees 5/6 (all except behind), lion sees 3/6 (forward cone)
    int sight_pred = 0, sight_food = 0, sight_zebra = 0;
    int32_t sight_best_food = -1, sight_best_prey = -1;

    int n_visible = (my_entity == ZEBRA) ? 5 : 3;  // zebra: wide, lion: narrow
    for (int v = 0; v < n_visible; v++) {
        // Map visible slot to actual direction relative to facing
        // Zebra: facing-2, facing-1, facing, facing+1, facing+2 (skip facing+3 = behind)
        // Lion: facing-1, facing, facing+1 (forward cone)
        int dir;
        if (my_entity == ZEBRA) {
            dir = (int(my_facing) + v - 2 + 6) % 6;
        } else {
            dir = (int(my_facing) + v - 1 + 6) % 6;
        }

        // Radius 1: direct neighbor in this direction
        int32_t nb1 = neighbors[node * 6 + dir];
        if (nb1 < 0) continue;
        int8_t e1 = entity[nb1];
        if (e1 == LION)  sight_pred++;
        if (e1 == GRASS) { sight_food++; if (sight_best_food < 0) sight_best_food = nb1; }
        if (e1 == ZEBRA) { sight_zebra++; if (sight_best_prey < 0) sight_best_prey = nb1; }

        // Radius 2: neighbor's neighbor in same direction
        int32_t nb2 = neighbors[nb1 * 6 + dir];
        if (nb2 < 0) continue;
        int8_t e2 = entity[nb2];
        if (e2 == LION)  sight_pred++;
        if (e2 == GRASS && sight_best_food < 0) sight_best_food = nb1; // move toward r1 to get to r2
        if (e2 == ZEBRA && sight_best_prey < 0) sight_best_prey = nb1;

        // Lion radius 3 (further sight for predators)
        if (my_entity == LION) {
            int32_t nb3 = neighbors[nb2 * 6 + dir];
            if (nb3 >= 0 && entity[nb3] == ZEBRA && sight_best_prey < 0) {
                sight_best_prey = nb1;
            }
        }
    }

    // ── SENSE 3: SMELL (scent gradient from diffusion fields) ──
    // Find the neighbor with the strongest scent of what we want
    int32_t smell_target = -1;
    float best_scent = 0;

    // Water smell: find neighbor with strongest water scent
    int32_t water_target = -1;
    float best_water = my_water_scent;  // only move toward STRONGER water scent

    for (int dd = 0; dd < 6; dd++) {
        int d = int((dd + dir_offset) % 6u);
        int32_t nb = neighbors[node * 6 + d];
        if (nb < 0) continue;
        int8_t nb_ent = entity[nb];

        // Water scent tracking (both species)
        if (nb_ent != my_entity && nb_ent != WATER) {
            float ws = scent_water[nb];
            if (ws > best_water) { best_water = ws; water_target = nb; }
        }

        // Food/prey scent tracking
        if (nb_ent == my_entity) continue;  // don't walk into own kind

        float s;
        if (my_entity == LION) {
            s = scent_zebra[nb];  // lions track zebra scent
        } else {
            s = scent_grass[nb];  // zebras track grass scent
        }

        // Also avoid: zebras avoid lion scent
        if (my_entity == ZEBRA && scent_lion[nb] > 0.3) continue;

        if (s > best_scent && nb_ent != LION) {  // don't walk into a lion
            best_scent = s;
            smell_target = nb;
        }
    }

    // Can we drink right here? Adjacent to water cell = drinking
    bool at_water = false;
    for (int dd = 0; dd < 6; dd++) {
        int32_t nb = neighbors[node * 6 + dd];
        if (nb >= 0 && entity[nb] == WATER) { at_water = true; break; }
    }

    // ── COMPUTE: priority chain using all three senses ────
    int32_t target = -1;
    int8_t new_facing = my_facing;
    bool fleeing = false;  // fleeing animals trample grass, don't eat

    // Ternary metabolic state: determined by behavior this tick
    // +1=active (grazing/hunting), 0=resting (flocking/patrolling), -1=stressed (fleeing/starving)
    // Firewall: 0→+1→-1→0. Check current state for valid transitions.
    int8_t old_ternary = ternary[node];
    int8_t new_ternary = 0;  // default: resting

    if (my_entity == ZEBRA) {
        // ONE behavior tree. is_day modulates priorities, not separate brains.
        // Night: more alert to predators (smell range), tighter flocking, no grazing.
        // Day: graze when hungry, looser flocking.

        // P0: FLEE — always top priority, day or night
        bool threat = hear_pred > 0 || sight_pred > 0;
        if (!threat && !is_day && scent_lion[node] > 0.3) threat = true;  // night: smell counts too

        if (threat) {
            fleeing = true;
            new_ternary = -1;  // STRESSED: fleeing
            // Find predator direction — check heard first, then smelled
            int pred_dir = -1;
            for (int dd = 0; dd < 6; dd++) {
                int32_t nb = neighbors[node * 6 + dd];
                if (nb >= 0 && entity[nb] == LION) { pred_dir = dd; break; }
            }
            if (pred_dir >= 0) {
                new_facing = int8_t((pred_dir + 3) % 6);
            } else if (!is_day) {
                // Night: flee from strongest lion scent
                float worst = 0; int worst_dir = -1;
                for (int dd = 0; dd < 6; dd++) {
                    int32_t nb = neighbors[node * 6 + dd];
                    if (nb >= 0 && scent_lion[nb] > worst) { worst = scent_lion[nb]; worst_dir = dd; }
                }
                if (worst_dir >= 0) new_facing = int8_t((worst_dir + 3) % 6);
            }
            int32_t flee_nb = neighbors[node * 6 + int(new_facing)];
            if (flee_nb >= 0 && entity[flee_nb] != LION && entity[flee_nb] != ZEBRA) {
                target = flee_nb;
            }
        } else if (my_energy < STARVING_THRESH && hear_food > 0) {
            // P1: STARVING — eat regardless of time (survival override)
            new_ternary = -1;  // STRESSED: starving
            for (int dd = 0; dd < 6; dd++) {
                int d = int((dd + dir_offset) % 6u);
                int32_t nb = neighbors[node * 6 + d];
                if (nb >= 0 && entity[nb] == GRASS) { target = nb; new_facing = int8_t(d); break; }
            }
        } else if (!hydrated && !at_water && water_target >= 0
                   && my_energy < STARVING_THRESH && my_water_scent < 0.005) {
            // P2: DESPERATELY THIRSTY — seek water only when truly dry AND starving
            // Once hydrated (scent > threshold), water pull shuts off → resume migration
            new_ternary = -1;  // STRESSED: desperate for water
            target = water_target;
            for (int dd = 0; dd < 6; dd++) {
                if (neighbors[node * 6 + dd] == target) { new_facing = int8_t(dd); break; }
            }
        } else if (is_day && sight_best_food >= 0 && my_energy < 300) {
            // P3: SEE GRASS — walk toward it (day only, only when hungry)
            new_ternary = 1;  // ACTIVE: grazing
            target = sight_best_food;
            for (int dd = 0; dd < 6; dd++) {
                if (neighbors[node * 6 + dd] == target) { new_facing = int8_t(dd); break; }
            }
        } else if (is_day && smell_target >= 0 && best_scent > 0.1 && my_energy < 300) {
            // P4: SMELL GRASS — follow gradient (day only, hungry)
            new_ternary = 1;  // ACTIVE: foraging
            target = smell_target;
            for (int dd = 0; dd < 6; dd++) {
                if (neighbors[node * 6 + dd] == target) { new_facing = int8_t(dd); break; }
            }
        } else {
            // P5: FLOCK — always. Tighter at night (more cohesion weight).
            int facing_sum_x = 0, facing_sum_y = 0;
            for (int dd = 0; dd < 6; dd++) {
                int32_t nb = neighbors[node * 6 + dd];
                if (nb < 0) continue;
                if (entity[nb] == ZEBRA) {
                    int8_t nb_face = orientation[nb];
                    facing_sum_x += dir_x[nb_face];
                    facing_sum_y += dir_y[nb_face];
                    // Night: extra cohesion weight (pull toward neighbors)
                    if (!is_day) {
                        facing_sum_x += dir_x[dd];  // bias toward neighbor's position
                        facing_sum_y += dir_y[dd];
                    }
                }
            }

            // Noise for alignment (prevents global sync)
            int noise_x = (int(node * 2654435761u ^ tick * 1103515245u) % 3) - 1;
            int noise_y = (int(node * 374761393u ^ tick * 2246822519u) % 3) - 1;
            facing_sum_x += noise_x;
            facing_sum_y += noise_y;

            if (hear_zebra > 0 && (facing_sum_x != 0 || facing_sum_y != 0)) {
                int best_dir = int(my_facing);
                int best_dot = -999;
                for (int d = 0; d < 6; d++) {
                    int dot = facing_sum_x * dir_x[d] + facing_sum_y * dir_y[d];
                    if (dot > best_dot) { best_dot = dot; best_dir = d; }
                }
                new_facing = int8_t(best_dir);

                int32_t fwd = neighbors[node * 6 + best_dir];
                if (fwd >= 0 && (entity[fwd] == EMPTY || (entity[fwd] == GRASS && my_energy < 300 && is_day))) {
                    target = fwd;
                } else {
                    int8_t alt = int8_t((best_dir + ((tick % 2 == 0) ? 1 : 5)) % 6);
                    int32_t alt_nb = neighbors[node * 6 + int(alt)];
                    if (alt_nb >= 0 && (entity[alt_nb] == EMPTY || (entity[alt_nb] == GRASS && my_energy < 300 && is_day))) {
                        target = alt_nb; new_facing = alt;
                    }
                }
            } else if (my_energy < HUNGRY_THRESH) {
                // Alone and hungry — wander
                int32_t fwd = neighbors[node * 6 + int(my_facing)];
                if (fwd >= 0 && entity[fwd] == EMPTY) target = fwd;
            }
        }
    } else if (my_entity == LION) {
        // Lions hunt at night, stalk by day. They're never truly immobile.
        // At night: aggressive hunt. During day: slow stalk toward scent.

        // Gemini Type II: satiated lions (energy >= 200) DON'T hunt.
        // They sit and digest — becoming a physical meat shield.
        bool lion_hungry = my_energy < SATIATION_THRESH;
        new_ternary = lion_hungry ? 1 : 0;  // hungry=ACTIVE, sated=RESTING
        if (my_energy < STARVING_THRESH) new_ternary = -1;  // STRESSED: starving lion
        if (lion_hungry && hear_zebra > 0) {
            for (int dd = 0; dd < 6; dd++) {
                int d = int((dd + dir_offset) % 6u);
                int32_t nb = neighbors[node * 6 + d];
                if (nb >= 0 && entity[nb] == ZEBRA) { target = nb; new_facing = int8_t(d); break; }
            }
        }

        if (target < 0) {
            // Lions ALWAYS move. Hungry: hunt. Sated: patrol/rest.
            if (lion_hungry && sight_best_prey >= 0) {
                // SEE prey — SPRINT charge (lions are faster than zebras in short burst)
                // Move to sight_best_prey (r=1 neighbor toward prey).
                // If that cell is passable, also check one more hop to close the gap.
                target = sight_best_prey;
                for (int dd = 0; dd < 6; dd++) {
                    if (neighbors[node * 6 + dd] == target) { new_facing = int8_t(dd); break; }
                }
                // SPRINT: if intermediate cell is empty/grass, jump through it
                // Gemini: sprint tax — miss and you pay
                my_energy -= SPRINT_COST;
                // to land on the cell beyond (closer to prey)
                int8_t charge_dir = new_facing;
                int8_t dest_e = entity[target];
                if (dest_e == EMPTY || dest_e == GRASS) {
                    int32_t beyond = neighbors[target * 6 + int(charge_dir)];
                    if (beyond >= 0) {
                        int8_t beyond_e = entity[beyond];
                        if (beyond_e == ZEBRA) {
                            // Sprint lands on zebra — KILL at distance 2!
                            // Trample intermediate cell, land on prey
                            if (dest_e == GRASS) gauge[target] = -30;
                            entity[target] = EMPTY; // clear intermediate
                            target = beyond;  // land on prey
                        } else if (beyond_e == EMPTY || beyond_e == GRASS) {
                            // Sprint through: land 2 hexes away (closer to prey)
                            if (dest_e == GRASS) gauge[target] = -30;
                            entity[target] = EMPTY;
                            target = beyond;
                        }
                    }
                }
            } else if (lion_hungry && smell_target >= 0 && best_scent > 0.01) {
                // SMELL prey — follow gradient (0.01 = ~30 hex range, long-range tracking)
                target = smell_target;
                for (int dd = 0; dd < 6; dd++) {
                    if (neighbors[node * 6 + dd] == target) { new_facing = int8_t(dd); break; }
                }
            } else if (!lion_hungry && smell_target >= 0 && best_scent > 0.01) {
                // SATED but smell prey — slow drift toward scent (patrol)
                target = smell_target;
                for (int dd = 0; dd < 6; dd++) {
                    if (neighbors[node * 6 + dd] == target) { new_facing = int8_t(dd); break; }
                }
            } else {
                // NO PREY DETECTED — lions ALWAYS move. Never sit idle.

                // 1. Follow zebra scent if any
                if (target < 0) {
                    float best_zs = 0; int32_t best_zt = -1; int8_t best_zd = my_facing;
                    for (int dd = 0; dd < 6; dd++) {
                        int32_t nb = neighbors[node * 6 + dd];
                        if (nb < 0 || entity[nb] == LION) continue;
                        float zs = scent_zebra[nb];
                        if (zs > best_zs && (entity[nb] == EMPTY || entity[nb] == GRASS)) {
                            best_zs = zs; best_zt = nb; best_zd = int8_t(dd);
                        }
                    }
                    if (best_zt >= 0 && best_zs > 0.001) {
                        target = best_zt; new_facing = best_zd;
                    }
                }
                // 2. PRIDE TERRITORIAL REPULSION (Super-Individual: 1 cell = 1 pride)
                // Prides repel each other — claim separate hunting grounds
                if (target < 0 && hear_lion > 0) {
                    {
                        // REPEL: move away from nearest pride
                        for (int dd = 0; dd < 6; dd++) {
                            int32_t nb = neighbors[node * 6 + dd];
                            if (nb >= 0 && entity[nb] == LION) {
                                int8_t away = int8_t((dd + 3) % 6);
                                int32_t away_nb = neighbors[node * 6 + int(away)];
                                if (away_nb >= 0 && (entity[away_nb] == EMPTY || entity[away_nb] == GRASS)) {
                                    target = away_nb; new_facing = away;
                                }
                                break;
                            }
                        }
                    }
                }

                // Strategy: Lévy flight biased toward water.
                if (target >= 0) {
                    // Moving with pride or toward pride
                } else if (at_water) {
                    // AT WATER: patrol around the edge — try all 6 directions
                    new_ternary = 0;  // RESTING: conserving energy at water
                    for (int dd = 0; dd < 6; dd++) {
                        int8_t pd = int8_t((int(my_facing) + dd + 1) % 6);
                        int32_t pnb = neighbors[node * 6 + int(pd)];
                        if (pnb >= 0 && (entity[pnb] == EMPTY || entity[pnb] == GRASS)) {
                            target = pnb; new_facing = pd; break;
                        }
                    }
                } else if (my_water_scent > 0.01 && water_target >= 0) {
                    // CAN SMELL WATER: walk toward it
                    target = water_target;
                    for (int dd = 0; dd < 6; dd++) {
                        if (neighbors[node * 6 + dd] == target) { new_facing = int8_t(dd); break; }
                    }
                } else {
                    // STATELESS LÉVY FLIGHT — decorrelated per node
                    // Murmur-style hash: multiply, xor-shift, multiply
                    uint h = uint(node) ^ (tick * 374761393u);
                    h ^= h >> 16; h *= 2654435761u; h ^= h >> 13; h *= 1103515245u; h ^= h >> 16;
                    if ((h % 100u) < 0) {
                        // Keep walking straight (DISABLED — diagnostic for drift bias)
                        int32_t fwd = neighbors[node * 6 + int(my_facing)];
                        if (fwd >= 0 && (entity[fwd] == EMPTY || entity[fwd] == GRASS)) {
                            target = fwd;
                        } else {
                            int8_t alt = int8_t((int(my_facing) + ((h >> 8) % 2 == 0 ? 1 : 5)) % 6);
                            int32_t alt_nb = neighbors[node * 6 + int(alt)];
                            if (alt_nb >= 0 && (entity[alt_nb] == EMPTY || entity[alt_nb] == GRASS)) {
                                target = alt_nb; new_facing = alt;
                            }
                        }
                    } else {
                        // New random direction — truly per-node
                        int8_t new_dir = int8_t((h >> 4) % 6u);
                        new_facing = new_dir;
                        int32_t fwd = neighbors[node * 6 + int(new_dir)];
                        if (fwd >= 0 && (entity[fwd] == EMPTY || entity[fwd] == GRASS)) {
                            target = fwd;
                        }
                    }
                }
            }
        }
    }

    // ── TERNARY FIREWALL: 0→+1→-1→0 ──────────────────────
    // No direct -1→+1 jump — EXCEPT predation interrupt.
    // A starving lion that finds prey MUST be allowed to kill.
    bool predation_interrupt = (my_entity == LION && target >= 0 && entity[target] == ZEBRA);
    if (old_ternary == -1 && new_ternary == 1 && !predation_interrupt) {
        new_ternary = 0;  // forced recovery: stressed→resting
    }
    ternary[node] = new_ternary;

    // Update orientation
    orientation[node] = new_facing;

    // ── EMIT ──────────────────────────────────────────────
    // Halo Protocol: cannot move into halo cells (read-only ghost zone)
    if (target >= 0 && uint32_t(target) >= main_tile_n) target = -1;
    if (target >= 0) {
        int8_t dest_entity = entity[target];

        // Eat / kill — zebra only eats when hungry AND not fleeing
        if (my_entity == ZEBRA && dest_entity == GRASS) {
            if (fleeing) {
                // FLEEING: trample through grass, don't eat — survival over food
                gauge[target] = -50;  // light trample (not as deep as grazing)
                // Fall through to move execution below
            } else if (my_energy < 300) {
                // Hungry: eat the grass
                int food_val = (gauge[target] >= 200) ? FOOD_ENERGY : FOOD_ENERGY / 2;
                my_energy = int16_t(clamp(int(my_energy) + food_val, 0, my_max_e));
                // Grass is consumed — mark as trampled
                gauge[target] = -100;
            } else {
                // Full: don't eat, don't move onto grass. Stay put.
                return;
            }
        } else if (my_entity == LION && dest_entity == ZEBRA) {
            my_energy = int16_t(clamp(int(my_energy) + KILL_ENERGY, 0, my_max_e));
            new_ternary = 0;  // forced handling time — sit and digest
        } else if (my_entity == LION && dest_entity == GRASS) {
            // Lions walk through grass — trample it lightly
            gauge[target] = -30;
        } else if (dest_entity != EMPTY) {
            // Can't move here — but still pay BMR (metabolism doesn't stop)
            return;
        }

        // Execute move (BMR applied after move section, fires every tick)
        entity[target] = my_entity;
        energy[target] = my_energy;
        ternary[target] = new_ternary;
        gauge[target] = gauge[node];  // keep age
        orientation[target] = new_facing;

        entity[node] = EMPTY;
        energy[node] = 0; ternary[node] = 0;
        orientation[node] = 0;
        // If we trampled grass at target, mark source as trampled too (trail)
        gauge[node] = (dest_entity == GRASS) ? -50 : 0;
    } else {
        // Idle — BMR still fires (see below)
    }

    // BMR already applied at top of tick — no duplicate here.

    // Post-move death
    if (entity[node] != EMPTY && entity[node] != GRASS && energy[node] <= 0) {
        entity[node] = EMPTY; energy[node] = 0;
        ternary[node] = 0; gauge[node] = 0; orientation[node] = 0;
    }
}

// ── Grass growth kernel ───────────────────────────────────
kernel void grow_grass(
    device int8_t*        entity    [[ buffer(0) ]],
    device int16_t*       gauge     [[ buffer(1) ]],
    device const int32_t* neighbors [[ buffer(2) ]],
    constant uint32_t&    tick      [[ buffer(3) ]],
    constant uint32_t&    node_count[[ buffer(4) ]],
    device const float*   scent_water [[ buffer(5) ]],  // water proximity boosts growth
    uint                  gid       [[ thread_position_in_grid ]]
) {
    if (gid >= node_count) return;
    if (entity[gid] != EMPTY) return;

    // Trampled ground: gauge is negative. Must recover before grass can grow.
    // Each tick, trampled gauge increments toward 0. Only at 0+ can grass sprout.
    if (gauge[gid] < 0) {
        // Near water: trampled ground recovers faster
        int recovery = (scent_water[gid] > 0.2) ? 3 : 1;
        gauge[gid] = int16_t(min(0, int(gauge[gid]) + recovery));
        return;  // can't grow yet — soil is trampled
    }

    uint hash = (uint(gid) * 2654435761u + tick * 2246822519u) % 10000u;

    // Water proximity: grass grows much faster near water (riparian zone)
    float water_boost = 1.0 + scent_water[gid] * WATER_GRASS_BOOST;

    // Adjacent grass: spread faster (roots, runners)
    int adj_grass = 0;
    for (int d = 0; d < 6; d++) {
        int32_t nb = neighbors[gid * 6 + d];
        if (nb >= 0 && entity[nb] == GRASS) adj_grass++;
    }

    if (adj_grass > 0) {
        // Spread from neighbors: ~0.7% per tick per adjacent grass
        // 3 neighbors → 2.1%/tick → fills in ~48 ticks (12 days). Bio: 1-2 weeks.
        uint threshold = uint(float(7 * adj_grass) * water_boost);
        if (hash < threshold) { entity[gid] = GRASS; gauge[gid] = 0; return; }
    }

    // Spontaneous growth: wind-blown seeds, bird droppings.
    // ~0.01%/tick = one seed per 10K empty cells per tick.
    // Near water: boosted. Far from water and grass: rare (months).
    uint spont_thresh = uint(1.0 * water_boost);
    if (hash < spont_thresh) {
        entity[gid] = GRASS;
        gauge[gid] = 0;
    }
}

// ── Census ────────────────────────────────────────────────
// ── Genesis: GPU state initialization ────────────────────
// Replaces CPU randomInit. Each thread initializes one cell.
// PCG32 hash per thread → deterministic, massively parallel.
// Water: noise threshold (replaces sequential flood-fill).
// Gemini Optimization B.

// PCG32-style hash: deterministic, decorrelated per thread
inline uint pcg32(uint state) {
    state = state * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Simple 2D hash noise for water lake placement
inline float hash_noise(uint col, uint row, uint seed) {
    // Two octaves of hash noise → organic lake shapes
    uint h1 = pcg32(col * 73856093u ^ row * 19349663u ^ seed);
    float n1 = float(h1) / float(0xFFFFFFFFu);
    // Second octave at 4× frequency
    uint h2 = pcg32((col/4u) * 56443811u ^ (row/4u) * 83492791u ^ seed * 37u);
    float n2 = float(h2) / float(0xFFFFFFFFu);
    return n1 * 0.6 + n2 * 0.4;
}

kernel void genesis(
    device int8_t*   entity      [[ buffer(0) ]],
    device int16_t*  energy      [[ buffer(1) ]],
    device int8_t*   ternary     [[ buffer(2) ]],
    device int16_t*  gauge       [[ buffer(3) ]],
    device int8_t*   orientation [[ buffer(4) ]],
    constant uint32_t& grid_w    [[ buffer(5) ]],
    constant uint32_t& grid_h    [[ buffer(6) ]],
    constant uint32_t& seed      [[ buffer(7) ]],
    constant float&  grass_frac  [[ buffer(8) ]],
    constant float&  zebra_frac  [[ buffer(9) ]],
    constant float&  lion_frac   [[ buffer(10) ]],
    constant float&  water_thresh [[ buffer(11) ]],  // ~0.92 for ~8% water
    device const int32_t* morton_rank [[ buffer(12) ]],  // row-major → Morton
    uint                  gid    [[ thread_position_in_grid ]]
) {
    if (gid >= grid_w * grid_h) return;

    // Row-major position
    uint col = gid % grid_w;
    uint row = gid / grid_w;

    // Morton-ordered buffer index
    uint m = uint(morton_rank[gid]);

    // Per-cell deterministic RNG chain
    uint rng = pcg32(gid ^ seed * 2654435761u);

    // ── Water: noise-based lakes ──
    float noise = hash_noise(col, row, seed);
    if (noise > water_thresh) {
        entity[m] = WATER;
        energy[m] = 0;
        ternary[m] = 0;
        gauge[m] = 0;
        orientation[m] = 0;
        return;
    }

    // ── Grass ──
    rng = pcg32(rng);
    float r = float(rng) / float(0xFFFFFFFFu);
    if (r < grass_frac) {
        entity[m] = GRASS;
        energy[m] = 0;
        ternary[m] = 0;
        rng = pcg32(rng);
        gauge[m] = int16_t(rng % 256u);  // random maturity
        orientation[m] = 0;
    } else {
        entity[m] = EMPTY;
        energy[m] = 0;
        ternary[m] = 0;
        gauge[m] = 0;
        orientation[m] = 0;
    }

    // ── Zebras: Gaussian clusters (5 herds, dice-5 pattern) ──
    // Check if this cell falls within any herd's Gaussian radius
    rng = pcg32(rng);
    float zr = float(rng) / float(0xFFFFFFFFu);

    // 5 herd centers (fractional positions × grid size)
    // Center, TL, TR, BL, BR
    float2 herds[5] = {
        float2(0.375, 0.375),
        float2(0.2, 0.2),
        float2(0.55, 0.2),
        float2(0.2, 0.55),
        float2(0.55, 0.55)
    };
    float herd_radius = float(grid_w) / 8.0;

    for (int h = 0; h < 5; h++) {
        float cx = herds[h].x * float(grid_w);
        float cy = herds[h].y * float(grid_h);
        float dx = float(col) - cx;
        float dy = float(row) - cy;
        float dist2 = dx * dx + dy * dy;
        float sigma2 = herd_radius * herd_radius;
        // Gaussian probability: peak = zebra_frac * 5
        float prob = zebra_frac * 5.0 * exp(-dist2 / (2.0 * sigma2));
        if (zr < prob && entity[m] != WATER) {
            entity[m] = ZEBRA;
            rng = pcg32(rng);
            energy[m] = int16_t(150 + (rng % 101u));
            ternary[m] = int8_t(rng % 2u);
            rng = pcg32(rng);
            orientation[m] = int8_t(rng % 6u);
            // Uniform age with spread repro phase
            rng = pcg32(rng);
            int age = 730 + int(rng % uint(32000 - 730));
            rng = pcg32(rng);
            int phase = int(rng % 365u);
            gauge[m] = int16_t(age - (age % 365) + phase);
            return;
        }
    }

    // ── Lions: grid of prides, 4 per pride ──
    rng = pcg32(rng);
    float lr = float(rng) / float(0xFFFFFFFFu);
    if (lr < lion_frac && entity[m] != WATER && entity[m] != ZEBRA) {
        entity[m] = LION;
        rng = pcg32(rng);
        energy[m] = int16_t(200 + (rng % 101u));
        ternary[m] = 1;
        rng = pcg32(rng);
        orientation[m] = int8_t(rng % 6u);
        // Uniform age
        rng = pcg32(rng);
        int age = 2920 + int(rng % uint(18000 - 2920));
        rng = pcg32(rng);
        int phase = int(rng % 2920u);
        gauge[m] = int16_t(age - (age % 2920) + phase);
    }
}

// ── RG-LOD: Renormalization Group Level-of-Detail ────────
// Reduces entity buffer to half resolution. Each output pixel stores
// the DOMINANT entity, but the real magic is in the composition buffer
// (4 floats per pixel: grass_frac, zebra_frac, lion_frac, water_frac).
// Multiple passes build a mipmap pyramid. Color at any zoom =
// weighted blend of entity colors × fractions.

kernel void reduce_lod_compose(
    device const int8_t*  src_entity  [[ buffer(0) ]],
    device float4*        dst_compose [[ buffer(1) ]],  // (grass, zebra, lion, water) fractions
    constant uint32_t&    src_w       [[ buffer(2) ]],
    constant uint32_t&    src_h       [[ buffer(3) ]],
    uint                  gid         [[ thread_position_in_grid ]]
) {
    uint dst_w = src_w / 2;
    uint dst_h = src_h / 2;
    if (gid >= dst_w * dst_h) return;

    uint dx = gid % dst_w;
    uint dy = gid / dst_w;
    uint sx = dx * 2, sy = dy * 2;

    // Count entities in 2×2 block
    float4 comp = float4(0);  // grass, zebra, lion, water
    for (int oy = 0; oy < 2; oy++) {
        for (int ox = 0; ox < 2; ox++) {
            int8_t e = src_entity[(sy + oy) * src_w + (sx + ox)];
            if (e == GRASS) comp.x += 0.25;
            else if (e == ZEBRA) comp.y += 0.25;
            else if (e == LION)  comp.z += 0.25;
            else if (e == WATER) comp.w += 0.25;
            // EMPTY contributes nothing (dark)
        }
    }
    dst_compose[gid] = comp;
}

// Reduce composition buffer to half (cascade: compose → compose → ...)
kernel void reduce_lod_cascade(
    device const float4*  src_compose [[ buffer(0) ]],
    device float4*        dst_compose [[ buffer(1) ]],
    constant uint32_t&    src_w       [[ buffer(2) ]],
    constant uint32_t&    src_h       [[ buffer(3) ]],
    uint                  gid         [[ thread_position_in_grid ]]
) {
    uint dst_w = src_w / 2;
    uint dst_h = src_h / 2;
    if (gid >= dst_w * dst_h) return;

    uint dx = gid % dst_w;
    uint dy = gid / dst_w;
    uint sx = dx * 2, sy = dy * 2;

    float4 a = src_compose[sy * src_w + sx];
    float4 b = src_compose[sy * src_w + sx + 1];
    float4 c = src_compose[(sy + 1) * src_w + sx];
    float4 d = src_compose[(sy + 1) * src_w + sx + 1];

    dst_compose[gid] = (a + b + c + d) * 0.25;
}

// Render composition to RGBA pixels for display
kernel void render_lod(
    device const float4* compose    [[ buffer(0) ]],
    device uchar4*       pixels     [[ buffer(1) ]],
    constant uint32_t&   pixel_count [[ buffer(2) ]],
    uint                 gid        [[ thread_position_in_grid ]]
) {
    if (gid >= pixel_count) return;

    float4 c = compose[gid];
    float empty_frac = max(0.0, 1.0 - c.x - c.y - c.z - c.w);

    // Blend entity colors by fraction
    // Empty: (26, 20, 8), Grass: (58, 74, 24), Zebra: (232, 228, 220)
    // Lion: (180, 40, 30), Water: (40, 90, 160)
    float3 color = float3(26, 20, 8) * empty_frac
                 + float3(58, 74, 24) * c.x    // grass
                 + float3(232, 228, 220) * c.y  // zebra
                 + float3(220, 50, 30) * c.z    // lion (boosted red for visibility)
                 + float3(40, 90, 160) * c.w;   // water

    // Boost rare entities: if lion fraction > 0, ensure minimum red visibility
    if (c.z > 0.001) color = mix(color, float3(255, 40, 30), max(0.15, c.z));
    if (c.y > 0.01)  color = mix(color, float3(240, 240, 230), max(0.1, c.y));

    pixels[gid] = uchar4(uchar(clamp(color.x, 0.0, 255.0)),
                          uchar(clamp(color.y, 0.0, 255.0)),
                          uchar(clamp(color.z, 0.0, 255.0)),
                          255);
}

// ── Census ──────────────────────────────────────────────
kernel void census_reduce(
    device const int8_t*   entity     [[ buffer(0) ]],
    device atomic_uint*    grass_count[[ buffer(1) ]],
    device atomic_uint*    zebra_count[[ buffer(2) ]],
    device atomic_uint*    lion_count [[ buffer(3) ]],
    device atomic_uint*    energy_sum [[ buffer(4) ]],
    device const int16_t*  energy     [[ buffer(5) ]],
    constant uint32_t&     node_count [[ buffer(6) ]],
    uint                   gid        [[ thread_position_in_grid ]]
) {
    if (gid >= node_count) return;
    int8_t e = entity[gid];
    if (e == GRASS || e == WATER) atomic_fetch_add_explicit(grass_count, 1, memory_order_relaxed);
    if (e == ZEBRA) atomic_fetch_add_explicit(zebra_count, 1, memory_order_relaxed);
    if (e == LION)  atomic_fetch_add_explicit(lion_count,  1, memory_order_relaxed);
    if (e == ZEBRA || e == LION)
        atomic_fetch_add_explicit(energy_sum, uint(energy[gid]), memory_order_relaxed);
}

// ══════════════════════════════════════════════════════════
// CARLOS DELTA — GPU Decode Kernels
// Phase 1: CPU decompresses zlib, GPU does XOR + de-Morton + LOD
// Phase 2: sparse scatter format, zero CPU
// ══════════════════════════════════════════════════════════

// XOR a decompressed delta buffer into the frame buffer (in-place)
kernel void delta_xor(
    device uint8_t*       frame       [[ buffer(0) ]],  // current frame (modified in-place)
    device const uint8_t* delta       [[ buffer(1) ]],  // decompressed XOR delta
    constant uint32_t&    count       [[ buffer(2) ]],
    uint                  gid         [[ thread_position_in_grid ]]
) {
    if (gid >= count) return;
    frame[gid] = frame[gid] ^ delta[gid];
}

// De-Morton: scatter from Morton-rank order to row-major order
kernel void delta_demorton(
    device const uint8_t*  morton_frame  [[ buffer(0) ]],  // Morton-ordered frame
    device uint8_t*        rowmajor_out  [[ buffer(1) ]],  // row-major output
    device const int32_t*  morton_to_node [[ buffer(2) ]], // mortonToNode[rank] = rowmajor index
    constant uint32_t&     count         [[ buffer(3) ]],
    uint                   gid           [[ thread_position_in_grid ]]
) {
    if (gid >= count) return;
    rowmajor_out[morton_to_node[gid]] = morton_frame[gid];
}

// LOD downsample: majority vote + trophic boost (replaces CPU displayFrame)
// Input: row-major entity buffer (full res)
// Output: downsampled int8 entity buffer (display res)
kernel void delta_lod_downsample(
    device const uint8_t*  src         [[ buffer(0) ]],  // full-res row-major
    device int8_t*         dst         [[ buffer(1) ]],  // downsampled output
    constant uint32_t&     src_w       [[ buffer(2) ]],
    constant uint32_t&     dst_w       [[ buffer(3) ]],
    constant uint32_t&     dst_h       [[ buffer(4) ]],
    constant uint32_t&     step        [[ buffer(5) ]],
    uint                   gid         [[ thread_position_in_grid ]]
) {
    if (gid >= dst_w * dst_h) return;

    uint dx = gid % dst_w;
    uint dy = gid / dst_w;
    uint s = step;
    uint bs = s * s;

    // Count entities in block
    uint counts[5] = {0, 0, 0, 0, 0};
    for (uint sy = 0; sy < s; sy++) {
        uint rowOff = (dy * s + sy) * src_w + dx * s;
        for (uint sx = 0; sx < s; sx++) {
            uint e = src[rowOff + sx] & 0x7;
            if (e < 5) counts[e]++;
        }
    }

    // Majority vote
    int8_t best = 0;
    uint bestC = counts[0];
    if (counts[1] > bestC) { best = 1; bestC = counts[1]; }
    if (counts[2] > bestC) { best = 2; bestC = counts[2]; }
    if (counts[3] > bestC) { best = 3; bestC = counts[3]; }
    if (counts[4] > bestC) { best = 4; }

    // Trophic boost: rare predators stay visible
    if (counts[2] * 100 > bs * 3) best = 2;  // zebra >3%
    if (counts[3] * 100 > bs * 1) best = 3;  // lion >1%

    dst[gid] = best;
}

// Phase 2: sparse scatter — apply non-zero delta entries
// P-frame format: array of (uint32 index, uint8 value) packed as 5-byte entries
kernel void delta_sparse_scatter(
    device uint8_t*        frame        [[ buffer(0) ]],  // frame buffer (XOR in-place)
    device const uint32_t* indices      [[ buffer(1) ]],  // sparse indices
    device const uint8_t*  values       [[ buffer(2) ]],  // sparse values
    constant uint32_t&     count        [[ buffer(3) ]],  // number of entries
    uint                   gid          [[ thread_position_in_grid ]]
) {
    if (gid >= count) return;
    uint idx = indices[gid];
    frame[idx] = frame[idx] ^ values[gid];
}
