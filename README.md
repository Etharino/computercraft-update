# ComputerCraft Pocket Radio

Chat-style radio for CC:Tweaked Advanced Ender Pocket Computers with Ender Modem upgrades.

## Install

Copy `radio.lua` and `radio_config.lua` onto every pocket computer that should join the radio.

If you are typing it in-game, paste each file into an `edit` session:

```lua
edit radio
edit radio_config.lua
```

## Configure Frequencies

Edit `radio_config.lua`:

```lua
return {
  frequencies = { 101, 102, 103 },
  defaultFrequency = 101,
  name = nil,
  maxMessageLength = 180,
}
```

Only listed frequencies can be used. Anything sent on a different modem channel is ignored.

## Run

```lua
radio
```

## Commands

- `/freq 101` tunes to an allowed frequency.
- `/list` shows allowed frequencies.
- `/name Alex` changes your chat name for this session.
- `/clear` clears the screen.
- `/quit` exits.

Normal text sends a message on the current frequency and appears like Minecraft chat:

```text
<Alex> meet at base
<Sam> on my way
```
