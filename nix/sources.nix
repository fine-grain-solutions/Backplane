# Pins for the official release binaries. nix/update.sh rewrites this from
# GitHub's SHA256SUMS and from the tag's deploy/kistack.lock (repository,
# revision, skills-tree hash, and the fetchFromGitHub hash of that revision).
# The lock names no subpath: the repository root is fetched, and the package
# keeps skills/, LICENSE, and a plugin.json the way scripts/build-kistack.sh does.
{
  version = "0.12.0";
  # deploy/kistack.lock at this tag (github.com/American-Embedded/KiStack).
  kistackOwner = "American-Embedded";
  kistackRepo = "KiStack";
  kistackRevision = "ecf16c119c7ed610f5f251c479b03884b8d98b09";
  # Unpacked fetchFromGitHub hash of kistackRevision.
  kistackHash = "sha256-l0cKAl2Xa8oQfn8e2JfrT8Rv4+UCf1QluRiJYlvrw9I=";
  # skills/ tree hash from that lock, checked as scripts/build-kistack.sh does.
  kistackSkills = "a716adde47ba01cce8e5ed430e93c214bd9954d3f8f430dc69ff3fd148d83fb9";
  platforms = {
    aarch64-linux = {
      dir = "linux-arm64";
      url = "https://github.com/i2cjak/Backplane/releases/download/v0.12.0/backplane-v0.12.0-classic-linux-arm64.tar.gz";
      hash = "sha256-GIyXF//FbkhKpZ+JH64Y0zi0JZRC0XuVTfkmma3YUIY=";
    };
    x86_64-linux = {
      dir = "linux-x64";
      url = "https://github.com/i2cjak/Backplane/releases/download/v0.12.0/backplane-v0.12.0-classic-linux-x64.tar.gz";
      hash = "sha256-TNYU/4VAr9l8jWTgx5TEzqXfmpUPTMyof2yVhgHskTM=";
    };
  };
}
