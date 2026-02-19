#!/bin/bash
# =============================================================================
# build-deb.sh
# Builds the signalsurge-k8s .deb package and generates apt repo index files.
#
# Usage: ./build-deb.sh
# Output: dist/signalsurge-k8s_<version>_all.deb + apt repo files in dist/
# =============================================================================
set -euo pipefail

VERSION="1.0.3"
PKG_NAME="signalsurge-k8s"
ARCH="all"
BUILD_DIR="${PKG_NAME}_${VERSION}_${ARCH}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"

echo "Building ${PKG_NAME} ${VERSION}..."

# Clean previous build
rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# =============================================================================
# Build .deb package
# =============================================================================
mkdir -p "${BUILD_DIR}/DEBIAN"
mkdir -p "${BUILD_DIR}/usr/local/bin"

cat > "${BUILD_DIR}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${VERSION}
Section: admin
Priority: optional
Architecture: ${ARCH}
Depends: curl, ca-certificates
Maintainer: SignalSurge <noreply@signalsurge.com>
Homepage: https://github.com/johan-ferguson-ai/signalsurge-k8s
Description: SignalSurge Kubernetes single-node installer
 Installs a single-node Kubernetes cluster with containerd, Flannel CNI,
 KEDA autoscaler, container registry, StorageClass, and CI service account.
 Designed for on-prem servers running Ubuntu/Debian.
 .
 Commands:
  install-k8s   - Install K8s cluster + registry + CI setup
  reset-k8s     - Tear down everything for a clean re-install
  setup-server  - Initial server setup and provisioning
EOF

cp "${SCRIPT_DIR}/scripts/install-k8s.sh" "${BUILD_DIR}/usr/local/bin/install-k8s"
cp "${SCRIPT_DIR}/scripts/reset-k8s.sh" "${BUILD_DIR}/usr/local/bin/reset-k8s"
cp "${SCRIPT_DIR}/scripts/setup-server.sh" "${BUILD_DIR}/usr/local/bin/setup-server"
chmod 755 "${BUILD_DIR}/usr/local/bin/install-k8s"
chmod 755 "${BUILD_DIR}/usr/local/bin/reset-k8s"
chmod 755 "${BUILD_DIR}/usr/local/bin/setup-server"

dpkg-deb --build "${BUILD_DIR}" "${DIST_DIR}/${BUILD_DIR}.deb"
rm -rf "${BUILD_DIR}"

echo "Built: ${DIST_DIR}/${BUILD_DIR}.deb"

# =============================================================================
# Generate apt repo index files
# =============================================================================
echo "Generating apt repo index..."

cd "${DIST_DIR}"

# Generate Packages file
dpkg-scanpackages --multiversion . /dev/null > Packages
gzip -k -f Packages

# Generate Release file
cat > Release <<EOF
Origin: SignalSurge
Label: SignalSurge K8s Tools
Suite: stable
Codename: stable
Architectures: all amd64
Components: main
Description: SignalSurge Kubernetes installer apt repository
Date: $(date -Ru)
EOF

# Add checksums to Release
{
    echo "MD5Sum:"
    for f in Packages Packages.gz "${BUILD_DIR}.deb"; do
        echo " $(md5sum "$f" | awk '{print $1}') $(wc -c < "$f") $f"
    done
    echo "SHA256:"
    for f in Packages Packages.gz "${BUILD_DIR}.deb"; do
        echo " $(sha256sum "$f" | awk '{print $1}') $(wc -c < "$f") $f"
    done
} >> Release

cd "${SCRIPT_DIR}"

echo ""
echo "============================================"
echo " Build complete"
echo "============================================"
echo ""
echo "Files in dist/:"
ls -lh "${DIST_DIR}"
echo ""
echo "To test locally:"
echo "  dpkg -i ${DIST_DIR}/${BUILD_DIR}.deb"
echo ""
