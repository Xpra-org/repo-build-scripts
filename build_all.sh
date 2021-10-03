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

RPM_DISTROS=${RPM_DISTROS:-Fedora:33 Fedora:34 Fedora:34:arm64 Fedora:35 Fedora:35:arm64 CentOS:7 CentOS:8 CentOS:8:arm64}
DEB_DISTROS=${DEB_DISTROS:-Ubuntu:bionic Ubuntu:focal Ubuntu:focal:arm64 Ubuntu:hirsute Ubuntu:hirsute:arm64 Ubuntu:impish Debian:stretch Debian:buster Debian:bullseye Debian:bullseye:arm64 Debian:bookworm Debian:sid}
if [ -z "${DISTROS}" ]; then
	DISTROS="$RPM_DISTROS $DEB_DISTROS"
fi

for DISTRO in $DISTROS; do
	echo
	echo "********************************************************************************"
	#ie: DISTRO="Fedora:35:arm64"
	# DISTRO_NAME="fedora-35-arm64"
	FULL_DISTRO_NAME=`echo ${DISTRO,,} | sed 's/:/-/g'`
	#split parts:
	#1=Fedora
	DISTRO_NAME=`echo ${DISTRO} | awk -F: '{print $1}'`
	#2=35
	DISTRO_VARIANT=`echo ${DISTRO} | awk -F: '{print $2}'`
	#3=arm64
	ARCH=`echo $DISTRO | awk -F: '{print $3}'`
	if [ -z "${ARCH}" ]; then
		ARCH="x86_64"
	fi
	#ie: fedora-35-arm64-repo-build
	IMAGE_NAME="$FULL_DISTRO_NAME-repo-build"

	#use a temp image:
	TEMP_IMAGE="$IMAGE_NAME-temp"
	buildah rm "${TEMP_IMAGE}" >& /dev/null
	buildah rmi "${TEMP_IMAGE}" >& /dev/null
	buildah from --pull-never --name  $TEMP_IMAGE $IMAGE_NAME
	if [ "$?" != "0" ]; then
		echo "cannot build $DISTRO : image $IMAGE_NAME is missing or $TEMP_IMAGE already exists?"
		continue
	fi
	echo "$DISTRO : $IMAGE_NAME"
	buildah run $TEMP_IMAGE mkdir -p /opt /src/repo /src/pkgs src/rpm /src/debian /var/cache/dnf
	echo "$DISTRO" | egrep -iv "fedora|centos" >& /dev/null
	RPM="$?"
	if [ "${RPM}" == "1" ]; then
		LIB="/usr/lib64"
		REPO_PATH="${BUILDAH_DIR}/repo/${DISTRO_NAME}/${DISTRO_VARIANT}"
		DISTRO_ARCH_NAME="${DISTRO_NAME,,}-${ARCH,,}"
		for rpm_list in "${FULL_DISTRO_NAME}-rpms.txt" "${DISTRO_ARCH_NAME}-rpms.txt" "${DISTRO_NAME,,}-rpms.txt" "${ARCH}-rpms.txt" "rpms.txt"; do
			if [ -r "${PACKAGING}/rpm/${rpm_list}" ]; then
				rpm_list_path=`readlink -e ${PACKAGING}/rpm/${rpm_list}`
				echo " using rpm package list from ${rpm_list_path}"
				buildah copy $TEMP_IMAGE "${rpm_list_path}" "/src/rpms.txt"
				break
			fi
		done
		BUILD_SCRIPT="build_rpms.sh"
		echo "RPM: $REPO_PATH"
	else
		LIB="/usr/lib"
		DISTRO_RELEASE=`echo $DISTRO | awk -F: '{print $2}'`
		REPO_PATH="${BUILDAH_DIR}/repo/$DISTRO_RELEASE"
		BUILD_SCRIPT="build_debs.sh"
		echo "DEB: $REPO_PATH"
	fi
	buildah copy $TEMP_IMAGE "./${BUILD_SCRIPT}" "/src/${BUILD_SCRIPT}"
	mkdir -p $REPO_PATH >& /dev/null

	#set to "0" to avoid building the NVIDIA proprietary codecs NVENC, NVFBC and NVJPEG,
	#this is only enabled by default on x86_64:
	if [ -z "${NVIDIA_CODECS}" ]; then
		if [ "${ARCH}" == "x86_64" ]; then
			NVIDIA_CODECS=1
		else
			NVIDIA_CODECS=0
		fi
	fi
	if [ "${NVIDIA_CODECS}" == "1" ]; then
		PKGCONFIG="${LIB}/pkgconfig"
		buildah copy $IMAGE_NAME "./nvenc.pc" "${PKGCONFIG}/nvenc.pc"
		buildah copy $IMAGE_NAME "./nvfbc.pc" "${PKGCONFIG}/nvfbc.pc"
		buildah copy $IMAGE_NAME "./nvjpeg.pc" "${PKGCONFIG}/nvjpeg.pc"
		buildah copy $IMAGE_NAME "./cuda.pc" "${PKGCONFIG}/cuda.pc"
		#no libnvidia-fbc in the standard repos, so use the local one:
		buildah copy $IMAGE_NAME /usr/lib64/libnvidia-fbc.so.*.* "$LIB/libnvidia-fbc.so"
	fi
	buildah commit $IMAGE_NAME $IMAGE_NAME

	if [ ! -z "${RUN_CMD}" ]; then
		buildah run \
					--volume ${BUILDAH_DIR}/opt:/opt:ro,z \
					--volume ${BUILDAH_DIR}/pkgs:/src/pkgs:ro,z \
					--volume ${BUILDAH_DIR}/cache:/var/cache:rw,z \
					--volume $REPO_PATH:/src/repo:noexec,nodev,z \
					--volume ${PACKAGING}/rpm:/src/rpm:ro,z \
					--volume ${PACKAGING}/debian:/src/debian:O \
					$TEMP_IMAGE ${RUN_CMD}
	else
		buildah run \
					--volume ${BUILDAH_DIR}/opt:/opt:ro,z \
					--volume ${BUILDAH_DIR}/pkgs:/src/pkgs:ro,z \
					--volume ${BUILDAH_DIR}/cache:/var/cache:rw,z \
					--volume $REPO_PATH:/src/repo:noexec,nodev,z \
					--volume ${PACKAGING}/rpm:/src/rpm:ro,z \
					--volume ${PACKAGING}/debian:/src/debian:O \
					$TEMP_IMAGE $BASH -c "DEBUG=${DEBUG} /src/${BUILD_SCRIPT}" |& tee "./${FULL_DISTRO_NAME}.log"
	fi
	buildah rm "${TEMP_IMAGE}"
done
