# acme.sh 自定义脚本使用指南

本文档介绍了如何使用自定义的 Deploy Hook (custom) 和 Renew Hook (renew-hook.sh)，以及配置 SSH 免密登录。

## 1. 配置文件说明 (Dynamic Config)

脚本从域名对应的 `.env` 文件中读取配置。

**文件路径优先级：**

1. `~/.acme.sh/example.com/example.com.env`
2. `~/.acme.sh/example.com_ecc/example.com.env`

**文件格式：** 每行定义一个目标服务器，格式为 `IP:目标路径:重启命令`。

```
# IP:Path:Command
1.2.3.4:/etc/letsencrypt:systemctl reload nginx
5.6.7.8:/etc/letsencrypt:systemctl reload nginx
```

## 2. SSH 配置教程

为了让脚本能自动部署，必须配置 SSH 免密登录。

### 2.1 配置公钥登录

1. **生成密钥对** (如果还没有)：

   ```
   ssh-keygen -t ed25519 -C "your_email@example.com"
   
   # 提示输入 passphrase 时，推荐设置密码以提高安全性
   ```

2. **上传公钥到目标服务器**：

   ```
   ssh-copy-id -i ~/.ssh/id_ed25519.pub root@1.2.3.4
   ```

### 2.2 使用带密码的私钥 (Keychain & SSH Agent)

如果您的私钥设置了密码 (Passphrase)，脚本运行时会卡住等待输入密码。使用 `ssh-agent` 和 `keychain` 可以解决这个问题。

1. **启动 ssh-agent**：

   ```
   eval "$(ssh-agent -s)"
   ```

2. **添加私钥到 agent** (macOS/Linux)：

   ```
   # macOS (将密码存入 Keychain)
   ssh-add --apple-use-keychain ~/.ssh/id_ed25519
   
   # Linux (普通添加)
   ssh-add ~/.ssh/id_ed25519
   ```

3. **配置 `~/.ssh/config` 自动使用 Keychain** (macOS 推荐)： 编辑 `~/.ssh/config` 文件，添加：

   ```
   Host *
     UseKeychain yes
     AddKeysToAgent yes
     IdentityFile ~/.ssh/id_ed25519
   ```

### 2.3 配置目标主机别名 (`~/.ssh/config`)

为了简化 `.env` 配置和管理连接参数（如端口、用户、特定密钥），建议配置 `~/.ssh/config`。

**示例配置：**

```
# ~/.ssh/config


# 目标服务器 1
Host server1
    HostName 1.2.3.4
    User root
    Port 22
    IdentityFile ~/.ssh/id_ed25519

# 目标服务器 2 (非标准端口)
Host server2
    HostName 5.6.7.8
    User root
    Port 2222
    IdentityFile ~/.ssh/id_rsa_legacy
```

**配合脚本使用：**

配置好别名后，`.env` 文件中可以直接使用别名代替 IP：

```
# HostAlias:Path:Command
server1:/etc/letsencrypt:systemctl reload nginx
server2:/etc/letsencrypt:systemctl reload nginx
```

## 3. Deploy Hook (custom)

用于 `acme.sh --deploy` 命令，支持手动触发部署。

### 安装

```
# 必须重命名为 custom.sh 以匹配函数名 custom_deploy
cp ~/custom.sh ~/.acme.sh/deploy/custom.sh
chmod +x ~/.acme.sh/deploy/custom.sh
```

### 使用 (新证书或更新配置)

```
acme.sh --deploy -d example.com --deploy-hook custom
```

## 4. Renew Hook (renew-hook.sh)

用于 `acme.sh --install-cert` 或 `--issue` 命令，在证书自动更新后触发。

### 安装

无需特定安装位置，建议放在安全目录：

```sh
chmod +x ~/renew-hook.sh
```

### 使用 (新证书或更新配置)

在安装证书时指定 `--renew-hook`：

```sh
acme.sh --install-cert -d example.com \
  --key-file /path/to/key.pem \
  --fullchain-file /path/to/fullchain.pem \
  --renew-hook "~/renew-hook.sh"
```

## 5. 验证与测试

### 手动测试 (推荐)

支持直接使用命令行参数，或仅指定域名自动查找证书：

```
# 方式 1: 仅指定域名 (自动查找证书)
~/.acme.sh/deploy/custom.sh -d example.com
~/renew-hook.sh -d example.com

# 方式 2: 指定完整路径
~/.acme.sh/deploy/custom.sh -d example.com -k /path/to/key.pem -f /path/to/cert.pem
~/renew-hook.sh -d example.com -k /path/to/key.pem -f /path/to/cert.pem
```
