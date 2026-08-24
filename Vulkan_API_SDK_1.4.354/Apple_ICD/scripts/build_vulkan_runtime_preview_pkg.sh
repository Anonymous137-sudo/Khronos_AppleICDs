#!/bin/sh
set -eu

export COPYFILE_DISABLE=1

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=$(git -C "$project_root" rev-parse --show-toplevel)

runtime_source=${AVK143_RUNTIME_SOURCE:-"$repo_root/Vulkan_API_SDK_1.4.354/build/AVK143/runtime-tools-validation2"}
icd_source=${AVK143_ICD_SOURCE:-"$repo_root/Vulkan_API_SDK_1.4.354/build/AVK143/prefix"}
output=${AVK143_RUNTIME_PKG_OUTPUT:-"$repo_root/dist/Vulkan-1.4.354-Preview.pkg"}
version=${AVK143_RUNTIME_PKG_VERSION:-"1.4.354.11"}

for tool in pkgbuild ditto install_name_tool codesign strip python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '%s\n' "$tool is required" >&2
        exit 1
    }
done

required_files="
bin/vulkaninfo
bin/vkcube
lib/libvulkan.1.dylib
lib/libvulkan.dylib
lib/libVkLayer_khronos_validation.dylib
share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json
"
for relative in $required_files; do
    [ -e "$runtime_source/$relative" ] || {
        printf '%s\n' "missing runtime component: $runtime_source/$relative" >&2
        exit 1
    }
done

[ -f "$icd_source/lib/libvulkan_kosmickrisp.dylib" ] || {
    printf '%s\n' "missing freshly built KosmicKrisp ICD" >&2
    exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/avk143-runtime-pkg.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
payload="$work/payload"
prefix="$payload/usr/local"

mkdir -p "$prefix" "$(dirname -- "$output")"
ditto --noextattr --noqtn "$runtime_source" "$prefix"

# Replace the tool-stage ICD with the tested driver build. SPIR-V Tools stays
# private beside the ICD instead of entering the global loader namespace.
mkdir -p "$prefix/lib/avk143" "$prefix/share/vulkan/icd.d"
install -m 0755 "$icd_source/lib/libvulkan_kosmickrisp.dylib" \
    "$prefix/lib/avk143/libvulkan_kosmickrisp.dylib"
if [ -f "$icd_source/lib/libSPIRV-Tools.dylib" ]; then
    install -m 0755 "$icd_source/lib/libSPIRV-Tools.dylib" \
        "$prefix/lib/avk143/libSPIRV-Tools.dylib"
elif [ -f "$icd_source/lib/avk143/libSPIRV-Tools.dylib" ]; then
    install -m 0755 "$icd_source/lib/avk143/libSPIRV-Tools.dylib" \
        "$prefix/lib/avk143/libSPIRV-Tools.dylib"
fi

cat >"$prefix/share/vulkan/icd.d/avk143_kosmickrisp_icd.aarch64.json" <<'EOF'
{
    "file_format_version": "1.0.1",
    "ICD": {
        "library_path": "../../../lib/avk143/libvulkan_kosmickrisp.dylib",
        "api_version": "1.4.359"
    }
}
EOF
rm -f "$prefix/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"

cat >"$prefix/lib/pkgconfig/vulkan.pc" <<'EOF'
prefix=/usr/local
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: Vulkan-Loader
Description: Vulkan Loader
Version: 1.4.360
Libs: -L${libdir} -lvulkan
Cflags: -I${includedir}
EOF

cube_app_source=${AVK143_VKCUBE_APP_SOURCE:-"$repo_root/Vulkan_API_SDK_1.4.354/build/VulkanTools-validation2/tools-build/cube/macOS/cube/vkcube.app"}
if [ -d "$cube_app_source" ]; then
    mkdir -p "$prefix/libexec/VulkanICD_KHR"
    ditto --noextattr --noqtn "$cube_app_source" \
        "$prefix/libexec/VulkanICD_KHR/vkcube.app"
    mkdir -p "$prefix/libexec/VulkanICD_KHR/vkcube.app/Contents/Frameworks"
    install -m 0755 "$prefix/lib/libvulkan.1.dylib" \
        "$prefix/libexec/VulkanICD_KHR/vkcube.app/Contents/Frameworks/libvulkan.1.dylib"
    cube_binary="$prefix/libexec/VulkanICD_KHR/vkcube.app/Contents/MacOS/vkcube"
    while IFS= read -r rpath; do
        case "$rpath" in
            /Users/*)
                install_name_tool -delete_rpath "$rpath" "$cube_binary"
                ;;
        esac
    done <<EOF
$(otool -l "$cube_binary" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
EOF
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$cube_binary"
    cat >"$prefix/bin/vkcube" <<'EOF'
#!/bin/sh
exec /usr/bin/open -W -n /usr/local/libexec/VulkanICD_KHR/vkcube.app --args "$@"
EOF
    chmod 0755 "$prefix/bin/vkcube"
fi

# Remove build-tree search paths while retaining loader-relative lookup.
for binary in "$prefix/bin/vkcube" "$prefix/bin/vulkaninfo"; do
    while IFS= read -r rpath; do
        case "$rpath" in
            /Users/*)
                install_name_tool -delete_rpath "$rpath" "$binary"
                ;;
        esac
    done <<EOF
$(otool -l "$binary" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
EOF
done

find "$prefix" -type f \( -name '*.dylib' -o -perm -0100 \) -print | while IFS= read -r binary; do
    if file "$binary" | grep -q 'Mach-O'; then
        strip -S -x "$binary" 2>/dev/null || true
        # Release builds may retain __FILE__ or generated configuration paths.
        # Replace only NUL-terminated absolute build strings, preserving each
        # Mach-O section's exact byte length.
        python3 - "$binary" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()

def neutralize(match):
    original = match.group(0)
    replacement = b"/usr/local/share/Khronos_AppleICDs/source"
    if b"/etc" in original:
        replacement = b"/usr/local/etc"
    if len(replacement) > len(original):
        replacement = b"/usr/local"
    return replacement + (b"\0" * (len(original) - len(replacement)))

data = re.sub(rb"/Users/[^\0\r\n]{1,2048}", neutralize, data)
data = re.sub(rb"/private/var/folders/[^\0\r\n]{1,2048}", neutralize, data)
path.write_bytes(data)
PY
        codesign --force --sign - --timestamp=none "$binary" >/dev/null
    fi
done
if [ -d "$prefix/libexec/VulkanICD_KHR/vkcube.app" ]; then
    codesign --force --deep --sign - --timestamp=none \
        "$prefix/libexec/VulkanICD_KHR/vkcube.app" >/dev/null
fi

find "$payload" -name '._*' -type f -delete
find "$payload" -name '.DS_Store' -type f -delete
xattr -rc "$payload" 2>/dev/null || true

if grep -R -a -E '/Users/|gitanshchakravarty|/private/var/folders/' "$payload" >/dev/null 2>&1; then
    printf '%s\n' "refusing package: build-machine metadata remains in payload" >&2
    grep -R -a -l -E '/Users/|gitanshchakravarty|/private/var/folders/' "$payload" >&2 || true
    exit 1
fi

pkgbuild \
    --root "$payload" \
    --identifier org.khronos.appleicds.vulkan-runtime-preview \
    --version "$version" \
    --install-location / \
    "$output"

printf '%s\n' "built machine-neutral Vulkan runtime package: $output"
