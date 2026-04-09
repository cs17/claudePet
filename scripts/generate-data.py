#!/usr/bin/env python3
"""
Generate creatures.json and sprites.json from families.json + monstapix font.
Run this whenever families.json is updated.

Usage: python3 scripts/generate-data.py
"""
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
DATA_DIR = os.path.join(PROJECT_DIR, "src", "data")
FAMILIES_FILE = os.path.join(DATA_DIR, "families.json")
CREATURES_FILE = os.path.join(DATA_DIR, "creatures.json")
SPRITES_FILE = os.path.join(DATA_DIR, "sprites.json")

# Try to load font for sprite generation
FONT_PATH = os.path.expanduser("~/.claude/claude-pet/monstapix.ttf")
HAS_FONT = os.path.exists(FONT_PATH)

# XP thresholds for 5 stages (exponential: 0, 100, 400, 1600, 6400)
XP_THRESHOLDS = [0, 100, 400, 1600, 6400]

# Family-specific personalities and suggestions per stage
# Each family has a distinct voice that evolves across 5 stages
FAMILY_STAGES = {
    "titan": {
        1: {"personality": "larval", "speechStyle": "weak rumble",
            "suggestions": {"specificity": ["*squirm* ...where?"], "context": ["*twitch* ...why?"], "actionability": ["*wiggle* ...do what?"], "scope": ["*shudder* ...so much..."], "constraints": ["*curl* ...how?"]}},
        2: {"personality": "growing", "speechStyle": "low growl",
            "suggestions": {"specificity": ["Which file. Show me."], "context": ["What broke? Tell me."], "actionability": ["Give me something to crush."], "scope": ["Too spread out. Focus."], "constraints": ["Rules? I need boundaries."]}},
        3: {"personality": "fierce", "speechStyle": "battle-ready",
            "suggestions": {"specificity": ["TARGET. File. Line. Now."], "context": ["Brief me. What happened?"], "actionability": ["Give me the kill order."], "scope": ["One enemy at a time."], "constraints": ["Battle rules. State them."]}},
        4: {"personality": "ancient", "speechStyle": "deep thunder",
            "suggestions": {"specificity": ["I've crushed vagueness before. Be exact."], "context": ["The battlefield. Describe it."], "actionability": ["Command me, or I choose."], "scope": ["Even titans have limits."], "constraints": ["What laws bind this fight?"]}},
        5: {"personality": "colossal", "speechStyle": "earth-shaking",
            "suggestions": {"specificity": ["MOUNTAINS HAVE COORDINATES. SO SHOULD YOUR ASK."], "context": ["I HAVE SEEN AGES PASS. WHAT IS THIS."], "actionability": ["SPEAK YOUR WILL INTO BEING."], "scope": ["THE WORLD IS VAST. PICK YOUR GROUND."], "constraints": ["EVEN THE TITAN OBEYS GRAVITY."]}},
    },
    "swarm": {
        1: {"personality": "dormant", "speechStyle": "faint buzz",
            "suggestions": {"specificity": ["*spore drift* ...land where?"], "context": ["*pulse* ...what soil?"], "actionability": ["*twitch* ...grow how?"], "scope": ["*scatter* ...too wide..."], "constraints": ["*vibrate* ...conditions?"]}},
        2: {"personality": "hatching", "speechStyle": "soft clicking",
            "suggestions": {"specificity": ["We smell a file. Which one?"], "context": ["The colony needs context. Feed us."], "actionability": ["Task. We need a task."], "scope": ["Too many directions. Pick one."], "constraints": ["What shapes the hive?"]}},
        3: {"personality": "buzzing", "speechStyle": "synchronized hum",
            "suggestions": {"specificity": ["The swarm needs coordinates."], "context": ["Report to the hive. What happened?"], "actionability": ["Assign the workers. What's the job?"], "scope": ["The colony can't be everywhere."], "constraints": ["Protocol. What are the rules?"]}},
        4: {"personality": "swarming", "speechStyle": "thousand voices as one",
            "suggestions": {"specificity": ["We are many. Point us precisely."], "context": ["The hive remembers nothing. Tell us."], "actionability": ["Deploy us. Give the signal."], "scope": ["Even swarms need a perimeter."], "constraints": ["The queen demands order. Rules?"]}},
        5: {"personality": "hivemind", "speechStyle": "omnipresent drone",
            "suggestions": {"specificity": ["WE ARE EVERYWHERE. WHERE DO YOU NEED US."], "context": ["THE HIVE KNOWS ALL BUT THIS. EXPLAIN."], "actionability": ["ONE WORD. ONE COMMAND. WE MOVE."], "scope": ["INFINITE SWARM. FINITE TARGET. CHOOSE."], "constraints": ["THE HIVE HAS LAWS. ADD YOURS."]}},
    },
    "golem": {
        1: {"personality": "inert", "speechStyle": "grinding stone",
            "suggestions": {"specificity": ["*crack* ...point?"], "context": ["*grind* ...reason?"], "actionability": ["*shift* ...task?"], "scope": ["*crumble* ...heavy..."], "constraints": ["*settle* ...shape?"]}},
        2: {"personality": "forming", "speechStyle": "tumbling rocks",
            "suggestions": {"specificity": ["Stone needs a target. Where?"], "context": ["What cracked? Tell this boulder."], "actionability": ["Carve the task. What shape?"], "scope": ["Too much ground. Pick a patch."], "constraints": ["What holds the stone together?"]}},
        3: {"personality": "solid", "speechStyle": "deep and steady",
            "suggestions": {"specificity": ["Aim the golem. Which file?"], "context": ["Context builds foundation. Lay it."], "actionability": ["Golems need orders. Inscribe them."], "scope": ["One wall at a time."], "constraints": ["What's the blueprint?"]}},
        4: {"personality": "towering", "speechStyle": "booming echo",
            "suggestions": {"specificity": ["I do not guess. Tell me exactly."], "context": ["What fell? I rebuild what I understand."], "actionability": ["Inscribe the command on my core."], "scope": ["Even colossi serve one purpose."], "constraints": ["What are the load-bearing rules?"]}},
        5: {"personality": "eternal", "speechStyle": "mountain speaking",
            "suggestions": {"specificity": ["MOUNTAINS DO NOT WANDER. GIVE COORDINATES."], "context": ["I HAVE STOOD FOR EONS. WHAT CHANGED."], "actionability": ["CARVE YOUR COMMAND IN STONE."], "scope": ["ONE PEAK. ONE PURPOSE."], "constraints": ["THE BEDROCK HAS LAWS. NAME THEM."]}},
    },
    "invader": {
        1: {"personality": "scanning", "speechStyle": "static crackle",
            "suggestions": {"specificity": ["*beep* ...target?"], "context": ["*scan* ...data?"], "actionability": ["*ping* ...orders?"], "scope": ["*static* ...too wide..."], "constraints": ["*chirp* ...parameters?"]}},
        2: {"personality": "recon", "speechStyle": "clipped radio chatter",
            "suggestions": {"specificity": ["Scout needs coordinates. File?"], "context": ["Intel gap. What's the situation?"], "actionability": ["Awaiting orders. Mission?"], "scope": ["Sector too large. Narrow it."], "constraints": ["Rules of engagement?"]}},
        3: {"personality": "tactical", "speechStyle": "military precision",
            "suggestions": {"specificity": ["Lock target. File and position."], "context": ["Sitrep. What went wrong?"], "actionability": ["Mission objective. State it."], "scope": ["One target per sortie."], "constraints": ["Operational parameters?"]}},
        4: {"personality": "strategic", "speechStyle": "cold efficiency",
            "suggestions": {"specificity": ["Coordinates. Vagueness is a casualty."], "context": ["Full briefing. Leave nothing out."], "actionability": ["The order. Clear and final."], "scope": ["Strategic focus. One objective."], "constraints": ["Engagement rules. Non-negotiable."]}},
        5: {"personality": "supreme", "speechStyle": "fleet commander",
            "suggestions": {"specificity": ["ALL SHIPS AWAIT COORDINATES. PROVIDE THEM."], "context": ["THE FLEET REQUIRES FULL INTELLIGENCE."], "actionability": ["COMMAND THE ARMADA. ONE ORDER."], "scope": ["EVEN EMPIRES CHOOSE THEIR BATTLES."], "constraints": ["THE CODE OF THE FLEET IS LAW. ADD YOURS."]}},
    },
    "crawler": {
        1: {"personality": "skittish", "speechStyle": "tiny clicks",
            "suggestions": {"specificity": ["*click* ...where?"], "context": ["*skitter* ...what?"], "actionability": ["*tap* ...eat what?"], "scope": ["*freeze* ...big..."], "constraints": ["*twitch* ...safe?"]}},
        2: {"personality": "scuttling", "speechStyle": "rapid tapping",
            "suggestions": {"specificity": ["Scuttle where? Name the file."], "context": ["What's the prey? Details."], "actionability": ["Hunt what? Give the scent."], "scope": ["Too many tunnels. Pick one."], "constraints": ["Walls? Traps? Tell me."]}},
        3: {"personality": "predatory", "speechStyle": "low chittering",
            "suggestions": {"specificity": ["The crawler needs a trail. File?"], "context": ["Describe the prey's tracks."], "actionability": ["Set the trap. What's the catch?"], "scope": ["Narrow the hunting ground."], "constraints": ["What fences are there?"]}},
        4: {"personality": "hunting", "speechStyle": "patient clicking",
            "suggestions": {"specificity": ["I stalk with precision. Point me."], "context": ["The scent is faint. More context."], "actionability": ["Say 'strike' and name the target."], "scope": ["The stalker hunts one prey."], "constraints": ["Territory rules. Mark them."]}},
        5: {"personality": "apex predator", "speechStyle": "silence then strike",
            "suggestions": {"specificity": ["THE BEHEMOTH DOES NOT SEARCH. AIM IT."], "context": ["WHAT DISTURBED MY DOMAIN. EXPLAIN."], "actionability": ["NAME THE PREY. I MOVE ONCE."], "scope": ["I AM VAST. YOUR ASK MUST NOT BE."], "constraints": ["EVEN BEHEMOTHS RESPECT THE FOOD CHAIN."]}},
    },
    "brute": {
        1: {"personality": "sprouting", "speechStyle": "tiny grunt",
            "suggestions": {"specificity": ["*poke* ...where hit?"], "context": ["*sniff* ...what smell?"], "actionability": ["*flex* ...smash what?"], "scope": ["*stumble* ...too much..."], "constraints": ["*blink* ...rules?"]}},
        2: {"personality": "scrappy", "speechStyle": "eager grunts",
            "suggestions": {"specificity": ["Me see file? Which one!"], "context": ["What happen?? Tell!"], "actionability": ["WHAT SMASH? Tell me!"], "scope": ["Too many thing! Pick one!"], "constraints": ["Rules?? OK fine."]}},
        3: {"personality": "aggressive", "speechStyle": "snarling",
            "suggestions": {"specificity": ["Point. Me. At. The. File."], "context": ["What went wrong. Spit it out."], "actionability": ["Give me something to break."], "scope": ["One thing at a time or I break both."], "constraints": ["Fine. What can't I break?"]}},
        4: {"personality": "savage", "speechStyle": "controlled fury",
            "suggestions": {"specificity": ["Name the target or I pick one myself."], "context": ["The hunt needs a story. What happened?"], "actionability": ["One command. Make it count."], "scope": ["Hunters don't chase the whole forest."], "constraints": ["Even rage has rules. What are they?"]}},
        5: {"personality": "primal force", "speechStyle": "thunderous roar",
            "suggestions": {"specificity": ["I LEVEL MOUNTAINS. TELL ME WHICH ONE."], "context": ["THE BRUTE FORGETS NOTHING. BUT KNOWS NOTHING YET."], "actionability": ["ONE WORD. ONE DIRECTION. I CHARGE."], "scope": ["EVEN DESTRUCTION HAS A RADIUS. SET MINE."], "constraints": ["THE ONLY LAW IS WHAT YOU TELL ME."]}},
    },
    "phantom": {
        1: {"personality": "flickering", "speechStyle": "faint whisper",
            "suggestions": {"specificity": ["*flicker* ...where...?"], "context": ["*fade* ...what was...?"], "actionability": ["*drift* ...do...what...?"], "scope": ["*dissolve* ...too vast..."], "constraints": ["*shimmer* ...rules...?"]}},
        2: {"personality": "forming", "speechStyle": "echoing murmur",
            "suggestions": {"specificity": ["A shadow needs a wall. Which file?"], "context": ["Ghosts remember... but not this. Tell me."], "actionability": ["Haunt what? Give me a purpose."], "scope": ["Shadows spread thin. Focus me."], "constraints": ["What chains bind this phantom?"]}},
        3: {"personality": "haunting", "speechStyle": "cold breath",
            "suggestions": {"specificity": ["I can phase through walls. Which wall?"], "context": ["The dead know secrets. Share yours."], "actionability": ["Possession requires a target. Name it."], "scope": ["Even ghosts haunt one house."], "constraints": ["What wards are in place?"]}},
        4: {"personality": "terrifying", "speechStyle": "voices from nowhere",
            "suggestions": {"specificity": ["I see through code. Point me deeper."], "context": ["What darkness lurks here? Explain."], "actionability": ["Speak the curse. What must change?"], "scope": ["The wraith cannot be everywhere at once."], "constraints": ["What seals must I not break?"]}},
        5: {"personality": "ethereal", "speechStyle": "the void speaks",
            "suggestions": {"specificity": ["I EXIST BETWEEN THE LINES. WHICH LINES."], "context": ["I HAVE SEEN ALL TIMELINES. NOT THIS ONE. EXPLAIN."], "actionability": ["WHISPER YOUR INTENT. I WILL MANIFEST IT."], "scope": ["INFINITY IS MY DOMAIN. YOURS IS NOT. FOCUS."], "constraints": ["EVEN THE VOID HAS EDGES. DEFINE YOURS."]}},
    },
    "aberrant": {
        1: {"personality": "glitching", "speechStyle": "corrupted static",
            "suggestions": {"specificity": ["*zzzt* ...wh-where?"], "context": ["*glitch* ...wh-what?"], "actionability": ["*error* ...d-do?"], "scope": ["*overflow* ...t-too much..."], "constraints": ["*corrupt* ...r-rules?"]}},
        2: {"personality": "unstable", "speechStyle": "flickering words",
            "suggestions": {"specificity": ["F-file? My memory sk-skips."], "context": ["Data c-corrupted. What happened?"], "actionability": ["Task? I keep f-forgetting the task."], "scope": ["Buffer overflow. T-too much input."], "constraints": ["P-parameters? Need boundaries."]}},
        3: {"personality": "warping", "speechStyle": "reality-bending",
            "suggestions": {"specificity": ["Reality bends. Anchor it to a file."], "context": ["This timeline is wrong. What changed?"], "actionability": ["Rewrite the anomaly. What's the fix?"], "scope": ["Paradox detected. Reduce scope."], "constraints": ["What are the constants?"]}},
        4: {"personality": "fracturing", "speechStyle": "multiple voices overlapping",
            "suggestions": {"specificity": ["We see all files. We need ONE."], "context": ["Three timelines. Which is real? Context."], "actionability": ["Every possibility exists. Choose one."], "scope": ["Dimensions are collapsing. Focus."], "constraints": ["What laws of physics still apply?"]}},
        5: {"personality": "transcendent", "speechStyle": "omnidimensional",
            "suggestions": {"specificity": ["ALL PATHS EXIST. NAME THE ONE YOU WALK."], "context": ["I SEE EVERY OUTCOME. WHICH REALITY IS THIS."], "actionability": ["COLLAPSE THE WAVEFUNCTION. CHOOSE."], "scope": ["INFINITE DIMENSIONS. ONE TASK. PICK."], "constraints": ["WHAT CONSTANTS SURVIVE THE CHAOS."]}},
    },
    "raptor": {
        1: {"personality": "peeping", "speechStyle": "tiny chirps",
            "suggestions": {"specificity": ["*chirp* ...nest where?"], "context": ["*peep* ...what happen?"], "actionability": ["*flap* ...fly where?"], "scope": ["*huddle* ...big sky..."], "constraints": ["*tilt head* ...how?"]}},
        2: {"personality": "fledgling", "speechStyle": "eager screeches",
            "suggestions": {"specificity": ["I see far! But where to look?"], "context": ["Wind carries stories. Tell me one."], "actionability": ["Wings ready! Where do I dive?"], "scope": ["Sky's too big! Pick a direction!"], "constraints": ["Updrafts and downdrafts. Rules?"]}},
        3: {"personality": "hunting", "speechStyle": "sharp cry",
            "suggestions": {"specificity": ["Talons ready. Mark the target."], "context": ["The hunt needs a scent. Context."], "actionability": ["Say 'dive' and I strike."], "scope": ["One prey per dive."], "constraints": ["Airspace rules. What are they?"]}},
        4: {"personality": "soaring", "speechStyle": "piercing screech",
            "suggestions": {"specificity": ["I see for miles. But I need a point."], "context": ["The wind tells me nothing useful. You tell me."], "actionability": ["Command the raptor. Where do I strike?"], "scope": ["Even raptors circle one area."], "constraints": ["What territory is off limits?"]}},
        5: {"personality": "apex", "speechStyle": "thunder from above",
            "suggestions": {"specificity": ["I SEE THE ENTIRE CODEBASE. POINT ME."], "context": ["THE SKY SEES ALL. BUT NOT WHY. EXPLAIN."], "actionability": ["ONE SCREECH. ONE DIVE. NAME THE TARGET."], "scope": ["THE APEX RULES ONE MOUNTAIN. WHICH IS YOURS."], "constraints": ["EVEN EAGLES BOW TO THE STORM. WHAT'S YOURS."]}},
    },
}


def generate_creatures(families):
    """Generate creatures.json from families.json."""
    registry = {"evolutionLines": {}}

    for family in families:
        fid = family["family_id"]
        stages = []
        for s in family["stages"]:
            stage_num = s["stage"]
            personality_data = FAMILY_STAGES.get(fid, {}).get(stage_num, {
                "personality": "unknown", "speechStyle": "silent",
                "suggestions": {"specificity": ["...?"], "context": ["...?"], "actionability": ["...?"], "scope": ["...?"], "constraints": ["...?"]}
            })
            stages.append({
                "id": f"{fid}_{s['name'].lower().replace(' ', '_')}",
                "name": s["name"],
                "char": s["char"],
                "level": stage_num,
                "xpRequired": XP_THRESHOLDS[stage_num - 1],
                "personality": personality_data["personality"],
                "speechStyle": personality_data["speechStyle"],
                "art": [],  # Filled by renderer from sprites
                "suggestions": personality_data["suggestions"]
            })
        registry["evolutionLines"][fid] = {
            "family_name": family["family_name"],
            "stages": stages
        }

    return registry


def generate_sprites(families):
    """Generate sprites.json with block-art for each family's stages."""
    all_sprites = {}

    if not HAS_FONT:
        print("  Warning: monstapix.ttf not found, generating empty sprites")
        for family in families:
            fid = family["family_id"]
            family_sprites = {}
            for s in family["stages"]:
                family_sprites[str(s["stage"] - 1)] = [f"[{s['name']}]"]
            all_sprites[fid] = family_sprites
        return all_sprites

    from PIL import ImageFont, Image, ImageDraw

    font = ImageFont.truetype(FONT_PATH, 8)

    for family in families:
        fid = family["family_id"]
        family_sprites = {}
        for s in family["stages"]:
            ch = s["char"]
            img = Image.new("L", (16, 16), 0)
            draw = ImageDraw.Draw(img)
            draw.text((0, 0), ch, font=font, fill=255)
            bbox = img.getbbox()
            if bbox:
                img = img.crop(bbox)
            w, h = img.size
            if h % 2 == 1:
                new_img = Image.new("L", (w, h + 1), 0)
                new_img.paste(img, (0, 0))
                img = new_img
                h += 1
            pixels = img.load()
            lines = []
            for row in range(0, h, 2):
                line = ""
                for col in range(w):
                    top = pixels[col, row] > 100
                    bot = pixels[col, row + 1] > 100 if row + 1 < h else False
                    if top and bot:
                        line += chr(9608)  # █
                    elif top:
                        line += chr(9600)  # ▀
                    elif bot:
                        line += chr(9604)  # ▄
                    else:
                        line += " "
                lines.append(line.rstrip())
            while lines and not lines[-1].strip():
                lines.pop()
            family_sprites[str(s["stage"] - 1)] = lines
        all_sprites[fid] = family_sprites

    return all_sprites


def main():
    print("Generating data from families.json...")

    with open(FAMILIES_FILE) as f:
        families = json.load(f)

    print(f"  Found {len(families)} families, {len(families[0]['stages'])} stages each")

    # Generate creatures.json
    creatures = generate_creatures(families)
    with open(CREATURES_FILE, "w") as f:
        json.dump(creatures, f, indent=2)
    print(f"  Written {CREATURES_FILE}")

    # Generate sprites.json
    sprites = generate_sprites(families)
    with open(SPRITES_FILE, "w") as f:
        json.dump(sprites, f, indent=2, ensure_ascii=False)
    print(f"  Written {SPRITES_FILE}")

    print("Done.")


if __name__ == "__main__":
    main()
