#!/bin/bash
# Savanna Narrated Tour — 3 levels, ~3 minutes total
# Jamie Premium voice, David Attenborough style
# Usage: bash tour.sh [1|2|3|all]

VOICE="Jamie (Premium)"
SPEED_FILE="/tmp/savanna_speed.txt"
SLEEP_FILE="/tmp/savanna_sleep.txt"

set_zoom() {
    echo "$1" > "$SPEED_FILE"
    echo "$2" > "$SLEEP_FILE"
}

speak() {
    say -v "$VOICE" -r 170 "$1"
}

# ═══════════════════════════════════════════════════════════
# LEVEL 1: General Public (~60 seconds)
# ═══════════════════════════════════════════════════════════
tour_level1() {
    echo "🌍 Level 1: The Serengeti (General Public)"

    # Start zoomed out
    set_zoom 4 60
    speak "Welcome to the digital Serengeti. What you see is a living world — one million cells, each one a tiny patch of African grassland. The green is grass. The dark patches are where herds of zebras have eaten everything bare. And those blue pools? Water. The source of all life."

    sleep 1
    set_zoom 2 80
    speak "Watch the zebras. Those white dots, moving together. They travel in herds, just like real zebras — safety in numbers. They follow the grass, and when they've eaten an area bare, they move on. Behind them, the grass slowly grows back. This is migration."

    sleep 1
    set_zoom 1 120
    speak "Now look for the red dots. Those are lions. Solitary hunters, spread across the savanna. They wait near watering holes — because every animal must drink. When a zebra comes too close, the lion charges. Two hexes in a single burst. A sprint kill."

    sleep 1
    set_zoom 4 60
    speak "Zoom back out and you see the whole picture. Grass feeds zebras. Zebras feed lions. Water draws them all together. And the cycle continues — as it has for millions of years. Except this one runs on a computer chip, sixty times per second."

    sleep 2
}

# ═══════════════════════════════════════════════════════════
# LEVEL 2: Science Enthusiast (~60 seconds)
# ═══════════════════════════════════════════════════════════
tour_level2() {
    echo "🔬 Level 2: The Dynamics (Science Enthusiast)"

    set_zoom 3 70
    speak "This is a Lotka-Volterra predator-prey system — but spatial, not just equations. Each zebra and lion is an autonomous agent with three senses: hearing, sight, and smell. They don't follow scripted paths. The herding, the hunting, the migration — it all emerges from local rules."

    sleep 1
    set_zoom 1 120
    speak "The metabolism is ternary. Each animal has three states: active, resting, and refractory. Active costs energy. Resting conserves. And refractory? For zebras, that's panic — burns double. For lions, it's torpor — burns nothing. A starving lion shuts down and drifts, like a shark in slow water, until it smells prey again."

    sleep 1
    set_zoom 6 40
    speak "The zoom controls time. This isn't just a camera trick. It's the renormalization group — the heat equation scaling. When you zoom in, time slows and you watch individual hunts. Zoom out and time accelerates — you see population waves, traveling across the savanna like weather systems. Same physics, different scale. The equation is t equals one over x squared."

    sleep 1
    set_zoom 3 70
    speak "Water creates the geography. Twelve lakes, each grown by flood-fill — fully connected bodies. Grass grows three times faster near water. Animals must drink or slowly dehydrate. The watering hole is where predator meets prey. This is where the drama happens."

    sleep 2
}

# ═══════════════════════════════════════════════════════════
# LEVEL 3: Technical (~60 seconds)
# ═══════════════════════════════════════════════════════════
tour_level3() {
    echo "⚙️ Level 3: The Engine (Technical)"

    set_zoom 2 80
    speak "One million nodes. Five channels per node: entity, energy, ternary, gauge, orientation. Four scent diffusion fields. The state tensor is updated via seven Metal compute kernel dispatches per tick — one per color group."

    sleep 1
    set_zoom 4 60
    speak "The seven-coloring formula: col plus row plus four times col-and-one, mod seven. This guarantees distance-two independence on the hex lattice — no two same-color nodes share any common neighbor. Molloy and Salavatipour, 2005. Twelve valid formulas exist. We use the simplest. This eliminates scatter-write collisions during movement. Zero silent entity loss."

    sleep 1
    set_zoom 1 120
    speak "The ternary firewall: zero to plus-one to minus-one to zero. No direct jump from refractory to active — except the predation interrupt. A starving lion that touches prey breaks the firewall. This is a hardware interrupt in the biological computer. The base metabolic rate is per-species, per-state, per-tick. Zebra active: four per tick, fifteen days without food. Lion torpor: zero per tick, infinite drift."

    sleep 1
    set_zoom 8 30
    speak "The unsolved problem: stable Lotka-Volterra oscillations. We get boom-bust, not limit cycles. Lions go extinct at the trough. The spatial Rosenzweig-MacArthur system with discrete hex topology may require a Type Two functional response — satiation — which we haven't implemented. That's the next stone."

    sleep 2
    set_zoom 3 70
}

# ═══════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════
LEVEL="${1:-all}"

echo "═══════════════════════════════════════"
echo "  SAVANNA NARRATED TOUR"
echo "  Voice: $VOICE"
echo "  Ensure simulation is running!"
echo "═══════════════════════════════════════"
echo ""

case "$LEVEL" in
    1) tour_level1 ;;
    2) tour_level2 ;;
    3) tour_level3 ;;
    all)
        tour_level1
        echo ""
        tour_level2
        echo ""
        tour_level3
        echo ""
        speak "That concludes our tour of the digital Serengeti. One million nodes. Seven colors. Three metabolic states. And one unsolved question: can we make it oscillate?"
        ;;
    *) echo "Usage: bash tour.sh [1|2|3|all]" ;;
esac

echo ""
echo "Tour complete."
