#!/bin/bash

#
# global definitions
#

set -u
set -x
set -E
set -o pipefail

temp_dir=""
temp_dmg=""
declare -a temp_dmg_mounts

BLOCKSIZE=512
ADDON_DISK_SPACE=$((100*1024*1024 / BLOCKSIZE)) # 100 Mb in blocks
ADDON_DISK_SPACE_BIGSUR=$((1536*1024*1024 / BLOCKSIZE)) # 1.5 Gb in blocks

ERR_INVALID_ARG=1
ERR_FILE_EXISTS=2
ERR_UNEXPECTED=3
ERR_INTERRUPTED=4

#
# declare functions
#

cleanup() {
	# Cleanup (ignore errors)

	# Detach in reverse order
	dettach_dmg_all || true

	if [[ -d "$temp_dir" ]]; then
		rm -rf -- "$temp_dir" || true
		temp_dir=""
	fi

	if [[ -e "$temp_dmg" ]]; then
		rm -rf -- "$temp_dmg" || true
		temp_dmg=""
	fi
}

calc_file_size() {
	du -H -s "$1" | awk '{print $1}'
}

get_dmg_size() {
	hdiutil resize -limits "$1" | tail -n1 | awk '{print $2}'
}

attach_dmg() {
	local outvar="$1" # return/ouput value - mount point path
	local dmg_path="$2"
	local mount_root="$3"
	shift 3
	local mount_path=""

	# Check file exists, first
	[ -e "$dmg_path" ]

	# At first, check if mounted (do not mount, just try attach) and get mount point,
	# if "mount point" found - consider image already mounted (do not add to unmount list)
	# otherwise mount it and add to unmount list.
	mount_path="$(hdiutil attach "$dmg_path" -nomount -plist "$@" | grep -A1 "mount-point" | sed -n 's:.*<string>\(.*\)</string>.*:\1:p' || true)"
	if [ -z "$mount_path" ]; then
		for i in {1..10}; do
			mount_path="$(hdiutil attach "$dmg_path" -mount required -mountrandom "$mount_root" -plist "$@" | grep -A1 "mount-point" | sed -n 's:.*<string>\(.*\)</string>.*:\1:p' || true)"
			if [ -n "$mount_path" ]; then
				temp_dmg_mounts+=("$mount_path")
				break
			fi
			local disk="$(diskutil list | grep /dev/disk | grep -o '[[:digit:]]*' | tail -1)"
			disk=$((disk+1))
			((disk+=1))
			diskutil eject /dev/disk$disk
			sleep 3
		done
	fi

	# Error if mounted path empty
	[ -n "$mount_path" ]

	# return mounted path
	eval $outvar=\$mount_path
}

