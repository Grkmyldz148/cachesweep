#!/bin/bash
# Deploy the landing (docs/) to Cloudflare Pages.
#
# Build steps (applied to a temp copy — docs/ stays dev-friendly):
#   1. CSS is inlined into index.html (<style>), removing the only
#      render-blocking request. Relative url("../img/…") refs are rewritten
#      to be root-relative since the CSS moves into the document.
#   2. JS files are referenced as `file?v=<content-hash>`: Pages deploys do
#      NOT purge the custom-domain zone cache, so assets carry immutable
#      1-year TTLs and bust by hash (index.html itself is max-age=0).
#
# Usage: Scripts/deploy-site.sh
set -euo pipefail
cd "$(dirname "$0")/../docs"

BUILD=$(mktemp -d /tmp/cachesweep-site.XXXXXX)
trap 'rm -rf "$BUILD"' EXIT
cp -R . "$BUILD/"

# 1. inline the stylesheet
python3 - "$BUILD" <<'EOF'
import re, sys
build = sys.argv[1]
html = open(f'{build}/index.html').read()
css = open(f'{build}/assets/css/site.css').read()
css = css.replace('url("../', 'url("assets/')
html, n = re.subn(
    r'<link rel="stylesheet" href="assets/css/site\.css[^"]*" />',
    '<style>\n' + css + '\n</style>', html)
assert n == 1, f'stylesheet link not found (n={n})'
open(f'{build}/index.html', 'w').write(html)
print('css inlined')
EOF

# 2. hash-stamp the JS
stamp() {
  local file="$1"
  local hash
  hash=$(md5 -q "$BUILD/assets/$file" | cut -c1-8)
  sed -i '' -E "s|assets/$file(\?v=[a-f0-9]*)?|assets/$file?v=$hash|g" "$BUILD/index.html"
}
stamp "js/liquid-glass.js"
stamp "js/main.js"
grep -o 'assets/js/[a-z-]*\.js?v=[a-f0-9]*' "$BUILD/index.html"

npx --yes wrangler pages deploy "$BUILD" --project-name cachesweep --branch main --commit-dirty=true
