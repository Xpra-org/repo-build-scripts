#!/bin/bash

die() { echo "$*" 1>&2 ; exit 1; }

buildah --version >& /dev/null
if [ "$?" != "0" ]; then
	die "cannot continue without buildah"
fi

BUILDAH_DIR=`dirname $(readlink -f $0)`
pushd ${BUILDAH_DIR}


# dnf5 completely broke this:
# `buildah run $IMAGE_NAME dnf config-manager --set-disabled $repo`
# and the recommended alternative is not backwards compatible!
# (why oh why all this unnecessary breakage)
enable_repo() {
	repo=$1
	# repofile="/etc/yum.repos.d/${repo}.repo"
	# buildah run $IMAGE_NAME bash -c "[ -r $repofile ] && sed -E -i 's/enabled=.?/enabled=1/g' ${repofile} || true"
	buildah run $IMAGE_NAME bash -c "dnf-3 config-manager --set-enabled ${repo}"
}
disable_repo() {
	repo=$1
	buildah run $IMAGE_NAME bash -c "dnf-3 config-manager --set-disabled ${repo}"
}

#arm64 builds require qemu-aarch64-static
RPM_DISTROS=${RPM_DISTROS:-Fedora:40 Fedora:40:arm64 Fedora:41 Fedora:41:arm64 Fedora:42 almalinux:8.8 almalinux:8.9 almalinux:8.10 rockylinux:8.8 rockylinux:8.9 rockylinux:8.10 oraclelinux:8.8 oraclelinux:8.9 oraclelinux:8.10 CentOS:stream9 CentOS:stream9:arm64 CentOS:stream10-development almalinux:9.5 almalinux:9.4 almalinux:9.3 almalinux:9.2 rockylinux:9.2 rockylinux:9.3 rockylinux:9.4 rockylinux:9.5 oraclelinux:9}
#other distros we can build for:
# CentOS:stream9
# CentOS:centos8.3.2011 CentOS:8.4.2105
# almalinux:8.4
for DISTRO in $RPM_DISTROS; do
	#docker names are lowercase:
	DISTRO_LOWER="${DISTRO,,}"
	DISTRO_NAME=`echo ${DISTRO} | awk -F: '{print $1}'`
	DISTRO_VARIANT=`echo ${DISTRO} | awk -F: '{print $2}'`
	DISTRO_NO=`echo "${DISTRO_VARIANT//[^0-9.]/}"`					#ie: "almalinux:9.2" - > "9.2"
	DISTRO_MAJOR_NO=`echo "${DISTRO_NO}" | awk -F. '{print $1}'`	#ie: "almalinux:9.2" - > "9"
	if [[ "$DISTRO_LOWER" == "xx"* ]];then
	    echo "skipped $DISTRO"
	    continue
	fi
	IMAGE_NAME="`echo $DISTRO_LOWER | awk -F'/' '{print $1}' | sed 's/:/-/g'`-repo-build"
	ARCH=`echo $DISTRO | awk -F: '{print $3}'`
	if [ -z "${ARCH}" ]; then
		ARCH="amd64"
	fi
	#remove $ARCH:
	DISTRO_NOARCH=`echo "${DISTRO_LOWER}" | awk -F: '{print $1":"$2}'`
	echo
	echo "********************************************************************************"
	podman image exists "${IMAGE_NAME}"
	if [ "$?" == "0" ]; then
		echo "${IMAGE_NAME} already exists"
		if [ "${SKIP_EXISTING:-1}" == "1" ]; then
			continue
		fi
		#delete existing image
		buildah rmi "${IMAGE_NAME}"
	fi
	buildah rm "${IMAGE_NAME}"
	echo "creating ${IMAGE_NAME}"
	buildah from --arch "${ARCH}" --name "${IMAGE_NAME}" "${DISTRO_NOARCH}"
	if [ "$?" != "0" ]; then
		echo "Warning: failed to create image $IMAGE_NAME"
		continue
	fi
	if [[ "${DISTRO}" == "CentOS:8"* ]]; then
		#use cloudflare for vault, where "centos8" now lives:
		buildah run $IMAGE_NAME bash -c "sed -i 's/^mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-Linux-*"
		buildah run $IMAGE_NAME bash -c "sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.epel.cloud|g' /etc/yum.repos.d/CentOS-Linux-*"
	fi

	buildah copy $IMAGE_NAME "./local-build.repo" "/etc/yum.repos.d/"

	if [[ "${DISTRO_LOWER}" == "fedora"* ]]; then
		#first install the config-manager plugin,
		#only enable the repo containing this plugin:
		#(this is more likely to succeed on flaky networks)
		buildah run $IMAGE_NAME dnf install -y dnf-plugins-core --disablerepo='*' --enablerepo='fedora'
		#some repositories are enabled by default,
		#but we don't want to use them
		#(any repository failures would cause problems)
		for repo in fedora-modular updates-modular updates-testing-modular updates-testing-modular-debuginfo updates-testing-modular-source; do
			disable_repo $repo
		done
		#enable openh264:
		enable_repo fedora-cisco-openh264
		#add rpmfusion:
		buildah run $IMAGE_NAME bash -c "dnf install -y \"https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${DISTRO_MAJOR_NO}.noarch.rpm\" --disablerepo=repo-local-build --disablerepo=repo-local-source || dnf install -y \"https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${DISTRO_MAJOR_NO}.noarch.rpm\" --disablerepo=repo-local-build --disablerepo=repo-local-source"
	else
		#why do we need to do this by hand?
		buildah run $IMAGE_NAME rpm --import ///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
		#add rpmfusion:
		buildah run $IMAGE_NAME bash -c "dnf install -y --nogpgcheck \"https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-${DISTRO_MAJOR_NO}.noarch.rpm\" --disablerepo=repo-local-build --disablerepo=repo-local-source || dnf install -y --nogpgcheck \"https://download1.rpmfusion.org/free/el/rpmfusion-free-release-${DISTRO_MAJOR_NO}.noarch.rpm\" --disablerepo=repo-local-build --disablerepo=repo-local-source"
		#also nonfree?
		#https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-$(rpm -E %rhel).noarch.rpm
	fi
	#don't update distros with a minor number:
	#(ie: CentOS:8.2.2004)
	echo $DISTRO | grep -vqF "."
	if [ "$?" == "0" ]; then
		buildah run $IMAGE_NAME dnf update -y --disablerepo=repo-local-build --disablerepo=repo-local-source
	fi
	buildah run $IMAGE_NAME dnf install -y redhat-rpm-config rpm-build rpmdevtools createrepo rsync --disablerepo=repo-local-build --disablerepo=repo-local-source
	buildah run $IMAGE_NAME dnf install -y 'dnf-command(builddep)' --disablerepo=repo-local-build --disablerepo=repo-local-source
	buildah run $IMAGE_NAME bash -c "echo 'keepcache=true' >> /etc/dnf/dnf.conf"
	buildah run $IMAGE_NAME bash -c "echo 'deltarpm=false' >> /etc/dnf/dnf.conf"
	buildah run $IMAGE_NAME bash -c "echo 'fastestmirror=true' >> /etc/dnf/dnf.conf"
	if [[ "${DISTRO_LOWER}" == "fedora"* ]]; then
		#the easy way on Fedora which has an 'rpmspectool' package:
		buildah run $IMAGE_NAME dnf install -y rpmspectool --disablerepo=repo-local-build --disablerepo=repo-local-source
	else
		#with stream8 and stream9,
		#we have to enable EPEL to get the PowerTools repo:
		EPEL="epel-release"
		RHEL=0
		if [[ "${DISTRO_LOWER}" == *"stream8"* ]]; then
			EPEL="epel-next-release"
			RHEL=8
		fi
		if [[ "${DISTRO_LOWER}" == *"stream9"* ]]; then
			EPEL="epel-next-release"
			RHEL=9
		fi
		if [[ "${DISTRO_LOWER}" == *"stream10"* ]]; then
			EPEL="epel-release"
			RHEL=10
		fi
		if [[ "${DISTRO_LOWER}" == *"oraclelinux:8"* ]]; then
			RHEL=8
			#the development headers live in this repo:
			enable_repo ol8_codeready_builder
		fi
		if [[ "${DISTRO_LOWER}" == *"oraclelinux:9"* ]]; then
			RHEL=9
			enable_repo ol9_codeready_builder
		fi
		if [[ "${DISTRO_LOWER}" == *"rockylinux:8"* ]]; then
			RHEL=8
		fi
		if [[ "${DISTRO_LOWER}" == *"rockylinux:9"* ]]; then
			RHEL=9
		fi
		if [[ "${DISTRO_LOWER}" == *"almalinux:8"* ]]; then
			RHEL=8
			buildah run $IMAGE_NAME rpm --import https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux
		fi
		if [[ "${DISTRO_LOWER}" == *"almalinux:9"* ]]; then
			RHEL=9
		fi
		if [[ "${DISTRO_LOWER}" == *"almalinux:10"* ]]; then
			RHEL=10
			EPEL="https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm"
		fi
		if [ "${RHEL}" != "0" ]; then
			buildah run $IMAGE_NAME dnf install -y $EPEL --disablerepo=repo-local-build --disablerepo=repo-local-source
		fi
		if [[ "${RHEL}" -ge "9" ]]; then
			enable_repo crb
		fi
		#CentOS 8 and later:
		#there is no "rpmspectool" package so we have to use pip to install it:
		buildah run $IMAGE_NAME dnf install -y python3-pip --disablerepo=repo-local-build --disablerepo=repo-local-source
		buildah run $IMAGE_NAME pip3 install python-rpm-spec
		#try different spellings because they've made it case sensitive and renamed the repo..
		enable_repo PowerTools
		enable_repo powertools
	fi
	buildah run $IMAGE_NAME rpmdev-setuptree
	#buildah run dnf clean all

	buildah run $IMAGE_NAME mkdir -p "/src/repo/" "/src/rpm" "/src/debian" "/src/pkgs"
	buildah config --workingdir /src $IMAGE_NAME
	buildah run $IMAGE_NAME createrepo "/src/repo/"
	buildah commit $IMAGE_NAME $IMAGE_NAME
