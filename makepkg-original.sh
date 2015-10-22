#!/usr/bin/bash
#
#   makepkg - make packages compatible for use with pacman
#   Generated from makepkg.sh.in; do not edit by hand.
#
#   Copyright (c) 2006-2014 Pacman Development Team <pacman-dev@archlinux.org>
#   Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
#   Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
#   Copyright (c) 2006 by Miklos Vajna <vmiklos@frugalware.org>
#   Copyright (c) 2005 by Christian Hamar <krics@linuxforum.hu>
#   Copyright (c) 2006 by Alex Smith <alex@alex-smith.me.uk>
#   Copyright (c) 2006 by Andras Voroskoi <voroskoi@frugalware.org>
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# makepkg uses quite a few external programs during its execution. You
# need to have at least the following installed for makepkg to function:
#   awk, bsdtar (libarchive), bzip2, coreutils, fakeroot, file, find (findutils),
#   gettext, gpg, grep, gzip, openssl, sed, tput (ncurses), xz

# gettext initialization
export TEXTDOMAIN='pacman-scripts'
export TEXTDOMAINDIR='/usr/share/locale'

# file -i does not work on Mac OSX unless legacy mode is set
export COMMAND_MODE='legacy'
# Ensure CDPATH doesn't screw with our cd calls
unset CDPATH
# Ensure GREP_OPTIONS doesn't screw with our grep calls
unset GREP_OPTIONS

declare -r makepkg_version='4.2.1'
declare -r confdir='/etc'
declare -r BUILDSCRIPT='PKGBUILD'
declare -r startdir="$PWD"

LIBRARY=${LIBRARY:-'/usr/lib/makepkg'}

packaging_options=('strip' 'docs' 'libtool' 'staticlibs' 'emptydirs' 'zipman'
                   'purge' 'upx' 'debug')
other_options=('ccache' 'distcc' 'buildflags' 'makeflags')
splitpkg_overrides=('pkgdesc' 'arch' 'url' 'license' 'groups' 'depends'
                    'optdepends' 'provides' 'conflicts' 'replaces' 'backup'
                    'options' 'install' 'changelog')
readonly -a packaging_options other_options splitpkg_overrides

known_hash_algos=('md5' 'sha1' 'sha224' 'sha256' 'sha384' 'sha512')

# Options
ASDEPS=0
BUILDFUNC=0
CHECKFUNC=0
CLEANBUILD=0
CLEANUP=0
DEP_BIN=0
FORCE=0
GENINTEG=0
HOLDVER=0
IGNOREARCH=0
INFAKEROOT=0
INSTALL=0
LOGGING=0
NEEDED=0
NOARCHIVE=0
NOBUILD=0
NODEPS=0
NOEXTRACT=0
PKGFUNC=0
PKGLIST=()
PKGVERFUNC=0
PREPAREFUNC=0
REPKG=0
RMDEPS=0
SKIPCHECKSUMS=0
SKIPPGPCHECK=0
SIGNPKG=''
SPLITPKG=0
SOURCEONLY=0
VERIFYSOURCE=0

# Forces the pkgver of the current PKGBUILD. Used by the fakeroot call
# when dealing with svn/cvs/etc PKGBUILDs.
FORCE_VER=""

PACMAN_OPTS=

shopt -s extglob

### SUBROUTINES ###

plain() {
	local mesg=$1; shift
	printf "${BOLD}    ${mesg}${ALL_OFF}\n" "$@" >&2
}

msg() {
	local mesg=$1; shift
	printf "${GREEN}==>${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
}

msg2() {
	local mesg=$1; shift
	printf "${BLUE}  ->${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
}

warning() {
	local mesg=$1; shift
	printf "${YELLOW}==> $(gettext "WARNING:")${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
}

error() {
	local mesg=$1; shift
	printf "${RED}==> $(gettext "ERROR:")${ALL_OFF}${BOLD} ${mesg}${ALL_OFF}\n" "$@" >&2
}


##
# Special exit call for traps, Don't print any error messages when inside,
# the fakeroot call, the error message will be printed by the main call.
##
trap_exit() {
	local signal=$1; shift

	if (( ! INFAKEROOT )); then
		echo
		error "$@"
	fi
	[[ -n $srclinks ]] && rm -rf "$srclinks"

	# unset the trap for this signal, and then call the default handler
	trap -- "$signal"
	kill "-$signal" "$$"
}


##
# Clean up function. Called automatically when the script exits.
##
clean_up() {
	local EXIT_CODE=$?

	if (( INFAKEROOT )); then
		# Don't clean up when leaving fakeroot, we're not done yet.
		return
	fi

	if (( ! EXIT_CODE && CLEANUP )); then
		local pkg file

		# If it's a clean exit and -c/--clean has been passed...
		msg "$(gettext "Cleaning up...")"
		rm -rf "$pkgdirbase" "$srcdir"
		if [[ -n $pkgbase ]]; then
			local fullver=$(get_full_version)
			# Can't do this unless the BUILDSCRIPT has been sourced.
			if (( BUILDFUNC )); then
				rm -f "${pkgbase}-${fullver}-${CARCH}-build.log"*
			fi
			if (( CHECKFUNC )); then
				rm -f "${pkgbase}-${fullver}-${CARCH}-check.log"*
			fi
			if (( PKGFUNC )); then
				rm -f "${pkgbase}-${fullver}-${CARCH}-package.log"*
			elif (( SPLITPKG )); then
				for pkg in ${pkgname[@]}; do
					rm -f "${pkgbase}-${fullver}-${CARCH}-package_${pkg}.log"*
				done
			fi

			# clean up dangling symlinks to packages
			for pkg in ${pkgname[@]}; do
				for file in ${pkg}-*-*-*{${PKGEXT},${SRCEXT}}; do
					if [[ -h $file && ! -e $file ]]; then
						rm -f "$file"
					fi
				done
			done
		fi
	fi

	remove_deps
}


enter_fakeroot() {
	msg "$(gettext "Entering %s environment...")" "fakeroot"
	fakeroot -- $0 -F "${ARGLIST[@]}" || exit $?
}


# a source entry can have two forms :
# 1) "filename::http://path/to/file"
# 2) "http://path/to/file"

# Return the absolute filename of a source entry
get_filepath() {
	local file="$(get_filename "$1")"
	local proto="$(get_protocol "$1")"

	case $proto in
		bzr*|git*|hg*|svn*)
			if [[ -d "$startdir/$file" ]]; then
				file="$startdir/$file"
			elif [[ -d "$SRCDEST/$file" ]]; then
				file="$SRCDEST/$file"
			else
				return 1
			fi
			;;
		*)
			if [[ -f "$startdir/$file" ]]; then
				file="$startdir/$file"
			elif [[ -f "$SRCDEST/$file" ]]; then
				file="$SRCDEST/$file"
			else
				return 1
			fi
			;;
	esac

	printf "%s\n" "$file"
}

# extract the filename from a source entry
get_filename() {
	local netfile=$1

	# if a filename is specified, use it
	if [[ $netfile = *::* ]]; then
		printf "%s\n" ${netfile%%::*}
		return
	fi

	local proto=$(get_protocol "$netfile")

	case $proto in
		bzr*|git*|hg*|svn*)
			filename=${netfile%%#*}
			filename=${filename%/}
			filename=${filename##*/}
			if [[ $proto = bzr* ]]; then
				filename=${filename#*lp:}
			fi
			if [[ $proto = git* ]]; then
				filename=${filename%%.git*}
			fi
			;;
		*)
			# if it is just an URL, we only keep the last component
			filename="${netfile##*/}"
			;;
	esac
	printf "%s\n" "${filename}"
}

# extract the URL from a source entry
get_url() {
	# strip an eventual filename
	printf "%s\n" "${1#*::}"
}

# extract the protocol from a source entry - return "local" for local sources
get_protocol() {
	if [[ $1 = *://* ]]; then
		# strip leading filename
		local proto="${1#*::}"
		printf "%s\n" "${proto%%://*}"
	elif [[ $1 = *lp:* ]]; then
		local proto="${1#*::}"
		printf "%s\n" "${proto%%lp:*}"
	else
		printf "%s\n" local
	fi
}

get_downloadclient() {
	local proto=$1

	# loop through DOWNLOAD_AGENTS variable looking for protocol
	local i
	for i in "${DLAGENTS[@]}"; do
		local handler="${i%%::*}"
		if [[ $proto = "$handler" ]]; then
			local agent="${i#*::}"
			break
		fi
	done

	# if we didn't find an agent, return an error
	if [[ -z $agent ]]; then
		error "$(gettext "Unknown download protocol: %s")" "$proto"
		plain "$(gettext "Aborting...")"
		exit 1 # $E_CONFIG_ERROR
	fi

	# ensure specified program is installed
	local program="${agent%% *}"
	if [[ ! -x $program ]]; then
		local baseprog="${program##*/}"
		error "$(gettext "The download program %s is not installed.")" "$baseprog"
		plain "$(gettext "Aborting...")"
		exit 1 # $E_MISSING_PROGRAM
	fi

	printf "%s\n" "$agent"
}

download_local() {
	local netfile=$1
	local filepath=$(get_filepath "$netfile")

	if [[ -n "$filepath" ]]; then
		msg2 "$(gettext "Found %s")" "${filepath##*/}"
	else
		local filename=$(get_filename "$netfile")
		error "$(gettext "%s was not found in the build directory and is not a URL.")" "$filename"
		exit 1 # $E_MISSING_FILE
	fi
}

download_file() {
	local netfile=$1

	local filepath=$(get_filepath "$netfile")
	if [[ -n "$filepath" ]]; then
		msg2 "$(gettext "Found %s")" "${filepath##*/}"
		return
	fi

	local proto=$(get_protocol "$netfile")

	# find the client we should use for this URL
	local -a cmdline
	IFS=' ' read -a cmdline < <(get_downloadclient "$proto")
	(( ${#cmdline[@]} )) || exit

	local filename=$(get_filename "$netfile")
	local url=$(get_url "$netfile")

	if [[ $proto = "scp" ]]; then
		# scp downloads should not pass the protocol in the url
		url="${url##*://}"
	fi

	msg2 "$(gettext "Downloading %s...")" "$filename"

	# temporary download file, default to last component of the URL
	local dlfile="${url##*/}"

	# replace %o by the temporary dlfile if it exists
	if [[ ${cmdline[*]} = *%o* ]]; then
		dlfile=$filename.part
		cmdline=("${cmdline[@]//%o/$dlfile}")
	fi
	# add the URL, either in place of %u or at the end
	if [[ ${cmdline[*]} = *%u* ]]; then
		cmdline=("${cmdline[@]//%u/$url}")
	else
		cmdline+=("$url")
	fi

	if ! command -- "${cmdline[@]}" >&2; then
		[[ ! -s $dlfile ]] && rm -f -- "$dlfile"
		error "$(gettext "Failure while downloading %s")" "$filename"
		plain "$(gettext "Aborting...")"
		exit 1
	fi

	# rename the temporary download file to the final destination
	if [[ $dlfile != "$filename" ]]; then
		mv -f "$SRCDEST/$dlfile" "$SRCDEST/$filename"
	fi
}

extract_file() {
	local file=$1

	local filepath=$(get_filepath "$file")
	rm -f "$srcdir/${file}"
	ln -s "$filepath" "$srcdir/"

	if in_array "$file" "${noextract[@]}"; then
		# skip source files in the noextract=() array
		# these are marked explicitly to NOT be extracted
		return 0
	fi

	# do not rely on extension for file type
	local file_type=$(file -bizL "$file")
	local ext=${file##*.}
	local cmd=''
	case "$file_type" in
		*application/x-tar*|*application/zip*|*application/x-zip*|*application/x-cpio*)
			cmd="bsdtar" ;;
		*application/x-gzip*)
			case "$ext" in
				gz|z|Z) cmd="gzip" ;;
				*) return;;
			esac ;;
		*application/x-bzip*)
			case "$ext" in
				bz2|bz) cmd="bzip2" ;;
				*) return;;
			esac ;;
		*application/x-xz*)
			case "$ext" in
				xz) cmd="xz" ;;
				*) return;;
			esac ;;
		*)
			# See if bsdtar can recognize the file
			if bsdtar -tf "$file" -q '*' &>/dev/null; then
				cmd="bsdtar"
			else
				return 0
			fi ;;
	esac

	local ret=0
	msg2 "$(gettext "Extracting %s with %s")" "$file" "$cmd"
	if [[ $cmd = "bsdtar" ]]; then
		$cmd -xf "$file" || ret=$?
	else
		rm -f -- "${file%.*}"
		$cmd -dcf "$file" > "${file%.*}" || ret=$?
	fi
	if (( ret )); then
		error "$(gettext "Failed to extract %s")" "$file"
		plain "$(gettext "Aborting...")"
		exit 1
	fi

	if (( EUID == 0 )); then
		# change perms of all source files to root user & root group
		chown -R 0:0 "$srcdir"
	fi
}

