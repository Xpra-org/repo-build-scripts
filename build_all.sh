#!/bin/bash

die() { echo "$*" 1>&2 ; exit 1; }

BASH="bash"
if [ "${DEBUG:-0}" == "1" ]; then
	BASH="bash -x"
fi

BUILDAH_DIR=`dirname $(readlink -f $0)`
cd ${BUILDAH_DIR}

mkdir cache >& /dev/null
rm -fr cache/ldconfig cache/libX11 cache/debconf cache/man

PACKAGING="$BUILDAH_DIR/packaging"
if [ ! -e "${PACKAGING}" ]; then
	echo "${PACKAGING} should point to the repository build definitions"
	exit 1
fi

DO_DOWNLOAD="${DO_DOWNLOAD:-1}"
if [ "${DO_DOWNLOAD}" == "1" ]; then
	$BASH ./download_source.sh
fi

#distros supported by xpra git master:
#DISTROS="Fedora:35 Fedora:35:arm64 Fedora:36 Fedora:36:arm64 Fedora:37 CentOS:8 almalinux:8.6 rockylinux:8 oraclelinux:8.6 CentOS:stream8 CentOS:stream8:arm64 CentOS:stream9 almalinux:9 rockylinux:9 oraclelinux:9 Ubuntu:bionic Ubuntu:focal Ubuntu:focal:arm64 Ubuntu:jammy Ubuntu:jammy:arm64 Ubuntu:kinetic Ubuntu:lunar Debian:stretch Debian:buster Debian:buster:arm64 Debian:bullseye Debian:bullseye:arm64 Debian:bookworm Debian:bookworm:arm64 Debian:sid"
#all the distros supported by the xpra 3.1.x branch:
#DISTROS="Fedora:35 Fedora:36 CentOS:7 CentOS:8 CentOS:stream8 almalinux:8.6 rockylinux:8 oraclelinux:8.6 CentOS:stream8 Ubuntu:bionic Debian:stretch Debian:buster Debian:bullseye"
if [ -z "${DISTROS}" ]; then
	#default to build all distros found:
	DISTROS=`buildah images | grep '\-repo-build' | awk '{print $1}' | sed 's+.*/++g' | sed 's/-repo-build//g' | grep -vF "." | sort -V`
fi

for DISTRO in $DISTROS; do
	echo
	echo "********************************************************************************"
	#ie: DISTRO="Fedora:35:arm64" or "ubuntu-focal"
	# DISTRO_NAME="fedora-35-arm64"
	FULL_DISTRO_NAME=`echo ${DISTRO,,} | sed 's/:/-/g'`
	#split parts:
	#1=Fedora
	DISTRO_NAME=`echo ${FULL_DISTRO_NAME} | awk -F- '{print $1}'`
	if [ "${DISTRO_NAME}" == "fedora" ]; then
		DISTRO_NAME="Fedora"
	elif [ "${DISTRO_NAME}" == "centos" ]; then
		DISTRO_NAME="CentOS"
	fi
	#2=35
	DISTRO_VARIANT=`echo ${FULL_DISTRO_NAME} | awk -F- '{print $2}'`
	#strip centos from distro variant:
	#ie: centos7.6.1801 -> 7.6.1801
	DISTRO_VARIANT="${DISTRO_VARIANT#centos}"
	#3=arm64
	ARCH=`echo ${FULL_DISTRO_NAME} | awk -F- '{print $3}'`
	if [ -z "${ARCH}" ]; then
		ARCH="x86_64"
	fi
	#ie: fedora-35-arm64-repo-build
	IMAGE_NAME="$FULL_DISTRO_NAME-repo-build"

	#use a temp image:
	TEMP_IMAGE="$IMAGE_NAME-temp"
	buildah rm "${TEMP_IMAGE}" >& /dev/null
	buildah rmi "${TEMP_IMAGE}" >& /dev/null
	buildah from --pull-never --name  $TEMP_IMAGE $IMAGE_NAME || die "failed to pull image $IMAGE_NAME"
	if [ "$?" != "0" ]; then
		echo "cannot build $DISTRO : image $IMAGE_NAME is missing or $TEMP_IMAGE already exists?"
		continue
	fi
	echo "$DISTRO : $IMAGE_NAME"
	buildah run $TEMP_IMAGE mkdir -p /opt /src/repo /src/pkgs src/rpm /src/debian /var/cache/dnf || die "failed to create directories"
	echo "$DISTRO" | egrep -iv "fedora|centos|almalinux|rockylinux|oraclelinux" >& /dev/null
	RPM="$?"
	if [ "${RPM}" == "1" ]; then
		LIB="/usr/lib64"
		REPO_PATH="${BUILDAH_DIR}/repo/${DISTRO_NAME}/${DISTRO_VARIANT}"
		DISTRO_ARCH_NAME="${DISTRO_NAME,,}-${ARCH,,}"
		RPM_LIST_OPTIONS="${FULL_DISTRO_NAME}"
		variant="${DISTRO_VARIANT,,}"
		while [ ! -z "$variant" ]; do
			#ie: CentOS-7.6.1801
			RPM_LIST_OPTIONS="${RPM_LIST_OPTIONS} ${DISTRO_NAME,,}-${variant}"
			#strip everything after the last dot:
			#ie: '7.6.1801' -> '7.6' -> '7' -> ''
			new_variant="${variant%.*}"
			if [ "$new_variant" == "$variant" ]; then
				break
			fi
			variant="$new_variant"
		done
		RPM_LIST_OPTIONS="${RPM_LIST_OPTIONS} ${DISTRO_ARCH_NAME} ${DISTRO_NAME,,} ${ARCH} default" 
		for list_name in ${RPM_LIST_OPTIONS}; do
			#prefer lists found in rpm/distros/
			if [ -r "${PACKAGING}/rpm/distros/${list_name}.list" ]; then
				rpm_list_path=`readlink -e ${PACKAGING}/rpm/distros/${list_name}.list`
				echo " using rpm package list from ${rpm_list_path}"
				buildah copy $TEMP_IMAGE "${rpm_list_path}" "/src/rpms.list" || die "failed to copy rpms.list list"
				break
			fi
			#old location:
			if [ "${list_name}" == "default" ]; then
				rpm_list="${PACKAGING}/rpm/rpms.txt"
			else
				rpm_list="${PACKAGING}/rpm/${list_name}-rpms.txt"
			fi
			if [ -r "${rpm_list}" ]; then
				rpm_list_path=`readlink -e ${rpm_list}`
				echo " using rpm package list from ${rpm_list_path}"
				buildah copy $TEMP_IMAGE "${rpm_list_path}" "/src/rpms.list" || die "failed to copy rpms.list list"
				break
			fi
		done
		BUILD_SCRIPT="build_rpms.sh"
		echo "RPM: $REPO_PATH"
	else
		LIB="/usr/lib"
		REPO_PATH="${BUILDAH_DIR}/repo/$DISTRO_VARIANT"
		BUILD_SCRIPT="build_debs.sh"
		echo "DEB: $REPO_PATH"
	fi
	buildah copy $TEMP_IMAGE "./${BUILD_SCRIPT}" "/src/${BUILD_SCRIPT}" || die "failed to copy build script"
	mkdir -p $REPO_PATH >& /dev/null

	#set to "0" to avoid building the NVIDIA proprietary codecs NVENC, NVFBC and NVJPEG
	NVIDIA_CODECS="${NVIDIA_CODECS:-1}"
	if [ "${NVIDIA_CODECS}" == "1" ]; then
		if [ -z "${NVIDIA_PC_FILES}" ]; then
			NVIDIA_PC_FILES=""
			if [ "${ARCH}" == "x86_64" ]; then
				NVIDIA_PC_FILES="cuda nvenc nvjpeg nvfbc"
				#libnvidia-fbc.so.* must be placed in the lib path specified in nvfbc.pc
			fi
			if [ "${ARCH}" == "arm64" ]; then
				NVIDIA_PC_FILES="cuda nvenc nvjpeg"
			fi
		fi
		for pc_file in ${NVIDIA_PC_FILES}; do
			#find the file, which may be arch specific:
			for t in "$pc_file-$ARCH.pc" "$pc_file.pc"; do
				if [ -r "./pkgconfig/$t" ]; then
					buildah copy $IMAGE_NAME "./pkgconfig/$t" "${LIB}/pkgconfig/$pc_file.pc" || die "failed to copy $pc_file.pc"
					break
				fi
			done
		done
	fi
	#manage ./opt/cuda as a symlink to the arch specific version:
	pushd opt
	rm -f cuda
	ln -sf cuda-$ARCH cuda
	popd

	buildah commit $IMAGE_NAME $IMAGE_NAME || die "failed to commit $IMAGE_NAME"

	if [ ! -z "${RUN_CMD}" ]; then
		buildah run \
					--volume ${BUILDAH_DIR}/opt:/opt:ro,z \
					--volume ${BUILDAH_DIR}/pkgs:/src/pkgs:ro,z \
					--volume ${BUILDAH_DIR}/cache:/var/cache:rw,z \
					--volume ${REPO_PATH}:/src/repo:noexec,nodev,z \
					--volume ${PACKAGING}/rpm:/src/rpm:ro,z \
					--volume ${PACKAGING}/debian:/src/debian:O \
					$TEMP_IMAGE ${RUN_CMD}
	else
		buildah run \
					--volume ${BUILDAH_DIR}/opt:/opt:ro,z \
					--volume ${BUILDAH_DIR}/pkgs:/src/pkgs:ro,z \
					--volume ${BUILDAH_DIR}/cache:/var/cache:rw,z \
					--volume ${REPO_PATH}:/src/repo:noexec,nodev,z \
					--volume ${PACKAGING}/rpm:/src/rpm:ro,z \
					--volume ${PACKAGING}/debian:/src/debian:O \
					$TEMP_IMAGE $BASH -c "DEBUG=${DEBUG} /src/${BUILD_SCRIPT}" |& tee "./logs/${FULL_DISTRO_NAME}.log"
	fi
	buildah rm "${TEMP_IMAGE}"
done
