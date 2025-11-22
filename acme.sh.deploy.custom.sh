#!/bin/bash

# ------------------------------------------------------------------------------
# acme.sh Custom Deploy Hook: custom
# ------------------------------------------------------------------------------
# 此脚本用于配合 acme.sh 的 --deploy-hook custom 使用。
# 它会自动读取 acme.sh 导出的环境变量，或者接受命令行参数。
#
# 用法:
#   1. 安装 Hook:
#      将此脚本复制到 ~/.acme.sh/deploy/custom.sh
#
#   2. 使用 Hook:
#      acme.sh --deploy -d example.com --deploy-hook custom
#
#   3. 手动测试:
#      KEY_FILE="..." FULLCHAIN_FILE="..." ~/.acme.sh/deploy/custom.sh
# ------------------------------------------------------------------------------

# acme.sh 钩子函数
# 函数名必须是: 文件名(去掉后缀, -替换为_)_deploy
custom_deploy() {
  local _domain="$1"
  local _key="$2"
  local _cert="$3"
  local _ca="$4"
  local _fullchain="$5"

  echo "=== 开始部署证书 (Hook: custom) ==="
  echo "域名: ${_domain:-Unknown}"
  echo "密钥: $_key"
  echo "证书: $_fullchain"

  # 验证必要文件
  if [[ -z "$_key" || ! -f "$_key" ]]; then
    echo "Error: 密钥文件无效或未提供。"
    return 1
  fi

  if [[ -z "$_fullchain" || ! -f "$_fullchain" ]]; then
    echo "Error: 证书文件无效或未提供。"
    return 1
  fi

  # --------------------------------------------------------------------------
  # 服务器配置
  # --------------------------------------------------------------------------
  declare -A SERVER_CONFIG
  SERVER_CONFIG["103.214.22.46"]="nginx:/etc/letsencrypt" # IP:服务:路径
  #SERVER_CONFIG["162.216.115.92"]="nginx:/etc/letsencrypt" # IP:服务:路径

  # --------------------------------------------------------------------------
  # 遍历部署
  # --------------------------------------------------------------------------
  for SERVER_IP in "${!SERVER_CONFIG[@]}"; do
    # 提取目标服务和路径
    local CONFIG_STRING="${SERVER_CONFIG[$SERVER_IP]}"
    local SERVER_TYPE="${CONFIG_STRING%%:*}"
    local TARGET_DIR="${CONFIG_STRING##*:}"
    local RELOAD_CMD=""

    echo "--- 正在部署到 $SERVER_IP ($SERVER_TYPE) ---"

    # 1. 确保目标目录存在
    ssh "root@$SERVER_IP" "mkdir -p $TARGET_DIR" || {
      echo "无法在 $SERVER_IP 创建目录 $TARGET_DIR"
      continue
    }

    # 2. 使用 scp 将文件复制到目标机器
    # 建议使用 -o StrictHostKeyChecking=no 确保自动化时不被询问
    # 复制密钥 (保持原文件名)
    # 复制证书 (重命名为 域名.fullchain.cer)
    if ! scp "$_key" "root@$SERVER_IP:$TARGET_DIR/" ||
      ! scp "$_fullchain" "root@$SERVER_IP:$TARGET_DIR/${_domain}.fullchain.cer"; then
      echo "SCP 复制到 $SERVER_IP 失败！"
      continue
    fi

    # 2. 根据服务器类型执行不同的重启命令
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

    # 3. 通过 ssh 执行重启命令
    if [ -n "$RELOAD_CMD" ]; then
      ssh "root@$SERVER_IP" "$RELOAD_CMD"
      echo "已在 $SERVER_IP 上执行重启命令：$RELOAD_CMD"
    fi
  done

  echo "=== 部署完成 ==="
  return 0
}

# ------------------------------------------------------------------------------
# 手动执行兼容层
# ------------------------------------------------------------------------------
# 如果脚本被直接执行（而不是被 source），则手动调用函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # 优先使用环境变量，兼容手动运行
  _d="${Le_Domain:-$DOMAIN}"
  _k="${Le_KeyFile:-$KEY_FILE}"
  _c="${Le_CertFile:-$CERT_FILE}"
  _ca="${Le_CaFile:-$CA_FILE}"
  _f="${Le_FullChainFile:-$FULLCHAIN_FILE}"

  if [[ -z "$_k" || -z "$_f" ]]; then
    echo "Error: 缺少证书文件路径。"
    echo "用法: KEY_FILE=... FULLCHAIN_FILE=... $0"
    exit 1
  fi

  custom_deploy "$_d" "$_k" "$_c" "$_ca" "$_f"
  exit $?
fi
