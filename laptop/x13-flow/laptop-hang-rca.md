---
title: Laptop Hang RCA Notes
host: rog-x13-flow
initial_date: 2026-06-21
last_updated: 2026-07-02
os_stack: Linux Mint / Ubuntu
problem_kernel: 6.8.0-110-generic
current_mitigation_kernel: 6.8.0-90-generic
current_status:
  Running 6.8.0-90-generic after a sudden unclean reboot on 2026-07-02 with no preserved final
  cause; reboot-investigation tooling prepared.
key_events:
  - date: 2026-06-21
    summary:
      Initial hard-hang investigation; SSH/display dead; hang monitoring and GPU mitigations added.
  - date: 2026-06-22
    summary:
      Headless/tent-mode screen-off workflow validated with backlight plus framebuffer blanking.
  - date: 2026-06-23
    summary:
      Kernel oops incident on 6.8.0-110-generic; SSH dead; console showed kmem_cache_alloc/anon_vma
      faults; switched GRUB default to 6.8.0-90-generic.
  - date: 2026-06-24
    summary:
      Confirmed more than 1 day stable on 6.8.0-90-generic; added screen keep-off service/timer.
  - date: 2026-07-02
    summary:
      Sudden unclean reboot on 6.8.0-90-generic; no oops/panic/OOM/thermal evidence preserved; added
      script to enable pstore archival, stronger panic-on-lockup sysctls, and timer dephasing.
---

# Laptop Hang RCA Notes

Date: 2026-06-21 Host: `rog-x13-flow` OS/kernel observed: Linux Mint/Ubuntu stack,
`6.8.0-110-generic`

## Incident summary

Laptop was being used as a mostly headless/server machine. It became unreachable: GUI/display was
not responsive and SSH was also dead. A hard reboot occurred afterward.

`last -x` showed prior sessions ending with `crash`, indicating the system did not shut down
cleanly.

## Timeline

### 2026-06-21 initial hard-hang investigation

- Machine previously became unreachable: display/GUI unresponsive and SSH dead.
- Hard reboot was required.
- `last -x` indicated an unclean shutdown / `crash`.
- Initial suspects investigated: battery charge limit, Qtile user display services, hybrid
  NVIDIA/AMD graphics stack, display power management.
- Mitigations added: hang-health monitoring, persistent journald, SysRq, nouveau blacklist cleanup,
  NVIDIA dGPU disabled, and later `supergfxctl` integrated graphics mode.

### 2026-06-22 display/headless/tent-mode work

- Machine was running in `multi-user.target` with LightDM inactive.
- LightDM DPMS was not applicable in this mode.
- Direct backlight sysfs control alone set `bl_power=4`, `brightness=0`, `actual_brightness=0`, but
  did not visibly blank the panel.
- Adding framebuffer blanking via `/sys/class/graphics/fb0/blank` made the screen visibly turn off.
- Reusable helper added: `./screen.sh --off|--on|--status`.

### 2026-06-23 kernel oops / SSH-dead incident

- Previous boot was `Mon 2026-06-22 08:19:36 IST → Tue 2026-06-23 08:32:20 IST`.
- First recorded kernel oops occurred at `Tue 2026-06-23 06:03:00 IST` on kernel
  `6.8.0-110-generic`.
- Repeated kernel faults continued until at least `08:32:12 IST`.
- Physical photo taken at `/tmp/IMG_20260623_083225.jpg` showed kernel oops traces on the
  sleeping/woken console.
- SSH was unavailable even though the console could still show oops output.
- Hard reboot occurred; current boot started `Tue 2026-06-23 08:37:34 IST`.
- Root interpretation shifted from display/GPU sleep to kernel VM/slab memory corruption or kernel
  regression.
- Added `./setup-panic-on-oops.sh` to auto-reboot after future oopses.
- GRUB default was changed to boot older kernel `6.8.0-90-generic` using
  `./set-grub-kernel-6.8.0-90.sh`.
- Reboot confirmed the active kernel is now `6.8.0-90-generic`.

### 2026-06-24 stable rollback and screen keep-off follow-up

- Machine was checked after more than 1 day of uptime on `6.8.0-90-generic`.
- No recurrence of the previous bad signatures was found:
  - no `general protection fault`
  - no kernel oops/panic
  - no `kmem_cache_alloc` faults
  - no `anon_vma` faults
  - no OOM
  - no thermal spike
