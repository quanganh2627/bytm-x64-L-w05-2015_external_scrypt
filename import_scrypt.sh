#!/bin/bash
#
# Copyright (C) 2009 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#
# This script imports new versions of scrypt (http://www.tarsnap.com/scrypt/) into the
# Android source tree.  To run, (1) fetch the appropriate tarball from the scrypt repository,
# (2) check the gpg/pgp signature, and then (3) run:
#   ./import_scrypt.sh import scrypt-*.tar.gz
#
# IMPORTANT: See README.android for additional details.

# turn on exit on error as well as a warning when it happens
set -e
set -x
trap  "echo WARNING: Exiting on non-zero subprocess exit code" ERR;

# Ensure consistent sorting order / tool output.
export LANG=C
export LC_ALL=C

export DIRNAME=$(dirname $0)

function die() {
  declare -r message=$1

  echo $message
  exit 1
}

function usage() {
  declare -r message=$1

  if [ ! "$message" = "" ]; then
    echo $message
  fi
  echo "Usage:"
  echo "  ./import_scrypt.sh import </path/to/scrypt-*.tar.gz>"
  echo "  ./import_scrypt.sh regenerate <patch/*.patch>"
  echo "  ./import_scrypt.sh generate <patch/*.patch> </path/to/scrypt-*.tar.gz>"
  exit 1
}

function main() {
  if [ ! -d patches ]; then
    die "scrypt patch directory patches/ not found"
  fi

  if [ ! -f scrypt.version ]; then
    die "scrypt.version not found"
  fi

  source $DIRNAME/scrypt.version
  if [ "$SCRYPT_VERSION" == "" ]; then
    die "Invalid scrypt.version; see README.android for more information"
  fi

  SCRYPT_DIR=scrypt-$SCRYPT_VERSION
  SCRYPT_DIR_ORIG=$SCRYPT_DIR.orig

  if [ ! -f scrypt.config ]; then
    die "scrypt.config not found"
  fi

  source $DIRNAME/scrypt.config
  if [ "$CONFIGURE_ARGS" == "" -o "$UNNEEDED_SOURCES" == "" -o "$NEEDED_SOURCES" == "" ]; then
    die "Invalid scrypt.config; see README.android for more information"
  fi

  declare -r command=$1
  shift || usage "No command specified. Try import, regenerate, or generate."
  if [ "$command" = "import" ]; then
    declare -r tar=$1
    shift || usage "No tar file specified."
    import $tar
  elif [ "$command" = "regenerate" ]; then
    declare -r patch=$1
    shift || usage "No patch file specified."
    [ -d $SCRYPT_DIR ] || usage "$SCRYPT_DIR not found, did you mean to use generate?"
    [ -d $SCRYPT_DIR_ORIG_ORIG ] || usage "$SCRYPT_DIR_ORIG not found, did you mean to use generate?"
    regenerate $patch
  elif [ "$command" = "generate" ]; then
    declare -r patch=$1
    shift || usage "No patch file specified."
    declare -r tar=$1
    shift || usage "No tar file specified."
    generate $patch $tar
  else
    usage "Unknown command specified $command. Try import, regenerate, or generate."
  fi
}

# Compute the name of an assembly source file generated by one of the
# gen_asm_xxxx() functions below. The logic is the following:
# - if "$2" is not empty, output it directly
# - otherwise, change the file extension of $1 from .pl to .S and output
#   it.
# Usage: default_asm_file "$1" "$2"
#     or default_asm_file "$@"
#
# $1: generator path (perl script)
# $2: optional output file name.
function default_asm_file () {
  if [ "$2" ]; then
    echo "$2"
  else
    echo "${1%%.pl}.S"
  fi
}

# Generate an ARM assembly file.
# $1: generator (perl script)
# $2: [optional] output file name
function gen_asm_arm () {
  local OUT
  OUT=$(default_asm_file "$@")
  perl "$1" > "$OUT"
}

function gen_asm_mips () {
  local OUT
  OUT=$(default_asm_file "$@")
  # The perl scripts expect to run the target compiler as $CC to determine
  # the endianess of the target. Setting CC to true is a hack that forces the scripts
  # to generate little endian output
  CC=true perl "$1" o32 > "$OUT"
}

function gen_asm_x86 () {
  local OUT
  OUT=$(default_asm_file "$@")
  perl "$1" elf -fPIC > "$OUT"
}

function gen_asm_x86_64 () {
  local OUT
  OUT=$(default_asm_file "$@")
  perl "$1" elf "$OUT" > "$OUT"
}


# Filter all items in a list that match a given pattern.
# $1: space-separated list
# $2: egrep pattern.
# Out: items in $1 that match $2
function filter_by_egrep() {
  declare -r pattern=$1
  shift
  echo "$@" | tr ' ' '\n' | grep -e "$pattern" | tr '\n' ' '
}

