#!/bin/sh

# Build a signed apt repository from the .deb files in <site>/pool/main.
#
# usage: APT_SIGNING_KEY="$(cat key.asc)" tools/build-apt-repo.sh <site> <url>
#
# APT_SIGNING_KEY is an ASCII-armored secret key without passphrase. The
# result is a static tree for GitHub Pages: dists/stable (Release, InRelease,
# Release.gpg, Packages for amd64 and arm64), pool/main, the public key as
# pve-fcsan.gpg (binary, for signed-by) and pve-fcsan.asc, and index.html.

set -eu

site=$1
url=$2
suite=stable
archs="amd64 arm64"

[ -n "${APT_SIGNING_KEY:-}" ] || { echo "APT_SIGNING_KEY is not set" >&2; exit 1; }
ls "$site"/pool/main/*.deb >/dev/null 2>&1 || { echo "no .deb files in $site/pool/main" >&2; exit 1; }

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
printf '%s\n' "$APT_SIGNING_KEY" | gpg --batch --quiet --import
fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/ { print $10; exit }')
[ -n "$fpr" ] || { echo "APT_SIGNING_KEY contains no secret key" >&2; exit 1; }

cd "$site"

# pve-fcsan is Architecture: all; list it for every architecture apt asks for
for arch in $archs; do
    dir=dists/$suite/main/binary-$arch
    mkdir -p "$dir"
    apt-ftparchive packages pool > "$dir/Packages"
    gzip -9nkf "$dir/Packages"
done

apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=pve-fcsan \
    -o APT::FTPArchive::Release::Label=pve-fcsan \
    -o APT::FTPArchive::Release::Suite=$suite \
    -o APT::FTPArchive::Release::Codename=$suite \
    -o APT::FTPArchive::Release::Architectures="$archs" \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Description="pve-fcsan for Proxmox VE" \
    release "dists/$suite" > Release.tmp
mv Release.tmp "dists/$suite/Release"

gpg --batch --yes --local-user "$fpr" --digest-algo SHA512 --clearsign \
    -o "dists/$suite/InRelease" "dists/$suite/Release"
gpg --batch --yes --local-user "$fpr" --digest-algo SHA512 --armor --detach-sign \
    -o "dists/$suite/Release.gpg" "dists/$suite/Release"

gpg --batch --export "$fpr" > pve-fcsan.gpg
gpg --batch --armor --export "$fpr" > pve-fcsan.asc
touch .nojekyll

latest=$(sed -n 's/^Version: //p' "dists/$suite/main/binary-amd64/Packages" | sort -V | tail -n 1)

cat > index.html <<EOF
<!doctype html>
<meta charset="utf-8">
<title>pve-fcsan apt repository</title>
<style>body{font:15px/1.5 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}pre{background:#f4f4f4;padding:.75rem;overflow-x:auto}</style>
<h1>pve-fcsan apt repository</h1>
<p>Packages for <a href="https://github.com/${GITHUB_REPOSITORY:-}">pve-fcsan</a>. Latest version: <b>$latest</b>.</p>
<p>On every Proxmox VE node, as root:</p>
<pre>curl -fsSL $url/pve-fcsan.gpg -o /usr/share/keyrings/pve-fcsan.gpg
cat &gt; /etc/apt/sources.list.d/pve-fcsan.sources &lt;&lt;'END'
Types: deb
URIs: $url
Suites: $suite
Components: main
Signed-By: /usr/share/keyrings/pve-fcsan.gpg
END
apt update
apt install pve-fcsan</pre>
<p>Signing key fingerprint: <code>$fpr</code></p>
EOF

echo "signed $suite with $fpr; latest pve-fcsan $latest"
