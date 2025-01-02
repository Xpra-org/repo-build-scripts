#!/bin/bash

date +"%Y-%m-%d %H:%M:%S"
if dnf-3 --version >& /dev/null; then
	DNF="${DNF:-dnf-3}"
else
	DNF="${DNF:-dnf}"
fi
if ! createrepo_c --version >& /dev/null; then
	CREATEREPO="${CREATEREPO:-createrepo_c}"
else
	CREATEREPO="${CREATEREPO:-createrepo}"
fi

if [ "$(id -u)" != "0" ]; then
	if [ "${DNF}" == "dnf" ]; then
		echo "Warning: this script usually requires root to be able to run dnf"
	fi
fi

ARCH="$(arch)"
for dir in "./repo/SRPMS" "./repo/$ARCH"; do
	echo "* (re)creating repodata in $dir"
	mkdir $dir 2> /dev/null
	rm -fr $dir/repodata
	${CREATEREPO} $dir > /dev/null
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
	nosrc=`grep -v ".src" "/tmp/${p}.list" > "/tmp/${p}.nosrclist"`
	MISSING=""
	while read -r dep; do
		MATCHES=$($DNF repoquery "$dep" --repo repo-local-build 2> /dev/null | wc -l)
		if [ "${MATCHES}" == "0" ]; then
			# workaround for python3-cairo which is actually named `pycairo`...
			# try harder to find a match:
			longpy=`echo "${dep}" | sed "s/^py/${PYTHON3:-python3}-/g"`
			if [ "${longpy}" != "${dep}" ]; then
				MATCHES=$($DNF repoquery "$longpy" --repo repo-local-build 2> /dev/null | wc -l)
			fi
		fi
		if [ "${MATCHES}" != "0" ]; then
			echo " * found   ${dep}"
			continue
		fi
		MISSING="${MISSING} ${dep}"
	done < "/tmp/${p}.nosrclist"
	if [ ! -z "${MISSING}" ]; then
		echo " need to rebuild $p to get:${MISSING}"
		date +"%Y-%m-%d %H:%M:%S"
		echo " - installing build dependencies"
		if ! $DNF builddep -y ${SPECFILE} > builddep.log; then
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
			if ! ${CREATEREPO} $dir >& createrepo.log; then
				echo "-------------------------------------------"
				echo "'createrepo $dir' failed"
				cat createrepo.log
				exit 1
			fi
		done
		echo " - updating local packages"
		$DNF update -y --disablerepo=* --enablerepo=repo-local-build
	fi
done <./rpms.list
date +"%Y-%m-%d %H:%M:%S"