# Sort and remove duplicates in a space-separated list
# $1: space-separated list
# Out: new space-separated list
function uniq_sort () {
  echo "$@" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

function print_autogenerated_header() {
  echo "# Auto-generated - DO NOT EDIT!"
  echo "# To regenerate, edit scrypt.config, then run:"
  echo "#     ./import_scrypt.sh import /path/to/scrypt-$SCRYPT_VERSION.tar.gz"
  echo "#"
}

function generate_build_config_mk() {
  ./configure $CONFIGURE_ARGS
  #rm -f apps/CA.pl.bak crypto/scryptconf.h.bak

  declare -r tmpfile=$(mktemp)
  (grep -e -D Makefile | grep -v CONFIGURE_ARGS= | grep -v OPTIONS=) > $tmpfile

  declare -r cflags=$(filter_by_egrep "^-D" $(grep -e "^CFLAG=" $tmpfile))
  declare -r depflags=$(filter_by_egrep "^-D" $(grep -e "^DEPFLAG=" $tmpfile))
  rm -f $tmpfile

  echo "Generating $(basename $1)"
  (
    print_autogenerated_header

    echo "scrypt_cflags := \\"
    for cflag in $cflags $depflags; do
      echo "  $cflag \\"
    done
    echo ""
  ) > $1
}

# Return the value of a computed variable name.
# E.g.:
#   FOO=foo
#   BAR=bar
#   echo $(var_value FOO_$BAR)   -> prints the value of ${FOO_bar}
# $1: Variable name
# Out: variable value
var_value() {
  # Note: don't use 'echo' here, because it's sensitive to values
  #       that begin with an underscore (e.g. "-n")
  eval printf \"%s\\n\" \$$1
}

# Same as var_value, but returns sorted output without duplicates.
# $1: Variable name
# Out: variable value (if space-separated list, sorted with no duplicates)
var_sorted_value() {
  uniq_sort $(var_value $1)
}

# Print the definition of a given variable in a GNU Make build file.
# $1: Variable name (e.g. common_src_files)
# $2+: Variable value (e.g. list of sources)
print_vardef_in_mk() {
  declare -r varname=$1
  shift
  if [ -z "$1" ]; then
    echo "$varname :="
  else
    echo "$varname := \\"
    for src; do
      echo "  $src \\"
    done
  fi
  echo ""
}

# Same as print_vardef_in_mk, but print a CFLAGS definition from
# a list of compiler defines.
# $1: Variable name (e.g. common_c_flags)
# $2: List of defines (e.g. SCRYPT_NO_DONKEYS ...)
print_defines_in_mk() {
  declare -r varname=$1
  shift
  if [ -z "$1" ]; then
    echo "$varname :="
  else
    echo "$varname := \\"
    for def; do
    echo "  -D$def \\"
    done
  fi
  echo ""
}

# Generate a configuration file like Scrypt-config.mk
# This uses variable definitions from scrypt.config to build a config
# file that can compute the list of target- and host-specific sources /
# compiler flags for a given component.
#
# $1: Target file name.  (e.g. Scrypt-config.mk)
function generate_config_mk() {
  declare -r output="$1"
  declare -r all_archs="arm x86 x86_64 mips"

  echo "Generating $(basename $output)"
  (
    print_autogenerated_header
    echo \
"# Before including this file, the local Android.mk must define the following
# variables:
#
#    local_c_flags
#    local_c_includes
#    local_additional_dependencies
#
# This script will define the following variables:
#
#    target_c_flags
#    target_c_includes
#    target_src_files
#
#    host_c_flags
#    host_c_includes
#    host_src_files
#

# Ensure these are empty.
unknown_arch_c_flags :=
unknown_arch_src_files :=
unknown_arch_exclude_files :=

"
    common_defines=$(var_sorted_value SCRYPT_DEFINES)
    print_defines_in_mk common_c_flags $common_defines

    common_sources=$(var_sorted_value SCRYPT_SOURCES)
    print_vardef_in_mk common_src_files $common_sources

    common_includes=$(var_sorted_value SCRYPT_INCLUDES)
    print_vardef_in_mk common_c_includes $common_includes

    for arch in $all_archs; do
      arch_defines=$(var_sorted_value SCRYPT_DEFINES_${arch})
      print_defines_in_mk ${arch}_c_flags $arch_defines

      arch_sources=$(var_sorted_value SCRYPT_SOURCES_${arch})
      print_vardef_in_mk ${arch}_src_files $arch_sources

      arch_exclude_sources=$(var_sorted_value SCRYPT_SOURCES_EXCLUDES_${arch})
      print_vardef_in_mk ${arch}_exclude_files $arch_exclude_sources

    done

    echo "\
target_arch := \$(TARGET_ARCH)
ifeq (\$(target_arch)-\$(TARGET_HAS_BIGENDIAN),mips-true)
target_arch := unknown_arch
endif

target_c_flags    := \$(common_c_flags) \$(\$(target_arch)_c_flags) \$(local_c_flags)
target_c_includes := \$(addprefix external/scrypt/,\$(common_c_includes)) \$(local_c_includes)
target_src_files  := \$(common_src_files) \$(\$(target_arch)_src_files)
target_src_files  := \$(filter-out \$(\$(target_arch)_exclude_files), \$(target_src_files))

ifeq (\$(HOST_OS)-\$(HOST_ARCH),linux-x86)
host_arch := x86
else
host_arch := unknown_arch
endif

host_c_flags    := \$(common_c_flags) \$(\$(host_arch)_c_flags) \$(local_c_flags)
host_c_includes := \$(addprefix external/scrypt/,\$(common_c_includes)) \$(local_c_includes)
host_src_files  := \$(common_src_files) \$(\$(host_arch)_src_files)
host_src_files  := \$(filter-out \$(\$(host_arch)_exclude_files), \$(host_src_files))

local_additional_dependencies += \$(LOCAL_PATH)/$(basename $output)
"

  ) > "$output"
}

function import() {
  declare -r SCRYPT_SOURCE=$1

  untar $SCRYPT_SOURCE readonly
  applypatches $SCRYPT_DIR

  cd $SCRYPT_DIR

  generate_build_config_mk ../build-config.mk

  touch ../MODULE_LICENSE_BSD_LIKE

  cd ..

  generate_config_mk Scrypt-config.mk

  # Prune unnecessary sources
  prune

  NEEDED_SOURCES="$NEEDED_SOURCES"
  for i in $NEEDED_SOURCES; do
    echo "Updating $i"
    rm -r $i
    mv $SCRYPT_DIR/$i .
  done

  cleantar
}

function regenerate() {
  declare -r patch=$1

  generatepatch $patch
}

function generate() {
  declare -r patch=$1
  declare -r SCRYPT_SOURCE=$2

  untar $SCRYPT_SOURCE
  applypatches $SCRYPT_DIR_ORIG $patch
  prune

  for i in $NEEDED_SOURCES; do
    echo "Restoring $i"
    rm -r $SCRYPT_DIR/$i
    cp -rf $i $SCRYPT_DIR/$i
  done

  generatepatch $patch
  cleantar
}

# Find all files in a sub-directory that are encoded in ISO-8859
# $1: Directory.
# Out: list of files in $1 that are encoded as ISO-8859.
function find_iso8859_files() {
  find $1 -type f -print0 | xargs -0 file | fgrep "ISO-8859" | cut -d: -f1
}

# Convert all ISO-8859 files in a given subdirectory to UTF-8
# $1: Directory name
function convert_iso8859_to_utf8() {
  declare -r iso_files=$(find_iso8859_files "$1")
  for iso_file in $iso_files; do
    iconv --from-code iso-8859-1 --to-code utf-8 $iso_file > $iso_file.tmp
    rm -f $iso_file
    mv $iso_file.tmp $iso_file
  done
}

function untar() {
  declare -r SCRYPT_SOURCE=$1
  declare -r readonly=$2

  # Remove old source
  cleantar

  # Process new source
  tar -zxf $SCRYPT_SOURCE
  convert_iso8859_to_utf8 $SCRYPT_DIR
  cp -rfP $SCRYPT_DIR $SCRYPT_DIR_ORIG
  if [ ! -z $readonly ]; then
    find $SCRYPT_DIR_ORIG -type f -print0 | xargs -0 chmod a-w
  fi
}

function prune() {
  echo "Removing $UNNEEDED_SOURCES"
  (cd $SCRYPT_DIR_ORIG && rm -rf $UNNEEDED_SOURCES)
  (cd $SCRYPT_DIR      && rm -r  $UNNEEDED_SOURCES)
}

function cleantar() {
  rm -rf $SCRYPT_DIR_ORIG
  rm -rf $SCRYPT_DIR
}

function applypatches () {
  declare -r dir=$1
  declare -r skip_patch=$2

  cd $dir

  # Apply appropriate patches
  for i in $SCRYPT_PATCHES; do
    if [ ! "$skip_patch" = "patches/$i" ]; then
      echo "Applying patch $i"
      patch -p1 --merge < ../patches/$i || die "Could not apply patches/$i. Fix source and run: $0 regenerate patches/$i"
    else
      echo "Skiping patch $i"
    fi

  done

  # Cleanup patch output
  find . \( -type f -o -type l \) -name "*.orig" -print0 | xargs -0 rm -f

  cd ..
}

function generatepatch() {
  declare -r patch=$1

  # Cleanup stray files before generating patch
  find $SCRYPT_DIR -type f -name "*.orig" -print0 | xargs -0 rm -f
  find $SCRYPT_DIR -type f -name "*~" -print0 | xargs -0 rm -f

  declare -r variable_name=SCRYPT_PATCHES_`basename $patch .patch | sed s/-/_/`_SOURCES
  # http://tldp.org/LDP/abs/html/ivr.html
  eval declare -r sources=\$$variable_name
  rm -f $patch
  touch $patch
  for i in $sources; do
    LC_ALL=C TZ=UTC0 diff -aup $SCRYPT_DIR_ORIG/$i $SCRYPT_DIR/$i >> $patch && die "ERROR: No diff for patch $path in file $i"
  done
  echo "Generated patch $patch"
  echo "NOTE To make sure there are not unwanted changes from conflicting patches, be sure to review the generated patch."
}

main $@
