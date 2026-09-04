#!/usr/bin/env bash
set -euo pipefail

INSTALL_SYSTEM_PACKAGES=1
INSTALL_DOCKER=1
INSTALL_RUST=1
INSTALL_ELIXIR=1
INSTALL_BUN=1
DRY_RUN=0

BUN_VERSION="${ANKOLE_BUN_VERSION:-1.4.1}"
RUST_TOOLCHAIN="${ANKOLE_RUST_TOOLCHAIN:-stable}"
ELIXIR_VERSION="${ANKOLE_ELIXIR_VERSION:-1.20.1-otp-29}"
OTP_MAJOR="${ANKOLE_OTP_MAJOR:-29}"
MISE_BIN="${MISE_BIN:-$HOME/.local/bin/mise}"

usage() {
  cat <<'USAGE'
Usage: env-setup.sh [options]

Installs the host tools needed for Ankole development on Linux and macOS:
system build packages, Docker, Rust, Elixir/Erlang, and Bun.

Options:
  --dry-run              Print commands without running them.
  --no-system-packages   Do not install OS build packages.
  --no-docker            Do not install Docker.
  --no-rust              Do not install Rust.
  --no-elixir            Do not install Elixir/Erlang.
  --no-bun               Do not install Bun.
  -h, --help             Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --no-system-packages | --skip-system-packages)
      INSTALL_SYSTEM_PACKAGES=0
      ;;
    --no-docker | --skip-docker)
      INSTALL_DOCKER=0
      ;;
    --no-rust | --skip-rust)
      INSTALL_RUST=0
      ;;
    --no-elixir | --skip-elixir)
      INSTALL_ELIXIR=0
      ;;
    --no-bun | --skip-bun)
      INSTALL_BUN=0
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

log() {
  printf '[env-setup] %s\n' "$*"
}

warn() {
  printf '[env-setup] WARN: %s\n' "$*" >&2
}

die() {
  printf '[env-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

print_banner() {
  if [[ -t 1 ]]; then
    printf '\033[36m'
  fi
  cat <<'BANNER'

▄▄▄▄                      ▄▄
▄██▀▀██▄       ▄▄           ██
███  ███ ████▄ ██ ▄█▀ ▄███▄ ██ ▄█▀█▄
███▀▀███ ██ ██ ████   ██ ██ ██ ██▄█▀
███  ███ ██ ██ ██ ▀█▄ ▀███▀ ██ ▀█▄▄▄

BANNER
  if [[ -t 1 ]]; then
    printf '\033[0m'
  fi
  printf '  @AgentBull/Ankole · Environment Setup\n\n'
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

run_shell() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ %s\n' "$*"
    return 0
  fi

  bash -lc "$*"
}

run_sudo() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    run "$@"
    return
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    run "$@"
    return
  fi

  command -v sudo >/dev/null 2>&1 || die "sudo is required for system package installation."
  run sudo "$@"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

detect_os() {
  case "$(uname -s)" in
    Darwin)
      echo macos
      ;;
    Linux)
      echo linux
      ;;
    MINGW* | MSYS* | CYGWIN*)
      echo windows
      ;;
    *)
      echo unknown
      ;;
  esac
}

OS="$(detect_os)"
if [[ "${OS}" == "windows" || "${OS}" == "unknown" || "${OS:-}" == "" || "${OS:-}" == "Windows_NT" ]]; then
  warn "Windows is not supported by Ankole devkit env-setup yet. Use macOS, Linux, WSL2, or GitHub Codespaces."
  exit 0
fi

export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$PATH"

print_banner

ensure_homebrew() {
  if have brew; then
    return
  fi

  [[ "$OS" == "macos" ]] || return 0
  log "Installing Homebrew."
  run_shell '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

  [[ "$DRY_RUN" -eq 0 ]] || return

  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

brew_install_missing() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    run brew install "$@"
    return
  fi

  local missing=()
  for package in "$@"; do
    if ! brew list --versions "$package" >/dev/null 2>&1; then
      missing+=("$package")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    run brew install "${missing[@]}"
  fi
}

