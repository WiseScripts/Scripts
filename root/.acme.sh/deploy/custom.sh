#!/usr/bin/bash

# 设置严格模式，防止脚本在遇到错误时继续执行
# -e: 遇到非零退出状态立即退出
# -u: 引用未定义变量时报错
# -o pipefail: 管道中任何命令失败，整个管道即失败
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
#      ~/.acme.sh/deploy/custom.sh -d example.com
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

  # 定义日志文件
  local LOG_FILE=""
  local EXPLICIT_LOG_FILE=""
  local HOST="*"

  # 根据参数数量设置可选参数
  
  # 检查是否有第6个参数 (EXPLICIT_LOG_FILE)
  if [[ "$#" -ge 6 ]]; then
    EXPLICIT_LOG_FILE="$6"
  fi
  
  # 检查是否有第7个参数 (HOST)
  if [[ "$#" -ge 7 ]]; then
    HOST="$7"
  fi

  if [[ -n "$EXPLICIT_LOG_FILE" ]]; then
    # 如果第6个参数不为空，则使用它
    LOG_FILE="$EXPLICIT_LOG_FILE"
  else
    # 否则，使用默认的、与域名相关的日志路径
    local DOMAIN_FOLDER="$DOMAIN"
    if [ -d "$HOME/.acme.sh/${DOMAIN}_ecc" ]; then
      DOMAIN_FOLDER="${DOMAIN}_ecc"
    fi
    # 注意：这里的 LOG_FILE 定义应该指向 $HOME/.acme.sh/domain_folder/domain.log
    # 原始逻辑是 $HOME/.acme.sh/${DOMAIN_FOLDER}/${DOMAIN}.log
    LOG_FILE="$HOME/.acme.sh/${DOMAIN_FOLDER}/${DOMAIN}.log"
  fi

  # 确保日志文件存在
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  # 日志函数
  log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
  }

  log "=== 开始部署证书 (Hook: custom) ==="
  log "域名: ${DOMAIN:-Unknown}"
  log "密钥: $KEY_FILE"
  log "证书: $FULLCHAIN_FILE"

  # 验证必要文件
  if [[ -z "$KEY_FILE" || ! -f "$KEY_FILE" ]]; then
    log "Error: 密钥文件无效或未提供: $KEY_FILE"
    return 1
  fi

  if [[ -z "$FULLCHAIN_FILE" || ! -f "$FULLCHAIN_FILE" ]]; then
    log "Error: 证书文件无效或未提供: $FULLCHAIN_FILE"
    return 1
  fi

  # 计算本地证书哈希 (MD5)
  local LOCAL_HASH
  if command -v md5sum >/dev/null 2>&1; then
    LOCAL_HASH=$(md5sum "$FULLCHAIN_FILE" | awk '{print $1}')
  else
    # Fallback to openssl if md5sum is missing (e.g. macOS)
    LOCAL_HASH=$(openssl dgst -md5 "$FULLCHAIN_FILE" | awk '{print $2}')
  fi
  log "本地证书哈希: $LOCAL_HASH"

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
    "$HOME/.acme.sh/custom.env"
  )

  for f in "${CANDIDATE_FILES[@]}"; do
    if [[ -f "$f" ]]; then
      CONFIG_FILE="$f"
      break
    fi
  done

  if [[ -z "$CONFIG_FILE" ]]; then
    log "Warning: 未找到配置文件 ${DOMAIN}.env，跳过部署。"
    log "请在以下路径之一创建配置文件: ${CANDIDATE_FILES[*]}"
    return 0
  fi

  log "使用配置文件: $CONFIG_FILE"
  log "--------------------------------------------------------------------------"

  # 核心修改：使用 cat 打印文件内容，并通过 log 函数写入日志
  # 注意：我们用 sed 过滤掉注释行和空行，只打印有效配置。
  # 确保文件内容打印完毕后，文件指针能够关闭，不影响后续的 while 循环。
