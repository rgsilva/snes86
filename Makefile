# snes86 — root build surface. The real rules live in snes/ (the ROMs,
# WLA-DX), core-c/ (the reference PC, runpc) and apps/ (the
# on-machine software). See docs/BUILDING.md.
#
#   make               the public MS-DOS ROM -> snes/build/msdos.sfc
#   make msdos         same
#   make freedos       FreeDOS 1.3 on the 172 KB machine
#   make elks          ELKS 0.9.1 (Linux for the 8086)
#   make msdos_big     MS-DOS on the 172 KB machine
#   make boot DISK=disks/fs1.img    a self-booting disk replaces DOS
#   make test          parity + host smokes + Mesen legs (QUICK=1 trims;
#                      Mesen legs self-skip when Mesen is absent)
#   make test-extra    the copyrighted app-matrix legs (local disks/ only)
#   make apps          rebuild every app from source + verify
#   make clean
#
# OVERLAYS="dir-or-img ..." on any DOS-booting target (msdos, msdos_big,
# freedos, boot) merges extra content onto the free C: and writes
# snes/build/<target>_overlay.sfc — the clean ROM is never clobbered.

.DEFAULT_GOAL := msdos

# overlay paths are resolved from here; the recipes run in snes/
msdos msdos_big freedos:
ifneq ($(strip $(OVERLAYS)),)
	$(MAKE) -C snes $@ OVERLAYS="$(foreach o,$(OVERLAYS),$(abspath $(o)))"
else
	$(MAKE) -C snes $@
endif

elks:
	$(MAKE) -C snes elks

boot:
	@test -n "$(DISK)" || { echo "usage: make boot DISK=path/to/disk.img (a 160 KB or 360 KB self-booting image)"; exit 1; }
ifneq ($(strip $(OVERLAYS)),)
	$(MAKE) -C snes boot DISK=$(abspath $(DISK)) OVERLAYS="$(foreach o,$(OVERLAYS),$(abspath $(o)))"
else
	$(MAKE) -C snes boot DISK=$(abspath $(DISK))
endif

test test-extra:
	@$(MAKE) -s -C core-c runpc
	$(MAKE) -C snes $@

apps:
	@$(MAKE) -s -C core-c runpc
	sh apps/rebuild_all.sh

clean:
	$(MAKE) -C snes clean
	$(MAKE) -C core-c clean

.PHONY: msdos msdos_big freedos elks boot test test-extra apps clean