install_linux_packages() {
  if have apt-get; then
    run_sudo apt-get update
    run_sudo apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      build-essential \
      ca-certificates \
      clang \
      cmake \
      curl \
      fop \
      git \
      libclang-dev \
      libgl1-mesa-dev \
      libglu1-mesa-dev \
      libncurses-dev \
      libpng-dev \
      libreadline-dev \
      libssh-dev \
      libssl-dev \
      libtool \
      libwxgtk3.2-dev \
      libxml2-utils \
      libxslt1-dev \
      libzmq3-dev \
      m4 \
      make \
      openssl \
      pkg-config \
      perl \
      unzip \
      unixodbc-dev \
      xz-utils \
      zlib1g-dev \
      zstd
    return
  fi

  if have dnf; then
    run_sudo dnf groupinstall -y "Development Tools"
    run_sudo dnf install -y \
      autoconf \
      automake \
      clang \
      cmake \
      curl \
      fop \
      git \
      libtool \
      libxslt-devel \
      m4 \
      ncurses-devel \
      openssl-devel \
      perl \
      pkgconf-pkg-config \
      unixODBC-devel \
      unzip \
      wxGTK3-devel \
      xz \
      zeromq-devel \
      zlib-devel
    return
  fi

  if have yum; then
    run_sudo yum groupinstall -y "Development Tools"
    run_sudo yum install -y \
      autoconf \
      automake \
      clang \
      cmake \
      curl \
      fop \
      git \
      libtool \
      libxslt-devel \
      m4 \
      ncurses-devel \
      openssl-devel \
      perl \
      pkgconfig \
      unixODBC-devel \
      unzip \
      wxGTK3-devel \
      xz \
      zeromq-devel \
      zlib-devel
    return
  fi

  if have pacman; then
    run_sudo pacman -Sy --needed --noconfirm \
      autoconf \
      automake \
      base-devel \
      clang \
      cmake \
      curl \
      fop \
      git \
      libtool \
      libxslt \
      ncurses \
      openssl \
      perl \
      pkgconf \
      unixodbc \
      unzip \
      wxwidgets-gtk3 \
      xz \
      zeromq \
      zlib \
      zstd
    return
  fi

  if have zypper; then
    run_sudo zypper --non-interactive install -t pattern devel_basis
    run_sudo zypper --non-interactive install \
      autoconf \
      automake \
      clang \
      cmake \
      curl \
      fop \
      git \
      libopenssl-devel \
      libtool \
      libxslt-devel \
      m4 \
      ncurses-devel \
      pkg-config \
      unixODBC-devel \
      unzip \
      wxWidgets-3_2-devel \
      xz \
      zeromq-devel \
      zlib-devel
    return
  fi

  warn "No supported Linux package manager found. Install compiler, OpenSSL, ncurses, wxWidgets, unixODBC, ZeroMQ, curl, and git manually."
}

install_system_packages() {
  [[ "$INSTALL_SYSTEM_PACKAGES" -eq 1 ]] || return 0

  if [[ "$OS" == "macos" ]]; then
    ensure_homebrew
    log "Installing macOS build packages."
    brew_install_missing autoconf automake cmake curl fop git libtool libxslt openssl@3 pkg-config unixodbc wxwidgets zeromq zstd
    return
  fi

  log "Installing Linux build packages."
  install_linux_packages
}

install_docker() {
  [[ "$INSTALL_DOCKER" -eq 1 ]] || return 0

  if have docker; then
    log "Docker CLI is already installed."
  elif [[ "$OS" == "macos" ]]; then
    ensure_homebrew
    log "Installing Docker Desktop."
    run brew install --cask docker
    warn "Start Docker Desktop once after installation so the Docker daemon is available."
  else
    log "Installing Docker Engine with Docker's Linux installer."
    run_shell 'curl -fsSL https://get.docker.com -o /tmp/ankole-get-docker.sh'
    run_sudo sh /tmp/ankole-get-docker.sh
  fi

  if [[ "$OS" == "linux" && "${EUID:-$(id -u)}" -ne 0 && "$(id -un)" != "root" ]]; then
    if getent group docker >/dev/null 2>&1 && ! id -nG | tr ' ' '\n' | grep -Fxq docker; then
      run_sudo usermod -aG docker "$(id -un)"
      warn "Added $(id -un) to the docker group. Log out and back in before using Docker without sudo."
    fi
  fi

  if have docker && ! docker compose version >/dev/null 2>&1; then
    warn "Docker is installed, but 'docker compose' is not available. Install the Docker Compose plugin before running devkit services."
  fi
}