- Remaining warnings were limited to recurring PCIe/runtime-PM noise:
  - `workqueue: pm_runtime_work hogged CPU for >10000us`
  - `pcieport 0000:00:08.1: PME: Spurious native interrupt!`
- These power-management warnings map to AMD internal bridge `0000:00:08.1`, which leads to the
  Radeon 680M/iGPU-side devices and related AMD internal USB/audio/sensor devices.
- Interpretation: annoying but not currently harmful; do not change further while `6.8.0-90-generic`
  remains stable.
- Health logs showed stable battery and thermals:
  - battery range across logs: `58–59%`
  - charge threshold: `60%`
  - last ~24h CPU range: `36.9–42.6°C`
  - last ~24h GPU edge range: `36.0–45.0°C`
  - last ~24h NVMe range: `30.9–38.9°C`
- In text-console/headless mode, turning the screen off once is not always persistent. The panel can
  wake later due to console/framebuffer redraws or power-management activity.
- A keep-off timer was added as a mitigation so the panel is periodically forced back off while the
  laptop is being used in tent/headless mode.
- This is a Linux/headless-mode workaround, not a firmware-level fix. If the laptop is used
  interactively again, the keep-off behavior should be disabled first.

### 2026-07-02 sudden unclean reboot on `6.8.0-90-generic`

The laptop rebooted unexpectedly while still on the older mitigation kernel:

```text
Current kernel after reboot: 6.8.0-90-generic
Previous boot: Wed 2026-07-01 09:46:56 IST → Thu 2026-07-02 13:10:33 IST
Current boot:  Thu 2026-07-02 13:13:08 IST
```

`last -x` did not show a clean shutdown before this reboot. A prior SSH session ended with `crash`,
and the current boot logged:

```text
systemd-journald: system.journal corrupted or uncleanly shut down, renaming and replacing.
```

Unlike the earlier `6.8.0-110-generic` incident, the previous boot did not preserve a visible chain
of kernel oopses. Searches did not find:

```text
general protection fault
kernel oops/panic
kmem_cache_alloc fault
anon_vma fault
OOM
thermal critical event
clean shutdown target
explicit reboot request
```

The previous boot journal stopped abruptly around the recurring one-minute timers:

```text
Jul 02 13:10:33 systemd[1]: Starting hang-health-snapshot.service - Collect a health snapshot for debugging hangs...
Jul 02 13:10:33 systemd[1]: Starting x13-screen-off.service - Force ASUS X13 laptop panel off for headless/tent mode...
Jul 02 13:10:33 systemd[1]: x13-screen-off.service: Deactivated successfully.
```

The health snapshots immediately before the reboot looked normal:

```text
snapshot: 2026-07-02T13:09:31+05:30
uptime: 1 day, 3:24
load average: 0.09, 0.16, 0.17
memory: ~28 GiB available, swap 0B used
root disk: 45% used
AC online: 1
battery: 59%, status=Not charging, charge_control_end_threshold=60, power_now=0
CPU Tctl: ~40.2°C
AMD GPU edge: ~40.0°C
NVMe: ~31.9°C
NVIDIA driver: not running, expected
recent kernel warnings/errors in health snapshot: none
```

Interpretation: this was an unclean reboot/reset with no preserved final cause. It is not the same
signature as the `6.8.0-110-generic` VM/slab oops incident. The leading possibilities are:

1. firmware/hardware reset or power event,
2. kernel/firmware hang where final logs were not flushed,
3. panic/reboot path where pstore/kdump did not yet preserve evidence,
4. less likely: interaction/noise from one-minute health and screen keep-off timers running at the
   same second.

Mitigation/investigation script added:

```text
./setup-reboot-investigation.sh
```

It is intended to be run manually. It prepares evidence capture for the next event by:

- setting diagnostic panic sysctls:
  - `kernel.panic = 30`
  - `kernel.panic_on_oops = 1`
  - `kernel.softlockup_panic = 1`
  - `kernel.hung_task_panic = 1`
- mounting/checking `/sys/fs/pstore` when firmware exposes it,
- installing `archive-pstore.service` to copy pstore records after boot into
  `/var/log/pstore-archive/`,
- de-phasing `x13-screen-off.timer` so it does not fire at exactly the same cadence/second as
  `hang-health-snapshot.timer`,
- optionally installing kdump tooling with `INSTALL_KDUMP=1 ./setup-reboot-investigation.sh`.

