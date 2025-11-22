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
	# 3. 获取配置文件
	# --------------------------------------------------------------------------
	# 尝试查找配置文件
	# 1. ~/.acme.sh/${_domain}/${_domain}.env (兼容默认安装路径)
	# 2. ~/.acme.sh/${_domain}_ecc/${_domain}.env

	local CONFIG_FILE=""
	local CANDIDATE_FILES=(
		"$HOME/.acme.sh/${_domain}/${_domain}.env"
		"$HOME/.acme.sh/${_domain}_ecc/${_domain}.env"
	)

	for f in "${CANDIDATE_FILES[@]}"; do
		if [[ -f "$f" ]]; then
			CONFIG_FILE="$f"
			break
		fi
	done

	if [[ -z "$CONFIG_FILE" ]]; then
		echo "Warning: 未找到配置文件 ${_domain}.env，跳过部署。"
		echo "请在以下路径之一创建配置文件: ${CANDIDATE_FILES[*]}"
		return 0
	fi

	echo "使用配置文件: $CONFIG_FILE"

	# --------------------------------------------------------------------------
	# 4. 遍历部署
	# --------------------------------------------------------------------------
	# 读取配置文件每一行
	# 格式: ip:path:reload_cmd
	while IFS= read -r line || [[ -n "$line" ]]; do
		# 跳过空行和注释
		[[ -z "$line" || "$line" =~ ^# ]] && continue

		# 解析配置
		local SERVER_IP=$(echo "$line" | cut -d: -f1)
		local TARGET_DIR=$(echo "$line" | cut -d: -f2)
		local RELOAD_CMD=$(echo "$line" | cut -d: -f3-)

		if [[ -z "$SERVER_IP" || -z "$TARGET_DIR" ]]; then
			echo "Warning: 配置行格式错误，跳过: $line"
			continue
		fi

		echo "--- 正在部署到 $SERVER_IP ---"
		echo "目标路径: $TARGET_DIR"
		echo "重启命令: ${RELOAD_CMD:-无}"

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

		# 3. 通过 ssh 执行重启命令
		if [ -n "$RELOAD_CMD" ]; then
			ssh "root@$SERVER_IP" "$RELOAD_CMD"
			echo "已在 $SERVER_IP 上执行重启命令：$RELOAD_CMD"
		fi

	done <"$CONFIG_FILE"

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
