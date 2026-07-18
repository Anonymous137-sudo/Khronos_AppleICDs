#!/bin/sh
set -eu

PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

dest_root=${1:-/}

if [ "$dest_root" != "/" ] || [ "${OPENGLKHR_SKIP_DEVELOPER_MAC_CHECK:-0}" = "1" ]; then
    exit 0
fi

warning_header="device identified as a developer mac"
warning_body="warning: the driver is currently Indev/WIP and may cause uncertain behaviour"
warning_footer="install at your own responsibility to maintain system stability"

if ! command -v csrutil >/dev/null 2>&1; then
    echo "live install requires csrutil to verify SIP and Authenticated Root state" >&2
    exit 1
fi

sip_status=$(csrutil status 2>&1 || true)
auth_root_status=$(csrutil authenticated-root status 2>&1 || true)

case "$sip_status" in
    *"disabled"*)
        sip_ok=1
        ;;
    *)
        sip_ok=0
        ;;
esac

case "$auth_root_status" in
    *"disabled"*|*"not supported"*|*"unsupported"*)
        auth_root_ok=1
        ;;
    *)
        auth_root_ok=0
        ;;
esac

if [ "$sip_ok" -ne 1 ] || [ "$auth_root_ok" -ne 1 ]; then
    echo "OpenGLKHR live install aborted: /System/Library/Frameworks and /usr/local/lib writes are only allowed for a developer mac with SIP and Authenticated Root disabled." >&2
    echo "Detected SIP status: $sip_status" >&2
    echo "Detected Authenticated Root status: $auth_root_status" >&2
    exit 1
fi

echo "$warning_header"
echo "$warning_body"
echo "$warning_footer"
