#!/bin/bash

# 设置严格模式，防止脚本在遇到错误时继续执行
set -euo pipefail

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
	# 推荐将 acme.sh 传入的参数重命名为更清晰的局部变量
	local DOMAIN="$1"
	local KEY_FILE="$2"
	# local CERT_FILE="$3" # 未使用
	# local CA_FILE="$4" # 未使用
	local FULLCHAIN_FILE="$5"

	echo "=== 开始部署证书 (Hook: custom) ==="
	echo "域名: ${DOMAIN:-Unknown}"
	echo "密钥: $KEY_FILE"
	echo "证书: $FULLCHAIN_FILE"

	# 验证必要文件
	if [[ -z "$KEY_FILE" || ! -f "$KEY_FILE" ]]; then
		echo "Error: 密钥文件无效或未提供: $KEY_FILE" >&2
		return 1
	fi

	if [[ -z "$FULLCHAIN_FILE" || ! -f "$FULLCHAIN_FILE" ]]; then
		echo "Error: 证书文件无效或未提供: $FULLCHAIN_FILE" >&2
		return 1
	fi

	# --------------------------------------------------------------------------
	# 3. 获取配置文件
	# --------------------------------------------------------------------------
	# 尝试查找配置文件
	# 1. ~/.acme.sh/${DOMAIN}/${DOMAIN}.env (兼容默认安装路径)
	# 2. ~/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.env

	local CONFIG_FILE=""
	local CANDIDATE_FILES=(
		"$HOME/.acme.sh/${DOMAIN}/${DOMAIN}.env"
		"$HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.env"
	)

	for f in "${CANDIDATE_FILES[@]}"; do
		if [[ -f "$f" ]]; then
			CONFIG_FILE="$f"
			break
		fi
	done

	if [[ -z "$CONFIG_FILE" ]]; then
		echo "Warning: 未找到配置文件 ${DOMAIN}.env，跳过部署。" >&2
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

		# 优化解析配置：使用 Bash 内部字符串操作代替 echo | cut (效率更高)
		# SERVER_IP
		local SERVER_IP="${line%%:*}"

		# 剩下的部分 (path:reload_cmd)
		local remaining="${line#*:}"

		# TARGET_DIR
		local TARGET_DIR="${remaining%%:*}"

		# RELOAD_CMD
		local RELOAD_CMD="${remaining#*:}"

		# 严格检查格式：确保有 SERVER_IP 和 TARGET_DIR
		if [[ -z "$SERVER_IP" || -z "$TARGET_DIR" ]]; then
			echo "Warning: 配置行格式错误 (缺少 IP 或路径)，跳过: $line" >&2
			continue
		fi

		echo "--- 正在部署到 $SERVER_IP ---"
		echo "目标路径: $TARGET_DIR"
		echo "重启命令: ${RELOAD_CMD:-无}"

		# 1. 确保目标目录存在
		# 目标路径必须加双引号，防止路径中包含空格
		ssh "root@$SERVER_IP" "mkdir -p \"$TARGET_DIR\"" || {
			echo "Error: 无法在 $SERVER_IP 创建目录 $TARGET_DIR" >&2
			continue
		}

		# 2. 使用 scp 将文件复制到目标机器
		# 建议使用 -o StrictHostKeyChecking=no 确保自动化时不被询问
		# 增加 -p 选项保留时间戳和权限，并确保目标路径加引号
		# 复制密钥 (保持原文件名)
		# 复制证书 (重命名为 域名.fullchain.cer)
		if ! scp -p "$KEY_FILE" "root@$SERVER_IP:\"$TARGET_DIR/\"" ||
			! scp -p "$FULLCHAIN_FILE" "root@$SERVER_IP:\"$TARGET_DIR/${DOMAIN}.fullchain.cer\""; then
			echo "Error: SCP 复制到 $SERVER_IP 失败！" >&2
			continue
		fi
		echo "证书文件已复制到 $SERVER_IP:$TARGET_DIR/"

		# 3. 通过 ssh 执行重启命令
		if [[ -n "$RELOAD_CMD" ]]; then # 使用 [[ ... ]] 增强判断
			# 增强逻辑：如果是 systemctl reload 命令，先检查服务是否存在/运行
			# 仅匹配简单的 "systemctl reload service_name" 格式
			if [[ "$RELOAD_CMD" =~ ^systemctl\ +reload\ +([^[:space:]]+)$ ]]; then
				local _svc="${BASH_REMATCH[1]}"
				echo "检测到 systemctl reload，目标服务: $_svc"
				# 远程执行：确保 $_svc 路径加引号，防止特殊字符
				# 并添加错误检查 (|| { ... })
				ssh "root@$SERVER_IP" "if systemctl is-active --quiet '$_svc'; then $RELOAD_CMD; else echo 'Service $_svc not active, skipping reload.'; fi" || {
					echo "Warning: 远程执行 systemctl reload 命令失败: $RELOAD_CMD" >&2
				}
			else
				# 其他命令直接执行，并添加错误检查
				ssh "root@$SERVER_IP" "$RELOAD_CMD" || {
					echo "Warning: 远程执行命令失败: $RELOAD_CMD" >&2
				}
			fi
			echo "已在 $SERVER_IP 上处理重启命令：$RELOAD_CMD"
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
	# 1. 解析命令行参数
	while [[ $# -gt 0 ]]; do
		case $1 in
		-d | --domain)
			_d="$2"
			shift
			shift
			;;
		-k | --key)
			_k="$2"
			shift
			shift
			;;
		-c | --cert)
			_c="$2"
			shift
			shift
			;;
		-a | --ca)
			_a="$2"
			shift
			shift
			;;
		-f | --fullchain)
			_f="$2"
			shift
			shift
			;;
		*) # 默认第一个位置参数为域名
			if [[ -z "$_d" && ! "$1" =~ ^- ]]; then
				_d="$1"
			fi
			shift
			;;
		esac
	done

	# 2. 如果参数未提供，尝试读取环境变量 (兼容 Hook 协议环境变量)
	_d="${_d:-${Le_Domain:-$DOMAIN}}"
	_k="${_k:-${Le_KeyFile:-$KEY_FILE}}"
	_c="${_c:-${Le_CertFile:-$CERT_FILE}}"
	_a="${_a:-${Le_CaFile:-$CA_FILE}}"
	_f="${_f:-${Le_FullChainFile:-$FULLCHAIN_FILE}}"

	_d="${_d:-${Le_Domain:-${DOMAIN:-}}}"
	_k="${_k:-${Le_KeyFile:-${KEY_FILE:-}}}"
	_c="${_c:-${Le_CertFile:-${CERT_FILE:-}}}"
	_a="${_a:-${Le_CaFile:-${CA_FILE:-}}}"
	_f="${_f:-${Le_FullChainFile:-${FULLCHAIN_FILE:-}}}"

	# 自动查找证书逻辑
	if [[ -n "$_d" ]] && [[ -z "$_k" || -z "$_f" ]]; then
		echo "尝试自动查找证书文件..."
		CANDIDATE_DIRS=(
			"$HOME/.acme.sh/${_d}_ecc"
			"$HOME/.acme.sh/${_d}"
		)

		for dir in "${CANDIDATE_DIRS[@]}"; do
			if [[ -f "$dir/${_d}.key" ]]; then
				# 优先使用 fullchain.cer，其次 fullchain.pem
				_f="" # 重置，确保找到的是fullchain
				if [[ -f "$dir/fullchain.cer" ]]; then
					_f="$dir/fullchain.cer"
				elif [[ -f "$dir/fullchain.pem" ]]; then
					_f="$dir/fullchain.pem"
				fi

				if [[ -n "$_f" ]]; then
					echo "找到证书: $dir"
					_k="$dir/${_d}.key"
					# 如果 acme.sh 的标准文件也存在，可以赋值 (可选)
					# _c="$dir/${_d}.cer"
					# _a="$dir/ca.cer"
					break
				fi
			fi
		done
	fi

	if [[ -z "$_k" || -z "$_f" ]]; then
		echo "Error: 缺少证书文件路径。" >&2
		echo "用法: $0 -d example.com [-k key.pem] [-f fullchain.cer]" >&2
		echo "或者: DOMAIN=example.com $0 (自动查找)" >&2
		exit 1
	fi

	# 将参数传递给自定义函数
	custom_deploy "$_d" "$_k" "$_c" "$_a" "$_f"
	exit $?
fi
