#!/bin/bash
# factory-post-deploy.sh — the mini's `~/.config/factory/post-deploy`, started in the background by software-factory's
# scripts/deploy.sh after a healthy deploy (arguments: the release dir and the sha, both ignored).
#
# Tells the MacBook to pull the live jk-glance and the live claude-account (fixed verbs `herdr-glance-sync` and
# `claude-account-sync` of scripts/iumac-gate.sh). Always exits 0: an unreachable or asleep MacBook means nothing to do;
# the next deploy or `make herdr-app-setup` converges. A gate without the second verb answers "refused" and costs nothing.
ssh -o BatchMode=yes -o ConnectTimeout=10 iumac herdr-glance-sync
ssh -o BatchMode=yes -o ConnectTimeout=10 iumac claude-account-sync
exit 0
