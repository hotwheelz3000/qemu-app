# LiberNT for iPhone (Unofficial)

An iPhone app that runs [LiberNT](https://github.com/LiberNT/LiberNT), the NT-based operating system, full screen. Open the app and LiberNT boots; there are no virtual machine menus.

Not affiliated with LiberNT, UTM, QEMU or Microsoft.

## How it works

- **Emulator:** QEMU (ARM64 `virt` machine), taken ready-made from [UTM](https://github.com/utmapp/UTM)'s iPhone app. The Build IPA workflow downloads UTM's IPA (version pinned as `UTM_VERSION` in the workflow) and copies `qemu-aarch64-softmmu.framework` and the frameworks it needs into this app. Nothing is compiled from QEMU's source.
- **Firmware:** AAVMF / EDK2 UEFI for ARM64 (`Firmware/`, from Ubuntu's `qemu-efi-aarch64` 2024.02). UTM's own firmware doesn't show a picture with LiberNT.
- **Disk:** on first launch the app downloads `LiberNT.qcow2` from this repo's `disk-nt10.0-043-2555` release. The **Publish LiberNT disk** workflow (run by hand) makes it from LiberNT's arm64 preinstalled disk (`LiberNT-img-clang-arm64-…zip`, build nt10.0-043-2555). QEMU reads qcow2 directly, so nothing is unzipped on the phone. You can use another disk instead (raw `.img` or `.qcow2`) with **Use a Disk from Files**.
- **Hardware:** NVMe disk, ramfb screen, USB tablet and keyboard, virtio network card (QEMU's default, with UTM's ROMs), UEFI settings saved in `efi-vars.fd`. Tested in QEMU: this setup boots to the LiberNT desktop. virtio-blk stops with error 0x7B, and virtio-gpu stays blank.
- **Screen:** QEMU's VNC server on 127.0.0.1, read by a small VNC client in the app.

## Machines

Settings › Machine switches between two computers (the app closes; open it again from StikDebug). Each has its own disk and CD drive.

- **ARM64 (LiberNT):** the setup above. Also runs other ARM64 UEFI systems from a disk image (for example Debian's `nocloud` arm64 qcow2).
- **x86 PC:** QEMU's i440FX PC with SeaBIOS, IDE disk and CD, standard VGA, USB tablet and an e1000 network card, using UTM's `qemu-x86_64-softmmu`. For ReactOS, Windows 95–XP, DOS and x86 Linux. First launch: pick an install ISO, make an empty (sparse) disk, and it boots from the CD.

**CD drive:** Settings › CD Drive › Choose ISO. The ISO stays where it is in Files (the app keeps a bookmark to it). Inserting or ejecting while the machine runs takes effect right away. The machine boots from the CD when one is in.

Files live in **Files › On My iPhone › LiberNT**: the disks (`LiberNT.img`, `PC.img`), `boot-log.txt` (LiberNT's serial output) and `qemu-log.txt`.

## Install and run

1. Sign and install the IPA with Signulous. The app asks for the same memory entitlements as Andarium.
2. In StikDebug, assign the script **legacy.js** to LiberNT. UTM's QEMU asks StikDebug for JIT memory with `brk #0x69`, which legacy.js handles (universal.js handles `brk #0xf00d`). QEMU runs with `split-wx=on`, which that needs on iOS 26 and later.
3. Launch LiberNT from StikDebug. The first time, tap **Download LiberNT** and wait for it to unpack.

## Controls

- Tap: left click. Two-finger tap or long press: right click.
- Drag with one finger: drag. Drag with two fingers: scroll.
- The ⋯ button: keyboard, Esc, Tab, Windows key, Ctrl+Alt+Del, Alt+F4, power button, restart and settings (memory and CPU cores).

## Licenses

QEMU is GPL-2.0, EDK2 is BSD-2-Clause-Patent (`Firmware/EDK2-COPYRIGHT.txt`), UTM is Apache-2.0, and LiberNT is GPL-3.0.

## Building

Every push to `main` builds the IPA on GitHub Actions and publishes it as the `latest` release:

```
https://github.com/hotwheelz3000/qemu-app/releases/download/latest/LiberNT-1.0.ipa
```

Built from the xtool template ([using xtool](.claude/skills/using-xtool/SKILL.md)).
