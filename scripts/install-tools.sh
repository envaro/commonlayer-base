#!/bin/sh
# install-tools.sh - install the pinned tools used by CommonLayer, locally and in CI.
#
# Usage: install-tools.sh [tool|group...]   (default: the group "project")
#   groups: project  the tools of the project scripts (build, test, scan, SBOM,
#                    charts, kind): yq, helm, helm-unittest, kubeconform,
#                    hadolint, shellcheck, trivy, grype, syft, cosign,
#                    helm-docs, kind, kubectl
#           infra    the platform's infrastructure checks: actionlint promtool
#                    tofu tflint k6 gitleaks buf
#           all      both
#
# This file is the one place where tool versions and checksums are recorded,
# for local use and for every workflow.
#
# Every download is verified against a SHA-256 recorded in this file, for the
# exact version recorded here. Nothing is installed when a checksum differs.
# Re-running is cheap: a tool whose recorded version is already installed is
# skipped.
#
# Environment:
#   CL_TOOLS_BIN   install directory (default: $HOME/.local/bin); must be on PATH
#   CL_TOOLS_ARCH  amd64 | arm64 (default: detected)
#
# Where the checksums come from (resolved 2026-11-10):
#   helm          get.helm.sh/<asset>.sha256sum
#   kubeconform   CHECKSUMS of the GitHub release
#   helm-unittest helm-unittest-checksum.sha of the GitHub release
#   trivy, grype, syft, cosign, helm-docs, yq   checksum files of the GitHub release
#   kind          <asset>.sha256sum of the GitHub release
#   hadolint, shellcheck  no checksum file is published for these releases; the
#                 values below were computed from the release assets downloaded
#                 over HTTPS from github.com on 2026-11-10.
#   kubectl       dl.k8s.io/release/v<v>/bin/linux/<arch>/kubectl.sha256 (version
#                 from dl.k8s.io/release/stable.txt; tag checked with git ls-remote)
#   actionlint    actionlint_<v>_checksums.txt
#   promtool      sha256sums.txt (Prometheus release; promtool is in the tarball)
#   tofu          tofu_<v>_SHA256SUMS
#   tflint        checksums.txt
#   k6            k6-v<v>-checksums.txt
#   gitleaks      gitleaks_<v>_checksums.txt
#   buf           sha256.txt
#
# Shared by the CommonLayer platform repository (https://github.com/envaro/commonlayer)
# and every CommonLayer project, which carries it as scripts/install-tools.sh.
# The platform repository keeps the canonical copy; change it there.
set -eu

HELM_VERSION=4.3.1
KUBECONFORM_VERSION=0.8.0
HELM_UNITTEST_VERSION=1.2.1
HADOLINT_VERSION=2.15.1
SHELLCHECK_VERSION=0.11.0
TRIVY_VERSION=0.76.2
GRYPE_VERSION=0.121.3
SYFT_VERSION=1.57.1
COSIGN_VERSION=3.1.4
HELM_DOCS_VERSION=1.14.2
YQ_VERSION=4.54.3
KIND_VERSION=0.33.0
KUBECTL_VERSION=1.37.2
ACTIONLINT_VERSION=1.7.12
PROMETHEUS_VERSION=3.16.0
TOFU_VERSION=1.13.9
TFLINT_VERSION=0.66.0
K6_VERSION=2.3.0
GITLEAKS_VERSION=8.30.1
BUF_VERSION=1.75.0

PROJECT_TOOLS="yq helm helm-unittest kubeconform hadolint shellcheck trivy grype syft cosign helm-docs kind kubectl"
INFRA_TOOLS="actionlint promtool tofu tflint k6 gitleaks buf"
ALL_TOOLS="$PROJECT_TOOLS $INFRA_TOOLS"

bin_dir=${CL_TOOLS_BIN:-$HOME/.local/bin}
stamp_dir="$bin_dir/.commonlayer-tools"

detect_arch() {
	case "$(uname -m)" in
	x86_64 | amd64) echo amd64 ;;
	aarch64 | arm64) echo arm64 ;;
	*) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
	esac
}
arch=${CL_TOOLS_ARCH:-$(detect_arch)}
if [ "$(uname -s)" != "Linux" ]; then
	echo "install-tools.sh supports Linux only; install the versions listed in this file by other means" >&2
	exit 1
fi

