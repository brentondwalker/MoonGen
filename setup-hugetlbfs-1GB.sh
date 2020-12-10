#!/bin/bash

(
cd $(dirname "${BASH_SOURCE[0]}")
cd libmoon
if [[ -e setup-hugetlbfs-1GB.sh ]] ; then
	./setup-hugetlbfs-1GB.sh
else
	echo "libmoon not found. Please run git submodule update --init --recursive"
fi
)

