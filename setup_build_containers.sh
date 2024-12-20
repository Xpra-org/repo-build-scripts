#!/bin/bash

die() { echo "$*" 1>&2 ; exit 1; }

buildah --version >& /dev/null
if [ "$?" != "0" ]; then
	die "cannot continue without buildah"
fi

BUILDAH_DIR=`dirname $(readlink -f $0)`
pushd ${BUILDAH_DIR}

DISTRO="CentOS:7"

#docker names are lowercase:
DISTRO_LOWER="${DISTRO,,}"
DISTRO_NAME=`echo ${DISTRO} | awk -F: '{print $1}'`
DISTRO_VARIANT=`echo ${DISTRO} | awk -F: '{print $2}'`
IMAGE_NAME="`echo $DISTRO_LOWER | awk -F'/' '{print $1}' | sed 's/:/-/g'`-repo-build"
PM="yum"
CREATEREPO="createrepo"
PM_CMD="$PM"
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
# fix centos7 repos after EOL:
buildah run $IMAGE_NAME bash -c "sed -i s/mirror.centos.org/vault.centos.org/g /etc/yum.repos.d/CentOS-*.repo"
buildah run $IMAGE_NAME bash -c "sed -i s/^#.*baseurl=http/baseurl=http/g /etc/yum.repos.d/CentOS-*.repo"
buildah run $IMAGE_NAME bash -c "sed -i s/^mirrorlist=http/#mirrorlist=http/g /etc/yum.repos.d/CentOS-*.repo"

buildah run $IMAGE_NAME $PM_CMD install -y redhat-rpm-config rpm-build rpmdevtools createrepo rsync
buildah run $IMAGE_NAME rpmdev-setuptree
#buildah run $PM clean all

buildah run $IMAGE_NAME mkdir -p "/src/repo/" "/src/rpm" "/src/debian" "/src/pkgs"
buildah config --workingdir /src $IMAGE_NAME
buildah copy $IMAGE_NAME "./local-build.repo" "/etc/yum.repos.d/"
buildah run $IMAGE_NAME ${CREATEREPO} "/src/repo/"
buildah commit $IMAGE_NAME $IMAGE_NAME