done

DEB_DISTROS=${DEB_DISTROS:-Ubuntu:bionic Ubuntu:focal Ubuntu:focal:arm64 Ubuntu:jammy Ubuntu:jammy:arm64 Ubuntu:noble Ubuntu:noble:arm64 Ubuntu:oracular Ubuntu:oracular:arm64 Ubuntu:plucky Debian:bullseye Debian:bullseye:arm64 Debian:bookworm Debian:bookworm:arm64 Debian:bookworm:riscv64 Debian:trixie Debian:trixie:arm64 Debian:trixie:riscv64 Debian:sid Debian:sid:arm64 Debian:sid:riscv64}
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
	podman image exists "${IMAGE_NAME}"
	if [ "$?" == "0" ]; then
		echo "${IMAGE_NAME} already exists"
		if [ "${SKIP_EXISTING:-1}" == "1" ]; then
			continue
		fi
		#delete existing image
		buildah rmi "${IMAGE_NAME}"
	fi
	buildah rm "${IMAGE_NAME}"
	echo "creating ${IMAGE_NAME}"
	buildah from --arch "${ARCH}" --name "$IMAGE_NAME" "$DISTRO_NOARCH"
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
	for x in `ls apt/*`; do
		buildah copy $IMAGE_NAME "$x" "/etc/apt/apt.conf.d/$x"
	done
	#we don't need a local repo yet:
	#DISTRO_NAME=`echo $DISTRO | awk -F: '{print $2}'`
	#buildah run $IMAGE_NAME bash -c 'echo "deb file:///repo $DISTRO_NAME main" > /etc/apt/sources.list.d/local-build.list'
	buildah commit $IMAGE_NAME $IMAGE_NAME
done