download_bzr() {
	local netfile=$1

	local url=$(get_url "$netfile")
	if [[ $url != bzr+ssh* ]]; then
		url=${url#bzr+}
	fi
	url=${url%%#*}

	local repo=$(get_filename "$netfile")
	local displaylocation="$url"

	local dir=$(get_filepath "$netfile")
	[[ -z "$dir" ]] && dir="$SRCDEST/$(get_filename "$netfile")"

	if [[ ! -d "$dir" ]] || dir_is_empty "$dir" ; then
		msg2 "$(gettext "Branching %s ...")" "${displaylocation}"
		if ! bzr branch "$url" "$dir" --no-tree --use-existing-dir; then
			error "$(gettext "Failure while branching %s")" "${displaylocation}"
			plain "$(gettext "Aborting...")"
			exit 1
		fi
	elif (( ! HOLDVER )); then
		msg2 "$(gettext "Pulling %s ...")" "${displaylocation}"
		cd_safe "$dir"
		if ! bzr pull "$url"; then
			# only warn on failure to allow offline builds
			warning "$(gettext "Failure while pulling %s")" "${displaylocation}"
		fi
	fi
}

extract_bzr() {
	local netfile=$1

	local repo=$(get_filename "$netfile")
	local fragment=${netfile#*#}
	if [[ $fragment = "$netfile" ]]; then
		unset fragment
	fi

	rev="last:1"
	if [[ -n $fragment ]]; then
		case ${fragment%%=*} in
			revision)
				rev="${fragment#*=}"
				displaylocation="$url -r ${fragment#*=}"
				;;
			*)
				error "$(gettext "Unrecognized reference: %s")" "${fragment}"
				plain "$(gettext "Aborting...")"
				exit 1
		esac
	fi

	local dir=$(get_filepath "$netfile")
	[[ -z "$dir" ]] && dir="$SRCDEST/$(get_filename "$netfile")"

	msg2 "$(gettext "Creating working copy of %s %s repo...")" "${repo}" "bzr"
	pushd "$srcdir" &>/dev/null

	if [[ -d "${dir##*/}" ]]; then
		cd_safe "${dir##*/}"
		if ! (bzr pull "$dir" -q --overwrite -r "$rev" && bzr clean-tree -q --detritus --force); then
			error "$(gettext "Failure while updating working copy of %s %s repo")" "${repo}" "bzr"
			plain "$(gettext "Aborting...")"
			exit 1
		fi
	elif ! bzr checkout "$dir" -r "$rev"; then
		error "$(gettext "Failure while creating working copy of %s %s repo")" "${repo}" "bzr"
		plain "$(gettext "Aborting...")"
		exit 1
	fi

	popd &>/dev/null
}

download_git() {
	local netfile=$1

	local dir=$(get_filepath "$netfile")
	[[ -z "$dir" ]] && dir="$SRCDEST/$(get_filename "$netfile")"

	local repo=$(get_filename "$netfile")

	local url=$(get_url "$netfile")
	url=${url#git+}
	url=${url%%#*}

	if [[ ! -d "$dir" ]] || dir_is_empty "$dir" ; then
		msg2 "$(gettext "Cloning %s %s repo...")" "${repo}" "git"
		if ! git clone --mirror "$url" "$dir"; then
			error "$(gettext "Failure while downloading %s %s repo")" "${repo}" "git"
			plain "$(gettext "Aborting...")"
			exit 1
		fi
	elif (( ! HOLDVER )); then
		cd_safe "$dir"
		# Make sure we are fetching the right repo
		if [[ "$url" != "$(git config --get remote.origin.url)" ]] ; then
			error "$(gettext "%s is not a clone of %s")" "$dir" "$url"
			plain "$(gettext "Aborting...")"
			exit 1
		fi
		msg2 "$(gettext "Updating %s %s repo...")" "${repo}" "git"
		if ! git fetch --all -p; then
			# only warn on failure to allow offline builds
			warning "$(gettext "Failure while updating %s %s repo")" "${repo}" "git"
		fi
	fi
}

extract_git() {
	local netfile=$1

	local fragment=${netfile#*#}
	if [[ $fragment = "$netfile" ]]; then
		unset fragment
	fi

	local repo=${netfile##*/}
	repo=${repo%%#*}
	repo=${repo%%.git*}

	local dir=$(get_filepath "$netfile")
	[[ -z "$dir" ]] && dir="$SRCDEST/$(get_filename "$netfile")"

	msg2 "$(gettext "Creating working copy of %s %s repo...")" "${repo}" "git"
	pushd "$srcdir" &>/dev/null

	local updating=0
	if [[ -d "${dir##*/}" ]]; then
		updating=1
		cd_safe "${dir##*/}"
		if ! git fetch; then
			error "$(gettext "Failure while updating working copy of %s %s repo")" "${repo}" "git"
			plain "$(gettext "Aborting...")"
			exit 1
		fi
		cd_safe "$srcdir"
	elif ! git clone "$dir" "${dir##*/}"; then
		error "$(gettext "Failure while creating working copy of %s %s repo")" "${repo}" "git"
		plain "$(gettext "Aborting...")"
		exit 1
	fi

	cd_safe "${dir##*/}"

	local ref=origin/HEAD
	if [[ -n $fragment ]]; then
		case ${fragment%%=*} in
			commit|tag)
				ref=${fragment##*=}
				;;
			branch)
				ref=origin/${fragment##*=}
				;;
			*)
				error "$(gettext "Unrecognized reference: %s")" "${fragment}"
				plain "$(gettext "Aborting...")"
				exit 1
		esac
	fi

	if [[ $ref != "origin/HEAD" ]] || (( updating )) ; then
		if ! git checkout --force --no-track -B makepkg $ref; then
			error "$(gettext "Failure while creating working copy of %s %s repo")" "${repo}" "git"
			plain "$(gettext "Aborting...")"
			exit 1
		fi
	fi

	popd &>/dev/null
}

download_hg() {
	local netfile=$1

	local dir=$(get_filepath "$netfile")
	[[ -z "$dir" ]] && dir="$SRCDEST/$(get_filename "$netfile")"

	local repo=$(get_filename "$netfile")

	local url=$(get_url "$netfile")
	url=${url#hg+}
	url=${url%%#*}

	if [[ ! -d "$dir" ]] || dir_is_empty "$dir" ; then
		msg2 "$(gettext "Cloning %s %s repo...")" "${repo}" "hg"
		if ! hg clone -U "$url" "$dir"; then
			error "$(gettext "Failure while downloading %s %s repo")" "${repo}" "hg"
			plain "$(gettext "Aborting...")"
			exit 1
		fi
	elif (( ! HOLDVER )); then
		msg2 "$(gettext "Updating %s %s repo...")" "${repo}" "hg"
		cd_safe "$dir"
		if ! hg pull; then
			# only warn on failure to allow offline builds
			warning "$(gettext "Failure while updating %s %s repo")" "${repo}" "hg"
		fi
	fi
}

extract_hg() {
	local netfile=$1

	local fragment=${netfile#*#}
	if [[ $fragment = "$netfile" ]]; then
		unset fragment
	fi

	local dir=$(get_filepath "$netfile")
	[[ -z "$dir" ]] && dir="$SRCDEST/$(get_filename "$netfile")"

	local repo=${netfile##*/}
	repo=${repo%%#*}

	msg2 "$(gettext "Creating working copy of %s %s repo...")" "${repo}" "hg"
	pushd "$srcdir" &>/dev/null

	local ref=tip
	if [[ -n $fragment ]]; then
		case ${fragment%%=*} in
			branch|revision|tag)
				ref="${fragment##*=}"
				;;
			*)
				error "$(gettext "Unrecognized reference: %s")" "${fragment}"
				plain "$(gettext "Aborting...")"
				exit 1
		esac
	fi

	if [[ -d "${dir##*/}" ]]; then
		cd_safe "${dir##*/}"
		if ! (hg pull && hg update -C -r "$ref"); then
			error "$(gettext "Failure while updating working copy of %s %s repo")" "${repo}" "hg"
			plain "$(gettext "Aborting...")"
			exit 1
		fi
	elif ! hg clone -u "$ref" "$dir" "${dir##*/}"; then
		error "$(gettext "Failure while creating working copy of %s %s repo")" "${repo}" "hg"
		plain "$(gettext "Aborting...")"
		exit 1
	fi

	popd &>/dev/null
}

download_svn() {
	local netfile=$1

	local fragment=${netfile#*#}
	if [[ $fragment = "$netfile" ]]; then
		unset fragment
	fi

	local dir=$(get_filepath "$netfile")
	[[ -z "$dir" ]] && dir="$SRCDEST/$(get_filename "$netfile")"

	local repo=$(get_filename "$netfile")

	local url=$(get_url "$netfile")
	if [[ $url != svn+ssh* ]]; then
		url=${url#svn+}
	fi
	url=${url%%#*}

	local ref=HEAD
	if [[ -n $fragment ]]; then
		case ${fragment%%=*} in
			revision)
				ref="${fragment##*=}"
				;;
			*)
				error "$(gettext "Unrecognized reference: %s")" "${fragment}"
				plain "$(gettext "Aborting...")"
				exit 1
		esac
	fi

	if [[ ! -d "$dir" ]] || dir_is_empty "$dir" ; then
		msg2 "$(gettext "Cloning %s %s repo...")" "${repo}" "svn"
		mkdir -p "$dir/.makepkg"
		if ! svn checkout -r ${ref} --config-dir "$dir/.makepkg" "$url" "$dir"; then
			error "$(gettext "Failure while downloading %s %s repo")" "${repo}" "svn"
			plain "$(gettext "Aborting...")"
			exit 1
		fi
	elif (( ! HOLDVER )); then
		msg2 "$(gettext "Updating %s %s repo...")" "${repo}" "svn"
		cd_safe "$dir"
		if ! svn update -r ${ref}; then
			# only warn on failure to allow offline builds
			warning "$(gettext "Failure while updating %s %s repo")" "${repo}" "svn"
		fi
	fi
}

extract_svn() {
	local netfile=$1

	local dir=$(get_filepath "$netfile")
	[[ -z "$dir" ]] && dir="$SRCDEST/$(get_filename "$netfile")"

	local repo=${netfile##*/}
	repo=${repo%%#*}

	msg2 "$(gettext "Creating working copy of %s %s repo...")" "${repo}" "svn"

	cp -au "$dir" "$srcdir"
}

get_all_sources() {
	local aggregate l a

	if array_build l 'source'; then
		aggregate+=("${l[@]}")
	fi

	for a in "${arch[@]}"; do
		if array_build l "source_$a"; then
			aggregate+=("${l[@]}")
		fi
	done

	array_build "$1" "aggregate"
}

get_all_sources_for_arch() {
	local aggregate l

	if array_build l 'source'; then
		aggregate+=("${l[@]}")
	fi

	if array_build l "source_$CARCH"; then
		aggregate+=("${l[@]}")
	fi

	array_build "$1" "aggregate"
}

download_sources() {
	local netfile all_sources
	local get_source_fn=get_all_sources_for_arch get_vcs=1

	msg "$(gettext "Retrieving sources...")"

	while true; do
		case $1 in
			allarch)
				get_source_fn=get_all_sources
				;;
			novcs)
				get_vcs=0
				;;
			*)
				break 2
				;;
		esac
		shift
	done

	"$get_source_fn" 'all_sources'
	for netfile in "${all_sources[@]}"; do
		pushd "$SRCDEST" &>/dev/null

		local proto=$(get_protocol "$netfile")
		case "$proto" in
			local)
				download_local "$netfile"
				;;
			bzr*)
				(( get_vcs )) && download_bzr "$netfile"
				;;
			git*)
				(( get_vcs )) && download_git "$netfile"
				;;
			hg*)
				(( get_vcs )) && download_hg "$netfile"
				;;
			svn*)
				(( get_vcs )) && download_svn "$netfile"
				;;
			*)
				download_file "$netfile"
				;;
		esac

		popd &>/dev/null
	done
}

# Automatically update pkgver variable if a pkgver() function is provided
# Re-sources the PKGBUILD afterwards to allow for other variables that use $pkgver
update_pkgver() {
	newpkgver=$(run_function_safe pkgver)
	if ! validate_pkgver "$newpkgver"; then
		error "$(gettext "pkgver() generated an invalid version: %s")" "$newpkgver"
		exit 1
	fi

	if [[ -n $newpkgver && $newpkgver != "$pkgver" ]]; then
		if [[ -f $BUILDFILE && -w $BUILDFILE ]]; then
			if ! sed --follow-symlinks -i "s:^pkgver=[^ ]*:pkgver=$newpkgver:" "$BUILDFILE"; then
				error "$(gettext "Failed to update %s from %s to %s")" \
						"pkgver" "$pkgver" "$newpkgver"
				exit 1
			fi
			sed --follow-symlinks -i "s:^pkgrel=[^ ]*:pkgrel=1:" "$BUILDFILE"
			source_safe "$BUILDFILE"
			local fullver=$(get_full_version)
			msg "$(gettext "Updated version: %s")" "$pkgbase $fullver"
		else
			warning "$(gettext "%s is not writeable -- pkgver will not be updated")" \
					"$BUILDFILE"
		fi
	fi
}

# Print 'source not found' error message and exit makepkg
missing_source_file() {
	error "$(gettext "Unable to find source file %s.")" "$(get_filename "$1")"
	plain "$(gettext "Aborting...")"
	exit 1 # $E_MISSING_FILE
}

##
#  usage : get_full_version()
# return : full version spec, including epoch (if necessary), pkgver, pkgrel
##
get_full_version() {
	if (( epoch > 0 )); then
		printf "%s\n" "$epoch:$pkgver-$pkgrel"
	else
		printf "%s\n" "$pkgver-$pkgrel"
	fi
}

##
#  usage : get_pkg_arch( [$pkgname] )
# return : architecture of the package
##
get_pkg_arch() {
	if [[ -z $1 ]]; then
		if [[ $arch = "any" ]]; then
			printf "%s\n" "any"
		else
			printf "%s\n" "$CARCH"
		fi
	else
		local arch_override
		pkgbuild_get_attribute "$1" arch 0 arch_override
		(( ${#arch_override[@]} == 0 )) && arch_override=("${arch[@]}")
		if [[ $arch_override = "any" ]]; then
			printf "%s\n" "any"
		else
			printf "%s\n" "$CARCH"
		fi
	fi
}

##
# Checks to see if options are present in makepkg.conf or PKGBUILD;
# PKGBUILD options always take precedence.
#
#  usage : check_option( $option, $expected_val )
# return : 0   - matches expected
#          1   - does not match expected
#          127 - not found
##
check_option() {
	in_opt_array "$1" ${options[@]}
	case $? in
		0) # assert enabled
			[[ $2 = y ]]
			return ;;
		1) # assert disabled
			[[ $2 = n ]]
			return
	esac

	# fall back to makepkg.conf options
	in_opt_array "$1" ${OPTIONS[@]}
	case $? in
		0) # assert enabled
			[[ $2 = y ]]
			return ;;
		1) # assert disabled
			[[ $2 = n ]]
			return
	esac

	# not found
	return 127
}


##
# Check if option is present in BUILDENV
#
#  usage : check_buildenv( $option, $expected_val )
# return : 0   - matches expected
#          1   - does not match expected
#          127 - not found
##
check_buildenv() {
	in_opt_array "$1" ${BUILDENV[@]}
	case $? in
		0) # assert enabled
			[[ $2 = "y" ]]
			return ;;
		1) # assert disabled
			[[ $2 = "n" ]]
			return ;;
	esac

	# not found
	return 127
}


##
#  usage : in_opt_array( $needle, $haystack )
# return : 0   - enabled
#          1   - disabled
#          127 - not found
##
in_opt_array() {
	local needle=$1; shift

	local i opt
	for (( i = $#; i > 0; i-- )); do
		opt=${!i}
		if [[ $opt = "$needle" ]]; then
			# enabled
			return 0
		elif [[ $opt = "!$needle" ]]; then
			# disabled
			return 1
		fi
	done

	# not found
	return 127
}


##
#  usage : in_array( $needle, $haystack )
# return : 0 - found
#          1 - not found
##
in_array() {
	local needle=$1; shift
	local item
	for item in "$@"; do
		[[ $item = "$needle" ]] && return 0 # Found
	done
	return 1 # Not Found
}

source_has_signatures() {
	local file all_sources

	get_all_sources_for_arch 'all_sources'
	for file in "${all_sources[@]}"; do
		if [[ ${file%%::*} = *.@(sig?(n)|asc) ]]; then
			return 0
		fi
	done
	return 1
}

run_pacman() {
	local cmd
	if [[ $1 != -@(T|Qq) ]]; then
		cmd=("$PACMAN_PATH" $PACMAN_OPTS "$@")
	else
		cmd=("$PACMAN_PATH" "$@")
	fi
	if [[ $1 != -@(T|Qq) ]]; then
		if type -p sudo >/dev/null; then
			cmd=(sudo "${cmd[@]}")
		else
			cmd=(su root -c "$(printf '%q ' "${cmd[@]}")")
		fi
	fi
	"${cmd[@]}"
}

check_deps() {
	(( $# > 0 )) || return 0

	local ret=0
	local pmout
	pmout=$(run_pacman -T "$@")
	ret=$?

	if (( ret == 127 )); then #unresolved deps
		printf "%s\n" "$pmout"
	elif (( ret )); then
		error "$(gettext "'%s' returned a fatal error (%i): %s")" "$PACMAN" "$ret" "$pmout"
		return "$ret"
	fi
}

handle_deps() {
	local R_DEPS_SATISFIED=0
	local R_DEPS_MISSING=1

	(( $# == 0 )) && return $R_DEPS_SATISFIED

	local deplist="$*"

	if (( ! DEP_BIN )); then
		return $R_DEPS_MISSING
	fi

	if (( DEP_BIN )); then
		# install missing deps from binary packages (using pacman -S)
		msg "$(gettext "Installing missing dependencies...")"

		if ! run_pacman -S --asdeps $deplist; then
			error "$(gettext "'%s' failed to install missing dependencies.")" "$PACMAN"
			exit 1 # TODO: error code
		fi
	fi

	# we might need the new system environment
	# save our shell options and turn off extglob
	local shellopts=$(shopt -p)
	shopt -u extglob
	source /etc/profile &>/dev/null
	eval "$shellopts"

	return $R_DEPS_SATISFIED
}

resolve_deps() {
	local R_DEPS_SATISFIED=0
	local R_DEPS_MISSING=1

	# deplist cannot be declared like this: local deplist=$(foo)
	# Otherwise, the return value will depend on the assignment.
	local deplist
	deplist="$(set +E; check_deps $*)" || exit 1
	[[ -z $deplist ]] && return $R_DEPS_SATISFIED

	if handle_deps $deplist; then
		# check deps again to make sure they were resolved
		deplist="$(set +E; check_deps $*)" || exit 1
		[[ -z $deplist ]] && return $R_DEPS_SATISFIED
	fi

	msg "$(gettext "Missing dependencies:")"
	local dep
	for dep in $deplist; do
		msg2 "$dep"
	done

	return $R_DEPS_MISSING
}

remove_deps() {
	(( ! RMDEPS )) && return

	# check for packages removed during dependency install (e.g. due to conflicts)
	# removing all installed packages is risky in this case
	if [[ -n $(grep -xvFf <(printf '%s\n' "${current_pkglist[@]}") \
			<(printf '%s\n' "${original_pkglist[@]}")) ]]; then
		warning "$(gettext "Failed to remove installed dependencies.")"
		return 0
	fi

	local deplist
	deplist=($(grep -xvFf <(printf "%s\n" "${original_pkglist[@]}") \
			<(printf "%s\n" "${current_pkglist[@]}")))
	if [[ -z $deplist ]]; then
		return 0
	fi

	msg "Removing installed dependencies..."
	# exit cleanly on failure to remove deps as package has been built successfully
	if ! run_pacman -Rn ${deplist[@]}; then
		warning "$(gettext "Failed to remove installed dependencies.")"
		return 0
	fi
}

get_integlist() {
	local integ
	local integlist=()

	for integ in "${known_hash_algos[@]}"; do
		local sumname="${integ}sums[@]"
		if [[ -n ${!sumname} ]]; then
			integlist+=("$integ")
		fi
	done

	if (( ${#integlist[@]} > 0 )); then
		printf "%s\n" "${integlist[@]}"
	else
		printf "%s\n" "${INTEGRITY_CHECK[@]}"
	fi
}

generate_one_checksum() {
	local integ=$1 arch=$2 sources numsrc indentsz idx

	if [[ $arch ]]; then
		array_build sources "source_$arch"
	else
		array_build sources 'source'
	fi

	numsrc=${#sources[*]}
	if (( numsrc == 0 )); then
		return
	fi

	if [[ $arch ]]; then
		printf "%ssums_%s=(%n" "$integ" "$arch" indentsz
	else
		printf "%ssums=(%n" "$integ" indentsz
	fi

	for (( idx = 0; idx < numsrc; ++idx )); do
		local netfile=${sources[idx]}
		local proto sum
		proto="$(get_protocol "$netfile")"

		case $proto in
			bzr*|git*|hg*|svn*)
				sum="SKIP"
				;;
			*)
				if [[ $netfile != *.@(sig?(n)|asc) ]]; then
					local file
					file="$(get_filepath "$netfile")" || missing_source_file "$netfile"
					sum="$(openssl dgst -${integ} "$file")"
					sum=${sum##* }
				else
					sum="SKIP"
				fi
				;;
		esac

		# indent checksum on lines after the first
		printf "%*s%s" $(( idx ? indentsz : 0 )) '' "'$sum'"

		# print a newline on lines before the last
		(( idx < (numsrc - 1) )) && echo
	done

	echo ")"
}

generate_checksums() {
	msg "$(gettext "Generating checksums for source files...")"

	if ! type -p openssl >/dev/null; then
		error "$(gettext "Cannot find the %s binary required for generating sourcefile checksums.")" "openssl"
		exit 1 # $E_MISSING_PROGRAM
	fi

	local integlist
	if (( $# == 0 )); then
		IFS=$'\n' read -rd '' -a integlist < <(get_integlist)
	else
		integlist=("$@")
	fi

	local integ
	for integ in "${integlist[@]}"; do
		if ! in_array "$integ" "${known_hash_algos[@]}"; then
			error "$(gettext "Invalid integrity algorithm '%s' specified.")" "$integ"
			exit 1 # $E_CONFIG_ERROR
		fi

		generate_one_checksum "$integ"
		for a in "${arch[@]}"; do
			generate_one_checksum "$integ" "$a"
		done
	done
}

verify_integrity_one() {
	local source_name=$1 integ=$2 expectedsum=$3

	local file="$(get_filename "$source_name")"
	printf '    %s ... ' "$file" >&2

	if [[ $expectedsum = 'SKIP' ]]; then
		printf '%s\n' "$(gettext "Skipped")" >&2
		return
	fi

	if ! file="$(get_filepath "$file")"; then
		printf '%s\n' "$(gettext "NOT FOUND")" >&2
		return 1
	fi

	local realsum="$(openssl dgst -${integ} "$file")"
	realsum="${realsum##* }"
	if [[ ${expectedsum,,} = "$realsum" ]]; then
		printf '%s\n' "$(gettext "Passed")" >&2
	else
		printf '%s\n' "$(gettext "FAILED")" >&2
		return 1
	fi

	return 0
}

verify_integrity_sums() {
	local integ=$1 arch=$2 integrity_sums=() sources=()

	if [[ $arch ]]; then
		array_build integrity_sums "${integ}sums_$arch"
		array_build sources "source_$arch"
	else
		array_build integrity_sums "${integ}sums"
		array_build sources source
	fi

	if (( ${#integrity_sums[@]} == 0 && ${#sources[@]} == 0 )); then
		return 1
	fi

	if (( ${#integrity_sums[@]} == ${#sources[@]} )); then
		msg "$(gettext "Validating source files with %s...")" "${integ}sums"
		local idx errors=0
		for (( idx = 0; idx < ${#sources[*]}; idx++ )); do
			verify_integrity_one "${sources[idx]}" "$integ" "${integrity_sums[idx]}" || errors=1
		done

		if (( errors )); then
			error "$(gettext "One or more files did not pass the validity check!")"
			exit 1 # TODO: error code
		fi
	elif (( ${#integrity_sums[@]} )); then
		error "$(gettext "Integrity checks (%s) differ in size from the source array.")" "$integ"
		exit 1 # TODO: error code
	else
		return 1
	fi
}

check_checksums() {
	local integ a
	declare -A correlation
	(( SKIPCHECKSUMS )) && return 0

	# Initialize a map which we'll use to verify that every source array has at
	# least some kind of checksum array associated with it.
	(( ${#source[*]} )) && correlation['source']=1
	case $1 in
		all)
			for a in "${arch[@]}"; do
				array_build _ source_"$a" && correlation["source_$a"]=1
			done
			;;
		*)
			array_build _ source_"$CARCH" && correlation["source_$CARCH"]=1
			;;
	esac

	for integ in "${known_hash_algos[@]}"; do
		verify_integrity_sums "$integ" && unset "correlation[source]"

		case $1 in
			all)
				for a in "${arch[@]}"; do
					verify_integrity_sums "$integ" "$a" && unset "correlation[source_$a]"
				done
				;;
			*)
				verify_integrity_sums "$integ" "$CARCH" && unset "correlation[source_$CARCH]"
				;;
		esac
	done

	if (( ${#correlation[*]} )); then
		error "$(gettext "Integrity checks are missing.")"
		exit 1 # TODO: error code
	fi
}

parse_gpg_statusfile() {
	local type arg1 arg6 arg10

	while read -r _ type arg1 _ _ _ _ arg6 _ _ _ arg10 _; do
		case "$type" in
			GOODSIG)
				pubkey=$arg1
				success=1
				status="good"
				;;
			EXPSIG)
				pubkey=$arg1
				success=1
				status="expired"
				;;
			EXPKEYSIG)
				pubkey=$arg1
				success=1
				status="expiredkey"
				;;
			REVKEYSIG)
				pubkey=$arg1
				success=0
				status="revokedkey"
				;;
			BADSIG)
				pubkey=$arg1
				success=0
				status="bad"
				;;
			ERRSIG)
				pubkey=$arg1
				success=0
				if [[ $arg6 == 9 ]]; then
					status="missingkey"
				else
					status="error"
				fi
				;;
			VALIDSIG)
				if [[ $arg10 ]]; then
					# If the file was signed with a subkey, arg10 contains
					# the fingerprint of the primary key
					fingerprint=$arg10
				else
					fingerprint=$arg1
				fi
				;;
			TRUST_UNDEFINED|TRUST_NEVER)
				trusted=0
				;;
			TRUST_MARGINAL|TRUST_FULLY|TRUST_ULTIMATE)
				trusted=1
				;;
		esac
	done < "$1"
}

check_pgpsigs() {
	(( SKIPPGPCHECK )) && return 0
	! source_has_signatures && return 0

	msg "$(gettext "Verifying source file signatures with %s...")" "gpg"

	local file ext decompress found pubkey success status fingerprint trusted
	local warning=0
	local errors=0
	local statusfile=$(mktemp)
	local all_sources

	case $1 in
		all)
			get_all_sources 'all_sources'
			;;
		*)
			get_all_sources_for_arch 'all_sources'
			;;
	esac
	for file in "${all_sources[@]}"; do
		file="$(get_filename "$file")"
		if [[ $file != *.@(sig?(n)|asc) ]]; then
			continue
		fi

		printf "    %s ... " "${file%.*}" >&2

		if ! file="$(get_filepath "$file")"; then
			printf '%s\n' "$(gettext "SIGNATURE NOT FOUND")" >&2
			errors=1
			continue
		fi

		found=0
		for ext in "" gz bz2 xz lrz lzo Z; do
			if sourcefile="$(get_filepath "${file%.*}${ext:+.$ext}")"; then
				found=1
				break;
			fi
		done
		if (( ! found )); then
			printf '%s\n' "$(gettext "SOURCE FILE NOT FOUND")" >&2
			errors=1
			continue
		fi

		case "$ext" in
			gz)  decompress="gzip -c -d -f" ;;
			bz2) decompress="bzip2 -c -d -f" ;;
			xz)  decompress="xz -c -d" ;;
			lrz) decompress="lrzip -q -d" ;;
			lzo) decompress="lzop -c -d -q" ;;
			Z)   decompress="uncompress -c -f" ;;
			"")  decompress="cat" ;;
		esac

		$decompress < "$sourcefile" | gpg --quiet --batch --status-file "$statusfile" --verify "$file" - 2> /dev/null
		# these variables are assigned values in parse_gpg_statusfile
		success=0
		status=
		pubkey=
		fingerprint=
		trusted=
		parse_gpg_statusfile "$statusfile"
		if (( ! $success )); then
			printf '%s' "$(gettext "FAILED")" >&2
			case "$status" in
				"missingkey")
					printf ' (%s)' "$(gettext "unknown public key") $pubkey" >&2
					;;
				"revokedkey")
					printf " ($(gettext "public key %s has been revoked"))" "$pubkey" >&2
					;;
				"bad")
					printf ' (%s)' "$(gettext "bad signature from public key") $pubkey" >&2
					;;
				"error")
					printf ' (%s)' "$(gettext "error during signature verification")" >&2
					;;
			esac
			errors=1
		else
			if (( ${#validpgpkeys[@]} == 0 && !trusted )); then
				printf "%s ($(gettext "the public key %s is not trusted"))" $(gettext "FAILED") "$fingerprint" >&2
				errors=1
			elif (( ${#validpgpkeys[@]} > 0 )) && ! in_array "$fingerprint" "${validpgpkeys[@]}"; then
				printf "%s (%s %s)" "$(gettext "FAILED")" "$(gettext "invalid public key")" "$fingerprint"
				errors=1
			else
				printf '%s' "$(gettext "Passed")" >&2
				case "$status" in
					"expired")
						printf ' (%s)' "$(gettext "WARNING:") $(gettext "the signature has expired.")" >&2
						warnings=1
						;;
					"expiredkey")
						printf ' (%s)' "$(gettext "WARNING:") $(gettext "the key has expired.")" >&2
						warnings=1
						;;
				esac
			fi
		fi
		printf '\n' >&2
	done

	rm -f "$statusfile"

	if (( errors )); then
		error "$(gettext "One or more PGP signatures could not be verified!")"
		exit 1
	fi

	if (( warnings )); then
		warning "$(gettext "Warnings have occurred while verifying the signatures.")"
		plain "$(gettext "Please make sure you really trust them.")"
	fi
}

check_source_integrity() {
	if (( SKIPCHECKSUMS && SKIPPGPCHECK )); then
		warning "$(gettext "Skipping all source file integrity checks.")"
	elif (( SKIPCHECKSUMS )); then
		warning "$(gettext "Skipping verification of source file checksums.")"
		check_pgpsigs "$@"
	elif (( SKIPPGPCHECK )); then
		warning "$(gettext "Skipping verification of source file PGP signatures.")"
		check_checksums "$@"
	else
		check_checksums "$@"
		check_pgpsigs "$@"
	fi
}

extract_sources() {
	msg "$(gettext "Extracting sources...")"
	local netfile all_sources

	get_all_sources_for_arch 'all_sources'
	for netfile in "${all_sources[@]}"; do
		local file=$(get_filename "$netfile")
		local proto=$(get_protocol "$netfile")
		case "$proto" in
			bzr*)
				extract_bzr "$netfile"
				;;
			git*)
				extract_git "$netfile"
				;;
			hg*)
				extract_hg "$netfile"
				;;
			svn*)
				extract_svn "$netfile"
				;;
			*)
				extract_file "$file"
				;;
		esac
	done
}

error_function() {
	if [[ -p $logpipe ]]; then
		rm "$logpipe"
	fi
	# first exit all subshells, then print the error
	if (( ! BASH_SUBSHELL )); then
		error "$(gettext "A failure occurred in %s().")" "$1"
		plain "$(gettext "Aborting...")"
	fi
	exit 2 # $E_BUILD_FAILED
}

cd_safe() {
	if ! cd "$1"; then
		error "$(gettext "Failed to change to directory %s")" "$1"
		plain "$(gettext "Aborting...")"
		exit 1
	fi
}

source_safe() {
	shopt -u extglob
	if ! source "$@"; then
		error "$(gettext "Failed to source %s")" "$1"
		exit 1
	fi
	shopt -s extglob
}

merge_arch_attrs() {
	local attr supported_attrs=(
		provides conflicts depends replaces optdepends
		makedepends checkdepends)

	for attr in "${supported_attrs[@]}"; do
		eval "$attr+=(\"\${${attr}_$CARCH[@]}\")"
	done

	# ensure that calling this function is idempotent.
	unset -v "${supported_attrs[@]/%/_$CARCH}"
}

source_buildfile() {
	source_safe "$@"

	if (( !SOURCEONLY )); then
		merge_arch_attrs
	fi
}

run_function_safe() {
	local restoretrap

	set -e
	set -E

	restoretrap=$(trap -p ERR)
	trap 'error_function $pkgfunc' ERR

	run_function "$1"

	eval $restoretrap

	set +E
	set +e
}

run_function() {
	if [[ -z $1 ]]; then
		return 1
	fi
	local pkgfunc="$1"

	# clear user-specified buildflags if requested
	if check_option "buildflags" "n"; then
		unset CPPFLAGS CFLAGS CXXFLAGS LDFLAGS
	fi

	if check_option "debug" "y"; then
		CFLAGS+=" $DEBUG_CFLAGS"
		CXXFLAGS+=" $DEBUG_CXXFLAGS"
	fi

	# clear user-specified makeflags if requested
	if check_option "makeflags" "n"; then
		unset MAKEFLAGS
	fi

	msg "$(gettext "Starting %s()...")" "$pkgfunc"
	cd_safe "$srcdir"

	# ensure all necessary build variables are exported
	export CPPFLAGS CFLAGS CXXFLAGS LDFLAGS MAKEFLAGS CHOST
	# save our shell options so pkgfunc() can't override what we need
	local shellopts=$(shopt -p)

	local ret=0
	if (( LOGGING )); then
		local fullver=$(get_full_version)
		local BUILDLOG="$LOGDEST/${pkgbase}-${fullver}-${CARCH}-$pkgfunc.log"
		if [[ -f $BUILDLOG ]]; then
			local i=1
			while true; do
				if [[ -f $BUILDLOG.$i ]]; then
					i=$(($i +1))
				else
					break
				fi
			done
			mv "$BUILDLOG" "$BUILDLOG.$i"
		fi

		# ensure overridden package variables survive tee with split packages
		logpipe=$(mktemp -u "$LOGDEST/logpipe.XXXXXXXX")
		mkfifo "$logpipe"
		tee "$BUILDLOG" < "$logpipe" &
		local teepid=$!

		$pkgfunc &>"$logpipe"

		wait $teepid
		rm "$logpipe"
	else
		"$pkgfunc"
	fi
	# reset our shell options
	eval "$shellopts"
}

run_prepare() {
	run_function_safe "prepare"
}

run_build() {
	# use distcc if it is requested (check buildenv and PKGBUILD opts)
	if check_buildenv "distcc" "y" && ! check_option "distcc" "n"; then
		[[ -d /usr/lib/distcc/bin ]] && export PATH="/usr/lib/distcc/bin:$PATH"
		export DISTCC_HOSTS
	fi

	# use ccache if it is requested (check buildenv and PKGBUILD opts)
	if check_buildenv "ccache" "y" && ! check_option "ccache" "n"; then
		[[ -d /usr/lib/ccache/bin ]] && export PATH="/usr/lib/ccache/bin:$PATH"
	fi

	run_function_safe "build"
}

run_check() {
	run_function_safe "check"
}

run_package() {
	local pkgfunc
	if [[ -z $1 ]]; then
		pkgfunc="package"
	else
		pkgfunc="package_$1"
	fi

	run_function_safe "$pkgfunc"
}

build_id() {
	LANG=C readelf -n $1 | sed -n '/Build ID/ { s/.*: //p; q; }'
}

strip_file() {
	local binary=$1; shift

	if check_option "debug" "y"; then
		local bid=$(build_id "$binary")

		# has this file already been stripped
		if [[ -n "$bid" ]]; then
			if [[ -f "$dbgdir/.build-id/${bid:0:2}/${bid:2}.debug" ]]; then
				return
			fi
		elif [[ -f "$dbgdir/$binary.debug" ]]; then
			return
		fi

		mkdir -p "$dbgdir/${binary%/*}"
		objcopy --only-keep-debug "$binary" "$dbgdir/$binary.debug"
		objcopy --add-gnu-debuglink="$dbgdir/${binary#/}.debug" "$binary"

		# create any needed hardlinks
		while read -rd '' file ; do
			if [[ "${binary}" -ef "${file}" && ! -f "$dbgdir/${file}.debug" ]]; then
				mkdir -p "$dbgdir/${file%/*}"
				ln "$dbgdir/${binary}.debug" "$dbgdir/${file}.debug"
			fi
		done < <(find . -type f -perm -u+w -print0 2>/dev/null)

		if [[ -n "$bid" ]]; then
			local target
			mkdir -p "$dbgdir/.build-id/${bid:0:2}"

			target="../../../../../${binary#./}"
			target="${target/..\/..\/usr\/lib\/}"
			target="${target/..\/usr\/}"
			ln -s "$target" "$dbgdir/.build-id/${bid:0:2}/${bid:2}"

			target="../../${binary#./}.debug"
			ln -s "$target" "$dbgdir/.build-id/${bid:0:2}/${bid:2}.debug"
		fi
	fi

	strip $@ "$binary"
}

tidy_install() {
	cd_safe "$pkgdir"
	msg "$(gettext "Tidying install...")"

	if check_option "docs" "n" && [[ -n ${DOC_DIRS[*]} ]]; then
		msg2 "$(gettext "Removing doc files...")"
		rm -rf -- ${DOC_DIRS[@]}
	fi

	if check_option "purge" "y" && [[ -n ${PURGE_TARGETS[*]} ]]; then
		msg2 "$(gettext "Purging unwanted files...")"
		local pt
		for pt in "${PURGE_TARGETS[@]}"; do
			if [[ ${pt} = "${pt//\/}" ]]; then
				find . ! -type d -name "${pt}" -exec rm -f -- '{}' +
			else
				rm -f ${pt}
			fi
		done
	fi

	if check_option "libtool" "n"; then
		msg2 "$(gettext "Removing "%s" files...")" "libtool"
		find . ! -type d -name "*.la" -exec rm -f -- '{}' +
	fi

	if check_option "staticlibs" "n"; then
		msg2 "$(gettext "Removing static library files...")"
		local l
		while read -rd '' l; do
			if [[ -f "${l%.a}.so" || -h "${l%.a}.so" ]]; then
				rm "$l"
			fi
		done < <(find . ! -type d -name "*.a" -print0)
	fi

	if check_option "emptydirs" "n"; then
		msg2 "$(gettext "Removing empty directories...")"
		find . -depth -type d -exec rmdir '{}' + 2>/dev/null
	fi

	# check existence of backup files
	local file
	for file in "${backup[@]}"; do
		if [[ ! -f $file ]]; then
			warning "$(gettext "%s entry file not in package : %s")" "backup" "$file"
		fi
	done

	# check for references to the build and package directory
	if find "${pkgdir}" -type f -print0 | xargs -0 grep -q -I "${srcdir}" ; then
		warning "$(gettext "Package contains reference to %s")" "\$srcdir"
	fi
	if find "${pkgdir}" -type f -print0 | xargs -0 grep -q -I "${pkgdirbase}" ; then
		warning "$(gettext "Package contains reference to %s")" "\$pkgdir"
	fi

	if check_option "zipman" "y" && [[ -n ${MAN_DIRS[*]} ]]; then
		msg2 "$(gettext "Compressing man and info pages...")"
		local file files inode link
		while read -rd ' ' inode; do
			read file
			find ${MAN_DIRS[@]} -type l 2>/dev/null |
			while read -r link ; do
				if [[ "${file}" -ef "${link}" ]] ; then
					rm -f "$link" "${link}.gz"
					if [[ ${file%/*} = ${link%/*} ]]; then
						ln -s -- "${file##*/}.gz" "${link}.gz"
					else
						ln -s -- "/${file}.gz" "${link}.gz"
					fi
				fi
			done
			if [[ -z ${files[$inode]} ]]; then
				files[$inode]=$file
				gzip -9 -n -f "$file"
			else
				rm -f "$file"
				ln "${files[$inode]}.gz" "${file}.gz"
				chmod 644 "${file}.gz"
			fi
		done < <(find ${MAN_DIRS[@]} -type f \! -name "*.gz" \! -name "*.bz2" \
			-exec stat -c '%i %n' '{}' + 2>/dev/null)
	fi

	if check_option "strip" "y"; then
		msg2 "$(gettext "Stripping unneeded symbols from binaries and libraries...")"
		# make sure library stripping variables are defined to prevent excess stripping
		[[ -z ${STRIP_SHARED+x} ]] && STRIP_SHARED="-S"
		[[ -z ${STRIP_STATIC+x} ]] && STRIP_STATIC="-S"

		if check_option "debug" "y"; then
			dbgdir="$pkgdir-debug/usr/lib/debug"
			mkdir -p "$dbgdir"
		fi

		local binary strip_flags
		find . -type f -perm -u+w -print0 2>/dev/null | while read -rd '' binary ; do
			case "$(file -bi "$binary")" in
				*application/x-sharedlib*)  # Libraries (.so)
					strip_flags="$STRIP_SHARED";;
				*application/x-archive*)    # Libraries (.a)
					strip_flags="$STRIP_STATIC";;
				*application/x-object*)
					case "$binary" in
						*.ko)                   # Kernel module
							strip_flags="$STRIP_SHARED";;
						*)
							continue;;
					esac;;
				*application/x-executable*) # Binaries
					strip_flags="$STRIP_BINARIES";;
				*)
					continue ;;
			esac
			strip_file "$binary" ${strip_flags}
		done
	fi

	if check_option "upx" "y"; then
		msg2 "$(gettext "Compressing binaries with %s...")" "UPX"
		local binary
		find . -type f -perm -u+w 2>/dev/null | while read -r binary ; do
			if [[ $(file -bi "$binary") = *'application/x-executable'* ]]; then
				upx $UPXFLAGS "$binary" &>/dev/null ||
						warning "$(gettext "Could not compress binary : %s")" "${binary/$pkgdir\//}"
			fi
		done
	fi
}

