# Better Damage Text

**See exactly what hit.** Better Damage Text replaces the default floating damage numbers on enemies with its own, and puts the icon of the spell that caused each hit right next to the number. Heroic Strike, Earth Shock, Flametongue procs, Lightning Shield zaps and DoT ticks each show their own icon.

Built for **World of Warcraft: Forever**.

## Features

- **Spell icon next to every number.** Works with any class and any spell you cast, with no setup.
- **Procs and passive damage are recognised too:**
  - **Weapon enchants:** Flametongue, Frostbrand, Instant Poison.
  - **Damage shields:** Lightning Shield, Thorns, Fire Shield, Retribution Aura.
  - **Damage over time:** ticks get the icon of the spell that applied them.
  - **Channelled spells.**
- **Only your damage.** Other players' and pets' hits on your target are filtered out.
- **Blizzard-style crits:** they pop in big and settle at a larger size.
- **No overlapping:** new numbers push older ones up.
- **Misses, dodges, parries and partial hits:** "Miss", "Parry", "(blocked)", "(glancing)" and so on.
- **White melee hits** are shown in white, spells and procs in yellow. Both colours can be changed.

## Settings

Type **/bdt**, or go to **Options → AddOns → Better Damage Text**.

| Section | Settings |
|---|---|
| **Text** | Font (including the game's bold fonts, or your own `.ttf`), outline, drop shadow, font size, crit size, crit "pop" size |
| **Icon** | Show or hide, icon on white hits on or off, left or right of the number, size |
| **Animation** | Time on screen, float distance |
| **Colours** | Melee colour, spell colour |
| **Show** | Misses and dodges, partial-hit labels, only my hits, instant mode, hide Blizzard's numbers |

Changes save automatically, and each one shows a short preview.

### Using your own font

1. Put a `.ttf` file in `Interface\AddOns\BetterDamageText\Fonts\`.
2. Fully restart the game.
3. Type the file name in **"Your own font"** in `/bdt`, then press **Use**.

Any fonts shared by other addons through LibSharedMedia also appear in the font list.

## Commands

| Command | What it does |
|---|---|
| `/bdt` | Open the settings window |
| `/bdt test` | Show some sample hits |
| `/bdt mine on` / `off` | Only show your own hits |
| `/bdt blizzard` | Turn Blizzard's own damage numbers on or off |
| `/bdt debug` | Print every hit and why it was shown or hidden |
| `/bdt record` | Save that output to disk, for bug reports |

## How it works

WoW: Forever doesn't let addons read the combat log, so no addon can be told directly "spell X hit for Y". Better Damage Text works it out from what addons *can* see:
- the damage each mob takes, and its damage type
- the spells you cast, and the damage type and duration in each spell's description
- the steady 3-second rhythm of DoT ticks
- your weapon enchants and shield buffs
- your threat on your target, which only rises from your own damage

## Known limitations

- **English game client only, for now.** Spell and buff names are matched in English.
- **Other mobs:** threat can only be read on your current target. On other mobs, other players' hits are filtered by timing, which is less exact.
- **Instant mode:** another player's hit that looks exactly like one of yours can occasionally show, e.g. a fire spell landing while you auto-attack with Flametongue. Turn off **Instant** for strict filtering, with a short delay.
- **Off-hand swings** show the main-hand weapon icon.
- **No exact blocked or resisted amounts.** The game doesn't give addons those numbers, so partial hits show "(blocked)" without the amount.
- **Melee numbers appear just after the swing,** because the game reports melee hits late to match the swing animation. Blizzard's own numbers did the same.

## Bug reports

Please include:
1. What you expected and what you saw.
2. A recording: type `/bdt record`, reproduce the problem, type `/bdt record` again, then `/reload`.
3. The log file: `WTF\Account\<your account>\SavedVariables\BetterDamageText.lua`.
