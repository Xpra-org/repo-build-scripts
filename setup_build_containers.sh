#!/bin/bash

die() { echo "$*" 1>&2 ; exit 1; }

buildah --version >& /dev/null
if [ "$?" != "0" ]; then
	die "cannot continue without buildah"
fi

BUILDAH_DIR=`dirname $(readlink -f $0)`
pushd ${BUILDAH_DIR}

#arm64 builds require qemu-aarch64-static
RPM_DISTROS=${RPM_DISTROS:-Fedora:33 Fedora:34 Fedora:34:arm64 Fedora:35 Fedora:35:arm64 CentOS:7 CentOS:8 CentOS:8:arm64 CentOS:stream9}
#other distros we can build for:
# CentOS:centos7.6.1810 CentOS:centos7.7.1908 CentOS:centos7.8.2003 CentOS:centos7.9:2009
# CentOS:stream8
# CentOS:centos8.3.2011 CentOS:centos8.4.2105
for DISTRO in $RPM_DISTROS; do
	#docker names are lowercase:
	DISTRO_LOWER="${DISTRO,,}"
	DISTRO_NAME=`echo ${DISTRO} | awk -F: '{print $1}'`
	DISTRO_VARIANT=`echo ${DISTRO} | awk -F: '{print $2}'`
	if [[ "$DISTRO_LOWER" == "xx"* ]];then
	    echo "skipped $DISTRO"
	    continue
	fi
	IMAGE_NAME="`echo $DISTRO_LOWER | awk -F'/' '{print $1}' | sed 's/:/-/g'`-repo-build"
	PM="dnf"
	createrepo="createrepo_c"
	if [ "${DISTRO_NAME}" == "CentOS" ]; then
		if [ "${DISTRO_VARIANT}" == "7" ] || [[ "${DISTRO_VARIANT}" == "centos7."* ]]; then
			PM="yum"
			createrepo="createrepo"
		fi
	fi
	PM_CMD="$PM"
	ARCH=`echo $DISTRO | awk -F: '{print $3}'`
	if [ -z "${ARCH}" ]; then
		ARCH="amd64"
	fi
	#remove $ARCH:
	DISTRO_NOARCH=`echo "${DISTRO_LOWER}" | awk -F: '{print $1":"$2}'`
	echo
	echo "********************************************************************************"
	podman image exists $IMAGE_NAME
	if [ "$?" == "0" ]; then
		if [ "${SKIP_EXISTING:-1}" == "1" ]; then
			continue
		fi
		#make sure to skip the local repositories,
		#which may or may not be in a usable state:
		PM_CMD="$PM --disablerepo=repo-local-source --disablerepo=repo-local-build"
	else
		echo "creating ${IMAGE_NAME}"
		buildah from --arch "${ARCH}" --name "${IMAGE_NAME}" "${DISTRO_NOARCH}"
		if [ "$?" != "0" ]; then
			echo "Warning: failed to create image $IMAGE_NAME"
			continue
		fi
	fi
	if [[ "${DISTRO_LOWER}" == "fedora"* ]]; then
		#first install the config-manager plugin,
		#only enable the repo containing this plugin:
		#(this is more likely to succeed on flaky networks)
		buildah run $IMAGE_NAME dnf install -y dnf-plugins-core --disablerepo='*' --enablerepo='fedora'
		#some repositories are enabled by default,
		#but we don't want to use them
		#(any repository failures would cause problems)
		for repo in fedora-cisco-openh264 fedora-modular updates-modular updates-testing-modular updates-testing-modular-debuginfo updates-testing-modular-source; do
			#buildah run $IMAGE_NAME dnf config-manager --save "--setopt=$repo.skip_if_unavailable=true" $repo
			buildah run $IMAGE_NAME dnf config-manager --set-disabled $repo
		done
	fi
	buildah run $IMAGE_NAME $PM_CMD update -y
	buildah run $IMAGE_NAME $PM_CMD install -y redhat-rpm-config rpm-build rpmdevtools ${createrepo} rsync
	if [ "$PM" == "dnf" ]; then
		buildah run $IMAGE_NAME $PM_CMD install -y 'dnf-command(builddep)'
		buildah run $IMAGE_NAME bash -c "echo 'keepcache=true' >> /etc/dnf/dnf.conf"
		buildah run $IMAGE_NAME bash -c "echo 'deltarpm=false' >> /etc/dnf/dnf.conf"
		buildah run $IMAGE_NAME bash -c "echo 'fastestmirror=true' >> /etc/dnf/dnf.conf"
		if [[ "${DISTRO_LOWER}" == "fedora"* ]]; then
			#the easy way on Fedora which has an 'rpmspectool' package:
			buildah run $IMAGE_NAME ${PM_CMD} install -y rpmspectool
			#generate dnf cache:
			RNUM=`echo $DISTRO | awk -F: '{print $2}'`
			$PM_CMD -y makecache --releasever=$RNUM --setopt=cachedir=`pwd`/cache/dnf/$RNUM
		else
			#CentOS 8 and later:
			#there is no "rpmspectool" package so we have to use pip to install it:
			buildah run $IMAGE_NAME $PM_CMD install -y python3-pip
			buildah run $IMAGE_NAME pip3 install python-rpm-spec
		fi
	fi
	buildah run $IMAGE_NAME rpmdev-setuptree
	#buildah run dnf clean all

	buildah run $IMAGE_NAME mkdir -p "/src/repo/" "/src/rpm" "/src/debian" "/src/pkgs"
	buildah config --workingdir /src $IMAGE_NAME
	buildah copy $IMAGE_NAME "./local-build.repo" "/etc/yum.repos.d/"
	buildah run $IMAGE_NAME createrepo "/src/repo/"
	buildah commit $IMAGE_NAME $IMAGE_NAME
