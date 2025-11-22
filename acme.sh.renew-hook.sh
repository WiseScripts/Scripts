#!/bin/bash

# ------------------------------------------------------------------------------
# acme.sh Renew Hook Script
# ------------------------------------------------------------------------------
# 此脚本用于配合 acme.sh 的 --renew-hook 使用。
# 当证书更新成功后，acme.sh 会自动调用此脚本。
#
# 用法:
#   acme.sh --install-cert -d example.com \
#     --key-file /path/to/key.pem \
#     --fullchain-file /path/to/fullchain.pem \
#     --renew-hook "/path/to/renew-hook.sh"
# ------------------------------------------------------------------------------

# 1. 获取证书路径
# acme.sh 在调用 renew-hook 时会导出以下环境变量
DOMAIN="${Le_Domain:-$DOMAIN}"
KEY_FILE="${Le_KeyFile:-$KEY_FILE}"
FULLCHAIN_FILE="${Le_FullChainFile:-$FULLCHAIN_FILE}"

# 2. 验证参数
if [[ -z "$KEY_FILE" || -z "$FULLCHAIN_FILE" ]]; then
  echo "Error: 缺少证书文件路径。"
  echo "此脚本应由 acme.sh 通过 --renew-hook 调用，或手动设置环境变量 Le_KeyFile 和 Le_FullChainFile。"
  exit 1
fi

if [[ ! -f "$KEY_FILE" ]]; then
  echo "Error: 密钥文件不存在: $KEY_FILE"
  exit 1
fi

if [[ ! -f "$FULLCHAIN_FILE" ]]; then
  echo "Error: 证书文件不存在: $FULLCHAIN_FILE"
  exit 1
fi

echo "=== 开始部署证书 (Renew Hook) ==="
echo "域名: ${DOMAIN:-Unknown}"
echo "密钥: $KEY_FILE"
echo "证书: $FULLCHAIN_FILE"

# 3. 服务器配置
# --------------------------------------------------------------------------
declare -A SERVER_CONFIG
SERVER_CONFIG["103.214.22.46"]="nginx:/etc/letsencrypt" # IP:服务:路径
#SERVER_CONFIG["162.216.115.92"]="nginx:/etc/letsencrypt" # IP:服务:路径

# 4. 遍历部署
# --------------------------------------------------------------------------
for SERVER_IP in "${!SERVER_CONFIG[@]}"; do
  # 提取目标服务和路径
  CONFIG_STRING="${SERVER_CONFIG[$SERVER_IP]}"
  SERVER_TYPE="${CONFIG_STRING%%:*}"
  TARGET_DIR="${CONFIG_STRING##*:}"
  RELOAD_CMD=""

  echo "--- 正在部署到 $SERVER_IP ($SERVER_TYPE) ---"

  # 4.1 确保目标目录存在
  ssh "root@$SERVER_IP" "mkdir -p $TARGET_DIR" || {
    echo "无法在 $SERVER_IP 创建目录 $TARGET_DIR"
    continue
  }

  # 4.2 使用 scp 将文件复制到目标机器
  # 建议使用 -o StrictHostKeyChecking=no 确保自动化时不被询问
  # 复制密钥 (保持原文件名)
  # 复制证书 (重命名为 域名.fullchain.cer)
  if ! scp "$KEY_FILE" "root@$SERVER_IP:$TARGET_DIR/" ||
    ! scp "$FULLCHAIN_FILE" "root@$SERVER_IP:$TARGET_DIR/${DOMAIN}.fullchain.cer"; then
    echo "SCP 复制到 $SERVER_IP 失败！"
    continue
  fi

  # 4.3 根据服务器类型执行不同的重启命令
  case "$SERVER_TYPE" in
  nginx)
    RELOAD_CMD="systemctl reload nginx"
    ;;
  apache)
    RELOAD_CMD="systemctl reload httpd"
    ;;
  *)
    echo "未知服务类型，跳过重启。"
    ;;
  esac

  # 4.3 通过 ssh 执行重启命令
  if [ -n "$RELOAD_CMD" ]; then
    ssh "root@$SERVER_IP" "$RELOAD_CMD"
    echo "已在 $SERVER_IP 上执行重启命令：$RELOAD_CMD"
  fi
done

echo "=== 部署完成 ==="
exit 0