find_libdepends() {
	local d sodepends;

	sodepends=0;
	for d in "${depends[@]}"; do
		if [[ $d = *.so ]]; then
			sodepends=1;
			break;
		fi
	done

	if (( sodepends == 0 )); then
		printf '%s\n' "${depends[@]}"
		return;
	fi

	local libdeps filename soarch sofile soname soversion;
	declare -A libdeps;

	while read -r filename; do
		# get architecture of the file; if soarch is empty it's not an ELF binary
		soarch=$(LC_ALL=C readelf -h "$filename" 2>/dev/null | sed -n 's/.*Class.*ELF\(32\|64\)/\1/p')
		[[ -n "$soarch" ]] || continue

		# process all libraries needed by the binary
		for sofile in $(LC_ALL=C readelf -d "$filename" 2>/dev/null | sed -nr 's/.*Shared library: \[(.*)\].*/\1/p')
		do
			# extract the library name: libfoo.so
			soname="${sofile%.so?(+(.+([0-9])))}".so
			# extract the major version: 1
			soversion="${sofile##*\.so\.}"

			if [[ ${libdeps[$soname]} ]]; then
				if [[ ${libdeps[$soname]} != *${soversion}-${soarch}* ]]; then
					libdeps[$soname]+=" ${soversion}-${soarch}"
				fi
			else
				libdeps[$soname]="${soversion}-${soarch}"
			fi
		done
	done < <(find "$pkgdir" -type f -perm -u+x)

	local libdepends v
	for d in "${depends[@]}"; do
		case "$d" in
			*.so)
				if [[ ${libdeps[$d]} ]]; then
					for v in ${libdeps[$d]}; do
						libdepends+=("$d=$v")
					done
				else
					warning "$(gettext "Library listed in %s is not required by any files: %s")" "'depends'" "$d"
					libdepends+=("$d")
				fi
				;;
			*)
				libdepends+=("$d")
				;;
		esac
	done

	printf '%s\n' "${libdepends[@]}"
}


find_libprovides() {
	local p libprovides missing
	for p in "${provides[@]}"; do
		missing=0
		case "$p" in
			*.so)
				mapfile -t filename < <(find "$pkgdir" -type f -name $p\*)
				if [[ $filename ]]; then
					# packages may provide multiple versions of the same library
					for fn in "${filename[@]}"; do
						# check if we really have a shared object
						if LC_ALL=C readelf -h "$fn" 2>/dev/null | grep -q '.*Type:.*DYN (Shared object file).*'; then
							# get the string binaries link to (e.g. libfoo.so.1.2 -> libfoo.so.1)
							local sofile=$(LC_ALL=C readelf -d "$fn" 2>/dev/null | sed -n 's/.*Library soname: \[\(.*\)\].*/\1/p')
							if [[ -z "$sofile" ]]; then
								warning "$(gettext "Library listed in %s is not versioned: %s")" "'provides'" "$p"
								libprovides+=("$p")
								continue
							fi

							# get the library architecture (32 or 64 bit)
							local soarch=$(LC_ALL=C readelf -h "$fn" | sed -n 's/.*Class.*ELF\(32\|64\)/\1/p')

							# extract the library major version
							local soversion="${sofile##*\.so\.}"

							libprovides+=("${p}=${soversion}-${soarch}")
						else
							warning "$(gettext "Library listed in %s is not a shared object: %s")" "'provides'" "$p"
							libprovides+=("$p")
						fi
					done
				else
					libprovides+=("$p")
					missing=1
				fi
				;;
			*)
				libprovides+=("$p")
				;;
		esac

		if (( missing )); then
			warning "$(gettext "Cannot find library listed in %s: %s")" "'provides'" "$p"
		fi
	done

	printf '%s\n' "${libprovides[@]}"
}

srcinfo_open_section() {
	printf '%s = %s\n' "$1" "$2"
}

srcinfo_close_section() {
	echo
}

srcinfo_write_attr() {
	# $1: attr name
	# $2: attr values

	local attrname=$1 attrvalues=("${@:2}")

	# normalize whitespace, strip leading and trailing
	attrvalues=("${attrvalues[@]//+([[:space:]])/ }")
	attrvalues=("${attrvalues[@]#[[:space:]]}")
	attrvalues=("${attrvalues[@]%[[:space:]]}")

	printf "\t$attrname = %s\n" "${attrvalues[@]}"
}

pkgbuild_extract_to_srcinfo() {
	# $1: pkgname
	# $2: attr name
	# $3: multivalued

	local pkgname=$1 attrname=$2 isarray=$3 outvalue=

	if pkgbuild_get_attribute "$pkgname" "$attrname" "$isarray" 'outvalue'; then
		srcinfo_write_attr "$attrname" "${outvalue[@]}"
	fi
}

srcinfo_write_section_details() {
	local attr package_arch a
	local multivalued_arch_attrs=(source provides conflicts depends replaces
	                              optdepends makedepends checkdepends
	                              {md5,sha{1,224,256,384,512}}sums)

	for attr in "${singlevalued[@]}"; do
		pkgbuild_extract_to_srcinfo "$1" "$attr" 0
	done

	for attr in "${multivalued[@]}"; do
		pkgbuild_extract_to_srcinfo "$1" "$attr" 1
	done

	pkgbuild_get_attribute "$1" 'arch' 1 'package_arch'
	for a in "${package_arch[@]}"; do
		# 'any' is special. there's no support for, e.g. depends_any.
		[[ $a = any ]] && continue

		for attr in "${multivalued_arch_attrs[@]}"; do
			pkgbuild_extract_to_srcinfo "$1" "${attr}_$a" 1
		done
	done
}

srcinfo_write_global() {
	local singlevalued=(pkgdesc pkgver pkgrel epoch url install changelog)
	local multivalued=(arch groups license checkdepends makedepends
	                   depends optdepends provides conflicts replaces
	                   noextract options backup
	                   source {md5,sha{1,224,256,384,512}}sums)

	srcinfo_open_section 'pkgbase' "${pkgbase:-$pkgname}"
	srcinfo_write_section_details ''
	srcinfo_close_section
}

srcinfo_write_package() {
	local singlevalued=(pkgdesc url install changelog)
	local multivalued=(arch groups license checkdepends depends optdepends
	                   provides conflicts replaces options backup)

	srcinfo_open_section 'pkgname' "$1"
	srcinfo_write_section_details "$1"
	srcinfo_close_section
}

write_srcinfo() {
	local pkg

	printf "# Generated by makepkg %s\n" "$makepkg_version"
	printf "# %s\n" "$(LC_ALL=C date -u)"

	srcinfo_write_global

	for pkg in "${pkgname[@]}"; do
		srcinfo_write_package "$pkg"
	done
}

write_pkginfo() {
	local builddate=$(date -u "+%s")
	if [[ -n $PACKAGER ]]; then
		local packager="$PACKAGER"
	else
		local packager="Unknown Packager"
	fi

	local size="$(/usr/bin/du -sk --apparent-size)"
	size="$(( ${size%%[^0-9]*} * 1024 ))"

	merge_arch_attrs

	msg2 "$(gettext "Generating %s file...")" ".PKGINFO"
	printf "# Generated by makepkg %s\n" "$makepkg_version"
	printf "# using %s\n" "$(fakeroot -v)"
	printf "# %s\n" "$(LC_ALL=C date -u)"

	printf "pkgname = %s\n" "$pkgname"
	if (( SPLITPKG )) || [[ "$pkgbase" != "$pkgname" ]]; then
		printf "pkgbase = %s\n" "$pkgbase"
	fi

	local fullver=$(get_full_version)
	printf "pkgver = %s\n" "$fullver"
	if [[ "$fullver" != "$basever" ]]; then
		printf "basever = %s\n" "$basever"
	fi

	# TODO: all fields should have this treatment
	local spd="${pkgdesc//+([[:space:]])/ }"
	spd=("${spd[@]#[[:space:]]}")
	spd=("${spd[@]%[[:space:]]}")

	printf "pkgdesc = %s\n" "$spd"
	printf "url = %s\n" "$url"
	printf "builddate = %s\n" "$builddate"
	printf "packager = %s\n" "$packager"
	printf "size = %s\n" "$size"
	printf "arch = %s\n" "$pkgarch"

	mapfile -t provides < <(find_libprovides)
	mapfile -t depends < <(find_libdepends)

	[[ $license ]]      && printf "license = %s\n"     "${license[@]}"
	[[ $replaces ]]     && printf "replaces = %s\n"    "${replaces[@]}"
	[[ $groups ]]       && printf "group = %s\n"       "${groups[@]}"
	[[ $conflicts ]]    && printf "conflict = %s\n"    "${conflicts[@]}"
	[[ $provides ]]     && printf "provides = %s\n"    "${provides[@]}"
	[[ $backup ]]       && printf "backup = %s\n"      "${backup[@]}"
	[[ $depends ]]      && printf "depend = %s\n"      "${depends[@]}"
	[[ $optdepends ]]   && printf "optdepend = %s\n"   "${optdepends[@]//+([[:space:]])/ }"
	[[ $makedepends ]]  && printf "makedepend = %s\n"  "${makedepends[@]}"
	[[ $checkdepends ]] && printf "checkdepend = %s\n" "${checkdepends[@]}"

	local it
	for it in "${packaging_options[@]}"; do
		check_option "$it" "y"
		case $? in
			0)
				printf "makepkgopt = %s\n" "$it"
				;;
			1)
				printf "makepkgopt = %s\n" "!$it"
				;;
		esac
	done
}

create_package() {
	(( NOARCHIVE )) && return

	if [[ ! -d $pkgdir ]]; then
		error "$(gettext "Missing %s directory.")" "\$pkgdir/"
		plain "$(gettext "Aborting...")"
		exit 1 # $E_MISSING_PKGDIR
	fi

	cd_safe "$pkgdir"
	msg "$(gettext "Creating package \"%s\"...")" "$pkgname"

	pkgarch=$(get_pkg_arch)
	write_pkginfo > .PKGINFO

	local comp_files=('.PKGINFO')

	# check for changelog/install files
	for i in 'changelog/.CHANGELOG' 'install/.INSTALL'; do
		IFS='/' read -r orig dest < <(printf '%s\n' "$i")

		if [[ -n ${!orig} ]]; then
			msg2 "$(gettext "Adding %s file...")" "$orig"
			if ! cp "$startdir/${!orig}" "$dest"; then
				error "$(gettext "Failed to add %s file to package.")" "$orig"
				exit 1
			fi
			chmod 644 "$dest"
			comp_files+=("$dest")
		fi
	done

	# tar it up
	local fullver=$(get_full_version)
	local pkg_file="$PKGDEST/${pkgname}-${fullver}-${pkgarch}${PKGEXT}"
	local ret=0

	[[ -f $pkg_file ]] && rm -f "$pkg_file"
	[[ -f $pkg_file.sig ]] && rm -f "$pkg_file.sig"

	# when fileglobbing, we want * in an empty directory to expand to
	# the null string rather than itself
	shopt -s nullglob

	msg2 "$(gettext "Generating .MTREE file...")"
	LANG=C bsdtar -czf .MTREE --format=mtree \
		--options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
		"${comp_files[@]}" *
	comp_files+=(".MTREE")

	msg2 "$(gettext "Compressing package...")"
	# TODO: Maybe this can be set globally for robustness
	shopt -s -o pipefail
	# bsdtar's gzip compression always saves the time stamp, making one
	# archive created using the same command line distinct from another.
	# Disable bsdtar compression and use gzip -n for now.
	LANG=C bsdtar -cf - "${comp_files[@]}" * |
	case "$PKGEXT" in
		*tar.gz)  ${COMPRESSGZ[@]:-gzip -c -f -n} ;;
		*tar.bz2) ${COMPRESSBZ2[@]:-bzip2 -c -f} ;;
		*tar.xz)  ${COMPRESSXZ[@]:-xz -c -z -} ;;
		*tar.lrz) ${COMPRESSLRZ[@]:-lrzip -q} ;;
		*tar.lzo) ${COMPRESSLZO[@]:-lzop -q} ;;
		*tar.Z)   ${COMPRESSZ[@]:-compress -c -f} ;;
		*tar)     cat ;;
		*) warning "$(gettext "'%s' is not a valid archive extension.")" \
			"$PKGEXT"; cat ;;
	esac > "${pkg_file}" || ret=$?

	shopt -u nullglob
	shopt -u -o pipefail

	if (( ret )); then
		error "$(gettext "Failed to create package file.")"
		exit 1 # TODO: error code
	fi

	create_signature "$pkg_file"

	if (( ! ret )) && [[ ! "$PKGDEST" -ef "${startdir}" ]]; then
		rm -f "${pkg_file/$PKGDEST/$startdir}"
		ln -s "${pkg_file}" "${pkg_file/$PKGDEST/$startdir}"
		ret=$?
		if [[ -f $pkg_file.sig ]]; then
			rm -f "${pkg_file/$PKGDEST/$startdir}.sig"
			ln -s "$pkg_file.sig" "${pkg_file/$PKGDEST/$startdir}.sig"
		fi
	fi

	if (( ret )); then
		warning "$(gettext "Failed to create symlink to package file.")"
	fi
}

create_debug_package() {
	# check if a debug package was requested
	if ! check_option "debug" "y" || ! check_option "strip" "y"; then
		return
	fi

	pkgdir="${pkgdir}-debug"

	# check if we have any debug symbols to package
	if dir_is_empty "$pkgdir/usr/lib/debug"; then
		return
	fi

	depends=("$pkgname=$(get_full_version)")
	pkgdesc="Detached debugging symbols for $pkgname"
	pkgname=$pkgname-debug

	unset groups optdepends provides conflicts replaces backup install changelog

	create_package
}

create_signature() {
	if [[ $SIGNPKG != 'y' ]]; then
		return
	fi
	local ret=0
	local filename="$1"
	msg "$(gettext "Signing package...")"

	local SIGNWITHKEY=""
	if [[ -n $GPGKEY ]]; then
		SIGNWITHKEY="-u ${GPGKEY}"
	fi

	gpg --detach-sign --use-agent ${SIGNWITHKEY} --no-armor "$filename" &>/dev/null || ret=$?


	if (( ! ret )); then
		msg2 "$(gettext "Created signature file %s.")" "$filename.sig"
	else
		warning "$(gettext "Failed to sign package file.")"
	fi
}

create_srcpackage() {
	local ret=0
	msg "$(gettext "Creating source package...")"
	local srclinks="$(mktemp -d "$startdir"/srclinks.XXXXXXXXX)"
	mkdir "${srclinks}"/${pkgbase}

	msg2 "$(gettext "Adding %s...")" "$BUILDSCRIPT"
	ln -s "${BUILDFILE}" "${srclinks}/${pkgbase}/${BUILDSCRIPT}"

	msg2 "$(gettext "Generating %s file...")" .SRCINFO
	write_srcinfo > "$srclinks/$pkgbase"/.SRCINFO

	local file all_sources

	get_all_sources 'all_sources'
	for file in "${all_sources[@]}"; do
		if [[ "$file" = "$(get_filename "$file")" ]] || (( SOURCEONLY == 2 )); then
			local absfile
			absfile=$(get_filepath "$file") || missing_source_file "$file"
			msg2 "$(gettext "Adding %s...")" "${absfile##*/}"
			ln -s "$absfile" "$srclinks/$pkgbase"
		fi
	done

	local i
	for i in 'changelog' 'install'; do
		local file files

		[[ ${!i} ]] && files+=("${!i}")
		for name in "${pkgname[@]}"; do
			if extract_function_var "package_$name" "$i" 0 file; then
				files+=("$file")
			fi
		done

		for file in "${files[@]}"; do
			if [[ $file && ! -f "${srclinks}/${pkgbase}/$file" ]]; then
				msg2 "$(gettext "Adding %s file (%s)...")" "$i" "${file}"
				ln -s "${startdir}/$file" "${srclinks}/${pkgbase}/"
			fi
		done
	done

	local TAR_OPT
	case "$SRCEXT" in
		*tar.gz)  TAR_OPT="-z" ;;
		*tar.bz2) TAR_OPT="-j" ;;
		*tar.xz)  TAR_OPT="-J" ;;
		*tar.lrz) TAR_OPT="--lrzip" ;;
		*tar.lzo) TAR_OPT="--lzop" ;;
		*tar.Z)   TAR_OPT="-Z" ;;
		*tar)     TAR_OPT=""  ;;
		*) warning "$(gettext "'%s' is not a valid archive extension.")" \
		"$SRCEXT" ;;
	esac

	local fullver=$(get_full_version)
	local pkg_file="$SRCPKGDEST/${pkgbase}-${fullver}${SRCEXT}"

	# tar it up
	msg2 "$(gettext "Compressing source package...")"
	cd_safe "${srclinks}"
	if ! LANG=C bsdtar -cL ${TAR_OPT} -f "$pkg_file" ${pkgbase}; then
		error "$(gettext "Failed to create source package file.")"
		exit 1 # TODO: error code
	fi

	create_signature "$pkg_file"

	if [[ ! "$SRCPKGDEST" -ef "${startdir}" ]]; then
		rm -f "${pkg_file/$SRCPKGDEST/$startdir}"
		ln -s "${pkg_file}" "${pkg_file/$SRCPKGDEST/$startdir}"
		ret=$?
		if [[ -f $pkg_file.sig ]]; then
			rm -f "${pkg_file/$PKGDEST/$startdir}.sig"
			ln -s "$pkg_file.sig" "${pkg_file/$PKGDEST/$startdir}.sig"
		fi
	fi

	if (( ret )); then
		warning "$(gettext "Failed to create symlink to source package file.")"
	fi

	cd_safe "${startdir}"
	rm -rf "${srclinks}"
}

# this function always returns 0 to make sure clean-up will still occur
install_package() {
	(( ! INSTALL )) && return

	if (( ! SPLITPKG )); then
		msg "$(gettext "Installing package %s with %s...")" "$pkgname" "$PACMAN -U"
	else
		msg "$(gettext "Installing %s package group with %s...")" "$pkgbase" "$PACMAN -U"
	fi

	local fullver pkgarch pkg pkglist
	(( ASDEPS )) && pkglist+=('--asdeps')
	(( NEEDED )) && pkglist+=('--needed')

	for pkg in ${pkgname[@]}; do
		fullver=$(get_full_version)
		pkgarch=$(get_pkg_arch $pkg)
		pkglist+=("$PKGDEST/${pkg}-${fullver}-${pkgarch}${PKGEXT}")

		if [[ -f "$PKGDEST/${pkg}-debug-${fullver}-${pkgarch}${PKGEXT}" ]]; then
			pkglist+=("$PKGDEST/${pkg}-debug-${fullver}-${pkgarch}${PKGEXT}")
		fi
	done

	if ! run_pacman -U "${pkglist[@]}"; then
		warning "$(gettext "Failed to install built package(s).")"
		return 0
	fi
}

have_function() {
	declare -f "$1" >/dev/null
}

array_build() {
	local dest=$1 src=$2 i keys values

	# it's an error to try to copy a value which doesn't exist.
	declare -p "$2" &>/dev/null || return 1

	# Build an array of the indicies of the source array.
	eval "keys=(\"\${!$2[@]}\")"

	# Clear the destination array
	eval "$dest=()"

	# Read values indirectly via their index. This approach gives us support
	# for associative arrays, sparse arrays, and empty strings as elements.
	for i in "${keys[@]}"; do
		values+=("printf -v '$dest[$i]' %s \"\${$src[$i]}\";")
	done

	eval "${values[*]}"
}

funcgrep() {
	{ declare -f "$1" || declare -f package; } 2>/dev/null | grep -E "$2"
}

extract_global_var() {
	# $1: variable name
	# $2: multivalued
	# $3: name of output var

	local attr=$1 isarray=$2 outputvar=$3 ref

	if (( isarray )); then
		array_build ref "$attr"
		[[ ${ref[@]} ]] && array_build "$outputvar" "$attr"
	else
		[[ ${!attr} ]] && printf -v "$outputvar" %s "${!attr}"
	fi
}

