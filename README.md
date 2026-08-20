# speclist (fork)

Shows you who is currently spectating you, as a HUD list. This is my fork of
**Spectator-List** by MandoCSGO, rewritten to stop it flickering and to let players move it
where they want.

Upstream is 210 lines, this is 509, so most of it is new.

## Install

Drop the `addons` folder into your `csgo` folder:

```
addons/sourcemod/plugins/speclist.smx        the compiled plugin
addons/sourcemod/scripting/speclist.sp       source
```

No config files. Convars land in `cfg/sourcemod/speclist.cfg` on first run.

## The flicker, which is why I touched it

This was the whole reason for the fork, and it had two separate causes.

**Cause one: the channel.** The old build passed channel `-1` to the HUD message, which tells
the engine to pick the next free channel on every send. So consecutive updates landed on
different channels and drew over each other. Hard-coding a channel would fix that, but then
you are fighting every other HUD plugin for the six channels that exist.

The right answer is a **synchronizer**: SourceMod hands this plugin a stable channel per
client and arbitrates against everyone else who asks for one. MHUD uses three of them the same
way.

**Cause two: redrawing too slowly.** Replacing a HUD message blanks its channel for a frame.
So redrawing once a second produces a visible strobe once a second, and making the refresh
*slower* made it more obvious, not less.

The fix is splitting the work: the spectator list is **rebuilt** on the interval, but
**drawn** every frame. Building the list is the expensive half, drawing is cheap, and drawing
every tick is exactly why MHUD looks solid.

There is a related detail. A HudMsg is an unreliable usermessage, so on a full server the
entity snapshot already eats most of the datagram and messages get dropped. The 0.5s hold only
has to be refreshed before it expires, and refreshing at 0.2s leaves two whole dropped sends
of margin, so a drop heals itself before the text can disappear.

## Other bugs I fixed

**Player names containing `%`** were being parsed as format specifiers, because the old build
passed the built string directly instead of through `"%s"`.

**SourcePawn's `Format` has no `+` flag.** `%+.2f` gets emitted almost literally, which is
where the menu's garbled `+.2f` title came from. A negative number already prints its own
sign, so only the plus needed adding by hand.

**Names are truncated on a UTF-8 boundary**, backing off a byte at a time, so a multi-byte
character never gets cut in half and left as a broken glyph.

**One timer for the whole server** instead of one per client. The old build ran `MaxClients`
timers at 10 Hz whether or not anybody was spectating.

**Preferences save properly now.** Defaults are seeded when cookies are cached, not in
`OnClientPutInServer`, because clientprefs loads cookies off client authorization and can land
first. Resetting in the wrong place wiped the freshly loaded preferences and blocked every
later save for that session, which is why a toggle never stuck.

## What I added

A preferences menu: position, color, and X/Y offsets, saved per player. While the menu is
open it draws a sample list even when nobody is watching you, otherwise you cannot judge what
you are adjusting.

All five settings go in one cookie rather than five, since five cookies means five handles and
five round trips for no benefit.

## Credits

Original **Spectator-List** by **MandoCSGO**:
[github.com/MandoCSGO/Spectator-List](https://github.com/MandoCSGO/Spectator-List)

## License

GPL-3.0, see `LICENSE`.
