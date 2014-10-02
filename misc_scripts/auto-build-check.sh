#!/bin/sh

## Copyright (C) 2014 Assaf Gordon <assafgordon@gmail.com>
##
## This file is part of PreTest
##
## PreTest is free software: you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation, either version 3 of the License, or
## (at your option) any later version.
##
## PreTest is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.
##
## You should have received a copy of the GNU General Public License
## along with PreTest If not, see <http://www.gnu.org/licenses/>.

##
## A small helper script to easily copy, build and check
## a tarball (after 'make dist') or git repository.
##

die()
{
    BASE=$(basename "$0")
    echo "$BASE: error: $@" >&2
    exit 1
}

validate_simple_name()
{
    # ensure the name contains only 'simple' characters
    ___tmp1=$(echo "$1" | tr -d -c '[:alnum:].\-_%^')
    test "x$1" = "x${___tmp1}" \
    || die "name '$1' contains non-regular characters; " \
           "Aborting to avoid potential troubles. " \
           "Please use only 'A-Za-z0-9.-_%^'."
}


show_help_and_exit()
{
    BASE=$(basename "$0")
    echo "
$BASE - build & test automation

Usage:  $BASE [OPTIONS] SOURCE

SOURCE - A source for the package, either:
  1. a local tarball filename
  2. a remote tarball filename (http/ftp)
  3. a remote git repository

OPTIONS:
   -h          - This help screen.
   -b BRANCH   - If SOURCE is GIT, check-out BRANCH
                 (instead of the default 'master' branch)
   -c PARAM    - Add PARAM as parameter to './configure'
   -m PARAM    - Add PARAM as parameter to 'make'
   -e NAME=VAL - Add NAME=VAL as environment variable to all commands.

NOTE:
  1. When building from tarball, will use './configure && make && make check'
  2. When building from git, will add './bootstrap' as well.
  3. Quoting is tricky, best to avoid double/single qutoes with -c/-m .
  4. Do not use spaces or quotes with '-e' - this will likely fail.

Examples:

  # Download the tarball and run
  #   ./configure && make && make check
  $BASE http://www.gnu.org/gnu/datamash/datamash-1.0.5.tar.gz

  # Extract the local tarball and run
  #   ./configure CC=clang && make -j && make check
  $BASE -c CC=lang -m -j /home/miles/datamash-1.0.5.tar.gz

  # run:
  #   git clone -b test git://git.savannah.gnu.org/datamash.git &&
  #    cd datamash &&
  #      ./bootstrap &&
  #        ./configure &&
  #          make && make check
  $BASE -b test git://git.savannah.gnu.org/datamash.git
"
    exit 0
}

report_system_versions()
{
    ## Report versions of several programs
    for PROG in \
        autoconf automake autopoint autoreconf \
        make makeinfo git wget \
        rsync gcc cc ;
    do
        printf "${PROG}-version: "
        if which ${PROG} 1>/dev/null 2>/dev/null ; then
            if $PROG --version 1>/dev/null 2>/dev/null ; then
                $PROG --version | head -n1
            else
                echo no-version
            fi
        else
            echo missing
        fi
    done

    ## Report values for several 'uname' options
    for FLAG in -s -r -m -p -i -o -v ;
    do
        printf "uname$FLAG: "
        if uname $FLAG 2>/dev/null 1>/dev/null ; then
            uname $FLAG
        else
            echo
        fi
    done

    ## Report values for several 'lsb_release' options
    if which lsb_release 1>/dev/null 2>/dev/null ; then
        for FLAG in -v -i -d -r -c ;
        do
            printf "lsb_release$FLAG: "
            lsb_release -s $FLAG
        done
    else
        for FLAG in -v -i -d -r -c ;
        do
            printf "lsb_release$FLAG: N/A"
        done
    fi
}


timestamp()
{
    printf "%s-TIMESTAMP-EPOCH: " "$1"
    # TODO: Is "%s" portable enough?
    date -u +%s
    printf "%s-TIMESTAMP-DATE: " "$1"
    date -u +"%Y-%m-%d %H:%M:%S"
}


##
## Script starts here
##

## parse parameterse
show_help=
configure_params=
make_params=
env_params=
git_branch=
while getopts b:c:m:e:h name
do
        case $name in
        b)      git_branch="-b '$OPTARG'"
                ;;
        c)      configure_params="$configure_params '$OPTARG'"
                ;;
        m)      make_params="$make_params '$OPTARG'"
                ;;
        e)      echo "$OPT_ARG" | grep -E -q '^[A-Za-z0-9]=' ||
                   die "error: '-e $OPTARG' doesn't look like a " \
                           "valid environment variable"
                env_params="$env_PARAMS $OPTARG"
                ;;
        h)      show_help=y
                ;;
        ?)      die "Try -h for help."
        esac
