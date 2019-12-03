#!/bin/bash
#
# Copyright (C) 2011,2013 Colin Walters <walters@verbum.org>
#
# SPDX-License-Identifier: LGPL-2.0+
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the
# Free Software Foundation, Inc., 59 Temple Place - Suite 330,
# Boston, MA 02111-1307, USA.

set -euo pipefail

. $(dirname $0)/libtest.sh

skip_without_user_xattrs

bindatafiles="bash true ostree"
morebindatafiles="false ls"

echo '1..19'

# This is explicitly opt in for testing
export OSTREE_DUMMY_SIGN_ENABLED=1

mkdir repo
ostree_repo_init repo --mode=archive

mkdir files
for bin in ${bindatafiles}; do
    cp $(which ${bin}) files
done

${CMD_PREFIX} ostree --repo=repo commit -b test -s test --tree=dir=files

function permuteFile() {
    permutation=$(($1 % 2))
    output=$2
    case $permutation in
	0) dd if=/dev/zero count=40 bs=1 >> $output;;
	1) echo aheader | cat - $output >> $output.new && mv $output.new $output;;
    esac
}

function permuteDirectory() {
    permutation=$1
    dir=$2
    for x in ${dir}/*; do
	for z in $(seq ${permutation}); do
	    permuteFile ${z} ${x}
	done
    done
}

get_assert_one_direntry_matching() {
    local path=$1
    local r=$2
    local child=""
    local bn
    for p in ${path}/*; do
	bn=$(basename $p)
	if ! echo ${bn} | grep -q "$r"; then
	    continue
	fi
	if test -z "${child}"; then
	    child=${bn}
	else
	    assert_not_reached "Expected only one child matching ${r} in ${path}";
	fi
    done
    if test -z "${child}"; then
	assert_not_reached "Failed to find child matching ${r}"
    fi
    echo ${child}
}

origrev=$(${CMD_PREFIX} ostree --repo=repo rev-parse test)

${CMD_PREFIX} ostree --repo=repo static-delta generate --empty --to=${origrev}
${CMD_PREFIX} ostree --repo=repo static-delta generate --if-not-exists --empty --to=${origrev} > out.txt
assert_file_has_content out.txt "${origrev} already exists"
${CMD_PREFIX} ostree --repo=repo static-delta list | grep ${origrev} || exit 1
${CMD_PREFIX} ostree --repo=repo prune
${CMD_PREFIX} ostree --repo=repo static-delta list | grep ${origrev} || exit 1

permuteDirectory 1 files
${CMD_PREFIX} ostree --repo=repo commit -b test -s test --tree=dir=files

newrev=$(${CMD_PREFIX} ostree --repo=repo rev-parse test)

${CMD_PREFIX} ostree --repo=repo static-delta generate --if-not-exists --from=${origrev} --to=${newrev} --inline
${CMD_PREFIX} ostree --repo=repo static-delta generate --if-not-exists --from=${origrev} --to=${newrev} --inline > out.txt
assert_file_has_content out.txt "${origrev}-${newrev} already exists"
# Should regenerate
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --inline > out.txt
assert_not_file_has_content out.txt "${origrev}-${newrev} already exists"

deltaprefix=$(get_assert_one_direntry_matching repo/deltas '.')
deltadir=$(get_assert_one_direntry_matching repo/deltas/${deltaprefix} '-')

assert_has_file repo/deltas/${deltaprefix}/${deltadir}/superblock
assert_not_has_file repo/deltas/${deltaprefix}/${deltadir}/0

${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev}

assert_has_file repo/deltas/${deltaprefix}/${deltadir}/superblock
assert_has_file repo/deltas/${deltaprefix}/${deltadir}/0

${CMD_PREFIX} ostree --repo=repo static-delta generate --disable-bsdiff --from=${origrev} --to=${newrev} 2>&1 | grep "bsdiff=0 objects"
${CMD_PREFIX} ostree --repo=repo static-delta generate --max-bsdiff-size=0 --from=${origrev} --to=${newrev} 2>&1 | grep "bsdiff=0 objects"
${CMD_PREFIX} ostree --repo=repo static-delta generate --max-bsdiff-size=10000 --from=${origrev} --to=${newrev} 2>&1 | grep "bsdiff=[1-9]"

${CMD_PREFIX} ostree --repo=repo static-delta list | grep ${origrev}-${newrev} || exit 1

if ${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --empty 2>>err.txt; then
    assert_not_reached "static-delta generate --from=${origrev} --empty unexpectedly succeeded"
fi

ostree_repo_init temp-repo --mode=archive
${CMD_PREFIX} ostree --repo=temp-repo pull-local repo
mkdir tmpsubdir
${CMD_PREFIX} ostree --repo=temp-repo static-delta generate --empty --to=${newrev} --filename=tmpsubdir/some.delta
assert_has_file tmpsubdir/some.delta
${CMD_PREFIX} ostree --repo=temp-repo static-delta list > delta-list.txt
assert_file_has_content delta-list.txt 'No static deltas'
rm temp-repo -rf

echo 'ok generate'

${CMD_PREFIX} ostree --repo=repo static-delta show ${origrev}-${newrev} > show.txt
assert_file_has_content show.txt "From: ${origrev}"
assert_file_has_content show.txt "To: ${newrev}"
assert_file_has_content show.txt 'Endianness: \(little\|big\)'

echo 'ok show'

${CMD_PREFIX} ostree --repo=repo static-delta generate --swap-endianness --from=${origrev} --to=${newrev}
${CMD_PREFIX} ostree --repo=repo static-delta show ${origrev}-${newrev} > show-swapped.txt
totalsize_orig=$(grep 'Total Size:' show.txt)
totalsize_swapped=$(grep 'Total Size:' show-swapped.txt)
assert_not_streq "${totalsize_orig}" ""
assert_streq "${totalsize_orig}" "${totalsize_swapped}"

echo 'ok generate + show endian swapped'

tar xf ${test_srcdir}/pre-endian-deltas-repo-big.tar.xz
mv pre-endian-deltas-repo{,-big}
tar xf ${test_srcdir}/pre-endian-deltas-repo-little.tar.xz
mv pre-endian-deltas-repo{,-little}
legacy_origrev=$(${CMD_PREFIX} ostree --repo=pre-endian-deltas-repo-big rev-parse main^)
legacy_newrev=$(${CMD_PREFIX} ostree --repo=pre-endian-deltas-repo-big rev-parse main)
${CMD_PREFIX} ostree --repo=pre-endian-deltas-repo-big static-delta show ${legacy_origrev}-${legacy_newrev} > show-legacy-big.txt
totalsize_legacy_big=$(grep 'Total Size:' show-legacy-big.txt)
${CMD_PREFIX} ostree --repo=pre-endian-deltas-repo-big static-delta show ${legacy_origrev}-${legacy_newrev} > show-legacy-little.txt
totalsize_legacy_little=$(grep 'Total Size:' show-legacy-little.txt)
for f in show-legacy-{big,little}.txt; do
    if grep 'Endianness:.*heuristic' $f; then
	found_heuristic=yes
	break
    fi
done
assert_streq "${found_heuristic}" "yes"
assert_streq "${totalsize_legacy_big}" "${totalsize_legacy_little}"

echo 'ok heuristic endian detection'

${CMD_PREFIX} ostree --repo=repo summary -u

mkdir repo2 && ostree_repo_init repo2 --mode=bare-user
${CMD_PREFIX} ostree --repo=repo2 pull-local --require-static-deltas repo ${origrev}
${CMD_PREFIX} ostree --repo=repo2 fsck
${CMD_PREFIX} ostree --repo=repo2 ls ${origrev} >/dev/null

echo 'ok pull delta'

rm repo2 -rf
mkdir repo2 && ostree_repo_init repo2 --mode=bare-user
mkdir deltadir

deltaprefix=$(get_assert_one_direntry_matching repo/deltas '.')
deltadir=$(get_assert_one_direntry_matching repo/deltas/${deltaprefix} '-')
${CMD_PREFIX} ostree --repo=repo2 pull-local repo ${origrev}
${CMD_PREFIX} ostree --repo=repo2 ls ${origrev} >/dev/null
${CMD_PREFIX} ostree --repo=repo2 static-delta apply-offline repo/deltas/${deltaprefix}/${deltadir}
${CMD_PREFIX} ostree --repo=repo2 fsck
${CMD_PREFIX} ostree --repo=repo2 ls ${newrev} >/dev/null

echo 'ok apply offline'

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --inline
assert_not_has_file repo/deltas/${deltaprefix}/${deltadir}/0

rm repo2 -rf
ostree_repo_init repo2 --mode=bare-user

${CMD_PREFIX} ostree --repo=repo2 pull-local repo ${origrev}
${CMD_PREFIX} ostree --repo=repo2 ls ${origrev} >/dev/null
${CMD_PREFIX} ostree --repo=repo2 static-delta apply-offline repo/deltas/${deltaprefix}/${deltadir}
${CMD_PREFIX} ostree --repo=repo2 fsck
${CMD_PREFIX} ostree --repo=repo2 ls ${newrev} >/dev/null

echo 'ok apply offline inline'

${CMD_PREFIX} ostree --repo=repo static-delta list | grep ^${origrev}-${newrev}$ || exit 1
${CMD_PREFIX} ostree --repo=repo static-delta list | grep ^${origrev}$ || exit 1

${CMD_PREFIX} ostree --repo=repo static-delta delete ${origrev} || exit 1

${CMD_PREFIX} ostree --repo=repo static-delta list | grep ^${origrev}-${newrev}$ || exit 1
${CMD_PREFIX} ostree --repo=repo static-delta list | grep ^${origrev}$ && exit 1

${CMD_PREFIX} ostree --repo=repo static-delta delete ${origrev}-${newrev} || exit 1

${CMD_PREFIX} ostree --repo=repo static-delta list | grep ^${origrev}-${newrev}$ && exit 1
${CMD_PREFIX} ostree --repo=repo static-delta list | grep ^${origrev}$ && exit 1

echo 'ok delete'

# Make another commit with no changes to create a delta with no parts
${CMD_PREFIX} ostree --repo=repo commit -b test -s test --tree=dir=files
samerev=$(${CMD_PREFIX} ostree --repo=repo rev-parse test)
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${newrev} --to=${samerev}
${CMD_PREFIX} ostree --repo=repo static-delta show ${newrev}-${samerev} > show-empty.txt
nparts_empty=$(grep '^Number of parts:' show-empty.txt)
part0_meta_empty=$(grep '^PartMeta0:' show-empty.txt)
totalsize_empty=$(grep '^Total Uncompressed Size:' show-empty.txt)
assert_streq "${nparts_empty}" "Number of parts: 1"
assert_str_match "${part0_meta_empty}" "nobjects=0"
assert_streq "${totalsize_empty}" "Total Uncompressed Size: 0 (0 bytes)"

echo 'ok generate + show empty delta part'

${CMD_PREFIX} ostree --repo=repo summary -u

rm -rf repo2
mkdir repo2 && ostree_repo_init repo2 --mode=bare-user
${CMD_PREFIX} ostree --repo=repo2 pull-local repo ${newrev}
${CMD_PREFIX} ostree --repo=repo2 pull-local --require-static-deltas repo ${samerev}
${CMD_PREFIX} ostree --repo=repo2 fsck
${CMD_PREFIX} ostree --repo=repo2 ls ${samerev} >/dev/null

echo 'ok pull empty delta part'

# Make a new branch to test "rebase deltas"
echo otherbranch-content > files/otherbranch-content
${CMD_PREFIX} ostree --repo=repo commit -b otherbranch --tree=dir=files
samerev=$(${CMD_PREFIX} ostree --repo=repo rev-parse test)
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=test --to=otherbranch
${CMD_PREFIX} ostree --repo=repo summary -u
${CMD_PREFIX} ostree --repo=repo2 pull-local --require-static-deltas repo otherbranch

echo 'ok rebase deltas'

${CMD_PREFIX} ostree --repo=repo summary -u
if ${CMD_PREFIX} ostree --repo=repo static-delta show GARBAGE 2> err.txt; then
    assert_not_reached "static-delta show GARBAGE unexpectedly succeeded"
fi
assert_file_has_content err.txt "Invalid rev GARBAGE"

echo 'ok handle bad delta name'

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev}
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=dummy ${origrev}-${newrev} dummysign > show-not-signed.txt
assert_file_has_content show-not-signed.txt "Not signed"

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --inline
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=dummy ${origrev}-${newrev} dummysign > show-inline-not-signed.txt
assert_file_has_content show-inline-not-signed.txt "Not signed"

echo 'ok verify ok with unsigned deltas'

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --sign-type=dummy --sign=dummysign
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=dummy ${origrev}-${newrev} dummysign > show-dummy-signed.txt
assert_file_has_content show-dummy-signed.txt "Verification OK"

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --inline --sign-type=dummy --sign=dummysign
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=dummy ${origrev}-${newrev} dummysign > show-dummy-inline-signed.txt
assert_file_has_content show-dummy-inline-signed.txt "Verification OK"

echo 'ok verified with dummy'

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --sign-type=dummy --sign=dummysign
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=dummy ${origrev}-${newrev} badsign > show-dummy-bad-signed.txt && exit 1
assert_file_has_content show-dummy-bad-signed.txt "Verification fails"

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --inline --sign-type=dummy --sign=dummysign
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=dummy ${origrev}-${newrev} badsign > show-dummy-bad-inline-signed.txt && exit 1
assert_file_has_content show-dummy-bad-inline-signed.txt "Verification fails"

echo 'ok verification failed with dummy and bad key'

if ! has_libsodium; then
    echo "ok verified with ed25519 (key) # SKIP due libsodium unavailability"
    echo "ok Verification fails with ed25519 (key) and bad key # SKIP due libsodium unavailability"
    echo "ok Verification fails with ed25519 (file) and bad keys # SKIP due libsodium unavailability"
    echo "ok verified with ed25519 (file) # SKIP due libsodium unavailability"
    exit 0
fi

# Test ostree sign with 'ed25519' module
gen_ed25519_keys
PUBLIC=${ED25519PUBLIC}
SEED=${ED25519SEED}
SECRET=${ED25519SECRET}
WRONG_PUBLIC="$(gen_ed25519_random_public)"

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --sign-type=ed25519 --sign=${SECRET}
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} "${PUBLIC}" > show-ed25519-key-signed-1.txt
assert_file_has_content show-ed25519-key-signed-1.txt "Verification OK"
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} "${PUBLIC}" "${WRONG_PUBLIC}" > show-ed25519-key-signed-2.txt
assert_file_has_content show-ed25519-key-signed-2.txt "Verification OK"
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} "${WRONG_PUBLIC}" "${PUBLIC}" > show-ed25519-key-signed-3.txt
assert_file_has_content show-ed25519-key-signed-3.txt "Verification OK"

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --inline --sign-type=ed25519 --sign=${SECRET}
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} "${PUBLIC}" > show-ed25519-key-inline-signed-1.txt
assert_file_has_content show-ed25519-key-inline-signed-1.txt "Verification OK"
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} "${PUBLIC}" "${WRONG_PUBLIC}" > show-ed25519-key-inline-signed-2.txt
assert_file_has_content show-ed25519-key-inline-signed-2.txt "Verification OK"
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} "${WRONG_PUBLIC}" "${PUBLIC}" > show-ed25519-key-inline-signed-3.txt
assert_file_has_content show-ed25519-key-inline-signed-3.txt "Verification OK"

echo 'ok verified with ed25519 (key)'

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --sign-type=ed25519 --sign=${SECRET}
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} "${WRONG_PUBLIC}" > show-ed25519-key-bad-signed.txt && exit 1
assert_file_has_content show-ed25519-key-bad-signed.txt "Verification fails"

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --inline --sign-type=ed25519 --sign=${SECRET}
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} "${WRONG_PUBLIC}" > show-ed25519-key-bad-inline-signed.txt && exit 1
assert_file_has_content show-ed25519-key-bad-inline-signed.txt "Verification fails"

echo 'ok Verification fails with ed25519 (key) and bad key'

# Prepare files with public ed25519 signatures
PUBKEYS="$(mktemp -p ${test_tmpdir} ed25519_XXXXXX.ed25519)"
for((i=0;i<100;i++)); do
    # Generate a list with some public signatures
    gen_ed25519_random_public
done > ${PUBKEYS}

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --sign-type=ed25519 --sign=${SECRET}
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} --keys-file=${PUBKEYS} > show-ed25519-file-bad-signed-1.txt && exit 1
assert_file_has_content show-ed25519-file-bad-signed-1.txt "Verification fails"
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} --keys-file=${PUBKEYS} "${WRONG_PUBLIC}" > show-ed25519-file-bad-signed-2.txt && exit 1
assert_file_has_content show-ed25519-file-bad-signed-2.txt "Verification fails"

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --inline --sign-type=ed25519 --sign=${SECRET}
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} --keys-file=${PUBKEYS} > show-ed25519-file-inline-bad-signed-1.txt && exit 1
assert_file_has_content show-ed25519-file-inline-bad-signed-1.txt "Verification fails"
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} --keys-file=${PUBKEYS} "${WRONG_PUBLIC}" > show-ed25519-file-inline-bad-signed-2.txt && exit 1
assert_file_has_content show-ed25519-file-inline-bad-signed-2.txt "Verification fails"

echo 'ok Verification fails with ed25519 (file) and bad keys'

# Add correct key into the list
echo ${PUBLIC} >> ${PUBKEYS}

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --sign-type=ed25519 --sign=${SECRET}
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} --keys-file=${PUBKEYS} > show-ed25519-file-signed-1.txt
assert_file_has_content show-ed25519-file-signed-1.txt "Verification OK"
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} --keys-file=${PUBKEYS} "${WRONG_PUBLIC}" > show-ed25519-file-signed-2.txt
assert_file_has_content show-ed25519-file-signed-2.txt "Verification OK"

rm -rf repo/deltas/${deltaprefix}/${deltadir}/*
${CMD_PREFIX} ostree --repo=repo static-delta generate --from=${origrev} --to=${newrev} --inline --sign-type=ed25519 --sign=${SECRET}
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} --keys-file=${PUBKEYS} > show-ed25519-file-inline-signed-1.txt
assert_file_has_content show-ed25519-file-inline-signed-1.txt "Verification OK"
${CMD_PREFIX} ostree --repo=repo static-delta verify --sign-type=ed25519 ${origrev}-${newrev} --keys-file=${PUBKEYS} "${WRONG_PUBLIC}" > show-ed25519-file-inline-signed-2.txt
assert_file_has_content show-ed25519-file-inline-signed-2.txt "Verification OK"

echo 'ok verified with ed25519 (file)'
