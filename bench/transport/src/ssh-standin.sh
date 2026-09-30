#!/bin/sh
# ssh for a host that is this machine: the command git or relic asks for,
# run here. Options are skipped as ssh would take them.
while [ $# -gt 0 ]; do case "$1" in -G) exit 0 ;; -o|-p|-P|-i|-J|-F) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
exec sh -c "$*"
