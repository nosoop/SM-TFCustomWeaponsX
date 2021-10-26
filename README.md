# Custom Weapons X

[:coffee: fund my caffeine addiction :coffee:](https://buymeacoff.ee/nosoop)

A new iteration of Custom Weapons.

This was not a sponsored project.

[Discuss this plugin on AlliedModders.](https://forums.alliedmods.net/showthread.php?t=331273)

## Features

Same as previous iterations of Custom Weapons:

- A text-based configuration format for server operators to create new items with.
  - However, the format is different and not completely compatible.
- A (newly localized) menu system for players to build their loadouts.
  - Know any languages?  Please help localize by sending a pull request!  Many of the
  localizations are copied straight from the game files, but there are custom messages that are
  not.
- Support for equipping wearable weapons such as shields and boots.

New to CWX:

- Dropped custom items can be picked up like any other item, and will retain their attributes
(assuming the implementing plugins are written to spec).
- Item exporting.  You can dynamically add / update attributes, then run `sm_cwx_export` to
export your item to a file once it's configured to your liking.
- Weapon persistence.  Custom items will not be dropped or reequipped on resupply, eliminating
a whole class of related bugs and crummy workarounds.

More information is provided in [the project wiki][].

[the project wiki]: https://github.com/nosoop/SM-TFCustomWeaponsX/wiki

## Installation

### Dependencies

The SourceMod plugins / extensions listed below are required for Custom Weapons X to run:

- [Econ Data](https://github.com/nosoop/SM-TFEconData)
  - Requires minimum version 0.18.0.
- [TF2Attributes](https://github.com/nosoop/tf2attributes)
  - Requires the string attributes pre-release!  (1.7.0)
- [TF2 Custom Attributes](https://github.com/nosoop/SM-TFCustAttr)
- [TF2Utils](https://github.com/nosoop/SM-TFUtils)
  - Requires minimum version 0.11.0.
- [DHooks2](https://github.com/peace-maker/DHooks2)

Additional software recommendations that aren't completely necessary:

- The [Attribute Support Fixes][] project, which is a no-configuration project that fixes
  certain attribute interactions.
- [CW3toX][], which may allow attributes written for Custom Weapons 3 to run under this project.

[Attribute Support Fixes]: https://github.com/nosoop/SM-TFAttributeSupport
[CW3toX]: https://github.com/nosoop/SM-TFCW3toX

### Prebuilt Package

This repository is configured to have Github automatically compile the plugin and create a
release whenever commits are pushed.

Download the `package.zip` from [the releases section][] and unpack into your SourceMod
directory.

This plugin can run alongside CW2/3, other than conflicting when weapons are applied.  (As CW2/3
handles their logic later during spawn / resupply, their weapons will be the ones active.)

[the releases section]: https://github.com/nosoop/SM-TFCustomWeaponsX/releases

### Upgrading

If you're upgrading an existing installation, please make sure to make a note of your currently
installed version, then read over the [Upgrade Notes][] section of the wiki to upgrade any
changed dependencies between your current version and the latest.

[Upgrade Notes]: https://github.com/nosoop/SM-TFCustomWeaponsX/wiki/Upgrade-Notes

### Building

This project can be built in a consistent manner with [Ninja](https://ninja-build.org/), `git`,
and Python 3.

1.  Clone the repository and its submodules: `git clone --recurse-submodules ...`
2.  Execute `python3 configure.py --spcomp-dir ${PATH}` within the repo, where `${PATH}` is the
path to the directory containing `spcomp`.  This repository targets 1.10.
3.  Run `ninja`.  Output will be available under `build/`.

(If you'd like to use a similar build system for your project,
[the template project is available here][ninjatemplate].)

[ninjatemplate]: https://github.com/nosoop/NinjaBuild-SMPlugin

## Differences

Core design changes in TF2 necessitated a clean break from previous iterations of
Custom Weapons.  This means that attributes originally written for CW2 ~~or CW3~~ are not
compatible with CWX; they will need to be rewritten.

CWX is also not backwards-compatible with configuration files written for CW2 or CW3.

To keep the responsibilities of the core plugin to a minimum, a number of properties that were
previously integral to CW2 / CW3 are delegated to attribute-implementing plugins in CWX.

This includes:

- killfeed / log name
- weapon model (view / world)
- clip / ammo settings

For implementations of those, see the [Core Attribute Implementations][] page on the project
wiki.

[Core Attribute Implementations]: https://github.com/nosoop/SM-TFCustomWeaponsX/wiki/Core-Attribute-Implementations

## For attribute developers

CWX has no unique format for attributes.  Instead, it has first-class support for the following
systems:

- Native game attributes through [TF2Attributes][].
  - It'd be pretty dumb if you couldn't use built-in attributes.
  - New attribute classes can be injected using a plugin like [Hidden Dev Attributes][], and
  developers can then use `TF2Attrib_HookValue*` to calculate values like any other in-game
  attribute.
- The [Custom Attributes Framework][].
  - These are basically `KeyValues` handles stored as an attribute value under a common
  interface.  "Attributes" can be declared freely without an injection process, speeding up
  development iteration.
  - I'll be referring to these as *CAF-based attributes*.
  - Full disclosure:  I made this.

By implementing your attribute in one of those two formats, they will interoperate with plugins
that support those systems; they are not bound to specifically to CWX.

If you're coming from CW2 or CW3, native / CAF-based attributes are very different (though
native / CAF-based attributes share similarities among themselves).

The main difference is the storage mechanism.  Whereas CW2 / CW3 receive attribute information
through forward functions and store them globally in-plugin, native / CAF-based ones retrieve
the value from entities at runtime and are tied to the game's attribute system.

[TF2Attributes]: https://github.com/nosoop/tf2attributes
[Hidden Dev Attributes]: https://forums.alliedmods.net/showthread.php?t=326853
[Custom Attributes Framework]: https://github.com/nosoop/SM-TFCustAttr
