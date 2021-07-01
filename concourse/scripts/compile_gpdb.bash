#!/bin/bash
set -exo pipefail

CWDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CWDIR}/common.bash"

function prep_env() {
	OUTPUT_ARTIFACT_DIR=${OUTPUT_ARTIFACT_DIR:=gpdb_artifacts}
	export CONFIGURE_FLAGS=${CONFIGURE_FLAGS}
	export GPDB_ARTIFACTS_DIR=$(pwd)/${OUTPUT_ARTIFACT_DIR}
	export BLD_ARCH=$(build_arch)

	GPDB_SRC_PATH=${GPDB_SRC_PATH:=gpdb_src}
	GPDB_BIN_FILENAME=${GPDB_BIN_FILENAME:="bin_gpdb.tar.gz"}
	GPDB_CL_FILENAME=${GPDB_CL_FILENAME:="bin_gpdb_clients.tar.gz"}

	GREENPLUM_INSTALL_DIR=/usr/local/greenplum-db-devel
	GREENPLUM_CL_INSTALL_DIR=/usr/local/greenplum-clients-devel

	mkdir -p "${GPDB_ARTIFACTS_DIR}"
	link_python

	# By default, only GPDB Server binary is build.
	# Use BLD_TARGETS flag with appropriate value string to generate client, loaders
	# connectors binaries
	if [ -n "${BLD_TARGETS}" ]; then
		BLD_TARGET_OPTION=("BLD_TARGETS=\"$BLD_TARGETS\"")
	else
		BLD_TARGET_OPTION=("")
	fi
}

function generate_build_number() {
	pushd ${GPDB_SRC_PATH}
	# Only if its git repo, add commit SHA as build number
	# BUILD_NUMBER file is used by getversion file in GPDB to append to version
	if [ -d .git ]; then
		echo "commit:$(git rev-parse HEAD)" >BUILD_NUMBER
	fi
	popd
}

function link_python() {
	echo "Installing python"
	export PYTHONHOME=$(find /opt -maxdepth 1 -type d -name "python*")
	export PATH="${PYTHONHOME}/bin:${PATH}"
	echo "${PYTHONHOME}/lib" >>/etc/ld.so.conf.d/gpdb.conf
	ldconfig
}

function build_gpdb() {
	pushd ${GPDB_SRC_PATH}/gpAux
	if [ -n "$1" ]; then
		make "$1" GPROOT=/usr/local PARALLEL_MAKE_OPTS=-j"$(nproc)" -s dist
	else
		make GPROOT=/usr/local PARALLEL_MAKE_OPTS=-j"$(nproc)" -s dist
	fi
	popd
}

function git_info() {
	pushd ${GPDB_SRC_PATH}
	if [[ -d .git ]]; then
		"${CWDIR}/git_info.bash" | tee ${GREENPLUM_INSTALL_DIR}/etc/git-info.json

		PREV_TAG=$(git describe --tags --abbrev=0 HEAD^)

		cat >${GREENPLUM_INSTALL_DIR}/etc/git-current-changelog.txt <<-EOF
			======================================================================
			Git log since previous release tag (${PREV_TAG})
			----------------------------------------------------------------------
		EOF

		git log --abbrev-commit --date=relative "${PREV_TAG}..HEAD" >>${GREENPLUM_INSTALL_DIR}/etc/git-current-changelog.txt
	fi
	popd
}

function unittest_check_gpdb() {
	pushd ${GPDB_SRC_PATH}
	source ${GREENPLUM_INSTALL_DIR}/greenplum_path.sh
	make GPROOT=/usr/local -s unittest-check
	popd
}


function include_dependencies() {

	mkdir -p ${GREENPLUM_INSTALL_DIR}/{lib,include}
	declare -a library_search_path header_search_path vendored_headers vendored_libs

	header_search_path=( /usr/local/include/ /usr/include/ )
	vendored_headers=(zstd*.h uv.h uv )

	vendored_libs=(libquicklz.so{,.1,.1.5.0} libzstd.so{,.1,.1.3.7} libuv.so{,.1,.1.0.0} libxerces-c{,-3.1}.so)

	if [[ -d /opt/gcc-6.4.0 ]]; then
		vendored_libs+=(libstdc++.so.6{,.0.22,*.pyc,*.pyo})
		library_search_path+=( /opt/gcc-6.4.0/lib64 )
	fi

	library_search_path+=( $(cat /etc/ld.so.conf.d/*.conf | grep -v '#') )
	library_search_path+=( /lib64 /usr/lib64 /lib /usr/lib)

	# Vendor shared libraries - follow symlinks
	for path in "${library_search_path[@]}"; do if [[ -d "${path}" ]] ; then for lib in "${vendored_libs[@]}"; do find -L $path -name $lib -exec cp -avn '{}' ${GREENPLUM_INSTALL_DIR}/lib \;; done; fi; done;
	# Vendor headers - follow symlinks
	for path in "${header_search_path[@]}"; do if [[ -d "${path}" ]] ; then for header in "${vendored_headers[@]}"; do find -L $path -name $header -exec cp -avn '{}' ${GREENPLUM_INSTALL_DIR}/include \;; done; fi; done

}

function export_gpdb() {
	TARBALL="${GPDB_ARTIFACTS_DIR}/${GPDB_BIN_FILENAME}"
	local server_version
	server_version="$("${GPDB_SRC_PATH}"/getversion --short)"

	local server_build
	server_build="${GPDB_ARTIFACTS_DIR}/server-build-${server_version}-${BLD_ARCH}${RC_BUILD_TYPE_GCS}.tar.gz"

	pushd ${GREENPLUM_INSTALL_DIR}
	chmod -R 755 .
	tar -czf "${TARBALL}" ./*
	popd

	cp "${TARBALL}" "${server_build}"
}

function export_gpdb_extensions() {
	pushd ${GPDB_SRC_PATH}/gpAux
	if ls greenplum-*zip* 1>/dev/null 2>&1; then
		chmod 755 greenplum-*zip*
		cp greenplum-*zip* "${GPDB_ARTIFACTS_DIR}/"
	fi
	popd
}

function export_gpdb_clients() {
	TARBALL="${GPDB_ARTIFACTS_DIR}/${GPDB_CL_FILENAME}"
	pushd ${GREENPLUM_CL_INSTALL_DIR}
	source ./greenplum_clients_path.sh
	mkdir -p bin/ext/gppylib
	cp ${GREENPLUM_INSTALL_DIR}/lib/python/gppylib/__init__.py ./bin/ext/gppylib
	cp ${GREENPLUM_INSTALL_DIR}/lib/python/gppylib/gpversion.py ./bin/ext/gppylib
	# GPHOME_LOADERS and greenplum_loaders_path.sh are still requried by some users
	# So link greenplum_loaders_path.sh to greenplum_clients_path.sh for compatible
	ln -sf greenplum_clients_path.sh greenplum_loaders_path.sh
	chmod -R 755 .
	tar -czf "${TARBALL}" ./*
	popd
}

function _main() {

	prep_env

	generate_build_number
	build_gpdb "${BLD_TARGET_OPTION[@]}"
	git_info

	if [[ -z "${SKIP_UNITTESTS}" ]]; then
		unittest_check_gpdb
	fi

	include_dependencies

	export_gpdb
	export_gpdb_extensions

	if echo "${BLD_TARGETS}" | grep -qwi "clients"; then
		export_gpdb_clients
	fi

}

_main "$@"
