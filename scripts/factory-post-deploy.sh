#!/bin/bash
# factory-post-deploy.sh — the mini's `~/.config/factory/post-deploy`, started in the background by software-factory's
# scripts/deploy.sh after a healthy deploy (arguments: the release dir and the sha, both ignored).
#
# Tells the MacBook to pull the live jk-glance (fixed verb `herdr-glance-sync` of scripts/iumac-gate.sh). Always exits
# 0: an unreachable or asleep MacBook means nothing to do; the next deploy or `make herdr-app-setup` converges.
ssh -o BatchMode=yes -o ConnectTimeout=10 iumac herdr-glance-sync
exit 0