# sha <amd64-sha256> <arm64-sha256>
sha() { if [ "$arch" = amd64 ]; then echo "$1"; else echo "$2"; fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

download() { # url sha256 dest
	echo "  fetching $1"
	curl -fsSL --retry 4 --retry-all-errors --proto '=https' -o "$3" "$1"
	echo "$2  $3" | sha256sum -c --quiet - || {
		echo "checksum mismatch for $1" >&2
		exit 1
	}
}

installed() { [ -f "$stamp_dir/$1@$2" ]; }
mark() { mkdir -p "$stamp_dir" && rm -f "$stamp_dir/$1@"* && : > "$stamp_dir/$1@$2"; }

install_bin() { install -m 0755 "$1" "$bin_dir/$2"; }

tool_yq() {
	v=$YQ_VERSION
	installed yq "$v" && return 0
	download "https://github.com/mikefarah/yq/releases/download/v$v/yq_linux_$arch" \
		"$(sha 129534601871538efe0ba4c5e62a34fb1d5f469bcb975c4fddeb467d82974973 89f69310b61b68d1245065a1241d1fc843f7a36cd6103ffd77ad987613bd1b67)" "$tmp/yq"
	install_bin "$tmp/yq" yq && mark yq "$v"
}

tool_helm() {
	v=$HELM_VERSION
	installed helm "$v" && return 0
	download "https://get.helm.sh/helm-v$v-linux-$arch.tar.gz" \
		"$(sha 0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b 8cf8f66ecbc252ac8f7f06cca68aba88508ddfde3a6a34feb1678ad1694b4f88)" "$tmp/helm.tgz"
	tar -xzf "$tmp/helm.tgz" -C "$tmp"
	install_bin "$tmp/linux-$arch/helm" helm && mark helm "$v"
}

tool_helm_unittest() {
	v=$HELM_UNITTEST_VERSION
	installed helm-unittest "$v" && return 0
	command -v helm >/dev/null 2>&1 || tool_helm
	download "https://github.com/helm-unittest/helm-unittest/releases/download/v$v/helm-unittest-linux-$arch-$v.tgz" \
		"$(sha 48e86ecc1467b009630e5954375e5d8494139f73b466df5fe8c04fa45b634939 c66062713cd3cbb1a80d7098bd1d4a48db8438f56b43fb6377df65447f93f8de)" "$tmp/hu.tgz"
	plugins=$("$bin_dir/helm" env HELM_PLUGINS 2>/dev/null || helm env HELM_PLUGINS)
	dest="$plugins/helm-unittest"
	rm -rf "$dest"
	mkdir -p "$dest"
	tar -xzf "$tmp/hu.tgz" -C "$dest"
	# The release archive carries plugin.yaml and the binaries; its install and
	# update hooks would download the binary again, and their scripts are not in
	# the archive, so drop them. platformHooks is the last key of plugin.yaml.
	if [ -f "$dest/plugin.yaml" ]; then
		sed -i -E '/^(platformHooks|hooks):/,$d' "$dest/plugin.yaml"
	fi
	mark helm-unittest "$v"
}

tool_kubeconform() {
	v=$KUBECONFORM_VERSION
	installed kubeconform "$v" && return 0
	download "https://github.com/yannh/kubeconform/releases/download/v$v/kubeconform-linux-$arch.tar.gz" \
		"$(sha 9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883 1f53fc8e81258197a35e8603054162a5af1de8c5af13746c71ab680d9534ed87)" "$tmp/kc.tgz"
	tar -xzf "$tmp/kc.tgz" -C "$tmp" kubeconform
	install_bin "$tmp/kubeconform" kubeconform && mark kubeconform "$v"
}

tool_hadolint() {
	v=$HADOLINT_VERSION
	installed hadolint "$v" && return 0
	a=x86_64; [ "$arch" = arm64 ] && a=arm64
	download "https://github.com/hadolint/hadolint/releases/download/v$v/hadolint-linux-$a" \
		"$(sha c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507 f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d)" "$tmp/hadolint"
	install_bin "$tmp/hadolint" hadolint && mark hadolint "$v"
}

tool_shellcheck() {
	v=$SHELLCHECK_VERSION
	installed shellcheck "$v" && return 0
	a=x86_64; [ "$arch" = arm64 ] && a=aarch64
	download "https://github.com/koalaman/shellcheck/releases/download/v$v/shellcheck-v$v.linux.$a.tar.xz" \
		"$(sha 8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588)" "$tmp/sc.tar.xz"
	tar -xJf "$tmp/sc.tar.xz" -C "$tmp"
	install_bin "$tmp/shellcheck-v$v/shellcheck" shellcheck && mark shellcheck "$v"
}

tool_trivy() {
	v=$TRIVY_VERSION
	installed trivy "$v" && return 0
	a=64bit; [ "$arch" = arm64 ] && a=ARM64
	download "https://github.com/aquasecurity/trivy/releases/download/v$v/trivy_${v}_Linux-$a.tar.gz" \
		"$(sha bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf ab9d51f86e6a5fb936f605faff6b593ac51bc378fff4d3e8b9d58358b9c367c3)" "$tmp/trivy.tgz"
	tar -xzf "$tmp/trivy.tgz" -C "$tmp" trivy
	install_bin "$tmp/trivy" trivy && mark trivy "$v"
}

tool_grype() {
	v=$GRYPE_VERSION
	installed grype "$v" && return 0
	download "https://github.com/anchore/grype/releases/download/v$v/grype_${v}_linux_$arch.tar.gz" \
		"$(sha e9da18cc1429e786722e32161288103600efffd8e483c90761f90485bd1bec85 b7815598d48da78bfd16f5b98ef28e1bb09c03d34fc8c3e350f99b6ccb3c7cba)" "$tmp/grype.tgz"
	tar -xzf "$tmp/grype.tgz" -C "$tmp" grype
	install_bin "$tmp/grype" grype && mark grype "$v"
}

tool_syft() {
	v=$SYFT_VERSION
	installed syft "$v" && return 0
	download "https://github.com/anchore/syft/releases/download/v$v/syft_${v}_linux_$arch.tar.gz" \
		"$(sha bf52519eb57f675d47c07d43213cb6dff6449f3d6d1147ff6701ed91f44eef0c aa3d3e07344f590bcce8d31043b752daa76c8a56c2aa34ceeee63c6168152582)" "$tmp/syft.tgz"
	tar -xzf "$tmp/syft.tgz" -C "$tmp" syft
	install_bin "$tmp/syft" syft && mark syft "$v"
}

tool_cosign() {
	v=$COSIGN_VERSION
	installed cosign "$v" && return 0
	download "https://github.com/sigstore/cosign/releases/download/v$v/cosign-linux-$arch" \
		"$(sha 424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2)" "$tmp/cosign"
	install_bin "$tmp/cosign" cosign && mark cosign "$v"
}

tool_helm_docs() {
	v=$HELM_DOCS_VERSION
	installed helm-docs "$v" && return 0
	a=x86_64; [ "$arch" = arm64 ] && a=arm64
	download "https://github.com/norwoodj/helm-docs/releases/download/v$v/helm-docs_${v}_Linux_$a.tar.gz" \
		"$(sha a8cf72ada34fad93285ba2a452b38bdc5bd52cc9a571236244ec31022928d6cc c3787212332386dcd122debef7848feb165aa701467ae3e3442df7638f3ac4e4)" "$tmp/hd.tgz"
	tar -xzf "$tmp/hd.tgz" -C "$tmp" helm-docs
	install_bin "$tmp/helm-docs" helm-docs && mark helm-docs "$v"
}

tool_kind() {
	v=$KIND_VERSION
	installed kind "$v" && return 0
	download "https://github.com/kubernetes-sigs/kind/releases/download/v$v/kind-linux-$arch" \
		"$(sha aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d 20022bee6cfcd5086cb7234d218e3454e6090022f2a8f55d1fa7fcf42c3867a2)" "$tmp/kind"
	install_bin "$tmp/kind" kind && mark kind "$v"
}

tool_kubectl() {
	v=$KUBECTL_VERSION
	installed kubectl "$v" && return 0
	download "https://dl.k8s.io/release/v$v/bin/linux/$arch/kubectl" \
		"$(sha c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4 fcc16f63186659d9722014b7e02d5fdd2d4e669cb8c0ab66365d7d3b8ba03509)" "$tmp/kubectl"
	install_bin "$tmp/kubectl" kubectl && mark kubectl "$v"
}

tool_actionlint() {
	v=$ACTIONLINT_VERSION
	installed actionlint "$v" && return 0
	download "https://github.com/rhysd/actionlint/releases/download/v$v/actionlint_${v}_linux_$arch.tar.gz" \
		"$(sha 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6)" "$tmp/al.tgz"
	tar -xzf "$tmp/al.tgz" -C "$tmp" actionlint
	install_bin "$tmp/actionlint" actionlint && mark actionlint "$v"
}

tool_promtool() {
	v=$PROMETHEUS_VERSION
	installed promtool "$v" && return 0
	download "https://github.com/prometheus/prometheus/releases/download/v$v/prometheus-$v.linux-$arch.tar.gz" \
		"$(sha 68727009472a2c02e1ff7f062fd5b3e637285bffc8fc2d340c76fb449d6e0f34 fd8571b8162f4020232d886f17340bcf92e1722985ae3b4c1d096157826c0fbe)" "$tmp/prom.tgz"
	tar -xzf "$tmp/prom.tgz" -C "$tmp" "prometheus-$v.linux-$arch/promtool"
	install_bin "$tmp/prometheus-$v.linux-$arch/promtool" promtool && mark promtool "$v"
}

tool_tofu() {
	v=$TOFU_VERSION
	installed tofu "$v" && return 0
	download "https://github.com/opentofu/opentofu/releases/download/v$v/tofu_${v}_linux_$arch.tar.gz" \
		"$(sha b34b327cc1ef07178207b6f2cd1f5276537d3e5b7be316500f6dac50d4c0a857 5dc196dde75b667e4806d358310ec96742774cd0993c54c1237efee5644b69b8)" "$tmp/tofu.tgz"
	tar -xzf "$tmp/tofu.tgz" -C "$tmp" tofu
	install_bin "$tmp/tofu" tofu && mark tofu "$v"
}

tool_tflint() {
	v=$TFLINT_VERSION
	installed tflint "$v" && return 0
	download "https://github.com/terraform-linters/tflint/releases/download/v$v/tflint_linux_$arch.zip" \
		"$(sha 22be11cadc25cd02401e94c0ccc91aa63467debb8485c2a755d98f4c0a9d1e2e 1105a0a5ddee7cdac7957a3475571a946b839192ea1bc0c722c6c4686001067e)" "$tmp/tflint.zip"
	(cd "$tmp" && unzip -q -o tflint.zip tflint)
	install_bin "$tmp/tflint" tflint && mark tflint "$v"
}

tool_k6() {
	v=$K6_VERSION
	installed k6 "$v" && return 0
	download "https://github.com/grafana/k6/releases/download/v$v/k6-v$v-linux-$arch.tar.gz" \
		"$(sha 39c3117b6af817592dcd0ce4242105c0a7af10948c2a425306f0be8f7a8a8ab1 5ca3433e8201da72a284aaa241a1bb5fb47f4abb4e384d39410ddd8062f49b90)" "$tmp/k6.tgz"
	tar -xzf "$tmp/k6.tgz" -C "$tmp" "k6-v$v-linux-$arch/k6"
	install_bin "$tmp/k6-v$v-linux-$arch/k6" k6 && mark k6 "$v"
}

tool_gitleaks() {
	v=$GITLEAKS_VERSION
	installed gitleaks "$v" && return 0
	a=x64; [ "$arch" = arm64 ] && a=arm64
	download "https://github.com/gitleaks/gitleaks/releases/download/v$v/gitleaks_${v}_linux_$a.tar.gz" \
		"$(sha 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080)" "$tmp/gl.tgz"
	tar -xzf "$tmp/gl.tgz" -C "$tmp" gitleaks
	install_bin "$tmp/gitleaks" gitleaks && mark gitleaks "$v"
}

tool_buf() {
	v=$BUF_VERSION
	installed buf "$v" && return 0
	a=x86_64; [ "$arch" = arm64 ] && a=aarch64
	download "https://github.com/bufbuild/buf/releases/download/v$v/buf-Linux-$a" \
		"$(sha fad1e38d6909bbb583a4da81d8c02a01046e2cd663bde7e337dd24277393764b 00eb190aa82df17f393e05b04889cc60a0b13b3259d336e21a87d5f23ab4fd26)" "$tmp/buf"
	install_bin "$tmp/buf" buf && mark buf "$v"
}

mkdir -p "$bin_dir"
case ":$PATH:" in
*":$bin_dir:"*) ;;
*) echo "note: $bin_dir is not on PATH; add it (export PATH=\"$bin_dir:\$PATH\")" >&2 ;;
esac

if [ -n "${GITHUB_PATH:-}" ]; then echo "$bin_dir" >> "$GITHUB_PATH"; fi

[ $# -gt 0 ] || set -- project
tools=""
for t in "$@"; do
	case "$t" in
	project) tools="$tools $PROJECT_TOOLS" ;;
	infra) tools="$tools $INFRA_TOOLS" ;;
	all) tools="$tools $ALL_TOOLS" ;;
	*) tools="$tools $t" ;;
	esac
done
for t in $tools; do
	case " $ALL_TOOLS " in
	*" $t "*) ;;
	*) echo "unknown tool: $t (known: $ALL_TOOLS; groups: project infra all)" >&2; exit 2 ;;
	esac
	echo "==> $t"
	"tool_$(echo "$t" | tr '-' '_')"
done
echo "tools installed in $bin_dir"
