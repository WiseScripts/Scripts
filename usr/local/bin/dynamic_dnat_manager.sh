#!/bin/bash
# 动态 DNAT FORWARD 规则管理器 (无注释、极简版)

LOG_FILE="/var/log/dynamic_dnat_manager.log"

# --- 1. 获取必要的运行时参数 ---

SOURCE_IP=$(echo "$SSH_CLIENT" | awk '{ print $1 }')

if [ -z "$SOURCE_IP" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Manager: Missing SOURCE_IP (SSH_CLIENT empty)." >> "$LOG_FILE"
    exit 1
fi

CURRENT_USER=$(whoami)

# --- 2. 规则解析和添加函数 (移除注释) ---
get_target_rules() {

    sudo /sbin/iptables-save -t nat |
    grep --no-filename '^-A PREROUTING.*-j DNAT' |
    while read -r RULE_LINE; do

        # 解析 IP/Port
        TARGET_IP=$(echo "$RULE_LINE" | sed -n 's/.*--to-destination \([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/p')
        DPORT=$(echo "$RULE_LINE" | sed -n 's/.*--dport \([^[:space:]]*\).*/\1/p')

        if [ -z "$TARGET_IP" ] || [ -z "$DPORT" ]; then continue; fi
        if [[ "$TARGET_IP" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.) ]]; then continue; fi

        # 构造动态端口选项
        if [[ "$DPORT" == *":"* ]]; then
            PORT_OPTIONS="-m multiport --dports $DPORT"
        else
            PORT_OPTIONS="--dport $DPORT"
        fi

        # 构造 DROP 规则 (黑名单，移除 --comment)
        DROP_CMD="/sbin/iptables -I FORWARD 1 -p tcp ! -s $SOURCE_IP -d $TARGET_IP $PORT_OPTIONS -j DROP"

        echo "$DROP_CMD"

    done
}


# --- 3. 清理旧 IP 规则函数 (移除注释依赖，基于目标/否定模式删除) ---
cleanup_old_rules() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Attempting to clean old dynamic rules based on destination/negation pattern." >> "$LOG_FILE"

    # 1. 从 NAT 表中提取所有 DNAT 规则的目标信息 (目标IP, 端口)
    sudo /sbin/iptables-save -t nat |
    grep --no-filename '^-A PREROUTING.*-j DNAT' |
    while read -r RULE_LINE; do

        TARGET_IP=$(echo "$RULE_LINE" | sed -n 's/.*--to-destination \([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/p')
        DPORT=$(echo "$RULE_LINE" | sed -n 's/.*--dport \([^[:space:]]*\).*/\1/p')

        if [ -z "$TARGET_IP" ] || [ -z "$DPORT" ]; then continue; fi
        if [[ "$TARGET_IP" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.) ]]; then continue; fi

        # 2. 构造用于匹配 iptables -nL 输出的模式 (目标IP + 端口)
        # 我们查找 DROP 规则，并且必须有 '!' (否定模式)，以及匹配的目标 IP 和端口。

        # 警告：这个 GREP 模式会匹配所有针对此目标和端口的 'DROP' 和 '!' 规则。
        MATCH_PATTERN_L="DROP.*!.*$TARGET_IP.*$DPORT"

        # 3. 查找并删除匹配的规则
        sudo /sbin/iptables -L FORWARD -n --line-numbers |
        grep -E "$MATCH_PATTERN_L" |
        tac |
        awk '{print $1}' |
        while read NUM; do
            echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] Deleting rule number $NUM matching target $TARGET_IP:$DPORT." >> "$LOG_FILE"
            sudo /sbin/iptables -D FORWARD $NUM 2>/dev/null
        done

    done

    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Old dynamic rules cleaned." >> "$LOG_FILE"
}

# --- 4. 检查当前 IP 是否已存在 (沿用极简检查) ---
check_current_ip_exists() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] Checking for existing rules for IP: $SOURCE_IP" >> "$LOG_FILE"

    # 目标：检查 iptables-save 中是否存在 ! -s <SOURCE_IP>/32 规则。
    MATCH_PATTERN="! -s ${SOURCE_IP}/32"

    if sudo /sbin/iptables-save -t filter |
        grep --no-filename '^-A FORWARD' |
        grep -q -- "$MATCH_PATTERN"; then

        RESULT=0 # 找到匹配当前 IP 排除模式的规则 -> 幂等性成功
    else
        RESULT=1 # 未找到 -> 需要清理和添加
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] Check pattern: $MATCH_PATTERN" >> "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] Check result for $SOURCE_IP: $RESULT" >> "$LOG_FILE"
    return $RESULT
}


# ==========================================================
# 主执行逻辑
# ==========================================================

echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Login detected. Source IP: $SOURCE_IP" >> "$LOG_FILE"

if check_current_ip_exists; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SKIP] Rules for $SOURCE_IP already exist. Skipping add operation." >> "$LOG_FILE"

else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ACTION] IP changed or first login. Cleaning old rules and adding new ones." >> "$LOG_FILE"

    cleanup_old_rules

    GENERATED_COMMANDS=$(get_target_rules)

    echo "$GENERATED_COMMANDS" | while read -r COMMAND_LINE; do

        if [ -z "$COMMAND_LINE" ]; then continue; fi

        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $COMMAND_LINE" >> "$LOG_FILE"

        eval sudo "$COMMAND_LINE"

        RESULT=$?
        echo "$(date '+%Y-%m-%d %H:%M:%S') [EXEC] Added: $COMMAND_LINE (Status: $RESULT)" >> "$LOG_FILE"
    done
fi

exit 0




