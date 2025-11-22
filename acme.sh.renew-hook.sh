#!/bin/bash

# ------------------------------------------------------------------------------
# acme.sh Renew Hook Script
# ------------------------------------------------------------------------------
# 此脚本用于配合 acme.sh 的 --renew-hook 使用。
# 当证书更新成功后，acme.sh 会自动调用此脚本。
#
# 用法:
#   acme.sh --install-cert -d example.com \
#     --key-file /path/to/example.com.key \
#     --fullchain-file /path/to/example.com.fullchain.cer \
#     --renew-hook "~/acme.sh/renew-hook.sh"
# ------------------------------------------------------------------------------

# 1. 获取证书路径
# acme.sh 在调用 renew-hook 时会导出以下环境变量
DOMAIN="${Le_Domain:-$DOMAIN}"
KEY_FILE="${Le_KeyFile:-$KEY_FILE}"
FULLCHAIN_FILE="${Le_FullChainFile:-$FULLCHAIN_FILE}"

# 自动查找证书逻辑 (用于手动执行)
if [[ -n "$DOMAIN" ]] && [[ -z "$KEY_FILE" || -z "$FULLCHAIN_FILE" ]]; then
	echo "尝试自动查找证书文件..."
	CANDIDATE_DIRS=(
		"$HOME/.acme.sh/${DOMAIN}_ecc"
		"$HOME/.acme.sh/${DOMAIN}"
	)

	for dir in "${CANDIDATE_DIRS[@]}"; do
		if [[ -f "$dir/${DOMAIN}.key" && -f "$dir/fullchain.cer" ]]; then
			echo "找到证书: $dir"
			KEY_FILE="$dir/${DOMAIN}.key"
			FULLCHAIN_FILE="$dir/fullchain.cer"
			break
		fi
	done
fi

# 2. 验证参数
if [[ -z "$KEY_FILE" || -z "$FULLCHAIN_FILE" ]]; then
	echo "Error: 缺少证书文件路径。"
	echo "此脚本应由 acme.sh 通过 --renew-hook 调用，或手动设置环境变量 Le_KeyFile 和 Le_FullChainFile。"
	echo "或者手动执行时设置 DOMAIN 环境变量以自动查找。"
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

# 3. 获取配置文件
# --------------------------------------------------------------------------
# 尝试查找配置文件
# 1. ~/.acme.sh/${DOMAIN}/${DOMAIN}.env (兼容默认安装路径)
# 2. ~/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.env

CONFIG_FILE=""
CANDIDATE_FILES=(
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
	echo "Warning: 未找到配置文件 ${DOMAIN}.env，跳过部署。"
	echo "请在以下路径之一创建配置文件: ${CANDIDATE_FILES[*]}"
	exit 0
fi

echo "使用配置文件: $CONFIG_FILE"

# 4. 遍历部署
# --------------------------------------------------------------------------
# 读取配置文件每一行
# 格式: ip:path:reload_cmd
while IFS= read -r line || [[ -n "$line" ]]; do
	# 跳过空行和注释
	[[ -z "$line" || "$line" =~ ^# ]] && continue

	# 解析配置
	SERVER_IP=$(echo "$line" | cut -d: -f1)
	TARGET_DIR=$(echo "$line" | cut -d: -f2)
	RELOAD_CMD=$(echo "$line" | cut -d: -f3-)

	if [[ -z "$SERVER_IP" || -z "$TARGET_DIR" ]]; then
		echo "Warning: 配置行格式错误，跳过: $line"
		continue
	fi

	echo "--- 正在部署到 $SERVER_IP ---"
	echo "目标路径: $TARGET_DIR"
	echo "重启命令: ${RELOAD_CMD:-无}"

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

	# 4.3 通过 ssh 执行重启命令
	if [ -n "$RELOAD_CMD" ]; then
		ssh "root@$SERVER_IP" "$RELOAD_CMD"
		echo "已在 $SERVER_IP 上执行重启命令：$RELOAD_CMD"
	fi

done <"$CONFIG_FILE"

echo "=== 部署完成 ==="
exit 0
