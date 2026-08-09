# Aura

A native macOS menu-bar app for the Sony WH-1000XM5 — noise cancelling, ambient
sound, equalizer, and one-tap Modes, without reaching for your phone.

No Sony account. No daemon. No Electron. ~1,900 lines of Swift, zero
dependencies, talking to the headphones directly over Bluetooth in the same
protocol Sony's own app speaks.

<br>

## Why this exists

Sony makes a perfectly good app. It runs on your phone.

So every time you want to switch from noise cancelling to ambient — while
already sitting at your Mac, wearing the headphones, with both hands on the
keyboard — you pick up a different device to change a setting on the thing
attached to your head.

There are excellent community clients for this. I tried them first. **None of
them work on the XM5**, and the reason turned out to be interesting enough to
write down.

<br>

## The part where nothing worked

The obvious starting point is [`Plutoberth/SonyHeadphonesClient`][plutoberth] —
306 stars, cross-platform, exactly the right idea. It was **archived in July
2025** and never supported the XM5.

The next lead was [`tanat/sony-connect-osx`][tanat]: a compact, well-built Swift
menu-bar app that lists `WH-1000XM5` right there in its device hints. I built it.
It found the headphones, connected to Bluetooth, located Sony's control service —
and then died:

```
[bt] Sony service UUID not found in cached SDP records
[bt] status -> failed(reason: "Sony service UUID not advertised by device")
```

It could see a service literally named **`Serial HPC`** sitting on RFCOMM channel
9 and refused to open it, because it was looking for a different UUID. The author
clearly never had an XM5 to test against.

So: dump every SDP record the headphones advertise and look.

```
• Serial HPC  rfcomm=9
     UUID 956C7B26-D49A-4BA8-B03F-B17D393CB6E2
```

That's the **V2** protocol UUID. Every macOS client in existence looks for
`96CC203E-5068-46AD-B32D-E316F5E069BA` — **V1**. One hex string apart in
spirit, completely incompatible in practice.

That was the whole wall. Everything after it was just work.

<br>

## Talking to it

The wire format is shared between V1 and V2, and it's pleasant:

```
0x3E │ escaped( type, seq, len[4] BE, payload, checksum ) │ 0x3C
```

Checksum is a plain byte sum. Any `0x3C`/`0x3D`/`0x3E` inside the body gets
escaped as `0x3D` followed by `byte & 0xEF`. Every inbound frame wants an ACK.

Open channel 9, send `00 00`, and the headphones say hello back:

```
>> INIT:  00 00
   RX  type=0x0C  01 00 03 00 20 16 00 00
>> BATTERY GET:  22 00
   RX  type=0x0C  23 00 56 00        ← 0x56 = 86%
>> ANC GET:  66 17
   RX  type=0x0C  67 17 01 01 00 00 14   ← noise cancelling, on
```

First contact. From here it's just finding out which numbers mean what.

<br>

## Four things the internet got wrong

Every one of these was found by **writing a value and reading it back**, which is
the only honest way to do this. Four times it disagreed with the documentation.

### 1. The equalizer isn't where the docs say

Reference implementations put the EQ on feature table `0x03`. On the XM5, `56 03`
returns *nothing at all* — no error, no reply, silence. The EQ is on table
**`0x00`**:

```
>> 56 00
   57 00 A0 06 0A 0A 0A 0A 0A 0A     ← preset 0xA0 (Custom), six bands, all flat
```

### 2. Ambient level silently ignores you

The documented SET body for ambient sound is 8 bytes, with a `0x02` before the
level. The XM5 accepts it, ACKs it, and **pins the level to 1 forever**.

| Form | Wrote 20 | Device reports |
|---|---|---|
| `68 17 01 01 01 02 00 14` (documented) | 20 | **1** |
| `68 17 01 01 01 00 14` (7 bytes) | 20 | **20** ✅ |

The SET body has to mirror the GET reply exactly. If I'd trusted the write
instead of reading it back, the ambient slider would have been decorative.

Also: the range is **1–20, not 0–20**. Writing 0 clamps to 1.

### 3. The band order is backwards

I labelled the six EQ bands `400 / 1k / 2.5k / 6.3k / 16k / Bass`, on the
reasonable assumption that Clear Bass — a separate low shelf, not one of the
graphic bands — goes last.

It goes **first**. And I didn't settle that by ear, I asked the headphones. Sony
ships named presets; read back what they contain:

| Preset | Reported bands | What it tells you |
|---|---|---|
| `0x16` "Bass" | `[17,10,10,10,10,10]` | only index 0 moves |
| `0x15` "Treble" | `[10,10,10,12,16,20]` | rises toward index 5 |
| `0x17` "Speech" | `[0,14,13,11,12,0]` | kills both ends, boosts the middle |

