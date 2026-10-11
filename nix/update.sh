#!/usr/bin/env bash
# Rewrite nix/sources.nix from an official GitHub release.
#   nix/update.sh              # latest stable release
#   nix/update.sh v0.11.1      # one tag
# The KiStack owner, repository, rev, and skills hash come from that tag's
# deploy/kistack.lock. The fetchFromGitHub hash is computed with nix.
# Then run `nix fmt` (alejandra).
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tag=${1:-}

if ! command -v python3 >/dev/null 2>&1; then
  echo "update.sh needs python3" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "update.sh needs curl" >&2
  exit 1
fi
if ! command -v nix >/dev/null 2>&1; then
  echo "update.sh needs nix (flakes enabled) to hash KiStack" >&2
  exit 1
fi

if [ -z "$tag" ]; then
  tag=$(
    curl -fsSL https://api.github.com/repos/i2cjak/Backplane/releases/latest |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
  )
fi
case $tag in
  v*) ;;
  *)
    echo "tag must look like v0.11.1 (got $tag)" >&2
    exit 1
    ;;
esac

echo "pinning $tag"
sums=$(curl -fsSL "https://github.com/i2cjak/Backplane/releases/download/${tag}/SHA256SUMS")
kicad=$(curl -fsSL "https://raw.githubusercontent.com/i2cjak/Backplane/${tag}/deploy/kistack.lock")

ROOT="$root" TAG="$tag" SUMS="$sums" KICAD="$kicad" python3 - <<'PY'
import base64, json, os, re, subprocess, textwrap

tag = os.environ["TAG"]
version = tag[1:]
sums = os.environ["SUMS"]
kicad = os.environ["KICAD"]
root = os.environ["ROOT"]
m = re.search(r'^rev ([0-9a-f]{40})$', kicad, re.M)
if not m:
    raise SystemExit("could not find the rev line in that tag's deploy/kistack.lock")
rev = m.group(1)
sm = re.search(r'^skills ([0-9a-f]{64})$', kicad, re.M)
if not sm:
    raise SystemExit("could not find the skills line in that tag's deploy/kistack.lock")
skills = sm.group(1)
um = re.search(r'github\.com/([^/\s]+)/([^/\s),]+)', kicad)
if not um:
    raise SystemExit("could not find a github.com owner/repo in that tag's deploy/kistack.lock")
owner, repo = um.group(1), um.group(2)
if re.search(r'(?m)^(subpath|path) ', kicad):
    raise SystemExit("deploy/kistack.lock names a subpath; nix/update.sh does not fetch one")

expr = f"""
let
  pkgs = import (builtins.getFlake {json.dumps(root)}).inputs.nixpkgs {{ system = builtins.currentSystem; }};
in
pkgs.fetchFromGitHub {{
  owner = {json.dumps(owner)};
  repo = {json.dumps(repo)};
  rev = {json.dumps(rev)};
  hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
}}
"""
proc = subprocess.run(
    [
        "nix",
        "--extra-experimental-features",
        "nix-command flakes",
        "build",
        "--no-link",
        "--impure",
        "--expr",
        expr,
    ],
    capture_output=True,
    text=True,
)
got = re.search(r"got:\s+(sha256-\S+)", proc.stderr + proc.stdout)
if not got:
    raise SystemExit(
        "could not compute the KiStack fetch hash\n" + proc.stderr + proc.stdout
    )
khash = got.group(1)

wanted = {
    "x86_64-linux": ("linux-x64", f"backplane-{tag}-classic-linux-x64.tar.gz"),
    "aarch64-linux": ("linux-arm64", f"backplane-{tag}-classic-linux-arm64.tar.gz"),
}
found = {}
for line in sums.splitlines():
    parts = line.split()
    if len(parts) != 2:
        continue
    digest, name = parts
    for system, (directory, filename) in wanted.items():
        if name == filename:
            raw = bytes.fromhex(digest)
            found[system] = (directory, filename, "sha256-" + base64.b64encode(raw).decode())

missing = [s for s in wanted if s not in found]
if missing:
    raise SystemExit(f"{tag} is missing release archives for: {', '.join(missing)}")

def block(system):
    directory, filename, sri = found[system]
    url = f"https://github.com/i2cjak/Backplane/releases/download/{tag}/{filename}"
    return textwrap.dedent(f"""\
      {system} = {{
        dir = "{directory}";
        url = "{url}";
        hash = "{sri}";
      }};
    """).rstrip()

body = "\n".join(block(s) for s in ("aarch64-linux", "x86_64-linux"))
text = f"""# Pins for the official release binaries. nix/update.sh rewrites this from
# GitHub's SHA256SUMS and from the tag's deploy/kistack.lock (repository,
# revision, skills-tree hash, and the fetchFromGitHub hash of that revision).
# The lock names no subpath: the repository root is fetched, and the package
# keeps skills/, LICENSE, and a plugin.json the way scripts/build-kistack.sh does.
{{
  version = "{version}";
  # deploy/kistack.lock at this tag (github.com/{owner}/{repo}).
  kistackOwner = "{owner}";
  kistackRepo = "{repo}";
  kistackRevision = "{rev}";
  # Unpacked fetchFromGitHub hash of kistackRevision.
  kistackHash = "{khash}";
  # skills/ tree hash from that lock, checked as scripts/build-kistack.sh does.
  kistackSkills = "{skills}";
  platforms = {{
{textwrap.indent(body, "    ")}
  }};
}}
"""
path = os.environ["ROOT"] + "/nix/sources.nix"
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
print(f"wrote {path}")
print(f"version {version}")
print(f"kistack {owner}/{repo} {rev}")
print(f"kistack hash {khash}")
print(f"kistack skills {skills}")
PY

echo "run nix fmt to normalize nix/sources.nix"