#  cat "$CONFIG_FILE" | grep -v '^\s*#' | grep -v '^\s*$' | while IFS= read -r line; do
#      log "$line" # 这会在日志和标准输出中打印配置行
#  done
#  log "--------------------------------------------------------------------------"

  # 核心修改：将有效配置行读入一个数组
  local CONFIG_LINES=()

  # 使用唯一的 while read 循环从文件中读取所有数据
  while IFS= read -r line || [[ -n "$line" ]]; do
      # 跳过空行和注释
      if [[ -z "$line" || "$line" =~ ^# ]]; then
          continue
      fi

      # 将有效配置行添加到数组
      CONFIG_LINES+=("$line")

      # 打印到日志和标准输出，满足您的打印需求
      log "$line"
  done <"$CONFIG_FILE"
  log "--------------------------------------------------------------------------"

  # 如果数组为空，说明配置文件是空的
  if [ ${#CONFIG_LINES[@]} -eq 0 ]; then
      log "Warning: 配置文件中没有发现有效的部署配置行，跳过部署。"
      return 0
  fi

  # --------------------------------------------------------------------------
  # 4. 遍历部署
  # --------------------------------------------------------------------------
  # 读取配置文件每一行
  # 格式: ip:path:reload_cmd
  # while IFS= read -r line || [[ -n "$line" ]]; do
  # 跳过空行和注释
  # [[ -z "$line" || "$line" =~ ^# ]] && continue
  for line in "${CONFIG_LINES[@]}"; do

    # 优化解析配置：使用 Bash 内部字符串操作代替 echo | cut (效率更高)
    # HOST_OR_IP
    local HOST_OR_IP="${line%%:*}"

    # 剩下的部分 (path:reload_cmd)
    local remaining="${line#*:}"

    # TARGET_DIR
    local TARGET_DIR="${remaining%%:*}"

    # RELOAD_CMD
    local RELOAD_CMD="${remaining#*:}"

    # 严格检查格式：确保有 HOST_OR_IP 和 TARGET_DIR
    if [[ -z "$HOST_OR_IP" || -z "$TARGET_DIR" ]]; then
      log "Warning: 配置行格式错误 (缺少 IP 或路径)，跳过: $line"
      continue
    fi

    log "=========================================================================="
    log "准备部署 $HOST_OR_IP"
    # 如果指定了 Host 则仅部署 Host，其他跳过
    if [[ -n "$HOST" ]] && [[ "$HOST" != "$HOST_OR_IP" ]]; then
        log "跳过部署 $HOST_OR_IP (用户指定目标为: $HOST)"
        log "完成部署 $HOST_OR_IP" # 这里的“完成”指配置行的处理完成
        log "=========================================================================="
        continue # 跳到下一个配置行
    fi
    # ----------------------------------------------------------------------
    # 哈希检查逻辑
    # ----------------------------------------------------------------------
    local NEED_DEPLOY=true
    local REMOTE_HASH=""

    # 获取远程文件哈希
    # 使用 ssh 执行 md5sum，如果文件不存在则会报错，我们捕获它
    # 注意: 远程机器也需要有 md5sum 命令
    REMOTE_HASH=$(ssh "root@$HOST_OR_IP" "md5sum \"$TARGET_DIR/${DOMAIN}.fullchain.cer\" 2>/dev/null" | awk '{print $1}') || true

    if [[ -n "$REMOTE_HASH" ]]; then
      if [[ "$LOCAL_HASH" == "$REMOTE_HASH" ]]; then
        log "远程证书哈希匹配 ($REMOTE_HASH)，无需更新。"
        NEED_DEPLOY=false
      else
        log "远程证书哈希不匹配 (远程: $REMOTE_HASH vs 本地: $LOCAL_HASH)，准备更新..."
      fi
    else
      log "远程证书不存在或无法获取哈希，准备首次部署..."
    fi

    if [[ "$NEED_DEPLOY" == "false" ]]; then
      log "完成部署 $HOST_OR_IP"
      log "=========================================================================="
      continue
    fi

    # ----------------------------------------------------------------------
    # 执行部署
    # ----------------------------------------------------------------------
    log "目标路径: $TARGET_DIR"
    log "重启命令: ${RELOAD_CMD:-无}"

    # 1. 确保目标目录存在
    # 目标路径必须加双引号，防止路径中包含空格
    ssh "root@$HOST_OR_IP" "mkdir -p \"$TARGET_DIR\"" || {
      log "Error: 无法在 $HOST_OR_IP 创建目录 $TARGET_DIR"
      continue
    }

    # 2. 使用 scp 将文件复制到目标机器
    # 建议使用 -o StrictHostKeyChecking=no 确保自动化时不被询问
    # 增加 -p 选项保留时间戳和权限，并确保目标路径加引号
    # 复制密钥 (保持原文件名)
    # 复制证书 (重命名为 域名.fullchain.cer)
    if ! scp -p "$KEY_FILE" "root@$HOST_OR_IP:$TARGET_DIR/" ||
      ! scp -p "$FULLCHAIN_FILE" "root@$HOST_OR_IP:$TARGET_DIR/${DOMAIN}.fullchain.cer"; then
      log "Error: SCP 复制到 $HOST_OR_IP 失败！"
      continue
    fi
    log "证书文件已复制到 $HOST_OR_IP:$TARGET_DIR/"

    # 3. 通过 ssh 执行重启命令
    if [[ -n "$RELOAD_CMD" ]]; then # 使用 [[ ... ]] 增强判断
      # 仅匹配简单的 "systemctl reload service_name" 格式
      if [[ "$RELOAD_CMD" =~ ^systemctl\ +reload\ +([^[:space:]]+)$ ]]; then
        local _svc="${BASH_REMATCH[1]}"
        local _ssh_cmd=""

        log "检测到 systemctl reload，目标服务: $_svc"

        # 增强逻辑：如果是 systemctl reload 命令，先检查服务是否存在/运行
        # 远程执行逻辑 (Bash 命令串):
        _ssh_cmd="
          SVC='$_svc';
          RELOAD_CMD='$RELOAD_CMD';
          # 1. 检查服务是否活跃
          if systemctl is-active --quiet \"\$SVC\"; then
            echo \"Service \$SVC is active. Executing reload...\";
            \$RELOAD_CMD;
            CMD_EXEC=\"reload\";
          # 2. 如果不活跃，则尝试执行 restart (以确保服务启动)
          elif systemctl is-enabled --quiet \"\$SVC\"; then
            echo \"Service \$SVC is inactive but enabled. Executing restart...\";
            systemctl restart \"\$SVC\";
            CMD_EXEC=\"restart\";
          else
            echo \"Service \$SVC is not active or not enabled. Skipping action.\";
            CMD_EXEC=\"skipped\";
          fi;
          exit_code=\$?;
          echo \"CMD_EXEC:\$CMD_EXEC\"; # 打印一个标记用于本地脚本解析
          exit \$exit_code;
        "

        # 远程执行，并捕获输出
        REMOTE_OUTPUT=$(ssh "root@$HOST_OR_IP" "$_ssh_cmd" 2>&1)
        SSH_STATUS=$?

        # 解析远程输出，查找 CMD_EXEC 标记
        ACTUAL_ACTION=$(echo "$REMOTE_OUTPUT" | grep 'CMD_EXEC:' | tail -n 1 | cut -d: -f2)

        if [[ $SSH_STATUS -ne 0 ]]; then
          log "Error: 远程执行 systemctl 命令失败 (return Code $SSH_STATUS)!"
          log "$REMOTE_OUTPUT"
        elif [[ "$ACTUAL_ACTION" == "skipped" ]]; then
          log "Warning: Service $_svc 在 $HOST_OR_IP 上未运行，操作已跳过。"
        else
          log "成功在 $HOST_OR_IP 上执行 systemctl $ACTUAL_ACTION $_svc"
        fi

      else
        # 其他命令（非 systemctl reload）直接执行
        ssh "root@$HOST_OR_IP" "$RELOAD_CMD" || {
          log "Warning: 远程执行命令失败: $RELOAD_CMD"
        }
        log "已在 $HOST_OR_IP 上执行命令：$RELOAD_CMD"
      fi
    fi

    log "完成部署 $HOST_OR_IP"
    log "=========================================================================="

  done <"$CONFIG_FILE"

  log "=== 部署完成 ==="
  return 0
}

# ------------------------------------------------------------------------------
# 脚本入口点 (Main Logic)
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 脚本入口点 (Main Logic)
# ------------------------------------------------------------------------------

main() {
  # 情况 A: Renew Hook 模式 (无参数调用)
  # acme.sh 在 renew 时会导出环境变量并执行脚本 (eval)，但不传递参数
  if [[ $# -eq 0 ]]; then
    # 尝试从环境变量获取 (兼容 acme.sh 导出的变量名)
    # issue/renew 成功后 export: CERT_KEY_PATH, CERT_FULLCHAIN_PATH, Le_Domain

    local _d="${Le_Domain:-${DOMAIN:-}}"
    local _k="${CERT_KEY_PATH:-${Le_KeyFile:-${KEY_FILE:-}}}"
    local _f="${CERT_FULLCHAIN_PATH:-${Le_FullChainFile:-${FULLCHAIN_FILE:-}}}"

    # 辅助变量 (CA 和 Cert 暂时用不到，但为了完整性)
    local _c="${CERT_PATH:-${Le_CertFile:-${CERT_FILE:-}}}"
    local _a="${CA_CERT_PATH:-${Le_CaFile:-${CA_FILE:-}}}"

    if [[ -n "$_d" && -n "$_k" && -n "$_f" ]]; then
      echo "=== 检测到 Renew Hook 调用模式 ==="
      custom_deploy "$_d" "$_k" "$_c" "$_a" "$_f"
      return $?
    fi

    # 如果既没有参数，环境变量也不全，则打印帮助
    echo "Error: 未提供参数，且未检测到完整的 acme.sh 环境变量。" >&2
    echo "用法:" >&2
    echo "  1. Deploy Hook: acme.sh --deploy -d example.com --deploy-hook custom" >&2
    echo "  2. Renew Hook:  (由 acme.sh 自动调用)" >&2
    echo "  3. 手动执行:    $0 -d example.com [-k key] [-f fullchain] 或 $0 -d *" >&2
    return 1
  fi

  # 情况 B: 手动执行模式 (有参数调用)
  local _d="" _k="" _c="" _a="" _f="" _h=""

  # 1. 解析命令行参数
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -d | --domain)
      _d="$2"
      shift 2
      ;;
    -k | --key)
      _k="$2"
      shift 2
      ;;
    -c | --cert)
      _c="$2"
      shift 2
      ;;
    -a | --ca)
      _a="$2"
      shift 2
      ;;
    -f | --fullchain)
      _f="$2"
      shift 2
      ;;
    -h | --host)
      _h="$2"
      shift 2
      ;;
    *) # 默认第一个位置参数为域名
      if [[ -z "$_d" && ! "$1" =~ ^- ]]; then
        _d="$1"
      else
        echo "Warning: 忽略未知参数: $1" >&2
      fi
      shift
      ;;
    esac
  done

  # --- [新增的遍历逻辑块开始] ---
  # 2. 检查是否为 '遍历所有' 模式
  # 触发条件：
  # 1. 确保参数 _d 非空。
  # 2. 确保参数 _d 长度小于 4。
  if [[ -n "$_d" ]] && [[ "${#_d}" -lt 4 ]]; then

    echo "=== 警告：触发 '遍历所有域名' 模式 (参数: $_d) ==="
    echo "此操作将尝试重新部署 acme.sh 目录下所有已签发的证书。"

    # --- Y/N 确认循环 ---
    while true; do
        read -r -p "是否继续部署所有证书? [y/N]: " confirm_action
        case "$confirm_action" in
            [Yy]* )
                break ;; # 确认，退出循环继续执行
            [Nn]* | "" )
                echo "操作已取消。"
                return 0 ;; # 取消，返回成功退出
            * )
                echo "输入无效，请输入 'y' 或 'n'。" ;;
        esac
    done
    # --- Y/N 确认循环结束 ---

    # set -x # 启用调试模式，打印所有执行的命令
    echo "DEBUG: 当前 \$HOME 路径为: $HOME"

    local ACME_HOME="${HOME}/.acme.sh"
    if [[ ! -d "$ACME_HOME" ]] && [[ -d "/root/.acme.sh" ]]; then
        ACME_HOME="/root/.acme.sh"
        echo "DEBUG: \$HOME 路径可能不正确，已矫正 ACME_HOME 为: $ACME_HOME"
    fi
    echo "DEBUG: 最终 ACME_HOME 路径为: $ACME_HOME"

    if [[ ! -d "$ACME_HOME" ]]; then
        echo "Error: 无法找到 acme.sh 根目录: $ACME_HOME" >&2
        return 1
    fi

    local total_count=0
    local success_count=0

    # 定义统一日志文件路径
    local GLOBAL_LOG_FILE="$HOME/.acme.sh/custom.log" # <--- 新增日志变量
    local HOST="$_h" # <--- 新增主机变量

    # 使用 for 循环遍历
    for dir in "$ACME_HOME"/*/; do
      if [[ ! -d "$dir" ]]; then
          continue
      fi

      local base_name
      base_name=$(basename "${dir%/}")

      # 排除非证书目录
      if [[ "$base_name" == "deploy" || "$base_name" == "acme.sh" || "$base_name" =~ ^\. ]]; then
        continue
      fi

      # --- 关键修复点 ---
      # 1. 从目录名 (base_name) 中提取纯域名 (domain_name)
      local domain_name
      # 移除 _ecc 或 _rsa 后缀
      if [[ "$base_name" =~ _ecc$ ]]; then
          domain_name="${base_name%_ecc}"
      elif [[ "$base_name" =~ _rsa$ ]]; then
          domain_name="${base_name%_rsa}"
      else
          # 目录名就是纯域名 (非 ecc/rsa 目录，如 acme.sh 默认的 rsa 目录)
          domain_name="$base_name"
      fi
      # --- 修复点结束 ---

      echo "DEBUG: 正在检查目录: $base_name -> 域名: $domain_name"

      # 检查是否为一个有效的证书目录结构
      # 使用 domain_name 来构造正确的私钥路径
      local key_path="$dir$domain_name.key"
      local fullchain_path=""

      if [[ -f "$key_path" ]]; then
        echo "DEBUG: 找到私钥文件: $key_path"

        # 尝试查找 fullchain 文件
        if [[ -f "$dir/fullchain.cer" ]]; then
          fullchain_path="$dir/fullchain.cer"
        elif [[ -f "$dir/fullchain.pem" ]]; then
          fullchain_path="$dir/fullchain.pem"
        fi

        if [[ -n "$fullchain_path" ]]; then
          echo "DEBUG: 找到完整链文件: $fullchain_path"
          echo "--- 正在部署域名: $domain_name ---"

          total_count=$((total_count + 1))

          # 调用部署函数，注意这里传递的域名是 domain_name
          if custom_deploy "$domain_name" "$key_path" "" "" "$fullchain_path" "$GLOBAL_LOG_FILE" "$HOST"; then
             success_count=$((success_count + 1))
          fi
        else
          echo "DEBUG: 未找到 fullchain.cer 或 fullchain.pem，忽略目录: $base_name"
        fi
      else
        echo "DEBUG: 未找到私钥文件 $domain_name.key，忽略目录: $base_name"
      fi
    done

    # set +x # 禁用调试模式
    echo "DEBUG: total_count=$total_count, success_count=$success_count"
    echo "=== 遍历部署完成。成功 $success_count/$total_count 个域名。==="

    if [[ "$total_count" -gt 0 && "$success_count" -eq "$total_count" ]]; then
      return 0
    else
      return 1
    fi
  fi

  # 如果不是 * 模式，则继续执行单域名逻辑
  # --- [新增的遍历逻辑块结束] ---


  # 3. 尝试补全缺失的参数 (环境变量或自动查找)
  # 如果不是 * 模式，则继续执行单域名逻辑
  _d="${_d:-${Le_Domain:-${DOMAIN:-}}}"

  # 如果指定了域名但没指定文件，尝试自动查找
  if [[ -n "$_d" ]] && [[ -z "$_k" || -z "$_f" ]]; then
    echo "尝试自动查找证书文件..."
    local CANDIDATE_DIRS=(
      "$HOME/.acme.sh/${_d}_ecc"
      "$HOME/.acme.sh/${_d}"
    )

    for dir in "${CANDIDATE_DIRS[@]}"; do
      if [[ -f "$dir/${_d}.key" ]]; then
        # 优先使用 fullchain.cer，其次 fullchain.pem
        local _found_f=""
        if [[ -f "$dir/fullchain.cer" ]]; then
          _found_f="$dir/fullchain.cer"
        elif [[ -f "$dir/fullchain.pem" ]]; then
          _found_f="$dir/fullchain.pem"
        fi

        if [[ -n "$_found_f" ]]; then
          echo "找到证书: $dir"
          _k="${_k:-$dir/${_d}.key}"
          _f="${_f:-$_found_f}"
          break
        fi
      fi
    done
  fi

  # 4. 最终验证
  if [[ -z "$_d" ]]; then
    echo "Error: 必须指定域名 (-d domain.com 或 -d \"*\")" >&2
    return 1
  fi

  if [[ -z "$_k" || -z "$_f" ]]; then
    echo "Error: 缺少证书文件路径。" >&2
    echo "请使用 -k 和 -f 指定，或确保 acme.sh 目录结构标准以供自动查找。" >&2
    return 1
  fi

  # 5. 调用部署函数 (单域名)
  custom_deploy "$_d" "$_k" "$_c" "$_a" "$_f" "" "$_h"
  return $?
}

# 只有当脚本被直接执行时才运行 main
# 当被 acme.sh source 时 (Deploy Hook)，不会执行 main，只会加载 custom_deploy 函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
  exit $?
fi