done
[ ! -z "$show_help" ] && show_help_and_exit;

shift $((OPTIND-1))

SOURCE=$1
test -z "$SOURCE" \
    && die "missing SOURCE file name or URL " \
           "(e.g. http://ftp.gnu.org/gnu/coreutils/coreutils-8.23.tar.xz ). "\
           "Try -h for help."
shift 1

##
## Extract basename for the project, create temporary directory
##
BASENAME=$(basename "$SOURCE")
# Remove known extensions
BASENAME=${BASENAME%.git}
BASENAME=${BASENAME%.xz}
BASENAME=${BASENAME%.gz}
BASENAME=${BASENAME%.bz2}
BASENAME=${BASENAME%.tar}
validate_simple_name "$BASENAME"

##
## Create temporary working directory
##
# The '-t' syntax is deprecated by GNU coreutils, but this forms still
# works on all tested systems (non GNU as well)
DIR=$(mktemp -d -t "${BASENAME}.XXXXXX") \
    || die "failed to create temporary directory"
cd "$DIR" || exit 1


##
## Validate source (git, remote file, local file)
##
## Is the source a git repository or a local TARBALL file?
if echo "$SOURCE" | grep -E -q '^git://|\.git$' ; then
    ## a Git repository source
    git ls-remote "$SOURCE" >/dev/null \
        || die "source ($SOURCE) is not a valid remote git repository"
    GIT_REPO=$SOURCE
elif echo "$SOURCE" |
	grep -E -q '^(ht|f)tp://[A-Za-z0-9\_\.\/:-]*\.tar\.(gz|bz2|xz)' ; then
    ## a remote tarball source
    TMP1=$(basename "$SOURCE") || die "failed to get basename of '$SOURCE'"
    if [ -e "$TMP1" ] ; then
    echo "$TMP1 already exists locally, skipping download." >&2
    else
    wget -O "$TMP1" "$SOURCE" || die "failed to download '$SOURCE'"
    fi
    TARBALL="$TMP1"
else
    ## assume a local tarball source
    [ -e "$SOURCE" ] || die "source file $SOURCE not found"
    cp "$SOURCE" "$DIR/" || die "failed to copy '$SOURCE' to '$DIR/'"
    TARBALL=$(basename "$SOURCE") || exit 1
fi


##
## If it's a local file, determine compression type
##
if test -n "$TARBALL" ; then
  FILENAME=$(basename "$TARBALL" ) || exit 1
  EXT=${FILENAME##*.tar.}
  if test "$EXT" = "gz" ; then
    COMPPROG=gzip
  elif test "$EXT" = "bz2" ; then
    COMPPROG=bzip2
  elif test "$EXT" = "xz" ; then
    COMPPROG=xz
  else
    die "unknown compression extension ($EXT) in filename ($FILENAME)"
  fi
fi


##
## Report system information
##
timestamp "START"
report_system_versions


##
## Extract the tarball (if needed)
##
## NOTE: about the convoluted 'cd' command:
##   Most release tarballs contain a sub-directory with the same name as
##   the tarball itself (e.g. 'grep-2.9.1-abcd.tar.gz' will contain
##   './grep-2.9.1-abcd/').
##   But few tarballs (especially alpha-stage and temporary ones send to
##   GNU platform-testers can contain other sub-directory names
##   (e.g. 'grep-2.9.1.tar.gz' might have './grep-ss' sub directory).
##   So use 'find' to find the first sub directory
##   (assuming there's only one).
if test -n "$TARBALL" ; then
    $COMPPROG -dc "$TARBALL" | tar -xf - \
        || die "failed to extract '$DIR/$TARBALL' (using $COMPPROG)"

    SRCDIR=$(find . -maxdepth 1 -type d | tail -n 1)
    test -d "$SRCDIR" || die "failed to find source directory after " \
                             "extracting '$DIR/$TARBALL'"
    cd "$SRCDIR" || exit 1
fi


##
## Clone the GIT repository (if needed)
##
if test -n "$GIT_REPO" ; then
    git clone $git_branch "$GIT_REPO" "$BASENAME" \
        || die "failed to clone '$GIT_REPO' to local directory '$BASENAME'"
    cd $BASENAME || exit 1

    ## TODO:
    ## accomodate for optional 'autogen.sh' or similar scripts
    ./bootstrap || die "./bootstrap failed"
fi

##
## common building steps
##
./configure $configure_params || die "./configure failed"

make $make_params || die "make failed"

# TODO:
# If make-check fails, post the test-suite.log somewhere
make check || die "make-check failed"

##
## Done
##
# TODO: report completion ?


## vim: set shiftwidth=4:
## vim: set tabstop=4:
## vim: set expandtab:
