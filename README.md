# halium13-plasma-mobile-m52xq

Halium 13 + Plasma Mobile port for the **Samsung Galaxy M52 5G** (codename
`m52xq`, models `SM-M526B`/`SM-M526BR`), using the device's original
Android vendor kernel and HAL blobs bridged into a real Linux/systemd
userspace via `libhybris`. This is the pragmatic, "get a working phone
now" approach — as opposed to the from-scratch mainline-kernel effort for
the same device tracked in a
[separate repository](https://github.com/korryasdlerto-lgtm/samsung-m52xq-mainline).

**Current status: real, working desktop with hardware GPU acceleration,
working SSH-over-USB, working Android-HAL container boot (telephony/
WiFi-service/bluetooth processes all start). Several major subsystems
remain broken or unfinished — see [Known issues](#known-issues) below,
this is honestly documented, not a "finished ROM".**

## What this actually is

Halium provides a thin Android-HAL compatibility layer so a normal Linux
distribution (here: Debian, patterned after the Droidian project) can run
as the primary OS on top of an unmodified Android vendor kernel and its
proprietary blobs (GPU driver, WiFi firmware, modem RIL, sensors, etc).
The Android side runs inside an **LXC container** purely to host the
vendor HAL services; there is no visible Android UI — the container is a
driver bridge, nothing else. `libhybris` translates between Android's
bionic-based HAL libraries and the host's glibc-based userspace.

On top of that bridge, this port runs **Plasma Mobile** (KDE's phone
shell) on the **wayfire** Wayland compositor — wayfire was specifically
chosen (over the more commonly-paired KWin) because it has a working
`hwcomposer`/hybris-EGL rendering backend for talking to the Android GPU
driver through the bridge.

## Hardware

Same device as documented in the
[mainline repository](https://github.com/korryasdlerto-lgtm/samsung-m52xq-mainline) —
see that repo for the full hardware table (SoC, PMIC, charger IC, panel,
touch, audio codec, all cross-referenced against real downstream device
tree sources). This project uses the vendor kernel as-is, so hardware
identification matters less here — the vendor drivers already know their
own hardware — but the same findings (SM5714/PCA9468 charger, PM8008
PMIC, Novatek NT36672E panel, WCD938x audio codec, Qualcomm `qca_cld3_wlan`
WiFi chip) were independently confirmed live on the running device via its
own kernel boot log (pstore/`console-ramoops`) during this project's
development, which is how the two independent efforts cross-validated
each other's hardware findings without sharing code.

## What's in this repository

This is **not** a full buildable rootfs image (that alone is several
gigabytes of vendor binaries, firmware blobs, and a bridge-library set
that can't be redistributed here) — it's the actual authored/patched
material this port consists of:

```
v8-latest/
  META-INF/com/google/android/update-binary
                          — the TWRP-flashable installer script. This is
                            the real core of the project: it flashes
                            boot/vendor_boot, converts and writes a
                            sparse system.img, patches a known Android
                            framework crash (org.lineageos.platform.jar
                            "LongScreen" bug), reassembles rootfs.img
                            from split chunks (works around a TWRP unzip
                            OOM issue), and injects every fix below into
                            the right place inside rootfs.img — a single
                            script accumulated over many iterations
                            (в1 through v8), each documented in its own
                            inline comments with dates and root-cause
                            explanations, not just "what" but "why".
  halium-extras/
    rootfs-files/         — files injected directly into rootfs.img at
                            flash time (systemd units, drop-in overrides,
                            scripts, patched configs). This is the bulk
                            of the actual fix material.
    libexec/               — standalone helper scripts (watchdogs,
                            container start/stop helpers, GPU bridge
                            setup, state save/restore across reboots)
    units/                 — systemd unit files and drop-ins that aren't
                            simple enough to live directly under
                            rootfs-files/
    system-patches/        — small, targeted binary/text patches applied
                            to specific system files at flash time
  docs/                    — the FIXES-*.md investigation logs written
                            during development, one per major bug/feature
                            area, kept as originally written (mix of
                            Russian and English, chronological, includes
                            dead ends and things that didn't work — not
                            cleaned up into a polished changelog on
                            purpose, since the reasoning and rejected
                            alternatives are often more useful than the
                            final answer alone)
```

**Deliberately excluded** from this repository (present in the actual
flashable ZIP but not here): the `lxc-bridge-libs/` bridge library set
(~540 MB of libhybris/Android bridge `.so` files extracted from the
device's own `/vendor` and `/system` partitions — device-specific, and
redistributing extracted vendor binaries isn't appropriate for a public
repo), `android-data-files/` (~140 MB of extracted/patched Android
framework `.jar`/`.apk` files, same concern), the full `rootfs.img` and
`system.img` themselves, and a handful of large third-party binaries and
data files that happened to be staged inside `rootfs-files/` for
injection (a bundled GeoNames city database, `libopencv`/`libwlroots`/
`liblapack` shared libraries, etc — these are unmodified upstream
binaries, not this project's own work).

## Architecture notes / key findings

A representative sample of the non-obvious things found and fixed during
development (see `docs/FIXES-*.md` for the full, dated investigation
trail of each):

- **bionic linker cross-namespace bug**: `libandroidicu.so` and related
  ICU libraries failed to resolve via the APEX-namespace redirect *only*
  for non-root service UIDs (`wifi`, `radio`), never for root, breaking
  WiFi HAL, RIL, `ipacm`, and the media codec service simultaneously.
  Root cause inside bionic itself was never fully identified despite deep
  live debugging (SELinux, capabilities, resource limits, and ASLR were
  all ruled out) — worked around by copying the missing libraries
  directly into `/system/lib64/` from the container's own mount hook, so
  the default linker namespace's local search path finds them without
  needing the cross-namespace redirect that specifically fails for
  non-root UIDs.
- **Container autostart reliability**: multiple earlier approaches
  (commenting out an `[Install]` symlink, a `ConditionPathExists`-based
  gate on this project's own from-scratch `lxc@android.service` template)
  turned out to be either unreliable or redundant — the container is
  actually started by a separate, pre-existing, properly-configured
  `lxc-android-config.service` (inherited from an earlier Droidian-based
  phase of this project) with its own working `ConditionPathExists` gate,
  restart-on-failure, and boot-ordering fixes. The from-scratch template
  unit is effectively dead code that was chased for longer than it should
  have been before this was discovered.
- **USB gadget mode / SSH-over-USB reliability**: the mode this project
  had been force-selecting via D-Bus (`developer_mode`) turned out to be
  `usb_moded`'s internal **rescue mode** (confirmed via `strings` on the
  `usb_moded` binary) — a mode that is timed and *designed* to revert
  after a few seconds, which explained a long-standing "SSH randomly
  drops" symptom. Switching to the ordinary `rndis` mode (not the
  combined `rndis_adb`, which triggered an unrelated endless mass-storage
  retry loop when the ADB sub-function couldn't come up) fixed this for
  good.
- **Read-only root overlay**: the live filesystem is an immutable overlay
  (`lowerdir=/halium-system,upperdir=/tmpmnt/rootfs-overlay`) — only a
  curated list of `/var/lib/*` subdirectories have individual `fstab`
  bind-mounts to real writable storage. Package installs
  (`dpkg`/`apt`) are not part of the normal boot-time workflow at all; a
  temporary `mount -o remount,rw /` is the documented way to do a one-off
  live package install for testing.
- **GPU rendering**: real hardware-accelerated rendering (wayfire holding
  `/dev/kgsl-3d0` open) was achieved by removing a hard systemd dependency
  between the Plasma shell service and a separate `android-service@
  hwcomposer.service` unit that was architecturally redundant — the shell
  service already had its own working `ExecStartPre=` GPU-bridge setup
  script, matching the pattern used elsewhere in the project.

## Known issues

Honestly unresolved as of the last development session:

- **Homescreen icons are invisible but functional** (draggable,
  tap-to-launch works) — root-caused (not fixed) to `Kirigami.Icon`'s
  `status` property getting permanently stuck at `Loading` (never
  transitioning to `Ready` or `Error`) for every single icon
  simultaneously, confirmed live via a custom `qInstallMessageHandler()`
  built into a from-source rebuild of the `plasma-mobile-wf` homescreen
  applet. No thread is blocked (checked via `/proc/<pid>/task/*/status`
  and `wchan`), so this points to a logic bug — likely in `libkirigami6`/
  `libKF6IconThemes`'s async icon-loading code, which is outside this
  project's own source tree.
- **No working on-screen keyboard.** wayfire's build only ships the
  `input-method-v1` Wayland protocol plugin; `maliit` (the framework used
  by `plasma-mobile-wf`) needs `input-method-v2` to pair with
  `text-input-v3`, so the two can't talk. `QtVirtualKeyboard` was
  installed as an alternative, but requires the shell's own QML to embed
  an `InputPanel` component, which `plasma-mobile-wf`'s compiled shell
  does not do (it's built around maliit's separate-surface model).
- **`kscreen` reports zero displays**, despite the actual screen working
  fine — traced to `KSCREEN_BACKEND=KSC_QScreen.so` being hardcoded in
  the session startup script, referencing a backend plugin file that
  does not exist anywhere on the system (only `KSC_Fake.so`,
  `KSC_KWayland.so`, `KSC_XRandR.so` are actually installed). Not yet
  fixed.
- **WiFi never initializes** at the kernel/firmware level (confirmed
  correct firmware is bind-mounted and MD5-verified, but the WPSS
  subsystem state stays `OFFLINING`) — attributed to the closed-source
  `qca_cld3_wlan.ko` vendor kernel module, for which no source is
  available in this project's kernel tree.
- Several native (Kirigami/Qt-based) applications reportedly self-close
  a few seconds after being launched from the homescreen; non-native apps
  (Firefox, GTK apps) do not have this problem. Root cause not yet
  identified — a manual SSH-launched reproduction attempt with a copied
  session environment did not reproduce the crash, suggesting the real
  launch path differs from a plain interactive shell in some way not yet
  understood (likely a mount-namespace or environment detail specific to
  how the shell itself launches child processes).

## Commands reference

Practical commands actually used throughout development, with the
reasoning behind each — not just what to run, but why it's written this
way.

### Building the flashable ZIP

```sh
cd v8 && zip -9 -r ../halium-m52xq-plasma-mobile.zip . -x ".*"
```
Must run **from inside** the version folder. Running it from outside as
`zip -9 -r out.zip v8` embeds a `v8/` path prefix on every archive entry,
which breaks TWRP's lookup of `META-INF/com/google/android/update-binary`
at flash time — this exact mistake was made and caught once during
development. `-9` is max compression (the archive is several GB, worth
the extra CPU time); `-x ".*"` excludes dotfiles that shouldn't be in the
package.

### Verifying an archive before flashing

```sh
unzip -l halium-m52xq-plasma-mobile.zip | head -15   # check for a flat
                                                       # structure, no v8/
                                                       # prefix
unzip -l halium-m52xq-plasma-mobile.zip | grep update-binary
unzip -t halium-m52xq-plasma-mobile.zip | tail -5     # integrity check
```

### Checking for broken symlinks before packaging

```sh
find v8 -xtype l
```
Run across the **whole** version folder, every time, before building a
ZIP. A broken symlink fails silently in two different ways once packaged:
either the file is simply missing from the archive, or — worse — it gets
replaced by a ~40-byte text file containing the literal symlink target
path instead of the real binary content, which is much harder to notice
than a missing file. This was caught only after it had already silently
corrupted a large number of injected bridge libraries across several
builds.

### Safely writing into an already-flashed `rootfs.img` from TWRP

```sh
# push the new file to TWRP's /tmp first (no mount needed for this step)
adb push fixed-script.sh /tmp/

# then a single tight command: mount, copy, sync, unmount
adb shell "mount -t ext4 -o loop,rw /data/rootfs.img /tmp/rofs && \
  cp /tmp/fixed-script.sh /tmp/rofs/path/to/target && \
  chmod 755 /tmp/rofs/path/to/target && \
  sync && umount /tmp/rofs"
```
`mount -o loop,rw` on this specific device's `rootfs.img` hung and
triggered a hardware watchdog reset (`__fput() for loop0 file is not
finished for 180 sec`) on two separate earlier occasions when done as
multiple separate commands with the mount left open for any length of
time. Doing the entire mount→copy→sync→unmount sequence as one single
shell invocation, with the replacement file already staged locally via
`adb push` beforehand (so no time is spent copying *while* mounted),
avoided the hang consistently afterward. `-o loop,ro` (read-only) mounts
were reliable throughout and never needed this precaution — only `rw`
mounts were affected.

If the ext4 journal needs replay and a plain `-o loop,rw` mount fails,
do **not** add `noload` to a `rw` mount — the kernel rejects that
combination outright (`Invalid argument`). `noload` is only safe to
combine with `-o ro`, for read-only inspection of an image with an
unclean journal.

### Checking container status live

```sh
sudo lxc-info -n android           # real container state (RUNNING/STOPPED),
                                    # independent of what systemd thinks
sudo systemctl status lxc-android-config.service
```
`lxc-info` is the ground truth; the systemd unit's own reported state can
lag or disagree with it during restarts, so check both if something looks
inconsistent.

### Enabling the container after a fresh flash

```sh
touch /userdata/CONTAINER_ENABLED
sudo systemctl start lxc-android-config.service
```
The container is gated behind `ConditionPathExists=/userdata/
CONTAINER_ENABLED` in a drop-in on `lxc-android-config.service` — this
marker is checked by systemd on *every* start attempt regardless of how
the unit is triggered (symlink, another unit's dependency, manual
`systemctl start`), and is intentionally never created automatically on
first boot, to avoid a startup race that used to cause real problems
early in the project. The marker persists across normal reboots (only a
full reflash/wipe clears it), so this is a one-time step per flash.

### Finding what's actually consuming CPU/heat

```sh
ps aux --sort=-%cpu | head -20
cat /sys/class/thermal/thermal_zone*/temp   # millidegrees C
```
Worth running whenever the device feels hot with no obvious cause —
orphaned compositor processes and leftover diagnostic/supervisor scripts
from earlier debugging sessions are a common, easy-to-miss culprit (both
have happened during this project's development).

## Flashing

The installer is a standard TWRP-flashable ZIP built from the contents of
a versioned folder (this repository reflects the `v8` staging state, the
latest at time of writing) via:

```sh
cd v8 && zip -9 -r ../output.zip . -x ".*"
```

(must be run from *inside* the version folder — running it from outside
with the folder name as an argument embeds a path prefix that breaks
TWRP's `update-binary` lookup; this exact mistake was made and caught
once during development).

Flashing itself, the actual bridge library set, extracted Android
framework files, and the built `rootfs.img`/`system.img` are not
included here — this repository is the patch/fix source material, not a
turnkey installer.

## License

No specific license asserted for the original scripts/configs in this
repository (personal project). Individual injected files retain whatever
license their upstream project uses (systemd unit conventions, standard
Debian package file formats, etc). Not for redistribution of the excluded
vendor-derived binary material described above.
