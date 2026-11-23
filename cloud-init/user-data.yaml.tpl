#cloud-config
# =============================================================================
# VulnServer - cloud-init/user-data.yaml.tpl
#
# Template, not a usable file: generate the real one with
#   ./scripts/cloud/make-cloud-init.sh --repo-url <https url> --out user-data.yaml
#
# Placeholders filled by the generator: repo URL, branch, WireGuard peer,
# install.sh arguments and the bootstrap log path. All of them are validated
# by scripts/cloud/make-cloud-init.sh before rendering.
# =============================================================================
package_update: false
package_upgrade: false
timezone: UTC

write_files:
  - path: /usr/local/sbin/vulnserver-bootstrap
    owner: root:root
    permissions: '0700'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      # Everything is logged; cloud-init's own log only keeps the tail.
      exec > >(tee -a "__BOOTSTRAP_LOG__") 2>&1
      export DEBIAN_FRONTEND=noninteractive

      echo "[cloud-init] starting VulnServer bootstrap $(date -Is)"

      apt-get update -qq
      apt-get install -y -qq git curl ca-certificates

      rm -rf /root/vulnserver
      mkdir -p /root/vulnserver

      REPO_URL="__REPO_URL__"
      case "$REPO_URL" in
          *.tar.gz|*.tgz)
              echo "[cloud-init] downloading tarball"
              curl -fsSL "$REPO_URL" -o /tmp/vulnserver.tar.gz
              tar -xzf /tmp/vulnserver.tar.gz --strip-components=1 -C /root/vulnserver
              rm -f /tmp/vulnserver.tar.gz
              ;;
          *)
              echo "[cloud-init] cloning $REPO_URL"
              git clone --depth 1 --branch "__BRANCH__" "$REPO_URL" /root/vulnserver
              ;;
      esac

      chmod +x /root/vulnserver/scripts/cloud/bootstrap-vm.sh

      # The tunnel is brought up before the lab so 10.8.0.1 exists when
      # Docker publishes Juice Shop.
      PEER="__PEER__" LAB_INSTALL_ARGS="__LAB_ARGS__" \
          /root/vulnserver/scripts/cloud/bootstrap-vm.sh
      echo "[cloud-init] bootstrap finished $(date -Is)"

runcmd:
  - [ bash, /usr/local/sbin/vulnserver-bootstrap ]

final_message: "VulnServer cloud-init finished; see __BOOTSTRAP_LOG__"