After any future unexpected reboot, check:

```bash
sudo find /var/log/pstore-archive -maxdepth 2 -type f -print
sudo grep -R . /var/log/pstore-archive /sys/fs/pstore 2>/dev/null | less
journalctl -b -1 -k --no-pager | tail -300
last -x | head -30
```

## Initial hypothesis checks

### Battery / charge limit

Battery was capped at 60%:

```text
charge_control_end_threshold=60
capacity≈59
status=Not charging / Discharging
AC0 online=1
```

Battery collector logs showed battery reached ~59% and stayed there. No low-battery/critical-battery
evidence was found.

Conclusion: battery charge limit is unlikely to be the direct cause.

### Qtile / user display services

Found user services running from Qtile setup even outside useful GUI context:

- `auto-rotate.service`
- `monitor-manager.service`

They were enabled under user `default.target`, so they could run on user systemd startup / SSH
login, not only Qtile login.

Observed repeated failures:

```text
auto-rotate.service: restart counter 900+
monitor-manager.sh: Invalid MIT-MAGIC-COOKIE-1 key
monitor-manager.sh: Can't open display :0
```

These were disabled as persistent user services. Qtile still starts them via
`~/.config/qtile/autostart.sh`, so they should run only when Qtile starts.

Conclusion: noisy/misconfigured, but since SSH was dead during the incident, this is probably not
the whole root cause.

### GPU / display stack

System has hybrid GPU:

```text
NVIDIA RTX 3050 Ti Laptop GPU
AMD Radeon 680M iGPU
```

Prior logs showed NVIDIA PCIe/AER warnings:

```text
nvidia 0000:01:00.0: PCIe Bus Error: severity=Correctable
BadTLP
RxErr
```

Because this machine is used for CPU/RAM/storage and not GPU, NVIDIA dGPU was disabled through PRIME
integrated mode.

Current post-reboot status:

```text
prime-select query => intel
nvidia-smi => fails because NVIDIA driver is not running
```

Note: `prime-select intel` means integrated-GPU mode even though this is an AMD iGPU system.

Conclusion: GPU/display power management or NVIDIA hybrid stack remains a plausible cause,
especially because hang happened after display sleep and SSH died.

## Changes made

### User display services

Disabled systemd user services from starting automatically:

```bash
systemctl --user disable --now auto-rotate.service monitor-manager.service
```

`auto-rotate.service` was restored as a file but left disabled. Qtile autostart still runs:

```bash
systemctl --user start auto-rotate.service
~/.config/qtile/install/monitor-manager/monitor-manager.sh &
```

### NVIDIA dGPU disabled

Script created:

```text
./disable-nvidia-dgpu.sh
```

It runs:

```bash
sudo prime-select intel
sudo systemctl disable --now nvidia-persistenced.service
```

A reboot is required after running it.

### Nouveau blacklist fixed

`/etc/modprobe.d/blacklist-nouveau.conf` had stray `EOF` line. Fixed with:

```text
blacklist nouveau
options nouveau modeset=0
```

Script created:

```text
./fix-blacklist-nouveau.sh
```

It also runs:

```bash
sudo update-initramfs -u
```

### Hang monitoring installed

Script created and run:

```text
./setup-hang-monitoring.sh
```

It installed:

```text
/usr/local/sbin/hang-health-snapshot
/etc/systemd/system/hang-health-snapshot.service
/etc/systemd/system/hang-health-snapshot.timer
```

Timer is enabled and logs every minute to:

```text
/var/log/hang-health.log
```

It records:

- uptime/load
- RAM/swap
- disk usage
- AC/battery state
- thermal zones
- `sensors` output
- NVIDIA state if available
- top CPU/memory processes
- recent kernel warnings/errors

Persistent journald storage was enabled via `/var/log/journal`.

SysRq was enabled:

```text
/etc/sysctl.d/99-sysrq.conf
kernel.sysrq = 1
```

## Current healthy baseline after reboot

After clean reboot at ~15:31:

```text
hang-health-snapshot.timer: active
prime-select query: intel
nvidia-smi: NVIDIA driver not running
RAM: ~29 GiB available
Swap: unused
Disk /: ~36% used
NVMe: ~34°C
CPU: ~49-59°C
AC0 online=1
Battery: ~59%, threshold=60
Recent kernel warnings/errors: none
```

Later update after installing `supergfxctl` and switching graphics mode:

