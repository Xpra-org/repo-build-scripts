#!/bin/bash

dnf --version >& /dev/null
if [ "$?" == "0" ]; then
	DNF="${DNF:-dnf}"
else
	DNF="${DNF:-yum}"
fi
createrepo_c --version >& /dev/null
if [ "$?" == "0" ]; then
	CREATEREPO="${CREATEREPO:-createrepo_c}"
else
	CREATEREPO="${CREATEREPO:-createrepo}"
fi

if [ `id -u` != "0" ]; then
	if [ "${DNF}" == "dnf" ]; then
		echo "Warning: this script usually requires root to be able to run dnf"
	fi
fi

ARCH=`arch`
for dir in "./repo/SRPMS" "./repo/$ARCH"; do
	echo "* (re)creating repodata in $dir"
	mkdir $dir 2> /dev/null
	rm -fr $dir/repodata
	${CREATEREPO} $dir > /dev/null
done

#if we are going to build xpra,
#make sure we expose the revision number
#so the spec file can generate the expected file names
#(ie: xpra-4.2-0.r29000)
XPRA_REVISION="0"
XPRA_TAR_XZ=`ls -d pkgs/xpra-* | grep -v html5 | sort -V | tail -n 1`
if [ -z "${XPRA_TAR_XZ}" ]; then
	echo "Warning: xpra source not found"
else
	rm -fr xpra-*
	tar -Jxf ${XPRA_TAR_XZ} "xpra-*/xpra/src_info.py"
	if [ "$?" != "0" ]; then
		echo "failed to extract src_info"
		exit 1
	fi
	XPRA_REVISION=`grep "REVISION=" xpra-*/xpra/src_info.py | awk -F= '{print $2}'`
	if [ -z "${XPRA_REVISION}" ]; then
		echo "revision not found in src_info.py"
		exit 1
	fi
fi


#prepare rpmbuild (assume we're going to build something):
rm -fr "rpmbuild/RPMS" "rpmbuild/SRPMS" "$HOME/rpmbuild/RPMS" "$HOME/rpmbuild/SRPMS"
mkdir -p "rpmbuild/SOURCES" "rpmbuild/RPMS" "$HOME/rpmbuild/RPMS" "$HOME/rpmbuild/SRPMS" 2> /dev/null
#specfiles and patches
cp ./rpm/*spec "rpmbuild/SOURCES/"
cp ./rpm/*spec "$HOME/rpmbuild/SOURCES/"
cp ./rpm/patches/* "rpmbuild/SOURCES/"
cp ./rpm/patches/* "$HOME/rpmbuild/SOURCES/"
#source packages
cp ./pkgs/* "rpmbuild/SOURCES/"
cp ./pkgs/* "$HOME/rpmbuild/SOURCES/"


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
	echo "****************************************************************"
	echo " $p"
	SPECFILE="./rpm/$p.spec"
	rpmspec -q --srpm ${SPECFILE} | sort > "/tmp/${p}.srpmlist"
	rpmspec -q --rpms ${SPECFILE} | sed 's/\.src$//g' | sort > "/tmp/${p}.rpmslist"
	cp "/tmp/${p}.rpmslist" "/tmp/${p}.list"
	rpmcount=`wc -l "/tmp/${p}.list" | awk '{print $1}'`
	if [ "${rpmcount}" -gt "1" ]; then
		#multiple rpms from this spec file
		#so remove the srpm from the list of all rpms
		comm -3 "/tmp/${p}.srpmlist" "/tmp/${p}.rpmslist" > "/tmp/${p}.list"
	fi
	MISSING=""
	while read -r dep; do
		if [ "$DNF" == "yum" ]; then
			MATCHES=`repoquery "$dep" --repoid=repo-local-build 2> /dev/null | wc -l`
		else
			MATCHES=`$DNF repoquery "$dep" --repo repo-local-build 2> /dev/null | wc -l`
		fi
		if [ "${MATCHES}" != "0" ]; then
			echo " * found   ${dep}"
		else
			if [[ $dep == *debuginfo* ]]; then
				echo "   ignore missing debuginfo ${dep}"
			elif [[ $dep == *debugsource* ]]; then
				echo "   ignore missing debugsource ${dep}"
			elif [[ $dep == *-doc-* ]]; then
				echo "   ignore missing doc ${dep}"
			else
				echo " * missing ${dep}"
				MISSING="${MISSING} ${dep}"
			fi
		fi
	done < "/tmp/${p}.list"
	if [ ! -z "${MISSING}" ]; then
		echo " need to rebuild $p to get:${MISSING}"
		echo " - installing build dependencies"
		yum-builddep --version >& /dev/null
		if [ "$?" == "0" ]; then
			yum-builddep -y ${SPECFILE} > builddep.log
		else
			$DNF builddep -y ${SPECFILE} > builddep.log
		fi
		if [ "$?" != "0" ]; then
			echo "-------------------------------------------"
			echo "builddep failed:"
			cat builddep.log
			exit 1
		fi
		echo " - building RPM package(s)"
		rpmbuild --define "_topdir `pwd`/rpmbuild" --define "xpra_revision_no ${XPRA_REVISION}" -ba $SPECFILE >& rpmbuild.log
		if [ "$?" != "0" ]; then
			echo "-------------------------------------------"
			echo "rpmbuild failed:"
			cat rpmbuild.log
			exit 1
		fi
		rsync -rplogt rpmbuild/RPMS/*/*rpm "./repo/$ARCH/"
		rsync -rplogt rpmbuild/SRPMS/*rpm "./repo/SRPMS/"
		#update the local repo:
		echo " - re-creating repository metadata"
		for dir in "./repo/SRPMS" "./repo/$ARCH"; do
			${CREATEREPO} $dir >& createrepo.log
			if [ "$?" != "0" ]; then
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
