# halium13-plasma-mobile-m52xq

Halium 13 + Plasma Mobile port for the **Samsung Galaxy M52 5G** (codename
`m52xq`, models `SM-M526B`/`SM-M526BR`), using the device's original
Android vendor kernel and HAL blobs bridged into a real Linux/systemd
userspace via `libhybris`. This is the pragmatic, "get a working phone
now" approach — as opposed to the from-scratch mainline-kernel effort for
the same device tracked in a
[separate repository](https://github.com/korryasdlerto-lgtm/samsung-m52xq-mainline).

**Current status (в21): real, working desktop with hardware GPU
acceleration, working SSH-over-USB, working Android-HAL container boot,
**working Bluetooth end-to-end** (daemon + real MAC + pairing UI),
**working password-protected lockscreen**, a **working on-screen
keyboard** (via `QtVirtualKeyboard`, discovered as a side-effect of an
unrelated `kwin-wayland` dependency bump), and an automatic
power-button-triggered screen-wake watchdog for a recurring DPMS bug.
Several major subsystems remain broken or unfinished — see
[Known issues](#known-issues) below, this is honestly documented, not a
"finished ROM".**

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
v21-latest/
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
                            (в1 through в21), each documented in its own
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
    android-data-files/    — our own patched Android framework jars
                            (org.lineageos.platform/framework/services)
                            plus a small native `halium_sensor_bridge`
                            helper binary we wrote ourselves. The vendor
                            sensors HAL `.so` and a bundled kernel-modules
                            tarball are excluded, see PROPRIETARY-FILES.txt
  firmware/                — boot.img and vendor_boot.img: real binaries,
                            included for real (these are the halium-
                            patched images this project builds/repacks
                            itself, not raw untouched Samsung signed
                            images). system.img is a symlink, see
                            "Repository layout" below.
  kernel-config/
    lineage-m52xq_defconfig — the vendor kernel's defconfig, for
                            reference/comparison (this project uses the
                            stock vendor kernel as-is, doesn't rebuild it,
                            but this file is useful for diffing against
                            sibling ports on the same device)
  FIXES-*.md, DROIDIAN-V23-PLAN.md, PLAN-NEXT-STEPS.md
                          — investigation logs written during
                            development, one per major bug/feature area,
                            kept as originally written (mix of Russian
                            and English, chronological, includes dead
                            ends and things that didn't work — not
                            cleaned up into a polished changelog on
                            purpose, since the reasoning and rejected
                            alternatives are often more useful than the
                            final answer alone)
```

## Repository layout — proprietary and oversized files

Two different categories of files are **not tracked directly** in this
repository, for two different reasons — see `PROPRIETARY-FILES.txt` for
the full manifest and rationale:

1. **Proprietary vendor blobs** (`halium-extras/lxc-bridge-libs/` — the
   ~540 MB libhybris/Android bridge `.so` library set extracted from the
   device's own `/vendor` and `/system` partitions, plus a couple of
   vendor binaries inside `android-data-files/`) are **not present at
   all** in this repo (not even as placeholders) — we don't have
   redistribution rights for them.
2. **Oversized-but-not-proprietary** files (`firmware/system.img`,
   `data/rootfs-chunks/rootfs.img.part-*`, `data/userdata-overlay.tar.gz`
   — several gigabytes total) are represented as symlinks pointing at a
   local, untracked `local-large-files/` directory at the repo root
   (already in `.gitignore`). The symlinks are committed so the
   directory structure is documented; the actual files are not.

### Obtaining the excluded files (for building a real flashable ZIP)

If you own this exact device (Samsung Galaxy M52 5G / `m52xq`) and want
to build an actual flashable ZIP from this source, not just read the
patch material:

1. **Vendor bridge libraries** (`halium-extras/lxc-bridge-libs/`): pull
   them from your own device's running Halium container, e.g.:
   ```sh
   adb shell su -c 'lxc-attach -n android -- tar -C / -cf - \
     vendor/lib64 vendor/lib system/lib64/vndk-sp system/lib/vndk-sp' \
     > lxc-bridge-libs.tar
   ```
   then extract into `v21-latest/halium-extras/lxc-bridge-libs/` at the
   exact relative paths listed in `PROPRIETARY-FILES.txt` (the manifest
   lists every individual file this project actually uses — you don't
   need the whole vendor partition, just those specific libraries).
2. **`firmware/system.img`, `data/rootfs-chunks/*`,
   `data/userdata-overlay.tar.gz`**: either build these yourself
   following this project's own build notes (see the `docs/` FIXES logs
   for the rootfs build process), or — simplest — just place your own
   copies **next to the cloned repository folder** (i.e. as siblings,
   `../local-large-files/<name>` relative to where you cloned this repo)
   and create the `local-large-files/` symlink target inside the repo to
   point at them:
   ```sh
   mkdir -p local-large-files
   ln -s ../../rootfs.img.part-0 local-large-files/rootfs.img.part-0
   # ...same for part-1, part-2, system.img, userdata-overlay.tar.gz
   ```
   (adjust the `../../` relative path to wherever you actually placed the
   real files — the symlinks already committed under `v21-latest/data/`
   and `v21-latest/firmware/system.img` point at `local-large-files/` by
   a fixed relative path, so as long as `local-large-files/` itself
   resolves to your real files, everything downstream just works).
3. `boot.img` and `vendor_boot.img` under `firmware/` are already
   **real, included** files — no action needed for those.

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
- **Container autostart reliability**: the container is started by this
  project's own `lxc@android.service` template (a systemd instance unit,
  triggered via `halium-container-autostart.timer`+`.sh` 45-55s into
  boot, with the delay handled entirely inside the script rather than
  via unit-level gating). An inherited `halium-watch-camera.sh` watchdog
  script kept checking a *different*, non-existent unit name
  (`lxc-android-config.service`, which this project's own `update-binary`
  explicitly removes in favor of `lxc@android.service`) for its whole
  lifetime — meaning that watchdog never once fired correctly until this
  was found and fixed. Also found: `/` sometimes comes back **read-only**
  after boot (an initrd race, root cause not found), which used to
  silently break any fix that touches `/etc`/`/usr` if that fix ran
  before the corresponding `remount,rw` check — resolved by moving the
  ro-check to the very first thing the autostart script does.
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

Honestly unresolved as of the в21 development session:

- **WiFi never reliably initializes** at the kernel/firmware level
  (`icnss2: Modules not initialized just return`, repeating forever) —
  an intermittent WCN-chip firmware/init race, **confirmed identical**
  in both sibling Droidian and Ubuntu Touch ports of this exact device
  (same kernel config, same watchdog script already present in all
  three projects) — sometimes a fresh reboot fixes it, sometimes not, no
  reliable software fix found in any of the three independent efforts.
  A safe `unbind`/`bind` of the `icnss2` platform driver (instead of the
  unsafe `rmmod`/`insmod`) was tried live as a possible per-boot
  mitigation; it stopped the retry-spam but did not bring the interface
  up. `CONFIG_MSM_SUBSYSTEM_RESTART` is enabled in the kernel, so a
  proper SSR-based recovery may exist but wasn't found.
- **Homescreen icons intermittently invisible or the homescreen
  layout comes up empty**, for two distinct, now-understood reasons: (1)
  the homescreen layout config is created fresh by the shell on first
  login and is genuinely empty right after any flash+`/data` wipe until
  a second session start, and (2) the icon theme's pixmap cache
  (`icon-theme.cache`) can go stale relative to the currently-installed
  app set after any package add/remove, making entries clickable but
  invisible until `gtk-update-icon-cache -f` regenerates it. Neither fix
  is yet wired into the automatic boot flow (both still require a manual
  SSH fix-up), so this remains inconsistent from boot to boot.
- **Camera provider (`vendor.camera-provider-2-6`) crash-loops** — root
  cause confirmed to be missing EFS multi-camera calibration data (the
  EFS partition isn't bridged into this Halium container), the same
  conclusion independently reached by the sibling Ubuntu Touch project.
  Not fixable in software; a best-effort retry watchdog exists but only
  occasionally succeeds.
- **No Russian (or other non-English) on-screen keyboard layout found**
  yet — `QtVirtualKeyboard`'s language switcher UI exists
  (Settings → On-Screen Keyboard → Configure Languages) but wasn't
  tested through to a working layout switch.
- Several native (Kirigami/Qt-based) applications (SDL2-based games in
  particular — `extremetuxracer`, `supertuxkart`) fail to launch from
  the homescreen with "Failed to open X11 display", since they don't
  support native Wayland and the launcher only provides
  `WAYLAND_DISPLAY`, not `DISPLAY` — fixed for these two specifically by
  patching their `.desktop` files to add `env DISPLAY=:0` (wayfire runs
  Xwayland), but the same class of bug likely affects other X11-only
  apps not yet identified.

## Commands reference

Practical commands actually used throughout development, with the
reasoning behind each — not just what to run, but why it's written this
way.

### Building the flashable ZIP

```sh
cd в21 && zip -9 -r ../halium-m52xq-plasma-mobile.zip . -x ".*"
```
Must run **from inside** the version folder. Running it from outside as
`zip -9 -r out.zip в21` embeds a `в21/` path prefix on every archive entry,
which breaks TWRP's lookup of `META-INF/com/google/android/update-binary`
at flash time — this exact mistake was made and caught once during
development. `-9` is max compression (the archive is several GB, worth
the extra CPU time); `-x ".*"` excludes dotfiles that shouldn't be in the
package.

### Verifying an archive before flashing

```sh
unzip -l halium-m52xq-plasma-mobile.zip | head -15   # check for a flat
                                                       # structure, no в21/
                                                       # prefix
unzip -l halium-m52xq-plasma-mobile.zip | grep update-binary
unzip -t halium-m52xq-plasma-mobile.zip | tail -5     # integrity check
```

### Checking for broken symlinks before packaging

```sh
find в21 -xtype l
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
sudo systemctl status lxc@android.service
```
`lxc-info` is the ground truth; the systemd unit's own reported state can
lag or disagree with it during restarts, so check both if something looks
inconsistent.

### Enabling the container after a fresh flash

```sh
touch /userdata/CONTAINER_ENABLED
sudo systemctl start lxc@android.service
```
The `/userdata/CONTAINER_ENABLED` marker (checked directly inside
`halium-container-autostart.sh`, not via a unit-level
`ConditionPathExists=` gate) controls only the *timing*: no marker means
this is treated as the first boot after a flash and the script sleeps an
extra 10s (55s total instead of 45s) before starting the container, to
give the rest of userspace more time to stabilize on the least reliable
boot. The marker persists across normal reboots (only a full
reflash/wipe clears it), so the extra delay is a one-time thing per
flash, not something you need to manage manually.

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
a versioned folder (this repository reflects the `в21` staging state, the
latest at time of writing) via:

```sh
cd в21 && zip -9 -r ../output.zip . -x ".*"
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