install_bun() {
  [[ "$INSTALL_BUN" -eq 1 ]] || return 0

  if have bun && [[ "$BUN_VERSION" == "canary" ]] && [[ "$(bun --revision 2>/dev/null)" == *-canary* ]]; then
    log "Bun canary is already installed."
    return
  fi

  if have bun && [[ "$BUN_VERSION" != "canary" ]] && [[ "$(bun --version 2>/dev/null)" == "$BUN_VERSION" ]]; then
    log "Bun $BUN_VERSION is already installed."
    return
  fi

  log "Installing Bun $BUN_VERSION."
  if [[ "$BUN_VERSION" == "canary" ]]; then
    run_shell "BUN_INSTALL=\"$HOME/.bun\" curl -fsSL https://bun.sh/install | bash -s canary"
  else
    run_shell "BUN_INSTALL=\"$HOME/.bun\" curl -fsSL https://bun.sh/install | bash -s \"bun-v$BUN_VERSION\""
  fi
}

install_rust() {
  [[ "$INSTALL_RUST" -eq 1 ]] || return 0

  if ! have rustup; then
    log "Installing Rust through rustup."
    run_shell "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile default --default-toolchain \"$RUST_TOOLCHAIN\""
  else
    log "rustup is already installed."
  fi

  run rustup toolchain install "$RUST_TOOLCHAIN" --profile default --component clippy --component rustfmt
  run rustup default "$RUST_TOOLCHAIN"
  run rustup component add clippy rustfmt
}

install_mise() {
  if have mise || [[ -x "$MISE_BIN" ]]; then
    return
  fi

  log "Installing mise for Erlang/Elixir toolchains."
  run_shell 'curl https://mise.run | sh'
}

resolve_erlang_version() {
  local resolved
  if resolved="$("$MISE_BIN" latest "erlang@$OTP_MAJOR" 2>/dev/null)"; then
    printf '%s\n' "$resolved"
    return
  fi

  printf '%s\n' "${ANKOLE_ERLANG_VERSION:-$OTP_MAJOR.0}"
}

install_elixir() {
  [[ "$INSTALL_ELIXIR" -eq 1 ]] || return 0

  if have elixir && elixir --version 2>/dev/null | grep -Eq "Elixir 1\\.20\\."; then
    log "Elixir 1.20 is already installed."
    write_shell_env
    return
  fi

  install_mise
  local erlang_version
  erlang_version="$(resolve_erlang_version)"

  log "Installing Erlang $erlang_version and Elixir $ELIXIR_VERSION with mise."
  run "$MISE_BIN" plugin install erlang || true
  run "$MISE_BIN" plugin install elixir || true
  run "$MISE_BIN" install "erlang@$erlang_version"
  run "$MISE_BIN" install "elixir@$ELIXIR_VERSION"
  run "$MISE_BIN" use --global "erlang@$erlang_version" "elixir@$ELIXIR_VERSION"
  run "$MISE_BIN" reshim

  write_shell_env
  run mix local.hex --force
  run mix local.rebar --force
}

ensure_profile_block() {
  local file="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ ensure PATH block in %q\n' "$file"
    return
  fi

  mkdir -p "$(dirname "$file")"
  touch "$file"

  if grep -Fq "# >>> ankole-env-setup" "$file"; then
    return
  fi

  cat >>"$file" <<'PROFILE'

# >>> ankole-env-setup
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$PATH"
# <<< ankole-env-setup
PROFILE
}

write_shell_env() {
  for profile in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    ensure_profile_block "$profile"
  done
}

install_system_packages
install_docker
install_rust
install_bun
install_elixir
write_shell_env

log "Environment setup complete. Open a new shell, then run: bun install"