done

DEB_DISTROS=${DEB_DISTROS:-Ubuntu:bionic Ubuntu:focal Ubuntu:focal:arm64 Ubuntu:hirsute Ubuntu:hirsute:arm64 Ubuntu:impish Debian:stretch Debian:buster Debian:buster:arm64 Debian:bullseye Debian:bullseye:arm64 Debian:bookworm Debian:sid}
for DISTRO in $DEB_DISTROS; do
	#DISTRO_DIR_NAME="`echo $DISTRO | sed 's/:/-/g'`-repo-build"
	#mkdir -p packaging/buildah/repo/Fedora/{32,33,34} >& /dev/null
	#docker names are lowercase:
	DISTRO_LOWER="${DISTRO,,}"
	if [[ "$DISTRO_LOWER" == "xx"* ]];then
	    echo "skipped $DISTRO"
	    continue
	fi
	IMAGE_NAME="`echo $DISTRO_LOWER | sed 's/:/-/g'`-repo-build"
	ARCH=`echo $DISTRO | awk -F: '{print $3}'`
	if [ -z "${ARCH}" ]; then
		ARCH="amd64"
	fi
	#remove $ARCH:
	DISTRO_NOARCH=`echo "${DISTRO_LOWER}" | awk -F: '{print $1":"$2}'`
	echo
	echo "********************************************************************************"
	podman image exists $IMAGE_NAME
	if [ "$?" == "0" ]; then
		echo "${IMAGE_NAME} already exists"
		if [ "${SKIP_EXISTING:-1}" == "1" ]; then
			continue
		fi
	else
		echo "creating ${IMAGE_NAME}"
		buildah from --arch "${ARCH}" --name "$IMAGE_NAME" "$DISTRO_NOARCH"
	fi
	buildah config --env DEBIAN_FRONTEND=noninteractive $IMAGE_NAME
	buildah run $IMAGE_NAME apt-get update
	buildah run $IMAGE_NAME apt-get upgrade -y
	buildah run $IMAGE_NAME apt-get dist-upgrade -y
	buildah run $IMAGE_NAME apt-get install -y software-properties-common xz-utils
	echo "${DISTRO}" | grep "Ubuntu" > /dev/null
	if [ "$?" == "0" ]; then
		#the codecs require the "universe" repository:
		buildah run $IMAGE_NAME add-apt-repository universe -y
		buildah run $IMAGE_NAME apt-add-repository restricted -y
	else
		buildah run $IMAGE_NAME apt-add-repository non-free -y
	fi
	buildah run $IMAGE_NAME apt-get update
	buildah run $IMAGE_NAME apt-get remove -y unattended-upgrades
	buildah run $IMAGE_NAME mkdir -p "/src/repo/" "/src/rpm" "/src/debian" "/src/pkgs"
	buildah config --workingdir /src $IMAGE_NAME
	buildah copy $IMAGE_NAME "01keep-debs" "/etc/apt/apt.conf.d/01keep-debs"
	buildah copy $IMAGE_NAME "02broken-downloads" "/etc/apt/apt.conf.d/02broken-downloads"
	#we don't need a local repo yet:
	#DISTRO_NAME=`echo $DISTRO | awk -F: '{print $2}'`
	#buildah run $IMAGE_NAME bash -c 'echo "deb file:///repo $DISTRO_NAME main" > /etc/apt/sources.list.d/local-build.list'
	buildah commit $IMAGE_NAME $IMAGE_NAME
done
