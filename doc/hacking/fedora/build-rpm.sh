#!/bin/bash

set -eu -o pipefail

progname=$(basename "$0")

fetch_instructions='
        Please fetch it with `dnf download --source systemd` and install
        it to your ~/rpmbuild with `rpm -ivh systemd-*.src.rpm`.

        Or clone git repo https://src.fedoraproject.org/rpms/systemd.git
        under your ~/fedora-scm directory.
'

# Ensure we're running from a git working tree. Chdir to the toplevel.

if git_toplevel=$(git rev-parse --show-toplevel 2>/dev/null) ; then
    cd "${git_toplevel}"
else
    cat <<EDQ >&2
${progname}: Not a git repository

        Please run this command from a working tree git clone
        of the systemd git repository.
EDQ
    exit 1
fi

# Check if building debuginfo was explicitly required with a --debuginfo
# argument, otherwise skip building the debug RPMs to save build time and
# diskspace.

debuginfo=
if [[ "${1:-}" == "--debuginfo" ]] ; then
    shift
    debuginfo=yes
fi

# Locate systemd.spec, look into ~/fedora-src or ~/fedora-scm directories,
# otherwise fallback to ~/rpmbuild/SPECS.
#
# But first, look at an additional command-line argument to see if it's a path
# to a custom rpmbuild directory, directory with specs or specfile itself.

specfile=
sourcedir=

specfilename="systemd.spec"

# Check for presence of this file to ensure we have the right %{_sourcedir}.
known_sourcefile="triggers.systemd"

if [[ "${1:+set}" == "set" ]] ; then
    if [[ -f "$1/SPECS/${specfilename}" ]] ; then
        specfile="$1/SPECS/${specfilename}"
        sourcedir="$1/SOURCES"
    else
        specdir=
        if [[ -f "$1" ]] ; then
            specname=$(basename "$1")
            if [[ "${specname}" == "${specfilename}" ]] ; then
                specfile="$1"
                specdir=$(dirname "$1")
            fi
        elif [[ -f "$1/${specfilename}" ]] ; then
            specdir="$1"
            specfile="${specdir}/${specfilename}"
        elif [[ -f "$1/systemd/${specfilename}" ]] ; then
            specdir="$1/systemd"
            specfile="${specdir}/${specfilename}"
        fi

        if [[ -f "${specdir}/${known_sourcefile}" ]] ; then
            sourcedir="${specdir}"
        elif [[ -f "${specdir}/../SOURCES/${known_sourcefile}" ]] ; then
            sourcedir="${specdir}/../SOURCES"
        else
            # Not a valid specfile.
            cat <<EDQ >&2
${progname}: Cannot find ${specfilename} under [$1]

        Please pass this script an argument that points to an rpmbuild
        directory or git clone of the Fedora systemd RPMs where a
        ${specfilename} file can be found.
${fetch_instructions}
EDQ
            exit 1
        fi
    fi
fi

if [[ -z "${specfile}" ]] ; then
    for dir in ~/fedora-{src,scm}/systemd ; do
        if [[ -f "${dir}/${specfilename}" ]] ; then
            specfile="${dir}/${specfilename}"
            sourcedir="${dir}"
            break
        fi
    done
fi

if [[ -z "${specfile}" ]] ; then
    dir=~/rpmbuild/SPECS
    if [[ -f "${dir}/${specfilename}" ]] ; then
        specfile="${dir}/${specfilename}"
        sourcedir=~/rpmbuild/SOURCES
    else
        cat <<EDQ >&2
${progname}: Cannot find ${specfilename}
${fetch_instructions}
EDQ
        exit 1
    fi
fi

if [[ ! -f "${sourcedir}/${known_sourcefile}" ]] ; then
    cat <<EDQ >&2
${progname}: Cannot find location of RPM sourcedir.

        Did not find well known source file ${known_sourcefile} under
        candidate [${sourcedir}].
${fetch_instructions}
EDQ
    exit 1
fi

# Define a "tag" to use for the RPM version.
#
# By default, Fedora's RPM macros will include %{distprefix} as part of the
# release, so let's use this to inject a unique serial number into our devel
# RPM version.
#
# Start with the full date, so packages will always be in proper lexicographic
# order, and installing packages using `rpm -Fvh` from the RPMS/ directory will
# always pick the latest one built.
#
# Then, include the `git describe` output, which should include the exact git
# commit on top of which this package was built and whether there were
# uncommitted changes to the local tree.
#
# Finally, include a reference to the name of the local git branch, to make it
# easier to identify what changes are included in the built package.
#
# Replace dashes with underscores, since a dash is an invalid character in an
# RPM release string (it's the separator between version and release.)

tag=".$(date +%Y%m%d%H%M%S)"
if git_tag=$(git describe --dirty --abbrev=12) ; then
    tag="${tag}.${git_tag//-/_}"
fi
if git_branch=$(git symbolic-ref -q --short HEAD) ; then
    tag="${tag}.${git_branch//-/_}"
fi

# Finally, run the rpmbuild command.

set -x
rpmbuild -bb --build-in-place --noprep \
    --define "_sourcedir ${sourcedir}" \
    --define "_vpath_builddir build" \
    --define "distprefix ${tag}" \
    ${debuginfo+ --define "debug_package %{nil}"} \
    "${specfile}"