extract_function_var() {
	# $1: function name
	# $2: variable name
	# $3: multivalued
	# $4: name of output var

	local funcname=$1 attr=$2 isarray=$3 outputvar=$4 attr_regex= decl= r=1

	if (( isarray )); then
		printf -v attr_regex '^[[:space:]]* %s\+?=\(' "$2"
	else
		printf -v attr_regex '^[[:space:]]* %s\+?=[^(]' "$2"
	fi

	while read -r; do
		# strip leading whitespace and any usage of declare
		decl=${REPLY##*([[:space:]])}
		eval "${decl/#$attr/$outputvar}"

		# entering this loop at all means we found a match, so notify the caller.
		r=0
	done < <(funcgrep "$funcname" "$attr_regex")

	return $r
}

pkgbuild_get_attribute() {
	# $1: package name
	# $2: attribute name
	# $3: multivalued
	# $4: name of output var

	local pkgname=$1 attrname=$2 isarray=$3 outputvar=$4

	printf -v "$outputvar" %s ''

	if [[ $pkgname ]]; then
		extract_global_var "$attrname" "$isarray" "$outputvar"
		extract_function_var "package_$pkgname" "$attrname" "$isarray" "$outputvar"
	else
		extract_global_var "$attrname" "$isarray" "$outputvar"
	fi
}

lint_pkgbase() {
	if [[ ${pkgbase:0:1} = "-" ]]; then
		error "$(gettext "%s is not allowed to start with a hyphen.")" "pkgname"
		return 1
	fi
}

lint_pkgname() {
	local ret=0 i

	for i in "${pkgname[@]}"; do
		if [[ -z $i ]]; then
			error "$(gettext "%s is not allowed to be empty.")" "pkgname"
			ret=1
			continue
		fi
		if [[ ${i:0:1} = "-" ]]; then
			error "$(gettext "%s is not allowed to start with a hyphen.")" "pkgname"
			ret=1
		fi
		if [[ ${i:0:1} = "." ]]; then
			error "$(gettext "%s is not allowed to start with a dot.")" "pkgname"
			ret=1
		fi
		if [[ $i = *[^[:alnum:]+_.@-]* ]]; then
			error "$(gettext "%s contains invalid characters: '%s'")" \
					'pkgname' "${i//[[:alnum:]+_.@-]}"
			ret=1
		fi
	done

	return $ret
}

lint_pkgrel() {
	if [[ -z $pkgrel ]]; then
		error "$(gettext "%s is not allowed to be empty.")" "pkgrel"
		return 1
	fi

	if [[ $pkgrel != +([0-9])?(.+([0-9])) ]]; then
		error "$(gettext "%s must be a decimal, not %s.")" "pkgrel" "$pkgrel"
		return 1
	fi
}

lint_pkgver() {
	if (( PKGVERFUNC )); then
		# defer check to after getting version from pkgver function
		return 0
	fi

	check_pkgver
}

lint_epoch() {
	if [[ $epoch != *([[:digit:]]) ]]; then
		error "$(gettext "%s must be an integer, not %s.")" "epoch" "$epoch"
		return 1
	fi
}

lint_arch() {
	local a name list

	if [[ $arch == 'any' ]]; then
		return 0
	fi

	for a in "${arch[@]}"; do
		if [[ $a = *[![:alnum:]_]* ]]; then
			error "$(gettext "%s contains invalid characters: '%s'")" \
					'arch' "${a//[[:alnum:]_]}"
			ret=1
		fi
	done

	if (( ! IGNOREARCH )) && ! in_array "$CARCH" "${arch[@]}"; then
		error "$(gettext "%s is not available for the '%s' architecture.")" "$pkgbase" "$CARCH"
		plain "$(gettext "Note that many packages may need a line added to their %s")" "$BUILDSCRIPT"
		plain "$(gettext "such as %s.")" "arch=('$CARCH')"
		return 1
	fi

	for name in "${pkgname[@]}"; do
		pkgbuild_get_attribute "$name" 'arch' 1 list
		if [[ $list && $list != 'any' ]] && ! in_array $CARCH "${list[@]}"; then
			if (( ! IGNOREARCH )); then
				error "$(gettext "%s is not available for the '%s' architecture.")" "$name" "$CARCH"
				ret=1
			fi
		fi
	done
}

lint_provides() {
	local a list name provides_list ret=0

	provides_list=("${provides[@]}")
	for a in "${arch[@]}"; do
		array_build list "provides_$a"
		provides_list+=("${list[@]}")
	done

	for name in "${pkgname[@]}"; do
		if extract_function_var "package_$name" provides 1 list; then
			provides_list+=("${list[@]}")
		fi

		for a in "${arch[@]}"; do
			if extract_function_var "package_$name" "provides_$a" 1 list; then
				provides_list+=("${list[@]}")
			fi
		done
	done

	for provide in "${provides_list[@]}"; do
		if [[ $provide == *['<>']* ]]; then
			error "$(gettext "%s array cannot contain comparison (< or >) operators.")" "provides"
			ret=1
		fi
	done

	return $ret
}

lint_backup() {
	local list name backup_list ret=0

	backup_list=("${backup[@]}")
	for name in "${pkgname[@]}"; do
		if extract_function_var "package_$name" backup 1 list; then
			backup_list+=("${list[@]}")
		fi
	done

	for name in "${backup_list[@]}"; do
		if [[ ${name:0:1} = "/" ]]; then
			error "$(gettext "%s entry should not contain leading slash : %s")" "backup" "$name"
			ret=1
		fi
	done

	return $ret
}

lint_optdepends() {
	local a list name optdepends_list ret=0

	optdepends_list=("${optdepends[@]}")
	for a in "${arch[@]}"; do
		array_build list "optdepends_$a"
		optdepends_list+=("${list[@]}")
	done

	for name in "${pkgname[@]}"; do
		if extract_function_var "package_$name" optdepends 1 list; then
			optdepends_list+=("${list[@]}")
		fi

		for a in "${arch[@]}"; do
			if extract_function_var "package_$name" "optdepends_$a" 1 list; then
				optdepends_list+=("${list[@]}")
			fi
		done
	done

	for name in "${optdepends_list[@]}"; do
		local pkg=${name%%:[[:space:]]*}
		# the '-' character _must_ be first or last in the character range
		if [[ $pkg != +([-[:alnum:]><=.+_:]) ]]; then
			error "$(gettext "Invalid syntax for %s: '%s'")" "optdepend" "$name"
			ret=1
		fi
	done

	return $ret
}

check_files_exist() {
	local kind=$1 files=("${@:2}") file ret

	for file in "${files[@]}"; do
		if [[ $file && ! -f $file ]]; then
			error "$(gettext "%s file (%s) does not exist or is not a regular file.")" \
				"$kind" "$file"
			ret=1
		fi
	done

	return $ret
}

lint_install() {
	local list file name install_list ret=0

	install_list=("${install[@]}")
	for name in "${pkgname[@]}"; do
		extract_function_var "package_$name" install 0 file
		install_list+=("$file")
	done

	check_files_exist 'install' "${install_list[@]}"
}

lint_changelog() {
	local list name file changelog_list ret=0

	changelog_list=("${changelog[@]}")
	for name in "${pkgname[@]}"; do
		if extract_function_var "package_$name" changelog 0 file; then
			changelog_list+=("$file")
		fi
	done

	check_files_exist 'changelog' "${changelog_list[@]}"
}

lint_options() {
	local ret=0 list name kopt options_list

	options_list=("${options[@]}")
	for name in "${pkgname[@]}"; do
		if extract_function_var "package_$name" options 1 list; then
			options_list+=("${list[@]}")
		fi
	done

	for i in "${options_list[@]}"; do
		# check if option matches a known option or its inverse
		for kopt in "${packaging_options[@]}" "${other_options[@]}"; do
			if [[ $i = "$kopt" || $i = "!$kopt" ]]; then
				# continue to the next $i
				continue 2
			fi
		done

		error "$(gettext "%s array contains unknown option '%s'")" "options" "$i"
		ret=1
	done

	return $ret
}

lint_source() {
	local idx=("${!source[@]}")

	if (( ${#source[*]} > 0 && (idx[-1] + 1) != ${#source[*]} )); then
		error "$(gettext "Sparse arrays are not allowed for source")"
		return 1
	fi
}

lint_pkglist() {
	local i ret=0

	for i in "${PKGLIST[@]}"; do
		if ! in_array "$i" "${pkgname[@]}"; then
			error "$(gettext "Requested package %s is not provided in %s")" "$i" "$BUILDFILE"
			ret=1
		fi
	done

	return $ret
}

lint_packagefn() {
	local i ret=0

	if (( ${#pkgname[@]} == 1 )); then
		if have_function 'build' && ! { have_function 'package' || have_function "package_$pkgname"; }; then
			error "$(gettext "Missing %s function in %s")" "package()" "$BUILDFILE"
			ret=1
		fi
	else
		for i in "${pkgname[@]}"; do
			if ! have_function "package_$i"; then
				error "$(gettext "Missing %s function for split package '%s'")" "package_$i()" "$i"
				ret=1
			fi
		done
	fi

	return $ret
}

check_sanity() {
	# check for no-no's in the build script
	local ret=0
	local lintfn lint_functions

	lint_functions=(
		lint_pkgbase
		lint_pkgname
		lint_pkgver
		lint_pkgrel
		lint_epoch
		lint_arch
		lint_provides
		lint_backup
		lint_optdepends
		lint_changelog
		lint_install
		lint_options
		lint_packagefn
		lint_pkglist
		lint_source
	)

	for lintfn in "${lint_functions[@]}"; do
		"$lintfn" || ret=1
	done

	return $ret
}

validate_pkgver() {
	if [[ $1 = *[[:space:]:-]* ]]; then
		error "$(gettext "%s is not allowed to contain colons, hyphens or whitespace.")" "pkgver"
		return 1
	fi
}

check_pkgver() {
	if [[ -z ${pkgver} ]]; then
		error "$(gettext "%s is not allowed to be empty.")" "pkgver"
		return 1
	fi

	validate_pkgver "$pkgver"
}

get_vcsclient() {
	local proto=${1%%+*}

	local i
	for i in "${VCSCLIENTS[@]}"; do
		local handler="${i%%::*}"
		if [[ $proto = "$handler" ]]; then
			local client="${i##*::}"
			break
		fi
	done

	# if we didn't find an client, return an error
	if [[ -z $client ]]; then
		error "$(gettext "Unknown download protocol: %s")" "$proto"
		plain "$(gettext "Aborting...")"
		exit 1 # $E_CONFIG_ERROR
	fi

	printf "%s\n" "$client"
}

check_vcs_software() {
	local all_sources all_deps deps ret=0

	if (( SOURCEONLY == 1 )); then
		# we will not download VCS sources
		return $ret
	fi

	if [[ -z $PACMAN_PATH ]]; then
		warning "$(gettext "Cannot find the %s binary needed to check VCS source requirements.")" "$PACMAN"
		return $ret
	fi

	# we currently only use global depends/makedepends arrays for --syncdeps
	for attr in depends makedepends; do
		pkgbuild_get_attribute "$pkg" "$attr" 1 'deps'
		all_deps+=("${deps[@]}")

		pkgbuild_get_attribute "$pkg" "${attr}_$CARCH" 1 'deps'
		all_deps+=("${deps[@]}")
	done

	get_all_sources_for_arch 'all_sources'
	for netfile in ${all_sources[@]}; do
		local proto=$(get_protocol "$netfile")

		case $proto in
			bzr*|git*|hg*|svn*)
				if ! type -p ${proto%%+*} > /dev/null; then
					local client
					client=$(get_vcsclient "$proto") || exit $?
					# ensure specified program is installed
					local uninstalled
					uninstalled="$(set +E; check_deps $client)" || exit 1
					# if not installed, check presence in depends or makedepends
					if [[ -n "$uninstalled" ]] && (( ! NODEPS || ( VERIFYSOURCE && !DEP_BIN ) )); then
						if ! in_array "$client" ${all_deps[@]}; then
							error "$(gettext "Cannot find the %s package needed to handle %s sources.")" \
									"$client" "${proto%%+*}"
							ret=1
						fi
					fi
				fi
				;;
			*)
				# non VCS source
				;;
		esac
	done

	return $ret
}

check_software() {
	# check for needed software
	local ret=0

	# check for PACMAN if we need it
	if (( ! NODEPS || DEP_BIN || RMDEPS || INSTALL )); then
		if [[ -z $PACMAN_PATH ]]; then
			error "$(gettext "Cannot find the %s binary required for dependency operations.")" "$PACMAN"
			ret=1
		fi
	fi

	# check for sudo if we will need it during makepkg execution
	if (( DEP_BIN || RMDEPS || INSTALL )); then
		if ! type -p sudo >/dev/null; then
			warning "$(gettext "Cannot find the %s binary. Will use %s to acquire root privileges.")" "sudo" "su"
		fi
	fi

	# fakeroot - correct package file permissions
	if check_buildenv "fakeroot" "y" && (( EUID > 0 )); then
		if ! type -p fakeroot >/dev/null; then
			error "$(gettext "Cannot find the %s binary.")" "fakeroot"
			ret=1
		fi
	fi

	# gpg - package signing
	if [[ $SIGNPKG == 'y' ]] || { [[ -z $SIGNPKG ]] && check_buildenv "sign" "y"; }; then
		if ! type -p gpg >/dev/null; then
			error "$(gettext "Cannot find the %s binary required for signing packages.")" "gpg"
			ret=1
		fi
	fi

	# gpg - source verification
	if (( ! SKIPPGPCHECK )) && source_has_signatures; then
		if ! type -p gpg >/dev/null; then
			error "$(gettext "Cannot find the %s binary required for verifying source files.")" "gpg"
			ret=1
		fi
	fi

	# openssl - checksum operations
	if (( ! SKIPCHECKSUMS )); then
		if ! type -p openssl >/dev/null; then
			error "$(gettext "Cannot find the %s binary required for validating sourcefile checksums.")" "openssl"
			ret=1
		fi
	fi

	# upx - binary compression
	if check_option "upx" "y"; then
		if ! type -p upx >/dev/null; then
			error "$(gettext "Cannot find the %s binary required for compressing binaries.")" "upx"
			ret=1
		fi
	fi

	# distcc - compilation with distcc
	if check_buildenv "distcc" "y" && ! check_option "distcc" "n"; then
		if ! type -p distcc >/dev/null; then
			error "$(gettext "Cannot find the %s binary required for distributed compilation.")" "distcc"
			ret=1
		fi
	fi

	# ccache - compilation with ccache
	if check_buildenv "ccache" "y" && ! check_option "ccache" "n"; then
		if ! type -p ccache >/dev/null; then
			error "$(gettext "Cannot find the %s binary required for compiler cache usage.")" "ccache"
			ret=1
		fi
	fi

	# strip - strip symbols from binaries/libraries
	if check_option "strip" "y"; then
		if ! type -p strip >/dev/null; then
			error "$(gettext "Cannot find the %s binary required for object file stripping.")" "strip"
			ret=1
		fi
	fi

	# gzip - compressig man and info pages
	if check_option "zipman" "y"; then
		if ! type -p gzip >/dev/null; then
			error "$(gettext "Cannot find the %s binary required for compressing man and info pages.")" "gzip"
			ret=1
		fi
	fi

	# tools to download vcs sources
	if ! check_vcs_software; then
		ret=1
	fi

	return $ret
}

check_build_status() {
	if (( ! SPLITPKG )); then
		fullver=$(get_full_version)
		pkgarch=$(get_pkg_arch)
		if [[ -f $PKGDEST/${pkgname}-${fullver}-${pkgarch}${PKGEXT} ]] \
				 && ! (( FORCE || SOURCEONLY || NOBUILD || NOARCHIVE)); then
			if (( INSTALL )); then
				warning "$(gettext "A package has already been built, installing existing package...")"
				install_package
				exit 0
			else
				error "$(gettext "A package has already been built. (use %s to overwrite)")" "-f"
				exit 1
			fi
		fi
	else
		allpkgbuilt=1
		somepkgbuilt=0
		for pkg in ${pkgname[@]}; do
			fullver=$(get_full_version)
			pkgarch=$(get_pkg_arch $pkg)
			if [[ -f $PKGDEST/${pkg}-${fullver}-${pkgarch}${PKGEXT} ]]; then
				somepkgbuilt=1
			else
				allpkgbuilt=0
			fi
		done
		if ! (( FORCE || SOURCEONLY || NOBUILD || NOARCHIVE)); then
			if (( allpkgbuilt )); then
				if (( INSTALL )); then
					warning "$(gettext "The package group has already been built, installing existing packages...")"
					install_package
					exit 0
				else
					error "$(gettext "The package group has already been built. (use %s to overwrite)")" "-f"
					exit 1
				fi
			fi
			if (( somepkgbuilt && ! PKGVERFUNC )); then
				error "$(gettext "Part of the package group has already been built. (use %s to overwrite)")" "-f"
				exit 1
			fi
		fi
		unset allpkgbuilt somepkgbuilt
	fi
}

backup_package_variables() {
	local var
	for var in ${splitpkg_overrides[@]}; do
		local indirect="${var}_backup"
		eval "${indirect}=(\"\${$var[@]}\")"
	done
}

restore_package_variables() {
	local var
	for var in ${splitpkg_overrides[@]}; do
		local indirect="${var}_backup"
		if [[ -n ${!indirect} ]]; then
			eval "${var}=(\"\${$indirect[@]}\")"
		else
			unset ${var}
		fi
	done
}

run_split_packaging() {
	local pkgname_backup=${pkgname[@]}
	for pkgname in ${pkgname_backup[@]}; do
		pkgdir="$pkgdirbase/$pkgname"
		mkdir "$pkgdir"
		backup_package_variables
		run_package $pkgname
		tidy_install
		create_package
		create_debug_package
		restore_package_variables
	done
	pkgname=${pkgname_backup[@]}
}

# Canonicalize a directory path if it exists
canonicalize_path() {
	local path="$1";

	if [[ -d $path ]]; then
		(
			cd_safe "$path"
			pwd -P
		)
	else
		printf "%s\n" "$path"
	fi
}

dir_is_empty() {
	(
		shopt -s dotglob nullglob
		files=("$1"/*)
		(( ${#files} == 0 ))
	)
}

# getopt-like parser
parseopts() {
	local opt= optarg= i= shortopts=$1
	local -a longopts=() unused_argv=()

	shift
	while [[ $1 && $1 != '--' ]]; do
		longopts+=("$1")
		shift
	done
	shift

	longoptmatch() {
		local o longmatch=()
		for o in "${longopts[@]}"; do
			if [[ ${o%:} = "$1" ]]; then
				longmatch=("$o")
				break
			fi
			[[ ${o%:} = "$1"* ]] && longmatch+=("$o")
		done

		case ${#longmatch[*]} in
			1)
				# success, override with opt and return arg req (0 == none, 1 == required)
				opt=${longmatch%:}
				if [[ $longmatch = *: ]]; then
					return 1
				else
					return 0
				fi ;;
			0)
				# fail, no match found
				return 255 ;;
			*)
				# fail, ambiguous match
				printf "makepkg: $(gettext "option '%s' is ambiguous; possibilities:")" "--$1"
				printf " '%s'" "${longmatch[@]%:}"
				printf '\n'
				return 254 ;;
		esac >&2
	}

	while (( $# )); do
		case $1 in
			--) # explicit end of options
				shift
				break
				;;
			-[!-]*) # short option
				for (( i = 1; i < ${#1}; i++ )); do
					opt=${1:i:1}

					# option doesn't exist
					if [[ $shortopts != *$opt* ]]; then
						printf "makepkg: $(gettext "invalid option") -- '%s'\n" "$opt" >&2
						OPTRET=(--)
						return 1
					fi

					OPTRET+=("-$opt")
					# option requires optarg
					if [[ $shortopts = *$opt:* ]]; then
						# if we're not at the end of the option chunk, the rest is the optarg
						if (( i < ${#1} - 1 )); then
							OPTRET+=("${1:i+1}")
							break
						# if we're at the end, grab the the next positional, if it exists
						elif (( i == ${#1} - 1 )) && [[ $2 ]]; then
							OPTRET+=("$2")
							shift
							break
						# parse failure
						else
							printf "makepkg: $(gettext "option requires an argument") -- '%s'\n" "$opt" >&2
							OPTRET=(--)
							return 1
						fi
					fi
				done
				;;
			--?*=*|--?*) # long option
				IFS='=' read -r opt optarg <<< "${1#--}"
				longoptmatch "$opt"
				case $? in
					0)
						# parse failure
						if [[ $optarg ]]; then
							printf "makepkg: $(gettext "option '%s' does not allow an argument")\n" "--$opt" >&2
							OPTRET=(--)
							return 1
						# --longopt
						else
							OPTRET+=("--$opt")
						fi
						;;
					1)
						# --longopt=optarg
						if [[ $optarg ]]; then
							OPTRET+=("--$opt" "$optarg")
						# --longopt optarg
						elif [[ $2 ]]; then
							OPTRET+=("--$opt" "$2" )
							shift
						# parse failure
						else
							printf "makepkg: $(gettext "option '%s' requires an argument")\n" "--$opt" >&2
							OPTRET=(--)
							return 1
						fi
						;;
					254)
						# ambiguous option -- error was reported for us by longoptmatch()
						OPTRET=(--)
						return 1
						;;
					255)
						# parse failure
						printf "makepkg: $(gettext "invalid option") '--%s'\n" "$opt" >&2
						OPTRET=(--)
						return 1
						;;
				esac
				;;
			*) # non-option arg encountered, add it as a parameter
				unused_argv+=("$1")
				;;
		esac
		shift
	done

	# add end-of-opt terminator and any leftover positional parameters
	OPTRET+=('--' "${unused_argv[@]}" "$@")
	unset longoptmatch

	return 0
}


usage() {
	printf "makepkg (pacman) %s\n" "$makepkg_version"
	echo
	printf -- "$(gettext "Make packages compatible for use with pacman")\n"
	echo
	printf -- "$(gettext "Usage: %s [options]")\n" "$0"
	echo
	printf -- "$(gettext "Options:")\n"
	printf -- "$(gettext "  -A, --ignorearch Ignore incomplete %s field in %s")\n" "arch" "$BUILDSCRIPT"
	printf -- "$(gettext "  -c, --clean      Clean up work files after build")\n"
	printf -- "$(gettext "  -C, --cleanbuild Remove %s dir before building the package")\n" "\$srcdir/"
	printf -- "$(gettext "  -d, --nodeps     Skip all dependency checks")\n"
	printf -- "$(gettext "  -e, --noextract  Do not extract source files (use existing %s dir)")\n" "\$srcdir/"
	printf -- "$(gettext "  -f, --force      Overwrite existing package")\n"
	printf -- "$(gettext "  -g, --geninteg   Generate integrity checks for source files")\n"
	printf -- "$(gettext "  -h, --help       Show this help message and exit")\n"
	printf -- "$(gettext "  -i, --install    Install package after successful build")\n"
	printf -- "$(gettext "  -L, --log        Log package build process")\n"
	printf -- "$(gettext "  -m, --nocolor    Disable colorized output messages")\n"
	printf -- "$(gettext "  -o, --nobuild    Download and extract files only")\n"
	printf -- "$(gettext "  -p <file>        Use an alternate build script (instead of '%s')")\n" "$BUILDSCRIPT"
	printf -- "$(gettext "  -r, --rmdeps     Remove installed dependencies after a successful build")\n"
	printf -- "$(gettext "  -R, --repackage  Repackage contents of the package without rebuilding")\n"
	printf -- "$(gettext "  -s, --syncdeps   Install missing dependencies with %s")\n" "pacman"
	printf -- "$(gettext "  -S, --source     Generate a source-only tarball without downloaded sources")\n"
	printf -- "$(gettext "  -V, --version    Show version information and exit")\n"
	printf -- "$(gettext "  --allsource      Generate a source-only tarball including downloaded sources")\n"
	printf -- "$(gettext "  --check          Run the %s function in the %s")\n" "check()" "$BUILDSCRIPT"
	printf -- "$(gettext "  --config <file>  Use an alternate config file (instead of '%s')")\n" "$confdir/makepkg.conf"
	printf -- "$(gettext "  --holdver        Do not update VCS sources")\n"
	printf -- "$(gettext "  --key <key>      Specify a key to use for %s signing instead of the default")\n" "gpg"
	printf -- "$(gettext "  --noarchive      Do not create package archive")\n"
	printf -- "$(gettext "  --nocheck        Do not run the %s function in the %s")\n" "check()" "$BUILDSCRIPT"
	printf -- "$(gettext "  --noprepare      Do not run the %s function in the %s")\n" "prepare()" "$BUILDSCRIPT"
	printf -- "$(gettext "  --nosign         Do not create a signature for the package")\n"
	printf -- "$(gettext "  --pkg <list>     Only build listed packages from a split package")\n"
	printf -- "$(gettext "  --sign           Sign the resulting package with %s")\n" "gpg"
	printf -- "$(gettext "  --skipchecksums  Do not verify checksums of the source files")\n"
	printf -- "$(gettext "  --skipinteg      Do not perform any verification checks on source files")\n"
	printf -- "$(gettext "  --skippgpcheck   Do not verify source files with PGP signatures")\n"
	printf -- "$(gettext "  --verifysource   Download source files (if needed) and perform integrity checks")\n"
	echo
	printf -- "$(gettext "These options can be passed to %s:")\n" "pacman"
	echo
	printf -- "$(gettext "  --asdeps         Install packages as non-explicitly installed")\n"
	printf -- "$(gettext "  --needed         Do not reinstall the targets that are already up to date")\n"
	printf -- "$(gettext "  --noconfirm      Do not ask for confirmation when resolving dependencies")\n"
	printf -- "$(gettext "  --noprogressbar  Do not show a progress bar when downloading files")\n"
	echo
	printf -- "$(gettext "If %s is not specified, %s will look for '%s'")\n" "-p" "makepkg" "$BUILDSCRIPT"
	echo
}

version() {
	printf "makepkg (pacman) %s\n" "$makepkg_version"
	printf -- "$(gettext "\
Copyright (c) 2006-2014 Pacman Development Team <pacman-dev@archlinux.org>.\n\
Copyright (C) 2002-2006 Judd Vinet <jvinet@zeroflux.org>.\n\n\
This is free software; see the source for copying conditions.\n\
There is NO WARRANTY, to the extent permitted by law.\n")"
}

# PROGRAM START

# ensure we have a sane umask set
umask 0022

# determine whether we have gettext; make it a no-op if we do not
if ! type -p gettext >/dev/null; then
	gettext() {
		printf "%s\n" "$@"
	}
fi

ARGLIST=("$@")

# Parse Command Line Options.
OPT_SHORT="AcCdefFghiLmop:rRsSV"
OPT_LONG=('allsource' 'check' 'clean' 'cleanbuild' 'config:' 'force' 'geninteg'
          'help' 'holdver' 'ignorearch' 'install' 'key:' 'log' 'noarchive' 'nobuild'
          'nocolor' 'nocheck' 'nodeps' 'noextract' 'noprepare' 'nosign' 'pkg:' 'repackage'
          'rmdeps' 'sign' 'skipchecksums' 'skipinteg' 'skippgpcheck' 'source' 'syncdeps'
          'verifysource' 'version')

# Pacman Options
OPT_LONG+=('asdeps' 'noconfirm' 'needed' 'noprogressbar')

if ! parseopts "$OPT_SHORT" "${OPT_LONG[@]}" -- "$@"; then
	exit 1 # E_INVALID_OPTION;
fi
set -- "${OPTRET[@]}"
unset OPT_SHORT OPT_LONG OPTRET

while true; do
	case "$1" in
		# Pacman Options
		--asdeps)         ASDEPS=1;;
		--needed)         NEEDED=1;;
		--noconfirm)      PACMAN_OPTS+=" --noconfirm" ;;
		--noprogressbar)  PACMAN_OPTS+=" --noprogressbar" ;;

		# Makepkg Options
		--allsource)      SOURCEONLY=2 ;;
		-A|--ignorearch)  IGNOREARCH=1 ;;
		-c|--clean)       CLEANUP=1 ;;
		-C|--cleanbuild)  CLEANBUILD=1 ;;
		--check)          RUN_CHECK='y' ;;
		--config)         shift; MAKEPKG_CONF=$1 ;;
		-d|--nodeps)      NODEPS=1 ;;
		-e|--noextract)   NOEXTRACT=1 ;;
		-f|--force)       FORCE=1 ;;
		-F)               INFAKEROOT=1 ;;
		-g|--geninteg)    GENINTEG=1 ;;
		--holdver)        HOLDVER=1 ;;
		-i|--install)     INSTALL=1 ;;
		--key)            shift; GPGKEY=$1 ;;
		-L|--log)         LOGGING=1 ;;
		-m|--nocolor)     USE_COLOR='n'; PACMAN_OPTS+=" --color never" ;;
		--noarchive)      NOARCHIVE=1 ;;
		--nocheck)        RUN_CHECK='n' ;;
		--noprepare)      RUN_PREPARE='n' ;;
		--nosign)         SIGNPKG='n' ;;
		-o|--nobuild)     NOBUILD=1 ;;
		-p)               shift; BUILDFILE=$1 ;;
		--pkg)            shift; IFS=, read -ra p <<<"$1"; PKGLIST+=("${p[@]}"); unset p ;;
		-r|--rmdeps)      RMDEPS=1 ;;
		-R|--repackage)   REPKG=1 ;;
		--sign)           SIGNPKG='y' ;;
		--skipchecksums)  SKIPCHECKSUMS=1 ;;
		--skipinteg)      SKIPCHECKSUMS=1; SKIPPGPCHECK=1 ;;
		--skippgpcheck)   SKIPPGPCHECK=1;;
		-s|--syncdeps)    DEP_BIN=1 ;;
		-S|--source)      SOURCEONLY=1 ;;
		--verifysource)   VERIFYSOURCE=1 ;;

		-h|--help)        usage; exit 0 ;; # E_OK
		-V|--version)     version; exit 0 ;; # E_OK

		--)               OPT_IND=0; shift; break 2;;
	esac
	shift
done

# attempt to consume any extra argv as environment variables. this supports
# overriding (e.g. CC=clang) as well as overriding (e.g. CFLAGS+=' -g').
extra_environment=()
while [[ $1 ]]; do
	if [[ $1 = [_[:alpha:]]*([[:alnum:]_])?(+)=* ]]; then
		extra_environment+=("$1")
	fi
	shift
done

# setup signal traps
trap 'clean_up' 0
for signal in TERM HUP QUIT; do
	trap "trap_exit $signal \"$(gettext "%s signal caught. Exiting...")\" \"$signal\"" "$signal"
done
trap 'trap_exit INT "$(gettext "Aborted by user! Exiting...")"' INT
trap 'trap_exit USR1 "$(gettext "An unknown error has occurred. Exiting...")"' ERR

# preserve environment variables and canonicalize path
[[ -n ${PKGDEST} ]] && _PKGDEST=$(canonicalize_path ${PKGDEST})
[[ -n ${SRCDEST} ]] && _SRCDEST=$(canonicalize_path ${SRCDEST})
[[ -n ${SRCPKGDEST} ]] && _SRCPKGDEST=$(canonicalize_path ${SRCPKGDEST})
[[ -n ${LOGDEST} ]] && _LOGDEST=$(canonicalize_path ${LOGDEST})
[[ -n ${BUILDDIR} ]] && _BUILDDIR=$(canonicalize_path ${BUILDDIR})
[[ -n ${PKGEXT} ]] && _PKGEXT=${PKGEXT}
[[ -n ${SRCEXT} ]] && _SRCEXT=${SRCEXT}
[[ -n ${GPGKEY} ]] && _GPGKEY=${GPGKEY}
[[ -n ${PACKAGER} ]] && _PACKAGER=${PACKAGER}
[[ -n ${CARCH} ]] && _CARCH=${CARCH}

# default config is makepkg.conf
MAKEPKG_CONF=${MAKEPKG_CONF:-$confdir/makepkg.conf}

# Source the config file; fail if it is not found
if [[ -r $MAKEPKG_CONF ]]; then
	source_safe "$MAKEPKG_CONF"
else
	error "$(gettext "%s not found.")" "$MAKEPKG_CONF"
	plain "$(gettext "Aborting...")"
	exit 1 # $E_CONFIG_ERROR
fi

# Source user-specific makepkg.conf overrides, but only if no override config
# file was specified
XDG_PACMAN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pacman"
if [[ "$MAKEPKG_CONF" = "$confdir/makepkg.conf" ]]; then
	if [[ -r "$XDG_PACMAN_DIR/makepkg.conf" ]]; then
		source_safe "$XDG_PACMAN_DIR/makepkg.conf"
	elif [[ -r "$HOME/.makepkg.conf" ]]; then
		source_safe "$HOME/.makepkg.conf"
	fi
fi

# set pacman command if not already defined
PACMAN=${PACMAN:-pacman}
# save full path to command as PATH may change when sourcing /etc/profile
PACMAN_PATH=$(type -P $PACMAN)

# check if messages are to be printed using color
unset ALL_OFF BOLD BLUE GREEN RED YELLOW
if [[ -t 2 && $USE_COLOR != "n" ]] && check_buildenv "color" "y"; then
	# prefer terminal safe colored and bold text when tput is supported
	if tput setaf 0 &>/dev/null; then
		ALL_OFF="$(tput sgr0)"
		BOLD="$(tput bold)"
		BLUE="${BOLD}$(tput setaf 4)"
		GREEN="${BOLD}$(tput setaf 2)"
		RED="${BOLD}$(tput setaf 1)"
		YELLOW="${BOLD}$(tput setaf 3)"
	else
		ALL_OFF="\e[0m"
		BOLD="\e[1m"
		BLUE="${BOLD}\e[34m"
		GREEN="${BOLD}\e[32m"
		RED="${BOLD}\e[31m"
		YELLOW="${BOLD}\e[33m"
	fi
fi
readonly ALL_OFF BOLD BLUE GREEN RED YELLOW

# override settings with an environment variable for batch processing
BUILDDIR=${_BUILDDIR:-$BUILDDIR}
BUILDDIR=${BUILDDIR:-$startdir} #default to $startdir if undefined
if [[ ! -d $BUILDDIR ]]; then
	if ! mkdir -p "$BUILDDIR"; then
		error "$(gettext "You do not have write permission to create packages in %s.")" "$BUILDDIR"
		plain "$(gettext "Aborting...")"
		exit 1
	fi
	chmod a-s "$BUILDDIR"
fi
if [[ ! -w $BUILDDIR ]]; then
	error "$(gettext "You do not have write permission to create packages in %s.")" "$BUILDDIR"
	plain "$(gettext "Aborting...")"
	exit 1
fi

# override settings from extra variables on commandline, if any
if (( ${#extra_environment[*]} )); then
	export "${extra_environment[@]}"
fi

PKGDEST=${_PKGDEST:-$PKGDEST}
PKGDEST=${PKGDEST:-$startdir} #default to $startdir if undefined
if (( ! (NOBUILD || GENINTEG) )) && [[ ! -w $PKGDEST ]]; then
	error "$(gettext "You do not have write permission to store packages in %s.")" "$PKGDEST"
	plain "$(gettext "Aborting...")"
	exit 1
fi

SRCDEST=${_SRCDEST:-$SRCDEST}
SRCDEST=${SRCDEST:-$startdir} #default to $startdir if undefined
if [[ ! -w $SRCDEST ]] ; then
	error "$(gettext "You do not have write permission to store downloads in %s.")" "$SRCDEST"
	plain "$(gettext "Aborting...")"
	exit 1
fi

SRCPKGDEST=${_SRCPKGDEST:-$SRCPKGDEST}
SRCPKGDEST=${SRCPKGDEST:-$startdir} #default to $startdir if undefined
if (( SOURCEONLY )); then
	if [[ ! -w $SRCPKGDEST ]]; then
		error "$(gettext "You do not have write permission to store source tarballs in %s.")" "$SRCPKGDEST"
		plain "$(gettext "Aborting...")"
		exit 1
	fi

	# If we're only making a source tarball, then we need to ignore architecture-
	# dependent behavior.
	IGNOREARCH=1
fi

LOGDEST=${_LOGDEST:-$LOGDEST}
LOGDEST=${LOGDEST:-$startdir} #default to $startdir if undefined
if (( LOGGING )) && [[ ! -w $LOGDEST ]]; then
	error "$(gettext "You do not have write permission to store logs in %s.")" "$LOGDEST"
	plain "$(gettext "Aborting...")"
	exit 1
fi

PKGEXT=${_PKGEXT:-$PKGEXT}
SRCEXT=${_SRCEXT:-$SRCEXT}
GPGKEY=${_GPGKEY:-$GPGKEY}
PACKAGER=${_PACKAGER:-$PACKAGER}
CARCH=${_CARCH:-$CARCH}

if (( ! INFAKEROOT )); then
	if (( EUID == 0 )); then
		error "$(gettext "Running %s as root is not allowed as it can cause permanent,\n\
catastrophic damage to your system.")" "makepkg"
		exit 1 # $E_USER_ABORT
	fi
else
	if [[ -z $FAKEROOTKEY ]]; then
		error "$(gettext "Do not use the %s option. This option is only for use by %s.")" "'-F'" "makepkg"
		exit 1 # TODO: error code
	fi
fi

unset pkgname pkgbase pkgver pkgrel epoch pkgdesc url license groups provides
unset md5sums replaces depends conflicts backup source install changelog build
unset makedepends optdepends options noextract validpgpkeys

BUILDFILE=${BUILDFILE:-$BUILDSCRIPT}
if [[ ! -f $BUILDFILE ]]; then
	error "$(gettext "%s does not exist.")" "$BUILDFILE"
	exit 1
else
	if [[ $(<"$BUILDFILE") = *$'\r'* ]]; then
		error "$(gettext "%s contains %s characters and cannot be sourced.")" "$BUILDFILE" "CRLF"
		exit 1
	fi

	if [[ ! $BUILDFILE -ef $PWD/${BUILDFILE##*/} ]]; then
		error "$(gettext "%s must be in the current working directory.")" "$BUILDFILE"
		exit 1
	fi

	if [[ ${BUILDFILE:0:1} != "/" ]]; then
		BUILDFILE="$startdir/$BUILDFILE"
	fi
	source_buildfile "$BUILDFILE"
fi

# set defaults if they weren't specified in buildfile
pkgbase=${pkgbase:-${pkgname[0]}}
basever=$(get_full_version)

if [[ $BUILDDIR = "$startdir" ]]; then
	srcdir="$BUILDDIR/src"
	pkgdirbase="$BUILDDIR/pkg"
else
	srcdir="$BUILDDIR/$pkgbase/src"
	pkgdirbase="$BUILDDIR/$pkgbase/pkg"

fi

# set pkgdir to something "sensible" for (not recommended) use during build()
pkgdir="$pkgdirbase/$pkgbase"

if (( GENINTEG )); then
	mkdir -p "$srcdir"
	chmod a-s "$srcdir"
	cd_safe "$srcdir"
	download_sources novcs allarch
	generate_checksums
	exit 0 # $E_OK
fi

if have_function pkgver; then
	PKGVERFUNC=1
fi

# check the PKGBUILD for some basic requirements
check_sanity || exit 1

# check we have the software required to process the PKGBUILD
check_software || exit 1

if (( ${#pkgname[@]} > 1 )); then
	SPLITPKG=1
fi

# test for available PKGBUILD functions
if have_function prepare; then
	# "Hide" prepare() function if not going to be run
	if [[ $RUN_PREPARE != "n" ]]; then
		PREPAREFUNC=1
	fi
fi
if have_function build; then
	BUILDFUNC=1
fi
if have_function check; then
	# "Hide" check() function if not going to be run
	if [[ $RUN_CHECK = 'y' ]] || { ! check_buildenv "check" "n" && [[ $RUN_CHECK != "n" ]]; }; then
		CHECKFUNC=1
	fi
fi
if have_function package; then
	PKGFUNC=1
elif [[ $SPLITPKG -eq 0 ]] && have_function package_${pkgname}; then
	SPLITPKG=1
fi

if [[ -n "${PKGLIST[@]}" ]]; then
	unset pkgname
	pkgname=("${PKGLIST[@]}")
fi

# check if gpg signature is to be created and if signing key is valid
if { [[ -z $SIGNPKG ]] && check_buildenv "sign" "y"; } || [[ $SIGNPKG == 'y' ]]; then
	SIGNPKG='y'
	if ! gpg --list-key ${GPGKEY} &>/dev/null; then
		if [[ ! -z $GPGKEY ]]; then
			error "$(gettext "The key %s does not exist in your keyring.")" "${GPGKEY}"
		else
			error "$(gettext "There is no key in your keyring.")"
		fi
		exit 1
	fi
fi

if (( ! PKGVERFUNC )); then
	check_build_status
fi

# Run the bare minimum in fakeroot
if (( INFAKEROOT )); then
	if (( SOURCEONLY )); then
		create_srcpackage
		msg "$(gettext "Leaving %s environment.")" "fakeroot"
		exit 0 # $E_OK
	fi

	chmod 755 "$pkgdirbase"
	if (( ! SPLITPKG )); then
		pkgdir="$pkgdirbase/$pkgname"
		mkdir "$pkgdir"
		if (( PKGFUNC )); then
			run_package
		fi
		tidy_install
		create_package
		create_debug_package
	else
		run_split_packaging
	fi

	msg "$(gettext "Leaving %s environment.")" "fakeroot"
	exit 0 # $E_OK
fi

msg "$(gettext "Making package: %s")" "$pkgbase $basever ($(date))"

# if we are creating a source-only package, go no further
if (( SOURCEONLY )); then
	if [[ -f $SRCPKGDEST/${pkgbase}-${basever}${SRCEXT} ]] \
			&& (( ! FORCE )); then
		error "$(gettext "A source package has already been built. (use %s to overwrite)")" "-f"
		exit 1
	fi

	# Get back to our src directory so we can begin with sources.
	mkdir -p "$srcdir"
	chmod a-s "$srcdir"
	cd_safe "$srcdir"
	if (( SOURCEONLY == 2 )); then
		download_sources allarch
	elif ( (( ! SKIPCHECKSUMS )) || \
			( (( ! SKIPPGPCHECK )) && source_has_signatures ) ); then
		download_sources allarch novcs
	fi
	check_source_integrity all
	cd_safe "$startdir"

	enter_fakeroot

	msg "$(gettext "Source package created: %s")" "$pkgbase ($(date))"
	exit 0
fi

if (( NODEPS || ( VERIFYSOURCE && !DEP_BIN ) )); then
	# no warning message needed for nobuild
	if (( NODEPS )); then
		warning "$(gettext "Skipping dependency checks.")"
	fi
else
	if (( RMDEPS && ! INSTALL )); then
		original_pkglist=($(run_pacman -Qq))    # required by remove_dep
	fi
	deperr=0

	msg "$(gettext "Checking runtime dependencies...")"
	resolve_deps ${depends[@]} || deperr=1

	if (( RMDEPS && INSTALL )); then
		original_pkglist=($(run_pacman -Qq))    # required by remove_dep
	fi

	msg "$(gettext "Checking buildtime dependencies...")"
	if (( CHECKFUNC )); then
		resolve_deps "${makedepends[@]}" "${checkdepends[@]}" || deperr=1
	else
		resolve_deps "${makedepends[@]}" || deperr=1
	fi

	if (( RMDEPS )); then
		current_pkglist=($(run_pacman -Qq))    # required by remove_deps
	fi

	if (( deperr )); then
		error "$(gettext "Could not resolve all dependencies.")"
		exit 1
	fi
fi

# get back to our src directory so we can begin with sources
mkdir -p "$srcdir"
chmod a-s "$srcdir"
cd_safe "$srcdir"

if (( NOEXTRACT && ! VERIFYSOURCE )); then
	warning "$(gettext "Using existing %s tree")" "\$srcdir/"
elif (( !REPKG )); then
	download_sources
	check_source_integrity
	(( VERIFYSOURCE )) && exit 0 # $E_OK

	if (( CLEANBUILD )); then
		msg "$(gettext "Removing existing %s directory...")" "\$srcdir/"
		rm -rf "$srcdir"/*
	fi

	extract_sources
	if (( PKGVERFUNC )); then
		update_pkgver
		basever=$(get_full_version)
		check_build_status
	fi
	if (( PREPAREFUNC )); then
		run_prepare
	fi
fi

if (( NOBUILD )); then
	msg "$(gettext "Sources are ready.")"
	exit 0 #E_OK
else
	# clean existing pkg directory
	if [[ -d $pkgdirbase ]]; then
		msg "$(gettext "Removing existing %s directory...")" "\$pkgdir/"
		rm -rf "$pkgdirbase"
	fi
	mkdir -p "$pkgdirbase"
	chmod a-srwx "$pkgdirbase"
	cd_safe "$startdir"

	if (( ! REPKG )); then
		(( BUILDFUNC )) && run_build
		(( CHECKFUNC )) && run_check
		cd_safe "$startdir"
	fi

	enter_fakeroot
fi

# if inhibiting archive creation, go no further
if (( NOARCHIVE )); then
	msg "$(gettext "Package directory is ready.")"
	exit 0
fi

msg "$(gettext "Finished making: %s")" "$pkgbase $basever ($(date))"

install_package

exit 0 #E_OK

# vim: set noet:
