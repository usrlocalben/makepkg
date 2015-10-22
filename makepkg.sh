#!/bin/bash
#
# minimal adaptation of archlinux's 'makepkg' for centos/rhel via fpm
# original: 
# https://projects.archlinux.org/pacman.git/tree/scripts/makepkg.sh.in
#

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

known_hash_algos=('md5' 'sha1' 'sha224' 'sha256' 'sha384' 'sha512')

# Options
BUILDFUNC=0
CLEANBUILD=0
CLEANUP=0
GENINTEG=0
INSTALL=0
LOGGING=0
NOBUILD=0
NODEPS=0
NOEXTRACT=0
PKGFUNC=0
PREPAREFUNC=0
REPKG=0
SKIPCHECKSUMS=0
VERIFYSOURCE=0

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
			case "$ext" in
				zip) cmd="unzip" ;;
				*) cmd="tar" ;;
			esac ;;
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
			if tar -taf "$file" -q '*' &>/dev/null; then
				cmd="tar"
			else
				return 0
			fi ;;
	esac

	local ret=0
	msg2 "$(gettext "Extracting %s with %s")" "$file" "$cmd"
	if [[ $cmd = "tar" ]]; then
		$cmd -xaf "$file" || ret=$?
	elif [[ $cmd = "unzip" ]]; then
		$cmd -qo "$file" || ret=$?
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
		if ! git branch -f --no-track makepkg $ref; then
			error "$(gettext "Failure while creating working copy of %s %s repo")" "${repo}" "git"
			plain "$(gettext "Aborting...")"
			exit 1
		fi
		if ! git checkout makepkg; then
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
	if [[ "$RPM_DIST" = "" ]]; then
		local trailer=''
	else
		local trailer=".$RPM_DIST"
	fi
	if (( epoch > 0 )); then
		printf "%s\n" "$epoch:$pkgver-$pkgrel$trailer"
	else
		printf "%s\n" "$pkgver-$pkgrel$trailer"
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

check_source_integrity() {
	if (( SKIPCHECKSUMS )); then
		warning "$(gettext "Skipping verification of source file checksums.")"
	else
		check_checksums "$@"
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
		error "Failed to change to directory %s" "$1"
		plain "Aborting..."
		exit 1
	fi
}

source_safe() {
	shopt -u extglob
	if ! source "$@"; then
		error "Failed to source %s" "$1"
		exit 1
	fi
	shopt -s extglob
}

source_buildfile() {
	source_safe "$@"
}

install_package() {
	(( ! INSTALL )) && return

	msg "Installing package %s with %s..." "$pkgname" "yum -y install"
	root_install
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

	msg "Starting %s()..." "$pkgfunc"
	cd_safe "$srcdir"

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
	printf -- "$(gettext "Make packages compatible for use with rpm")\n"
	echo
	printf -- "$(gettext "Usage: %s [options]")\n" "$0"
	echo
	printf -- "$(gettext "Options:")\n"
	printf -- "$(gettext "  -c, --clean      Clean up work files after build")\n"
	printf -- "$(gettext "  -C, --cleanbuild Remove %s dir before building the package")\n" "\$srcdir/"
	printf -- "$(gettext "  -d, --nodeps     Skip all dependency checks")\n"
	printf -- "$(gettext "  -e, --noextract  Do not extract source files (use existing %s dir)")\n" "\$srcdir/"
	printf -- "$(gettext "  -g, --geninteg   Generate integrity checks for source files")\n"
	printf -- "$(gettext "  -h, --help       Show this help message and exit")\n"
	printf -- "$(gettext "  -i, --install    Install package after successful build")\n"
	printf -- "$(gettext "  -L, --log        Log package build process")\n"
	printf -- "$(gettext "  -m, --nocolor    Disable colorized output messages")\n"
	printf -- "$(gettext "  -o, --nobuild    Download and extract files only")\n"
	printf -- "$(gettext "  -p <file>        Use an alternate build script (instead of '%s')")\n" "$BUILDSCRIPT"
	printf -- "$(gettext "  -R, --repackage  Repackage contents of the package without rebuilding")\n"
	printf -- "$(gettext "  -V, --version    Show version information and exit")\n"
	printf -- "$(gettext "  --config <file>  Use an alternate config file (instead of '%s')")\n" "$confdir/makepkg.conf"
	printf -- "$(gettext "  --noprepare      Do not run the %s function in the %s")\n" "prepare()" "$BUILDSCRIPT"
	printf -- "$(gettext "  --skipchecksums  Do not verify checksums of the source files")\n"
	printf -- "$(gettext "  --skipinteg      Do not perform any verification checks on source files")\n"
	printf -- "$(gettext "  --verifysource   Download source files (if needed) and perform integrity checks")\n"
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
OPT_SHORT="hcCoiemRp:gVdL"
OPT_LONG=('help' 'clean' 'cleanbuild' 'nobuild' 'install' 'noextract' 'nocolor' 'repackage'
          'noprepare' 'config:' 'geninteg' 'verifysource' 'version' 'nodeps' 'check'
          'skipchecksums' 'skipinteg' 'log')
if ! parseopts "$OPT_SHORT" "${OPT_LONG[@]}" -- "$@"; then
	exit 1 # E_INVALID_OPTION;
fi
set -- "${OPTRET[@]}"
unset OPT_SHORT OPT_LONG OPTRET

while true; do
	case "$1" in
		-c|--clean)       CLEANUP=1 ;;
		-C|--cleanbuild)  CLEANBUILD=1 ;;
		--check)          RUN_CHECK='y' ;;
		--config)         shift; MAKEPKG_CONF=$1 ;;
		-d|--nodeps)      NODEPS=1 ;;
		-e|--noextract)   NOEXTRACT=1 ;;
		-g|--geninteg)    GENINTEG=1 ;;
		-i|--install)     INSTALL=1 ;;
		-L|--log)         LOGGING=1 ;;
		-m|--nocolor)     USE_COLOR='n' ;;
		--nocheck)        RUN_CHECK='n' ;;
		--noprepare)      RUN_PREPARE='n' ;;
		-o|--nobuild)     NOBUILD=1 ;;
		-p)               shift; BUILDFILE=$1 ;;
		-R|--repackage)   REPKG=1 ;;
		--skipchecksums)  SKIPCHECKSUMS=1 ;;
		--skipinteg)      SKIPCHECKSUMS=1; SKIPPGPCHECK=1 ;;
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
fi


