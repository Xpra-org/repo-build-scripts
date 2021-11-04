#!/bin/bash

die() { echo "$*" 1>&2 ; exit 1; }

BUILDAH_DIR=`dirname $(readlink -f $0)`
pushd ${BUILDAH_DIR}

RPM_DISTROS=${RPM_DISTROS:-Fedora:33 Fedora:34 Fedora:34:arm64 Fedora:35 Fedora:35:arm64 CentOS:8 CentOS:8:arm64 CentOS:stream9}
DEB_DISTROS=${DEB_DISTROS:-Ubuntu:xenial Ubuntu:bionic Ubuntu:focal Ubuntu:groovy Ubuntu:hirsute Ubuntu:impish Debian:stretch Debian:buster Debian:buster:arm64 Debian:bullseye Debian:bookworm Debian:sid}
if [ -z "${DISTROS}" ]; then
	DISTROS="$RPM_DISTROS $DEB_DISTROS"
fi

for DISTRO in $DISTROS; do
	#ie: DISTRO_NAME="fedora-33"
	FULL_DISTRO_NAME=`echo ${DISTRO,,} | sed 's/:/-/g'`
	DISTRO_NAME=`echo ${DISTRO,,} | awk -F: '{print $1}'`
	IMAGE_NAME="$FULL_DISTRO_NAME-repo-build"

	COUNT=`buildah images | grep "$IMAGE_NAME " | wc -l`
	if [ "${COUNT}" != "1" ]; then
		echo "cannot update $DISTRO: image $IMAGE_NAME is missing?"
		continue
	fi
	echo $DISTRO : $IMAGE_NAME
	echo $DISTRO | egrep -iv "fedora|centos" >& /dev/null
	RPM="$?"
	if [ "${RPM}" == "1" ]; then
		buildah run $IMAGE_NAME rm -fr "/src/repo/.repodata" "/src/repo/repodata" "/src/repo/x86_64"
		buildah run $IMAGE_NAME mkdir "/src/repo/x86_64"
		buildah run $IMAGE_NAME createrepo "/src/repo/x86_64/"
		buildah run $IMAGE_NAME dnf update --disablerepo=repo-local-build --disablerepo=repo-local-source -y
	else
		buildah config --env DEBIAN_FRONTEND=noninteractive $IMAGE_NAME
		buildah run $IMAGE_NAME apt-get update
		buildah run $IMAGE_NAME apt-get upgrade -y
		buildah run $IMAGE_NAME apt-get dist-upgrade -y
		buildah run $IMAGE_NAME apt-get autoremove -y
	fi
	buildah commit --squash $IMAGE_NAME $IMAGE_NAME
done
