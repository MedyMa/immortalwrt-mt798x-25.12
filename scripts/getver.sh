#!/usr/bin/env bash
export LANG=C
export LC_ALL=C
[ -n "$TOPDIR" ] && cd $TOPDIR

GET_REV=$1

try_version() {
	[ -f version ] || return 1
	REV="$(cat version)"
	[ -n "$REV" ]
}

try_git() {
	REBOOT=ee53a240ac902dc83209008a2671e7fdcf55957a
	git rev-parse --git-dir >/dev/null 2>&1 || return 1

	[ -n "$GET_REV" ] || GET_REV="HEAD"

	case "$GET_REV" in
	r*)
		GET_REV="$(echo $GET_REV | tr -d 'r')"
		case "$GET_REV" in ''|*[!0-9]*) return 1 ;; esac
		[ "$(git rev-parse --is-shallow-repository)" != true ] || return 1
		git merge-base --is-ancestor "$REBOOT" HEAD 2>/dev/null || return 1
		BASE_REV="$(git rev-list ${REBOOT}..HEAD 2>/dev/null | wc -l | awk '{print $1}')"
		[ $((BASE_REV - GET_REV)) -ge 0 ] && REV="$(git rev-parse HEAD~$((BASE_REV - GET_REV)))"
		;;
	*-*-*)  # ISO date format - for approximating when packages were removed or renamed
		GET_REV="$(git log -n 1 --format="%h" --until "$GET_REV")"
		[ -n "$GET_REV" ] || return 1
		;&  # FALLTHROUGH
	*)
		git rev-parse --verify "$GET_REV^{commit}" >/dev/null 2>&1 || return 1
		# A source snapshot (or shallow clone) cannot supply the upstream
		# revision count. Do not turn a failed rev-list into a misleading r0.
		if [ "$(git rev-parse --is-shallow-repository)" = true ] ||
		   ! git merge-base --is-ancestor "$REBOOT" "$GET_REV" 2>/dev/null; then
			REV="g$(git rev-parse --short "$GET_REV")"
			return 0
		fi
		BRANCH="$(git rev-parse --abbrev-ref HEAD)"
		ORIGIN="$(git rev-parse --verify --symbolic-full-name ${BRANCH}@{u} 2>/dev/null)"
		[ -n "$ORIGIN" ] || ORIGIN="$(git rev-parse --verify --symbolic-full-name main@{u} 2>/dev/null)"
		REV="$(git rev-list ${REBOOT}..$GET_REV 2>/dev/null | wc -l | awk '{print $1}')"

		UPSTREAM_BASE="$GET_REV"
		if [ -n "$ORIGIN" ] && UPSTREAM_BASE="$(git merge-base "$GET_REV" "$ORIGIN")"; then
			UPSTREAM_REV="$(git rev-list ${REBOOT}..$UPSTREAM_BASE 2>/dev/null | wc -l | awk '{print $1}')"
		else
			UPSTREAM_BASE="$GET_REV"
			UPSTREAM_REV="$REV"
		fi

		if [ "$REV" -gt "$UPSTREAM_REV" ]; then
			REV="${UPSTREAM_REV}+$((REV - UPSTREAM_REV))"
		fi

		REV="${REV:+r$REV-$(git log -n 1 --no-show-signature --format="%h" $UPSTREAM_BASE)}"

		;;
	esac

	[ -n "$REV" ]
}

try_hg() {
	[ -d .hg ] || return 1
	REV="$(hg log -r-1 --template '{desc}' | awk '{print $2}' | sed 's/\].*//')"
	REV="${REV:+r$REV}"
	[ -n "$REV" ]
}

try_version || try_git || try_hg || REV="unknown"
echo "$REV"