```text
supergfxctl -g: Integrated
prime-select query: intel
nvidia-smi: NVIDIA driver not running
/sys/class/backlight/amdgpu_bl1 exists
/sys/class/drm/card1-eDP-1 connected/enabled
```

This fixed the earlier bad display-routing state where LightDM/Xorg was using a simple framebuffer
and no real `/sys/class/backlight` device existed. After `sudo supergfxctl -m Integrated` and
reboot, the login-screen display timeout worked: the screen/backlight turned off and pressing a
laptop key woke it.

Fan/performance controls available through kernel platform profiles:

```text
/sys/firmware/acpi/platform_profile_choices: quiet balanced performance
/sys/firmware/acpi/platform_profile: balanced
```

Useful commands:

```bash
cat /sys/firmware/acpi/platform_profile_choices
cat /sys/firmware/acpi/platform_profile
echo quiet | sudo tee /sys/firmware/acpi/platform_profile
echo balanced | sudo tee /sys/firmware/acpi/platform_profile
echo performance | sudo tee /sys/firmware/acpi/platform_profile
sensors
```

TTY/headless screen-off notes after disabling LightDM:

- Physical console is usually `tty1`; SSH sessions are `pts/*`.
- `setterm --blank/--powerdown` did not reliably blank/power off the laptop panel.
- Kernel consoleblank was already set to `60`, but that did not visibly power off the panel.
- Direct backlight sysfs control works, but may have a delayed visible effect.

Observed working manual screen-off method in text-console/headless mode:

```bash
echo 4 | sudo tee /sys/class/backlight/amdgpu_bl1/bl_power
echo 0 | sudo tee /sys/class/backlight/amdgpu_bl1/brightness
echo 1 | sudo tee /sys/class/graphics/fb0/blank
```

The backlight-only commands set `bl_power=4`, `brightness=0`, and `actual_brightness=0`, but the
panel still appeared active. Adding framebuffer blanking via `/sys/class/graphics/fb0/blank` made
`--off` visibly work.

Restore from SSH:

```bash
echo 0 | sudo tee /sys/class/graphics/fb0/blank
echo 0 | sudo tee /sys/class/backlight/amdgpu_bl1/bl_power
echo 255 | sudo tee /sys/class/backlight/amdgpu_bl1/brightness
```

Reusable helper added:

```bash
~/.config/qtile/laptop/x13-flow/screen.sh --off
~/.config/qtile/laptop/x13-flow/screen.sh --on
~/.config/qtile/laptop/x13-flow/screen.sh --status
```

State when off should look like:

```text
brightness=0
actual_brightness=0
bl_power=4
fb0 blank=1
```

Unlike LightDM/DPMS, a laptop keypress may not restore this sysfs/framebuffer state; SSH restore
with `screen.sh --on` is safest. This works for now for tent/headless mode.

## 2026-06-23 kernel oops / SSH-dead incident

The machine became unreachable over SSH again and required a hard reboot. The screen had been
sleeping/blanked, but pressing a laptop key showed kernel oops traces on the physical console.

Photo evidence from `/tmp/IMG_20260623_083225.jpg` matched the journal logs. The visible console
showed faults in:

```text
RIP: kmem_cache_alloc+0xd3/0x350
Call Trace:
  anon_vma_clone
  anon_vma_fork
  dup_mmap
  dup_mm
  copy_process
  kernel_clone
  __do_sys_clone
```

and also:

```text
RIP: anon_vma_interval_tree_insert+0x40/0xe0
```

Journal evidence from previous boot:

```text
Previous boot: Mon 2026-06-22 08:19:36 IST → Tue 2026-06-23 08:32:20 IST
Current boot:  Tue 2026-06-23 08:37:34 IST
Kernel: 6.8.0-110-generic
First fault: Jun 23 06:03:00, Comm: sh, RIP: anon_vma_interval_tree_insert
Repeated faults: 90 total by Jun 23 08:32:12, often Comm: cron/runc/containerd-shim, RIP: kmem_cache_alloc
```

Preserved log evidence from `last -x` and `journalctl --list-boots`:

```text
last -x:
  reboot   system boot 6.8.0-110-generic Mon Jun 22 08:19   still running
  runlevel (to lvl 3) 6.8.0-110-generic Mon Jun 22 08:19 - 08:37 (1+00:17)
  reboot   system boot 6.8.0-110-generic Tue Jun 23 08:37   still running

journalctl --list-boots:
  -1 00d5ad1b6c7a44ae869050145d443ef2 Mon 2026-06-22 08:19:36 IST Tue 2026-06-23 08:32:20 IST
   0 f686260ec1814c4cb5ab7e42add335fb Tue 2026-06-23 08:37:34 IST Tue 2026-06-23 08:38:43 IST

post-reboot journal note:
  systemd-journald: system.journal corrupted or uncleanly shut down, renaming and replacing.
```

First-oops context from previous boot kernel log:

```text
Jun 22 08:23:13 workqueue: pm_runtime_work hogged CPU for >10000us 4 times
Jun 22 08:27:43 workqueue: pm_runtime_work hogged CPU for >10000us 8 times
Jun 22 08:36:23 workqueue: pm_runtime_work hogged CPU for >10000us 16 times
Jun 22 08:53:43 workqueue: pm_runtime_work hogged CPU for >10000us 32 times
Jun 22 09:28:53 workqueue: pm_runtime_work hogged CPU for >10000us 64 times
Jun 22 10:39:52 workqueue: pm_runtime_work hogged CPU for >10000us 128 times
Jun 22 13:00:23 workqueue: pm_runtime_work hogged CPU for >10000us 256 times
Jun 22 16:04:01 pcieport 0000:00:08.1: PME: Spurious native interrupt!
Jun 22 17:42:01 workqueue: pm_runtime_work hogged CPU for >10000us 512 times
Jun 23 03:04:33 workqueue: pm_runtime_work hogged CPU for >10000us 1024 times
Jun 23 03:42:20 pcieport 0000:00:08.1: PME: Spurious native interrupt!
Jun 23 05:29:01 pcieport 0000:00:08.1: PME: Spurious native interrupt!
Jun 23 06:03:00 general protection fault, probably for non-canonical address 0x8d6c54288c526de0: 0000 [#1] PREEMPT SMP NOPTI
Jun 23 06:03:00 CPU: 13 PID: 1401821 Comm: sh Not tainted 6.8.0-110-generic #110-Ubuntu
Jun 23 06:03:00 RIP: 0010:anon_vma_interval_tree_insert+0x40/0xe0
Jun 23 06:03:00 Call Trace: anon_vma_fork → dup_mmap → dup_mm → copy_process → kernel_clone → __do_sys_clone
Jun 23 06:03:01 general protection fault, probably for non-canonical address 0x6293dec4c5fbb468: 0000 [#2] PREEMPT SMP NOPTI
Jun 23 06:03:01 CPU: 13 PID: 1401826 Comm: cron Tainted: G      D            6.8.0-110-generic #110-Ubuntu
Jun 23 06:03:01 RIP: 0010:kmem_cache_alloc+0xd3/0x350
```

Fault progression summary:

```text
Oops count: 90
First: Jun 23 06:03:00, Comm: sh, RIP: anon_vma_interval_tree_insert
Second: Jun 23 06:03:01, Comm: cron, RIP: kmem_cache_alloc
Later examples:
  Jun 23 07:55:15 Comm: runc / runc:[2:INIT]
  Jun 23 08:14:41 Comm: containerd-shim
  Jun 23 08:27:42 Comm: runc:[1:CHILD]
Last: Jun 23 08:32:12, Comm: runc, RIP: kmem_cache_alloc
Common repeated bad address: 0x6293dec4c5fbb468
Common CPU in traces: CPU 13
```

Cron/systemd activity immediately before first oops:

```text
Jun 23 06:00:01 cron ran battery-monitor.sh, battery-cycles collect, redshift/gamma.sh
Jun 23 06:00:22 systemd ran fwupd-refresh and hang-health-snapshot
Jun 23 06:00:53 systemd ran battery-charge-limit.service
Jun 23 06:01:01 cron ran battery-cycles collect
Jun 23 06:01:23 systemd ran hang-health-snapshot
Jun 23 06:01:53 user systemd ran battery-logger.service
Jun 23 06:02:01 cron ran battery-cycles collect
Jun 23 06:02:33 systemd ran hang-health-snapshot
Jun 23 06:03:00 first kernel oops in sh/fork path
Jun 23 06:03:43 hang-health-snapshot started but resulting snapshot was incomplete
```

Last complete health snapshots before the first oops were normal:

