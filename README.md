# Mirador

Mirador is an open-source lookalike/typosquat domain monitor. Point it at the
domains you care about, it generates permutations (via [dnstwist](https://github.com/elceef/dnstwist)),
checks which ones are alive, separates the legitimate from the suspicious, and
keeps watching -- including domains that aren't registered yet. dnstwist tells
you what lookalike domains exist; Mirador tells you when one of them starts
moving, and later, when one stops being dangerous. Licensed under AGPL-3.0.
