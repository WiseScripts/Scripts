#!/bin/bash

# ------------------------------------------------------------------------------
# acme.sh Renew Hook Script
# ------------------------------------------------------------------------------
# 此脚本用于配合 acme.sh 的 --renew-hook 使用。
# 当证书更新成功后，acme.sh 会自动调用此脚本。
#
# 用法:
#   自动模式 (由 acme.sh 调用):
#     acme.sh --install-cert -d example.com ... --renew-hook "/path/to/renew-hook.sh"
#
#   手动模式 (通过参数):
#     ./renew-hook.sh -d example.com --key-file /path/to/key --fullchain-file /path/to/cert
# ------------------------------------------------------------------------------

# 设置严格模式，防止脚本在遇到错误时继续执行
set -euo pipefail

# 1. 获取证书路径
# 优先使用命令行参数，其次使用环境变量 (acme.sh 导出)，最后尝试使用已有的环境变量

# 优先级：acme.sh 环境变量 > 手动环境变量 > 空字符串

# 1. 确保环境变量在扩展时不会因为 set -u 而报错。
#    使用 :- 来抑制未定义变量的错误。

# 如果 Le_Domain 已定义，取 Le_Domain 的值；否则，取手动设置的 DOMAIN 的值；
# 如果 DOMAIN 也没定义，取空字符串。
DOMAIN="${Le_Domain:-${DOMAIN:-}}"
KEY_FILE="${Le_KeyFile:-${KEY_FILE:-}}"
FULLCHAIN_FILE="${Le_FullChainFile:-${FULLCHAIN_FILE:-}}"

# 另一种更简洁但效果一样的写法：
# DOMAIN="${Le_Domain:-}"
# DOMAIN="${DOMAIN:-}"

# 但为了保持原有的优先级逻辑，以下写法最能体现原意：
# 优先级: Le_Var > User_Var > ''
_d_hook="${Le_Domain:-}" # 确保 Le_Domain 没定义时不报错
_d_user="${DOMAIN:-}"    # 确保 DOMAIN 没定义时不报错
DOMAIN="${_d_hook:-$_d_user}"

_k_hook="${Le_KeyFile:-}"
_k_user="${KEY_FILE:-}"
KEY_FILE="${_k_hook:-$_k_user}"

_f_hook="${Le_FullChainFile:-}"
_f_user="${FULLCHAIN_FILE:-}"
FULLCHAIN_FILE="${_f_hook:-$_f_user}"

# 解析命令行参数 (覆盖环境变量)
while [[ $# -gt 0 ]]; do
	case "$1" in # 变量加引号是良好习惯
	-d | --domain)
		DOMAIN="$2"
		shift 2
		;;
	-k | --key-file)
		KEY_FILE="$2"
		shift 2
		;;
	-f | --fullchain-file)
		FULLCHAIN_FILE="$2"
		shift 2
		;;
	*)
		echo "Warning: 忽略未知参数: $1" >&2 # 警告输出到 stderr
		shift
		;;
	esac
done

# 自动查找证书逻辑 (用于手动执行)
if [[ -n "$DOMAIN" ]] && [[ -z "$KEY_FILE" || -z "$FULLCHAIN_FILE" ]]; then
	echo "尝试自动查找证书文件..."
	CANDIDATE_DIRS=(
		"$HOME/.acme.sh/${DOMAIN}_ecc"
		"$HOME/.acme.sh/${DOMAIN}"
	)

	for dir in "${CANDIDATE_DIRS[@]}"; do
		if [[ -f "$dir/${DOMAIN}.key" ]]; then
			FULLCHAIN_FILE="" # 重置，确保找到的是fullchain
			if [[ -f "$dir/fullchain.cer" ]]; then
				FULLCHAIN_FILE="$dir/fullchain.cer"
			elif [[ -f "$dir/fullchain.pem" ]]; then
				FULLCHAIN_FILE="$dir/fullchain.pem"
			fi

			if [[ -n "$FULLCHAIN_FILE" ]]; then
				echo "找到证书: $dir"
				KEY_FILE="$dir/${DOMAIN}.key"
				break
			fi
		fi
	done
fi

# 2. 验证参数
if [[ -z "$KEY_FILE" || -z "$FULLCHAIN_FILE" ]]; then
	echo "Error: 缺少证书文件路径。" >&2
	echo "此脚本应由 acme.sh 通过 --renew-hook 调用，或手动设置环境变量 Le_KeyFile 和 Le_FullChainFile。" >&2
	echo "或者手动执行时设置 DOMAIN 环境变量以自动查找。" >&2
	exit 1
