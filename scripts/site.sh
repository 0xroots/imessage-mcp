#!/bin/bash
# Renders the landing page into docs/ (GitHub Pages source).
#   ./scripts/site.sh https://0xroots.github.io/<repo>/ https://github.com/0xroots/<repo>
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 <site-url-with-trailing-slash> <repo-url>" >&2; exit 2; }
site="$1"; repo="$2"
[[ "$site" == https://*/ ]] || { echo "site URL must be https and end with /" >&2; exit 2; }
root="$(cd "$(dirname "$0")/.." && pwd)"
slug="${repo#https://github.com/}"
for f in index.html llms.txt robots.txt sitemap.xml; do
  sed -e "s|{{SITE_URL}}|$site|g" -e "s|{{REPO_URL}}|$repo|g" -e "s|{{REPO_SLUG}}|$slug|g" -e "s|{{LASTMOD}}|$(date +%F)|g" \
    "$root/site/$f" > "$root/docs/$f"
done
cp "$root/site/og.png" "$root/docs/og.png"
touch "$root/docs/.nojekyll"
echo "Rendered docs/ for $site"
