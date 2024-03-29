#!/bin/bash

date +"%Y-%m-%d %H:%M:%S"
apt-get update
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get autoremove -y
apt-get install -y devscripts equivs

eval "$(dpkg-architecture -s)"
if [ ! -z "$DEB_BUILD_ARCH" ]; then
	REPO_ARCH_PATH="`pwd`/repo/main/binary-$DEB_BUILD_ARCH"
	export REPO_ARCH_PATH
	mkdir -p "$REPO_ARCH_PATH"
fi

BASH="bash"
if [ "${DEBUG:-0}" == "1" ]; then
	BASH="bash -x"

	ls -la
	ls -la debian
	ls -la pkgs
fi

pushd debian || exit 1
$BASH ./build.sh
popd || exit 1
date +"%Y-%m-%d %H:%M:%S"