dettach_dmg() {
	# Unmount image by specified mount point
	local mount_path="$1"
	hdiutil detach "$mount_path"

	# Remove mount point from unmount list
	for (( idx=0 ; idx<${#temp_dmg_mounts[@]} ; )) ; do
		if [ "${temp_dmg_mounts[$idx]}" == "$mount_path" ]; then
			unset temp_dmg_mounts[$idx]
			return
		else
			((++idx))
		fi
	done
}

dettach_dmg_all() {
	# Unmount/detach all images in reverse order and cleanup the list
	while [ ${#temp_dmg_mounts[@]} -gt 0 ]; do
		local idx=$((${#temp_dmg_mounts[@]}-1))
		local mount_path="${temp_dmg_mounts[$idx]}"
		# Remove element from arr, to make sure no ifinite loop
		unset temp_dmg_mounts[$idx]
		dettach_dmg "$mount_path" || true
	done
}

move_file() {
	mkdir -p "$(dirname "$2")"
	mv "$1" "$2"
}

copy_file() {
	mkdir -p "$(dirname "$2")"
	cp -r "$1" "$2"
}

make_hard_link() {
	mkdir -p "$(dirname "$2")"
	ln "$1" "$2"
}

do_estimate() {
	if [[ $# -lt 1 ]]; then
		echo "Please specify the app bundle."
		return $ERR_INVALID_ARG
	fi

	local source_app="${1%/}"
	local size=$(calc_file_size "$source_app")
	if [[ -f "$source_app/Contents/SharedSupport/InstallESD.dmg" ]]; then
		size=$(((size + ADDON_DISK_SPACE)*BLOCKSIZE))
	else
		size=$(((size + ADDON_DISK_SPACE_BIGSUR)*BLOCKSIZE))
	fi
	echo $size
}

do_repack() {
	# Parse and check args/options
	if [[ $# -lt 2 ]]; then
		echo "Please specify the app bundle and resulting image file path."
		return $ERR_INVALID_ARG
	fi

	local source_app="${1%/}"
	local result_dmg="$2"
	shift 2

	local overwrite="n"
	local p7z_tool=""
	while getopts wz: OPT; do
		case "$OPT" in
		w) overwrite="y" ;;
		z) p7z_tool="$OPTARG" ;;
		esac
	done

	if [[ -L "$source_app" ]]; then
		source_app=$(readlink "$source_app")
	fi

	if [[ ! -r "$source_app" ]]; then
		echo "'$source_app' is not accessible."
		return $ERR_INVALID_ARG
	fi

	if [[ -e "$result_dmg" ]]; then
		if [[ "$overwrite" != "y" ]]; then
			echo "The file '$result_dmg' already exists. Please choose another filename and try again."
			return $ERR_FILE_EXISTS
		fi
		echo "The file '$result_dmg' already exists and will be removed."
		rm -- "$result_dmg"
	fi

	# check p7z_tool existance (if specified)
	if [[ -n "$p7z_tool"  && ! -x "$p7z_tool" ]]; then
		echo "7z tool '$p7z_tool' can not be executed."
		return $ERR_INVALID_ARG
	fi

	# Do repack (using 7z tool, if specified, or native tools only)
	if [[ -f "$source_app/Contents/SharedSupport/InstallESD.dmg" || -n "$p7z_tool" ]]; then
		do_repack_manual "$source_app" "$result_dmg" "$p7z_tool"
	else
		do_repack_createinstallmedia "$source_app" "$result_dmg"
	fi
}

do_repack_createinstallmedia() {
	local source_app="$1"
	local result_dmg="$2"
	local temp_result_dir=""

	# make temp directory for files manipulation
	temp_dir=$(mktemp -d "$result_dmg.tmp.XXXXXX")
	local temp_img_name="macOSInstallImage"
	local temp_img_file="$temp_dir/$temp_img_name.sparsebundle"

	# create sparse image with extra space (+3072MB)
	local size=$(($(calc_file_size "$source_app") + 2*ADDON_DISK_SPACE_BIGSUR))
	hdiutil create -sectors "$size" -fs hfs+ -volname "$temp_img_name" -type SPARSEBUNDLE "$temp_img_file"
	attach_dmg temp_result_dir "$temp_img_file" "$temp_dir" -nobrowse -noverify

	# should run with root privileges
	temp_result_dir="$("$source_app"/Contents/Resources/createinstallmedia --volume "$temp_result_dir" --nointeraction \
		| grep "available at" | sed 's/.*"\(.*\)".*/\1/')"

	# Note: mountpoint changes it's name, so detach the new one
	hdiutil detach -force "$temp_result_dir"

	# tweak to unmount forgotten image from Install.app bundle (BigSur beta issue)
	hdiutil info | awk -v path="$source_app" 'BEGIN{RS="================================================"} $0~path {print}' \
		 | awk -F$'\t' '/^\/dev\/disk.*\/Volumes\//{ print $3 }' | tr '\n' '\0' | xargs -0 -n1 hdiutil detach || true

	# make resulting .iso image
	hdiutil makehybrid -o "$result_dmg" "$temp_img_file"

	rm -rf -- "$temp_dir"

	# Write resulting image file size
	stat -f "%z" "$result_dmg"
}

do_repack_manual() {
	local source_app="$1"
	local result_dmg="$2"
	local p7z_tool="$3"

	# make temp directory for files manupulation
	temp_dir="$(mktemp -d -t 'osx_install_diskimage')"
	local temp_contents_dir="$temp_dir"/contents
	mkdir "$temp_contents_dir"

	local source_app_basename="$(basename "$source_app")"

	local result_vol_name="$(defaults read "$source_app"/Contents/Info CFBundleDisplayName)"
	local temp_result_dir=""

	local kernelcache_name=""
	local bootefi_name=""

	if [[ -z "$p7z_tool" ]]; then
		local temp_mount_installesd=""
		local temp_mount_basesystem=""

		# Mount (or get mount path, if already mounted) InstallESD.dmg and BaseSystem.dmg
		if [[ -e "$source_app"/Contents/SharedSupport/BaseSystem.dmg ]]; then
			attach_dmg temp_mount_basesystem "$source_app"/Contents/SharedSupport/BaseSystem.dmg "$temp_dir" -nobrowse -noverify -readonly
		else
			attach_dmg temp_mount_installesd "$source_app"/Contents/SharedSupport/InstallESD.dmg "$temp_dir" -nobrowse -noverify -readonly
			attach_dmg temp_mount_basesystem "$temp_mount_installesd"/BaseSystem.dmg "$temp_dir" -nobrowse -noverify -readonly
		fi

		# Copy boot.efi, prelinkedkernel, ... from BaseSystem.dmg to temp dir
		# ignore errors, will handle missing files later
		copy_file "$temp_mount_basesystem"/System/Library/PrelinkedKernels/prelinkedkernel "$temp_contents_dir"/prelinkedkernel || true
		copy_file "$temp_mount_basesystem"/System/Library/Caches/com.apple.kext.caches/Startup/kernelcache "$temp_contents_dir"/kernelcache || true
		copy_file "$temp_mount_basesystem"/System/Library/CoreServices/bootbase.efi "$temp_contents_dir"/bootbase.efi || true
		copy_file "$temp_mount_basesystem"/System/Library/CoreServices/boot.efi "$temp_contents_dir"/boot.efi || true
		copy_file "$temp_mount_basesystem"/System/Library/CoreServices/SystemVersion.plist "$temp_contents_dir"/SystemVersion.plist || true
		copy_file "$temp_mount_basesystem"/System/Library/CoreServices/PlatformSupport.plist "$temp_contents_dir"/PlatformSupport.plist || true
	else
		local base_system_dmg=""
		local temp_base_system_dmg=""

		if [[ -e "$source_app"/Contents/SharedSupport/BaseSystem.dmg ]]; then
			base_system_dmg="$source_app"/Contents/SharedSupport/BaseSystem.dmg
		elif [[ -e "$source_app"/Contents/SharedSupport/InstallESD.dmg ]]; then
			local temp_install_esd_dmg="$temp_dir"/InstallESD.dmg

			# Convert (via hdiutil) InstallESD.dmg to plain format readable for 7z
			# Extract (via 7z) BaseSystem.dmg from InstallESD.dmg
			hdiutil convert -format UDRW -o "$temp_install_esd_dmg" "$source_app"/Contents/SharedSupport/InstallESD.dmg

			"$p7z_tool" e -aos -o"$temp_dir" "$temp_install_esd_dmg" */BaseSystem.dmg

			# Extracted BaseSystem.dmg (temporary file) can be found in "$temp_dir"
			temp_base_system_dmg="$temp_dir"/BaseSystem.dmg
			base_system_dmg="$temp_base_system_dmg"

			rm -- "$temp_install_esd_dmg"
		elif [[ -e "$source_app"/Contents/SharedSupport/SharedSupport.dmg ]]; then
			local temp_ss_dmg="$temp_dir"/SharedSupport.dmg

			# Convert SharedSupport.dmg to plain format readable for 7z
			hdiutil convert -format UDRW -o "$temp_ss_dmg" "$source_app"/Contents/SharedSupport/SharedSupport.dmg

			# Extract main .zip update package
			local zip_update_dir="$temp_dir/zip-update"
			mkdir "$zip_update_dir"
			"$p7z_tool" e -aos -o"$zip_update_dir" "$temp_ss_dmg" */com_apple_MobileAsset_MacSoftwareUpdate/*.zip
			local temp_update_zip="$(find "$zip_update_dir" -name "*.zip")"
			rm -- "$temp_ss_dmg"

			# Extract BaseSystem image and other boot files
			"$p7z_tool" e -aos -o"$temp_contents_dir" "$temp_update_zip" \
				AssetData/Restore/BaseSystem.dmg \
				AssetData/Restore/BaseSystem.chunklist \
				AssetData/boot/Firmware/usr/standalone/i386/boot.efi \
				AssetData/boot/System/Library/KernelCollections/BootKernelExtensions.kc \
				AssetData/boot/System/Library/PrelinkedKernels/immutablekernel \
				AssetData/boot/SystemVersion.plist \
				AssetData/boot/PlatformSupport.plist \
				AssetData/boot/BridgeVersion.bin

			[ -e "$temp_contents_dir"/immutablekernel ] && mv "$temp_contents_dir"/immutablekernel "$temp_contents_dir"/prelinkedkernel

			rm -- "$temp_update_zip"
		fi

		# Extract (via 7z) boot.efi, prelinkedkernel, ... from BaseSystem.dmg
		[ -e "$base_system_dmg" ] && "$p7z_tool" e -aos -o"$temp_contents_dir" "$base_system_dmg" \
			*/System/Library/PrelinkedKernels/prelinkedkernel \
			*/System/Library/Caches/com.apple.kext.caches/Startup/kernelcache \
			*/System/Library/CoreServices/bootbase.efi \
			*/System/Library/CoreServices/boot.efi \
			*/System/Library/CoreServices/SystemVersion.plist \
			*/System/Library/CoreServices/PlatformSupport.plist

		[ -z "$temp_base_system_dmg" ] || rm -- "$temp_base_system_dmg"
	fi

	[ -e "$temp_contents_dir"/prelinkedkernel ] && kernelcache_name="prelinkedkernel" || kernelcache_name="kernelcache"
	[ -e "$temp_contents_dir"/bootbase.efi ] && bootefi_name="bootbase.efi" || bootefi_name="boot.efi"

	# Generate InstallAssistant config files
	local kernel_flags="container-dmg=file:///${source_app_basename// /%20}/Contents/SharedSupport/InstallESD.dmg root-dmg=file:///BaseSystem.dmg"
	local plist_cache_entry="<key>Kernel Cache</key>
	<string>/.IABootFiles/$kernelcache_name</string>"
	if [[ -e "$source_app"/Contents/SharedSupport/BaseSystem.dmg ]]; then
		kernel_flags="root-dmg=file:///${source_app_basename// /%20}/Contents/SharedSupport/BaseSystem.dmg"
	elif [[ -e "$source_app"/Contents/SharedSupport/SharedSupport.dmg ]]; then
		kernel_flags="root-dmg=file:///BaseSystem/BaseSystem.dmg"
		plist_cache_entry=""
	fi

	cat <<STOP >"$temp_contents_dir"/.IAPhysicalMedia
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AppName</key>
	<string>$source_app_basename</string>
</dict>
</plist>
STOP

	cat <<STOP >"$temp_contents_dir"/com.apple.Boot.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	$plist_cache_entry
	<key>Kernel Flags</key>
	<string>$kernel_flags</string>
</dict>
</plist>
STOP

	if [[ -z "$p7z_tool" ]]; then
		# Calc resulting dmg size (in sectors)
		local dmg_size=$(( $(calc_file_size "$source_app") + $(calc_file_size "$temp_contents_dir") ))
		dmg_size=$((dmg_size + ADDON_DISK_SPACE))

		# Create resulting temp dmg (APM lyaout)
		temp_dmg="$result_dmg"
		hdiutil create "$result_dmg" -layout SPUD -sectors "$dmg_size" -fs HFS+J -volname "$result_vol_name"

		# Mount/attach resulting temp dmg to $temp_result_dir
		attach_dmg temp_result_dir "$result_dmg" "$temp_dir" -nobrowse -noverify
	else
		# Make directory for "hybrid CD" creation
		temp_result_dir="$temp_dir"/"$result_vol_name"
		mkdir "$temp_result_dir"
	fi

	# Compose resulting .dmg contents (copy .app bundle, boot and kernel files, ...)

	move_file "$temp_contents_dir"/"$bootefi_name" "$temp_result_dir"/System/Library/CoreServices/boot.efi
	move_file "$temp_contents_dir"/SystemVersion.plist "$temp_result_dir"/System/Library/CoreServices/SystemVersion.plist
	move_file "$temp_contents_dir"/PlatformSupport.plist "$temp_result_dir"/System/Library/CoreServices/PlatformSupport.plist
	move_file "$temp_contents_dir"/.IAPhysicalMedia "$temp_result_dir"/.IAPhysicalMedia
	move_file "$temp_contents_dir"/com.apple.Boot.plist "$temp_result_dir"/Library/Preferences/SystemConfiguration/com.apple.Boot.plist

	make_hard_link "$temp_result_dir"/System/Library/CoreServices/boot.efi "$temp_result_dir"/EFI/Boot/bootx64.efi
	make_hard_link "$temp_result_dir"/System/Library/CoreServices/boot.efi "$temp_result_dir"/usr/standalone/i386/boot.efi
	make_hard_link "$temp_result_dir"/System/Library/CoreServices/boot.efi "$temp_result_dir"/.IABootFiles/boot.efi
	make_hard_link "$temp_result_dir"/System/Library/CoreServices/PlatformSupport.plist "$temp_result_dir"/.IABootFiles/PlatformSupport.plist
	make_hard_link "$temp_result_dir"/Library/Preferences/SystemConfiguration/com.apple.Boot.plist "$temp_result_dir"/.IABootFiles/com.apple.Boot.plist
	make_hard_link "$temp_result_dir"/System/Library/CoreServices/SystemVersion.plist "$temp_result_dir"/.IABootFilesSystemVersion.plist

	if [[ -e "$temp_contents_dir"/"$kernelcache_name" ]]; then
		move_file "$temp_contents_dir"/"$kernelcache_name" "$temp_result_dir"/System/Library/Caches/com.apple.kext.caches/Startup/"$kernelcache_name"
		make_hard_link "$temp_result_dir"/System/Library/Caches/com.apple.kext.caches/Startup/"$kernelcache_name" "$temp_result_dir"/.IABootFiles/"$kernelcache_name"
		make_hard_link "$temp_result_dir"/System/Library/Caches/com.apple.kext.caches/Startup/"$kernelcache_name" "$temp_result_dir"/System/Library/PrelinkedKernels/"$kernelcache_name"
	fi

	if [[ -e "$source_app"/Contents/SharedSupport/SharedSupport.dmg ]]; then
		move_file "$temp_contents_dir"/BridgeVersion.bin "$temp_result_dir"/System/Library/CoreServices/BridgeVersion.bin
		move_file "$temp_contents_dir"/BootKernelExtensions.kc "$temp_result_dir"/System/Library/KernelCollections/BootKernelExtensions.kc
		make_hard_link "$temp_result_dir"/System/Library/PrelinkedKernels/"$kernelcache_name" "$temp_result_dir"/System/Library/PrelinkedKernels/immutablekernel || true

		move_file "$temp_contents_dir"/BaseSystem.dmg "$temp_result_dir"/BaseSystem/BaseSystem.dmg
		move_file "$temp_contents_dir"/BaseSystem.chunklist "$temp_result_dir"/BaseSystem/BaseSystem.chunklist
	fi

	# Copy source .app into image
	cp -R "$source_app" "$temp_result_dir"

	if [[ -z "$p7z_tool" ]]; then
		# Detach resulting image, all done
		dettach_dmg "$temp_result_dir"
	else
		local temp_hybrid_cd_dmg="$temp_dir"/hybrid-cd.dmg

		local temp_hfs_partition_dmg="$temp_dir"/hfs-partition.dmg

		# Make (via hdiutil) "hybrid CD" and extract (via 7z) HFS partition image
		hdiutil makehybrid -hfs -o "$temp_hybrid_cd_dmg" "$temp_result_dir"

		rm -rf -- "$temp_result_dir"

		"$p7z_tool" e -tapm -so -aos "$temp_hybrid_cd_dmg" *.hfs > "$temp_hfs_partition_dmg" || true

		rm -- "$temp_hybrid_cd_dmg"

		# Convert (via hdituil) HFS+ partition image to APM disk image (with partition map) and
		temp_dmg="$result_dmg"
		hdiutil convert -format UDRW -pmap -o "$result_dmg" "$temp_hfs_partition_dmg"

		rm -- "$temp_hfs_partition_dmg"

		# May not resize in sandbox. So resulted disk will not have
		# any free space. But this appears to be not a problem
	fi

	# Image is ready
	temp_dmg=""

	# Write resulting image file size
	stat -f "%z" "$result_dmg"
}

#
# perform
#

trap "cleanup; exit $ERR_UNEXPECTED" ERR
trap "cleanup; exit $ERR_INTERRUPTED" SIGHUP SIGINT SIGTERM

#
# Usage :
#
# estimate <path to .app bundle>
# repack   <path to .app bundle> <path to destination image file .dmg> [-w] [-z=<path to 7z tool>]
#
# -w : overwrite existing image file
# -z : use 7z tool to exstract source image file(s) contents (use for sandbox mode, when mount is not available)
#

# Parse args and do an action

if [[ $# -lt 1 ]]; then
	echo "Please specify the action."
	exit $ERR_INVALID_ARG
fi
action="$1"
shift

case "$action" in
	estimate)
		do_estimate "$@"
		;;
	repack)
		do_repack "$@"
		;;
	*)
		echo "Invalid action '$action'."
		exit $ERR_INVALID_ARG
		;;
esac

trap ERR
trap SIGHUP SIGINT SIGTERM
cleanup