fi

if [[ ! -f "$KEY_FILE" ]]; then
	echo "Error: 密钥文件不存在: $KEY_FILE" >&2
	exit 1
fi

if [[ ! -f "$FULLCHAIN_FILE" ]]; then
	echo "Error: 证书文件不存在: $FULLCHAIN_FILE" >&2
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
	echo "Warning: 未找到配置文件 ${DOMAIN}.env，跳过部署。" >&2
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

	# 优化: 使用 Bash 自身的字符串分割 (read -r) 替换 echo | cut，更高效
	# 注意: 这里的 IFS 默认是 ':'，但行首 IFS= read -r line 已经重置为默认，
	# 实际上还是需要通过 cut 或 Bash 内部替换。
	# 为保持清晰度和兼容性，这里使用 Bash 内部替换：

	# SERVER_IP
	SERVER_IP="${line%%:*}"

	# 剩下的部分 (path:reload_cmd)
	remaining="${line#*:}"

	# TARGET_DIR
	TARGET_DIR="${remaining%%:*}"

	# RELOAD_CMD
	RELOAD_CMD="${remaining#*:}"

	# 检查是否成功解析（确保至少有 IP 和 路径）
	# 这是一个更严格的检查，要求行中必须有两个 ':' 分隔符
	if [[ ! "$line" =~ :.*:.* ]]; then
		echo "Warning: 配置行格式错误 (应为 ip:path:reload_cmd)，跳过: $line" >&2
		continue
	fi

	echo "--- 正在部署到 $SERVER_IP ---"
	echo "目标路径: $TARGET_DIR"
	echo "重启命令: ${RELOAD_CMD:-无}"

	# 4.1 确保目标目录存在
	ssh "root@$SERVER_IP" "mkdir -p \"$TARGET_DIR\"" || { # 目标路径加引号防止空格问题
		echo "Error: 无法在 $SERVER_IP 创建目录 $TARGET_DIR" >&2
		continue
	}

	# 4.2 使用 scp 将文件复制到目标机器
	# 建议使用 -o StrictHostKeyChecking=no 确保自动化时不被询问
	# 复制密钥 (保持原文件名)
	# 复制证书 (重命名为 域名.fullchain.cer)
	# 证书文件名使用 "$DOMAIN.fullchain.cer"，确保它不包含 .pem 或 .key 等后缀
	if ! scp -p "$KEY_FILE" "root@$SERVER_IP:\"$TARGET_DIR/\"" || # -p 保持权限和时间戳
		! scp -p "$FULLCHAIN_FILE" "root@$SERVER_IP:\"$TARGET_DIR/${DOMAIN}.fullchain.cer\""; then
		echo "Error: SCP 复制到 $SERVER_IP 失败！" >&2
		continue
	fi
	echo "证书文件已复制到 $SERVER_IP:$TARGET_DIR/"

	# 4.3 通过 ssh 执行重启命令
	if [[ -n "$RELOAD_CMD" ]]; then
		# 增强逻辑：如果是 systemctl reload 命令，先检查服务是否存在/运行
		# 仅匹配简单的 "systemctl reload service_name" 格式
		if [[ "$RELOAD_CMD" =~ ^systemctl\ +reload\ +([^[:space:]]+)$ ]]; then
			_svc="${BASH_REMATCH[1]}"
			echo "检测到 systemctl reload，目标服务: $_svc"
			# 远程执行：检查服务是否 active，是则 reload，否则跳过
			# 注意：这里的 $RELOAD_CMD 在远程执行时需要双引号保护，以防命令本身包含空格
			ssh "root@$SERVER_IP" "if systemctl is-active --quiet '$_svc'; then $RELOAD_CMD; else echo 'Service $_svc not active, skipping reload.'; fi" || {
				echo "Warning: 远程执行命令失败: $RELOAD_CMD" >&2
			}
		else
			# 其他命令直接执行
			ssh "root@$SERVER_IP" "$RELOAD_CMD" || {
				echo "Warning: 远程执行命令失败: $RELOAD_CMD" >&2
			}
		fi
		echo "已在 $SERVER_IP 上处理重启命令：$RELOAD_CMD"
	fi

done <"$CONFIG_FILE"

echo "=== 部署完成 ==="
exit 0