```text
snapshot 2026-06-23T06:02:33+05:30
uptime: 21:44
load average: 0.12, 0.17, 0.14
memory: 30Gi total, 2.5Gi used, 18Gi free, 28Gi available
swap: 2.0Gi total, 0B used
root disk: 384G size, 133G used, 232G available, 37% used
AC0: online=1
BAT0: status=Not charging, capacity=58, charge_control_end_threshold=60, power_now=0
thermal zones: acpitz 38C/20C, iwlwifi 37C
amdgpu edge: +39.0°C, PPT 15.22 W
CPU k10temp Tctl: +39.0°C
NVMe composite: +31.9°C
asus fans: cpu_fan=0 RPM, gpu_fan=0 RPM
NVIDIA: nvidia-smi failed because NVIDIA driver was not running
recent kernel warnings/errors in health snapshot: none
```

The final pre-reboot health log marker was:

```text
===== snapshot 2026-06-23T06:03:43+05:30 =====
```

That snapshot was truncated/incomplete after `-- top cpu --`, consistent with the machine already
being damaged by the first oopses. The next health snapshot was after hard reboot:

```text
===== snapshot 2026-06-23T08:38:01+05:30 =====
uptime: 2 min
```

Negative evidence preserved from logs:

```text
No OOM or swap exhaustion before first oops.
No thermal spike before first oops.
No NVIDIA driver running; nvidia-smi failed as expected.
No clear MCE/EDAC/hardware-error report was found in the journal.
Only one Docker container was observed after reboot: linuxserver/syncthing.
```

Interpretation: not a display-sleep issue, not OOM, not thermal, and not likely NVIDIA. The kernel
was alive enough to print oops traces and wake the panel, but userspace/networking was broken enough
that SSH was unavailable. This points to kernel memory corruption / kernel bug / RAM instability.
Because the repeated failures happened in fork/exec/VM/slab paths, ordinary cron, shell,
Docker/runc, and sshd activity could fail after the first corruption.

Mitigations added:

```text
./setup-panic-on-oops.sh
```

This installs:

```text
/etc/sysctl.d/99-panic-on-oops.conf
kernel.panic_on_oops = 1
kernel.panic = 30
```

Purpose: if a future kernel oops occurs, reboot automatically after ~30 seconds instead of staying
SSH-dead indefinitely.

Recommended kernel test:

1. Reboot.
2. In GRUB, choose:

```text
Advanced options for Linux Mint/Ubuntu
→ Linux ... 6.8.0-90-generic
```

3. Do not choose recovery mode.
4. Verify after boot:

```bash
uname -r
```

Expected:

```text
6.8.0-90-generic
```

If `6.8.0-90-generic` is stable, suspect a `6.8.0-110-generic` regression. If the issue recurs
across older kernels, suspect RAM/hardware and run an overnight memtest.

## If it hangs/reboots again

After reboot, collect:

```bash
last -x | head -30
journalctl -b -1 -p warning..alert --no-pager
journalctl -b -1 -k --no-pager | tail -300
tail -500 /var/log/hang-health.log
prime-select query
lsmod | grep '^nvidia' || true
nvidia-smi || true
```

Also check whether the previous shutdown was clean:

```bash
last -x | head
```

Interpretation:

- If `last` says `crash`, previous boot died uncleanly.
- If `/var/log/hang-health.log` stops abruptly without thermal/OOM warnings, suspect
  kernel/hardware/firmware hang.
- If temps spike before stop, suspect thermal/power.
- If memory/swap exhaustion appears, suspect workload/OOM.
- If NVIDIA modules reappear or GPU/AER messages return, suspect dGPU/hybrid graphics.
- If AC goes offline or battery drains rapidly, suspect charger/EC/power path.

## Next mitigation ideas if hang recurs

1. Disable display manager/GUI entirely when using as server:

```bash
sudo systemctl set-default multi-user.target
sudo systemctl disable --now lightdm
```

2. Disable DPMS/display sleep from Qtile autostart as a test.

3. Add kernel boot params to reduce PCIe power-management issues, e.g. test-only:

```text
pcie_aspm=off
```

4. Check firmware/BIOS updates for ASUS ROG X13 Flow.

5. Boot/test older installed kernel `6.8.0-90-generic` from GRUB advanced options; avoid
   `6.8.0-110-generic` until proven safe.

6. If the issue recurs across kernels, run overnight memtest / hardware diagnostics.

7. Consider a newer HWE/OEM kernel if GPU/ACPI hangs continue or if older-kernel rollback is not
   sufficient.
