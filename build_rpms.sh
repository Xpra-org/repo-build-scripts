#!/bin/bash

date +"%Y-%m-%d %H:%M:%S"

if [ "$(id -u)" != "0" ]; then
	echo "Warning: this script usually requires root to be able to run yum"
fi

ARCH="$(arch)"
for dir in "./repo/SRPMS" "./repo/$ARCH"; do
	echo "* (re)creating repodata in $dir"
	mkdir $dir 2> /dev/null
	rm -fr $dir/repodata
	createrepo $dir > /dev/null
done

#prepare rpmbuild (assume we're going to build something):
rm -fr "rpmbuild/RPMS" "rpmbuild/SRPMS" "$HOME/rpmbuild/RPMS" "$HOME/rpmbuild/SRPMS" "$HOME/rpmbuild/SOURCES"
mkdir -p "rpmbuild/SOURCES" "rpmbuild/RPMS" "$HOME/rpmbuild/RPMS" "$HOME/rpmbuild/SRPMS" "$HOME/rpmbuild/SOURCES" 2> /dev/null

#specfiles and patches
cp ./rpm/*spec "rpmbuild/SOURCES/"
cp ./rpm/*spec "$HOME/rpmbuild/SOURCES/"
cp ./rpm/patches/* "rpmbuild/SOURCES/"
cp ./rpm/patches/* "$HOME/rpmbuild/SOURCES/"
#source packages
cp ./pkgs/* "rpmbuild/SOURCES/"
cp ./pkgs/* "$HOME/rpmbuild/SOURCES/"

echo "Package list:"
cat ./rpms.list
echo

echo "Sources:"
ls -laZ "$HOME/rpmbuild/SOURCES"
echo


#read the name of the spec files we may want to build:
while read p; do
	if [ -z "${p}" ]; then
		#skip empty lines
		continue
	fi
	if [[ "$p" == "#"* ]]; then
		#skip comments
		continue
	fi
	if [[ $p =~ [=] ]]; then
		#parse as environment variables:
		varname=${p%%=*}
		value=${p#*=}
		if [ -z "${value}" ]; then
			echo " clearing ${varname}"
			unset "$varname"
		else
			echo " declaring ${varname}=${value}"
			declare -x "$varname=$value"
		fi
		continue
	fi

	echo "****************************************************************"
	echo " $p"
	SPECFILE="./rpm/$p.spec"
	rpmspec -q --srpm "${SPECFILE}" | grep -Ev "debuginfo|debugsource|-doc-" | sort > "/tmp/${p}.srpmlist"
	rpmspec -q --rpms "${SPECFILE}" | grep -Ev "debuginfo|debugsource|-doc-" | sed 's/\.src$//g' | sort > "/tmp/${p}.rpmslist"
	cp "/tmp/${p}.rpmslist" "/tmp/${p}.list"
	rpmcount=$(wc -l "/tmp/${p}.list" | awk '{print $1}')
	if [ "${rpmcount}" -gt "1" ]; then
		#multiple rpms from this spec file
		#so remove the srpm from the list of all rpms
		comm -3 "/tmp/${p}.srpmlist" "/tmp/${p}.rpmslist" > "/tmp/${p}.list"
	fi
	MISSING=""
	while read -r dep; do
		MATCHES=$(repoquery "$dep" --repoid=repo-local-build 2> /dev/null | wc -l)
		if [ "${MATCHES}" != "0" ]; then
			echo " * found   ${dep}"
		else
			MISSING="${MISSING} ${dep}"
		fi
	done < "/tmp/${p}.list"
	if [ ! -z "${MISSING}" ]; then
		echo " need to rebuild $p to get:${MISSING}"
		date +"%Y-%m-%d %H:%M:%S"
		echo " - installing build dependencies"
		if ! yum-builddep -y ${SPECFILE} > builddep.log; then
			echo "-------------------------------------------"
			echo "builddep failed:"
			cat builddep.log
			exit 1
		fi
		echo " - building RPM package(s)"
		if ! rpmbuild --define "_topdir `pwd`/rpmbuild" -ba $SPECFILE >& rpmbuild.log; then
			echo "-------------------------------------------"
			echo "rpmbuild failed"
			echo "builddep log:"
			cat builddep.log
			echo "rpmbuild log:"
			cat rpmbuild.log
			exit 1
		fi
		rsync -rplogt rpmbuild/RPMS/*/*rpm "./repo/$ARCH/"
		rsync -rplogt rpmbuild/SRPMS/*rpm "./repo/SRPMS/"
		#update the local repo:
		echo " - re-creating repository metadata"
		for dir in "./repo/SRPMS" "./repo/$ARCH"; do
			if ! createrepo $dir >& createrepo.log; then
				echo "-------------------------------------------"
				echo "'createrepo $dir' failed"
				cat createrepo.log
				exit 1
			fi
		done
		echo " - updating local packages"
		yum update -y --disablerepo=* --enablerepo=repo-local-build
	fi
done <./rpms.list
date +"%Y-%m-%d %H:%M:%S"