Unambiguous: `[Clear Bass, 400, 1k, 2.5k, 6.3k, 16k]`, ascending. Every EQ curve
in the app had been mirrored, and the device told me so in three queries.

### 4. Two settings that were the wrong settings entirely

This one's the good one.

Gadgetbridge's V1 mapping says `E6 02` is audio upsampling and `F6 05` is
Speak-to-Chat. I wired both up. Both wrote cleanly. Both read back correctly.
Verification: **10/11 passed.**

Then I found the generated V2 enum in [`mos9527/SonyHeadphonesClient`][mos9527]
and discovered the sub-types don't carry over from V1 at all:

- `E6 02` is `CONNECTION_MODE_WITH_LDAC_STATUS` — the Bluetooth
  quality-vs-stability trade-off. Upscaling is sub-type **`0x01`**.
- `F6 05` is `VOICE_ASSISTANT_WAKE_WORD`. Speak-to-Chat is `SMART_TALKING_MODE`,
  sub-type `0x02` or `0x0C`.

My "DSEE Extreme" toggle had been changing the codec negotiation mode. My
"Speak-to-Chat" toggle had been turning the voice assistant wake word on and off.

**Read-back proves the write landed. It does not prove it landed on the right
setting.** Both are fixed; Speak-to-Chat was pulled entirely rather than shipped
on a guess, because `0x02` and `0x0C` both exist, both read `01 01`, and both are
writable — the wire can't tell me which is real.

<br>

## Cracking the rest of it

The last piece was realising the opcode space is completely regular. Every
subsystem owns a block of `0x10`:

```
+0/+1  GET/RET_CAPABILITY
+2/+3/+4/+5  GET/RET/SET/NTFY_STATUS
+6/+7/+8/+9  GET/RET/SET/NTFY_PARAM
```

Which is why `x6/x7/x8` kept showing up everywhere — those are *always*
`GET/RET/SET_PARAM`.

| | | | |
|---|---|---|---|
| `0x00` CONNECT | `0x40` LEA (LE Audio) | `0x80` OPT | `0xC0` LOG |
| `0x10` COMMON | `0x50` EQEBB | `0x90` ALERT | `0xD0` GENERAL_SETTING |
| `0x20` POWER | `0x60` NCASM | `0xA0` PLAY | `0xE0` AUDIO |
| `0x30` UPDT | `0x70` SENSE | `0xB0` SAR_AUTO_PLAY | `0xF0` SYSTEM |

`0x46` was never "sound position" as the V1 docs claim — it's **LE Audio**.

<br>

## Verified commands

Everything below was confirmed against a real WH-1000XM5 on firmware 2.4.1, by
writing, reading back, and restoring. `Tools/verify.swift` is the harness:
**23 passed, 0 failed.**

| Purpose | Request | Reply |
|---|---|---|
| Handshake | `00 00` | `01 00 …` |
| Battery | `22 00` | `23 00 <level> <charging>` |
| Ambient / ANC | `66 17` | `67 17 01 <en> <amb> <voice> <level>` |
| Set ambient | `68 17 01 <en> <amb> <voice> <level>` | — |
| Equalizer | `56 00` | `57 00 <preset> <count> <b1…b6>` |
| Set equalizer | `58 00 <preset> 06 <b1…b6>` | — |
| Volume | `A6 20` | `A7 20 <0…30>` |
| DSEE upscaling | `E6 01` | `E7 01 <on>` |
| Auto power-off | `26 05` | `27 05 <c0> <c1>` |

Auto power-off is worth a note: the XM5 **dropped timed shutoff**. Its
predecessors accepted 5 min / 30 min / 1 h / 3 h; the XM5 takes those codes,
ACKs them, and ignores them. Only `10 00` (when taken off) and `11 00` (off)
actually apply — wearing detection replaced the timers.

Unsolicited notifications arrive on the odd twins (`0x25` battery, `0x69` ANC,
`0x59` EQ), which is how the UI stays honest when you press the physical button
or change something in Sony's app.

<br>

## What it does

- **Modes** — one tap sets ambient behaviour *and* a tuned EQ curve together.
  Meeting, Focus, Commute, Music, Outdoors, plus your own: adjust anything and a
  *Save Current* affordance appears.
- **Ambient Sound** — NC / Off / Ambient, 1–20 level, Focus on Voice.
- **Equalizer** — six bands with a centre detent, in the correct order.
- **Playback** — volume, DSEE Extreme, power-off-when-removed.
- **Microphone** — level and mute for the headset input.
- **Alerts** — connect, disconnect, battery thresholds, charging, full. All
  edge-triggered, so a battery sitting at 30% notifies once, not every minute.