if (( NODEPS || ( VERIFYSOURCE && !DEP_BIN ) )); then
	# no warning message needed for nobuild
	if (( NODEPS )); then
		warning "$(gettext "Skipping dependency checks.")"
	fi
else
	msg "$(gettext "Checking buildtime dependencies...")"
	if [ ${#makedepends[@]} -ne 0 ]; then
		depout=`rpm -q ${makedepends[@]} | grep 'not installed' | cut -d ' ' -f 2`
		while read -r depline; do
			if [ "$depline" != "" ]; then
				error "makedepend %s is not installed." "$depline"
				deperr=1
			fi
		done <<< "$depout"
	fi
	if (( CHECKFUNC )); then
		if [ ${#checkdepends[@]} -ne 0 ]; then
			depout=`rpm -q ${checkdepends[@]} | grep 'not installed' | cut -d ' ' -f 2`
			while read -r depline; do
				if [ "$depline" != "" ]; then
					error "checkdepend %s is not installed." "$depline"
					deperr=1
				fi
			done <<< "$depout"
		fi
	fi
	if (( deperr )); then
		error "Could not resolve all dependencies."
		exit 1
	fi
fi


fpmx() {
	if [[ "$url" = "" ]]; then
		local url_param=''
	else
		local url_param="--url \"$url\""
	fi
	if [[ "$arch" = "any" ]]; then
		local fpm_arch='all'
	else
		local fpm_arch='native'
	fi
	if [[ "$epoch" = "" ]]; then
		local epoch_param='--epoch 0'
	else
		local epoch_param="--epoch $epoch"
	fi
	if [[ "$RPM_DIST" = "" ]]; then
		local rpm_dist_param=''
	else
		local rpm_dist_param="--rpm-dist \"$RPM_DIST\""
	fi
	if [[ "$pkgdesc" = "" ]]; then
		local description_param=''
	else
		local description_param="--description \"$pkgdesc\""
	fi
	if [[ "$PACKAGER" = "" ]]; then
		local maintainer_param=''
		warning "RPM will have current user & hostname for Packager"
	else
		local maintainer_param="--maintainer \"$PACKAGER\""
	fi
	if [[ "$RPM_VENDOR" = "" ]]; then
		warning "RPM will have current user & hostname for Vendor"
		local vendor_param=''
	else
		local vendor_param="--vendor \"$RPM_VENDOR\""
	fi

	local nm=$1; shift
	local cmd="fpm -s dir -t rpm -a $fpm_arch"
	cmd="$cmd $rpm_dist_param"
	cmd="$cmd --rpm-os linux"
	cmd="$cmd --package \"$PKGDEST\"" # output path
	cmd="$cmd $maintainer_param"
	cmd="$cmd $description_param"
	cmd="$cmd $url_param"
	cmd="$cmd $vendor_param"
	cmd="$cmd --name \"$nm\""
	cmd="$cmd --version \"$pkgver\""
	cmd="$cmd --iteration \"$pkgrel\""
	cmd="$cmd $epoch_param"
	cmd="$cmd -C \"$pkgdir\""         # chdir here for contents
	for item in "${depends[@]}"; do
		cmd="$cmd -d \"$item\""
	done
	cmd="$cmd --rpm-use-file-permissions --rpm-user root --rpm-group root"
	cmd="$cmd $@"
	eval $cmd
}

fpmx_python() {
	local nm=$1; shift
	fpm -s python -t rpm \
		-p "$startdir" \
		-n "$nm" \
		-C "$pkgdir" \
		-v "$pkgver" --iteration "${pkgrel}${VERSION_SUFFIX}" --epoch 1 \
		"$@"
}

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
	cd_safe "$startdir"

	if (( ! REPKG )); then
		(( BUILDFUNC )) && run_build
		(( CHECKFUNC )) && run_check
		cd_safe "$startdir"
	fi

	if (( PKGFUNC )); then
		run_package
	fi
fi

# if inhibiting archive creation, go no further
if (( NOARCHIVE )); then
	msg "$(gettext "Package directory is ready.")"
	exit 0
fi

msg "$(gettext "Finished making: %s")" "$pkgbase $basever ($(date))"

#cd_safe "$startdir"
install_package

exit 0 #E_OK

# vim: set noet:
