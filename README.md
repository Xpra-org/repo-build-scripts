# Container Builds with [buildah](https://buildah.io/)

## Setup the build containers
```
./setup_build_containers.sh
```

## Run the build
Point to a `packaging` directory containing the RPM spec files and debian package structure.  
For example:

```shell
git clone https://github.com/Xpra-org/xpra
ln -sf xpra/packaging .
```
Build all the packages:

```shell
./build_all.sh
```
The resulting `RPM` and `DEB` packages are found in the `./repo` directory.


## Options
You may want to specify which distributions you want to setup:

```
DEB_DISTROS="xx" RPM_DISTROS="Fedora:41" ./setup_build_containers.sh
DISTROS="Fedora:41" ./build_all.sh
```

For more details, refer to the (ugly) scripts themselves. 
The source download script requires `rpmspec` (found in `rpm-build` package on Fedora).  
The `arm64` images require `qemu-system-aarch64` and / or `qemu-user-static`.