- **Connects itself** — watches for the headphones and attaches when they return.
- **Launch at Login** via `SMAppService`.

The device is always the source of truth. Every setter writes, then re-reads.

### About the microphone

The XM5 exposes **no microphone gain** — Sony's app doesn't offer one either, and
nothing in the feature tables reports one. Aura adjusts the input gain macOS
applies to the headset via CoreAudio, which is the level that actually reaches
your calls. The section appears only while something is using the mic; Bluetooth
stays in playback-only mode until then.

<br>

## Download

Grab `Aura-1.0.zip` from [Releases][releases], unzip, drag **Aura.app** to
Applications. It lives in the menu bar — no Dock icon, that's `LSUIElement`
doing its job.

**macOS will refuse to open it the first time.** The app is ad-hoc signed, not
notarized — I don't pay Apple $99/year for this. Gatekeeper flags anything
downloaded without a Developer ID, so:

```sh
xattr -dr com.apple.quarantine /Applications/Aura.app
```

Then open it normally. (Right-click → Open works too, on some macOS versions.)
If that makes you uncomfortable — reasonably — build from source instead, it
takes about thirty seconds.

macOS asks for Bluetooth permission on first launch. Approve it once.

<br>

## Build

```sh
make install     # build, bundle, sign, install to /Applications
make run         # …and launch it
make dist        # produce dist/Aura-<version>.zip
make uninstall
```

Needs macOS 14+, Xcode Command Line Tools, and the headphones already paired.

The app **must** run from a signed `.app` bundle — a bare binary is killed by TCC
the moment it touches IOBluetooth, because the usage description is read from the
bundle's `Info.plist`. The `Makefile` handles it.

> Ad-hoc signing derives identity from the binary, so every rebuild looks like a
> new app to macOS and the Bluetooth grant is re-evaluated. If a fresh build comes
> up with no `[link]` lines in the log, quit and reopen once.

<br>

## Poking at it yourself

```sh
Tools/verify.swift    # 23-check protocol suite, restores state afterwards
Tools/verify2.swift   # device settings: power-off, DSEE, volume
Tools/scan2.swift     # sweeps every GET opcode and dumps what answers
Tools/probe3.swift    # narrows sub-types within a subsystem
```

They discover the headset by name, and take a name fragment as `argv[1]` if you
have several paired. Quit Aura first — there's only one control channel.

`~/Library/Logs/Aura.log` records every frame both directions:

```
[link] connected("WH-1000XM5")
[tx] 66 17
[rx] 67 17 01 01 00 00 14
```

<br>

## Still unmapped

Honest list. These respond, and nothing writes to them:

| GET | Reply | Guess |
|---|---|---|
| `FA 02` / `03` / `06` | `FB 03 01 35 01 00 02` | Speak-to-Chat sensitivity / timeout |
| `F6 01`–`0E` | `F7 06 22 14 40 50 22 14` | SYSTEM params — richest group left |
| `B6 10` / `20` / `21` | `B7 10 01` | SAR auto-play; absent from V1 entirely |
| `46 00` / `01` / `0C` | `47 xx 01` | LE Audio |

`FA` is the promising one. Pinning it down needs a human in the loop — flip a
bit, wear the headphones, report what changed — which is exactly the loop that
caught the four errors above, and exactly why I'd rather leave these blank than
guess a fifth time.

<br>

## Credit

The community did the hard groundwork:
[Plutoberth/SonyHeadphonesClient][plutoberth] for the framing,
[tanat/sony-connect-osx][tanat] for the macOS IOBluetooth approach,
[Leonard013/sony-ult-ctl][ult] for V2 command shapes,
[Gadgetbridge][gb] for the V1/V2 payload split, and
[mos9527/SonyHeadphonesClient][mos9527] for the generated V2 spec that named the
last of it.

The XM5-specific UUID, the EQ table, the band order, the ambient-level layout and
the corrected sub-types here were established by probing the hardware directly.

Not affiliated with Sony. Reverse-engineered for interoperability with hardware I
own.

MIT.

[plutoberth]: https://github.com/Plutoberth/SonyHeadphonesClient
[tanat]: https://github.com/tanat/sony-connect-osx
[ult]: https://github.com/Leonard013/sony-ult-ctl
[gb]: https://github.com/Freeyourgadget/Gadgetbridge
[mos9527]: https://github.com/mos9527/SonyHeadphonesClient

[releases]: https://github.com/argjentsahiti/aura-xm5/releases/latest
