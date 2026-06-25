PBG_VERSION ?= snapshot

# the directory on the pixel where the scripts will be installed
DEVICE_INSTALL_DIRECTORY := /data/local/tmp
# uncomment the following line to install into the termux home directory
# DEVICE_INSTALL_DIRECTORY := /data/data/com.termux/files/home

HOST_ADB_COMMAND ?= adb
# uncomment the following line on WSL to use adb.exe from windows, which allows for USB support
# HOST_ADB_COMMAND := /mnt/c/Users/someone/AppData/Local/Android/Sdk/platform-tools/adb.exe

# the directory on the pixel where the release tarball will be pushed
DEVICE_TEMP_DIRECTORY := /data/local/tmp
RELEASE_BUILD_DIRECTORY := .release/pixel-backup-gang

ALL_SCRIPTS := \
ssd.sh \
scripts/run_as_termux.sh \
scripts/mount_ext4.sh \
scripts/remount_vfat.sh \
scripts/unmount.sh \
scripts/find_device.sh \
scripts/show_devices.sh \
scripts/enable_tcp_debugging.sh \
scripts/disable_tcp_debugging.sh \
scripts/start_global_shell.sh \

CONFIG_FILES := \
config/drive.uuid.example \

TEST_SCRIPTS := \
tests/ssd_sh_test.sh \

.PHONY: release
release: shellcheck pixel-backup-gang-$(PBG_VERSION).tar.gz

.PHONY: shellcheck
shellcheck: $(ALL_SCRIPTS) $(TEST_SCRIPTS)
	shellcheck --shell=sh --severity=style --check-sourced $^

pixel-backup-gang-$(PBG_VERSION).tar.gz: $(ALL_SCRIPTS) $(CONFIG_FILES)
	rm -rf .release
	mkdir -p $(RELEASE_BUILD_DIRECTORY)/config
	cp $(ALL_SCRIPTS) $(RELEASE_BUILD_DIRECTORY)/
	cp $(CONFIG_FILES) $(RELEASE_BUILD_DIRECTORY)/config/
	tar -czvf $@ -C .release pixel-backup-gang

.PHONY: clean
clean:
	rm -f pixel-backup-gang-*.tar.gz
	rm -rf .release

# utility to install to the device connected over adb
.PHONY: mobile-install
mobile-install: release
	# copy the tarball containing scripts
	$(HOST_ADB_COMMAND) push ./pixel-backup-gang-$(PBG_VERSION).tar.gz $(DEVICE_TEMP_DIRECTORY)
	# extract the scripts
	$(HOST_ADB_COMMAND) shell su --command 'tar -xvf $(DEVICE_TEMP_DIRECTORY)/pixel-backup-gang-$(PBG_VERSION).tar.gz -C $(DEVICE_INSTALL_DIRECTORY)'
	# make the scripts executable
	$(HOST_ADB_COMMAND) shell su --command 'chmod +x $(DEVICE_INSTALL_DIRECTORY)/pixel-backup-gang/*.sh'
	# done, installed scripts to $(DEVICE_INSTALL_DIRECTORY)/pixel-backup-gang
