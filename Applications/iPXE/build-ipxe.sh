#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build iPXE (UEFI x64 snponly.efi + legacy BIOS ipxe.pxe) with an EMBEDDED
# script that deterministically chainloads the NDT HTTP boot script. This
# removes all dependence on DHCP option 67 / user-class steering (which stock
# iPXE binaries do not reliably honour when chainloaded from WDS).
#
# Run inside WSL (Ubuntu) on IPXE01:
#     bash build-ipxe.sh
#
# Optional args:
#     bash build-ipxe.sh <chain-url> <windows-output-dir>
# Defaults:
#     chain-url          = http://ipxe01.corp.dev/boot/boot.ipxe
#     windows-output-dir = /mnt/c/temp/ipxe-build   (i.e. C:\temp\ipxe-build)
# ---------------------------------------------------------------------------
set -euo pipefail

CHAIN_URL="${1:-http://ipxe01.corp.dev/boot/boot.ipxe}"
OUTDIR="${2:-/mnt/c/temp/ipxe-build}"

echo "==> Installing build dependencies"
sudo apt-get update -y
sudo apt-get install -y git build-essential liblzma-dev perl

echo "==> Cloning iPXE"
rm -rf "$HOME/ipxe"
git clone --depth 1 https://github.com/ipxe/ipxe.git "$HOME/ipxe"
cd "$HOME/ipxe/src"

echo "==> Writing embedded boot script (chain -> $CHAIN_URL)"
cat > embed.ipxe <<EOF
#!ipxe
echo NDT iPXE - embedded boot script
ifopen
dhcp || echo DHCP failed, continuing
echo Chaining ${CHAIN_URL}
chain --replace ${CHAIN_URL} || goto failed
:failed
echo Boot script failed - dropping to iPXE shell
shell
EOF

echo "==> Building UEFI x64 (snponly.efi)"
make -j"$(nproc)" bin-x86_64-efi/snponly.efi EMBED=embed.ipxe

echo "==> Building legacy BIOS (ipxe.pxe)"
make -j"$(nproc)" bin/ipxe.pxe EMBED=embed.ipxe

echo "==> Copying artefacts to $OUTDIR"
mkdir -p "$OUTDIR"
cp bin-x86_64-efi/snponly.efi "$OUTDIR/snponly.efi"
cp bin/ipxe.pxe               "$OUTDIR/ipxe.pxe"

echo ""
echo "DONE. Built with embedded chain to: $CHAIN_URL"
ls -l "$OUTDIR"/snponly.efi "$OUTDIR"/ipxe.pxe
echo ""
echo "Next: on DC01 (or IPXE01), place these into WDS:"
echo "  C:\\temp\\ipxe-build\\snponly.efi -> C:\\RemoteInstall\\Boot\\x64\\snponly.efi  AND  ...\\wdsmgfw.efi"
echo "  C:\\temp\\ipxe-build\\ipxe.pxe    -> C:\\RemoteInstall\\Boot\\x86\\ipxe.pxe"
echo "  then restart the WDSServer service."
