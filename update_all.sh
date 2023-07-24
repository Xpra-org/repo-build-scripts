#!/bin/bash

die() { echo "$*" 1>&2 ; exit 1; }

BUILDAH_DIR=`dirname $(readlink -f $0)`
pushd ${BUILDAH_DIR}

if [ -z "${DISTROS}" ]; then
	#update all the '-repo-build' images we find:
	DISTROS=`buildah images | grep '\-repo-build' | awk '{print $1}' | sed 's+.*/++g' | sed 's/-repo-build//g' | grep -vF "." | sort -V`
fi

for DISTRO in $DISTROS; do
	#ie: DISTRO_NAME="fedora-33"
	DISTRO_NAME=`echo ${DISTRO} | awk -F- '{print $1}'`
	IMAGE_NAME="$DISTRO-repo-build"

	COUNT=`buildah images | grep "$IMAGE_NAME " | wc -l`
	if [ "${COUNT}" != "1" ]; then
		echo "cannot update $DISTRO: image $IMAGE_NAME is missing?"
		continue
	fi
	echo $DISTRO : $IMAGE_NAME
	echo $DISTRO | grep -Eiv "fedora|centos|rockylinux|oraclelinux|almalinux" >& /dev/null
	RPM="$?"
	if [ "${RPM}" == "1" ]; then
		CREATEREPO="createrepo"
		PM="dnf"
		echo $DISTRO | grep -Eqi "centos:7|centos-7|centos7"
		if [ "$?" == "0" ]; then
			PM="yum"
		fi

		buildah run $IMAGE_NAME rm -fr "/src/repo/.repodata" "/src/repo/repodata" "/src/repo/x86_64"
		buildah run $IMAGE_NAME mkdir "/src/repo/x86_64"
		buildah run $IMAGE_NAME $CREATEREPO "/src/repo/x86_64/"
		buildah run $IMAGE_NAME $PM update --disablerepo=repo-local-build --disablerepo=repo-local-source -y
	else
		buildah config --env DEBIAN_FRONTEND=noninteractive $IMAGE_NAME
		buildah run $IMAGE_NAME apt-get update
		buildah run $IMAGE_NAME apt-get upgrade -y
		buildah run $IMAGE_NAME apt-get dist-upgrade -y
		buildah run $IMAGE_NAME apt-get autoremove -y
	fi
	buildah commit --squash $IMAGE_NAME $IMAGE_NAME
done
