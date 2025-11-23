# ACME 证书部署 Hook 脚本使用教程

该脚本 (`custom.sh`) 旨在实现证书的**集中式管理**和**自动化跨服务器部署**，兼容 `acme.sh` 的 `deploy-hook` 和 `renew-hook` 两种模式。

## 📄 脚本功能概览

- **核心功能：** 通过 SSH/SCP 将证书私钥 (`.key`) 和完整链文件 (`.fullchain.cer`) 自动部署到多个目标服务器。
- **配置方式：** 从一个单独的配置文件 (`[DOMAIN].env`) 中读取目标服务器的 IP、路径和重启命令。
- **智能重启：** 自动检测 `systemctl reload` 命令，并在服务未运行时升级为 `systemctl restart`，保证服务在线。
- **多模式兼容：** 支持 `acme.sh` 自动调用（无参）和手动命令行调用（带参）。
- **自动查找：** 在手动调用时，能自动查找 `~/.acme.sh` 目录下的证书文件。

------

## 第一步：配置免密登录

**这是无人交互部署的关键！** 

确保中心 VPS 可以对所有目标 VPS 上的 `root` 用户进行 **带口令的 SSH 密钥认证**，并通过 `keychain` 自动解锁私钥，以便 Cron Job 无障碍运行。

### 步骤一：在中心 VPS 上生成 SSH 密钥对（带口令）

为提高安全性，生成的私钥文件必须设置一个复杂的口令 (passphrase)。

生成密钥对： 在中心 VPS 的命令行中执行以下命令，建议使用 ED25519 或 RSA 4096 位密钥：

```sh
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_acme -C "acme_deploy_key"
```

重要： 系统会提示您输入口令 (passphrase)。请务必设置一个强口令。

- 生成的私钥文件：~/.ssh/id_ed25519_acme

- 生成的公钥文件：~/.ssh/id_ed25519_acme.pub

设置密钥权限： 确保私钥文件权限严格：

```sh
chmod 600 ~/.ssh/id_ed25519_acme
```

### 步骤二：将公钥复制到所有目标 VPS

将步骤一生成的公钥 (.pub 文件) 复制到所有需要部署证书的目标 VPS 上，允许中心 VPS 进行无密码身份验证（但仍需解锁私钥）。

使用 ssh-copy-id 复制公钥： 对每个目标 VPS 重复执行此命令：

```sh
ssh-copy-id -i ~/.ssh/id_ed25519_acme.pub root@目标VPS的IP或域名
```

提示： 在首次执行此命令时，您需要输入 目标 VPS 的密码。

（如果您没有 `ssh-copy-id` 命令，需要手动将公钥内容复制到目标 VPS 的 `~/.ssh/authorized_keys` 文件中。）

### 步骤三：使用 keychain 实现 SSH 密钥免密登录 (关键步骤)

keychain 工具可以管理 SSH 密钥代理 (ssh-agent)，并在用户登录时自动加载私钥，只要求用户输入一次口令，即可在所有后续会话和 Cron Job 中保持密钥解锁状态。

安装 keychain：

Debian/Ubuntu： 

```sh
sudo apt install keychain
```

RHEL/CentOS： 

```sh
sudo yum install keychain 或 sudo dnf install keychain
```

配置 Shell 启动文件： 将以下代码添加到中心 VPS 的 `~/.bashrc` (或 `~/.zshrc`) 文件末尾：

```sh
# 使用 keychain 管理 acme 部署密钥
eval "$(keychain --eval --agents ssh --dir ~/.ssh id_ed25519_acme)"
```

注意： 这里的 `--dir ~/.ssh` 和 `id_ed25519_acme` 必须与您在步骤一中创建的密钥路径匹配。

### 步骤四：测试和解锁密钥：

退出并重新登录 中心 VPS。

首次登录时，keychain 会提示您输入 id_ed25519_acme 私钥的口令 (passphrase)。

输入口令后，密钥会被添加到 ssh-agent。

后续您在当前会话中执行任何 scp 或 ssh 命令时，都不需要再次输入口令。

验证： 执行 ssh-add -l，如果看到 id_ed25519_acme (ED25519) 已经被列出，则表示成功。

### 步骤五：在 ~/.ssh/config 中设置 Host (提高兼容性)

为了确保 acme.sh 脚本中的 ssh 命令能正确使用该密钥，即使在 Cron Job 这样的非交互式环境中，也推荐在 SSH 配置文件中明确指定使用哪个密钥。

创建或编辑 ~/.ssh/config：

```sh
nano ~/.ssh/config
```

添加配置条目： 为所有目标 VPS 添加通配符配置（或单独配置）：

```sh
# 设置所有 SSH 连接的默认值
Host *
    ForwardAgent yes             # 允许密钥转发 (如果需要跳板机)
    StrictHostKeyChecking no     # (可选) 首次连接时不询问，适合自动化环境
    UserKnownHostsFile /dev/null # (可选) 忽略 host key 检查

# 为部署连接设置专用密钥
Host 目标VPS的IP或域名 
    User root                    # 确保使用 root 用户连接
    IdentityFile ~/.ssh/id_ed25519_acme

# 或者如果目标很多，使用通配符匹配 IP 段或特定的 Hostname
Host 192.168.1.* 10.0.0.*
    IdentityFile ~/.ssh/id_ed25519_acme
```

最终效果

当 您（用户） 登录中心 VPS 时，keychain 会自动运行，提示您输入一次口令，解锁私钥。

只要您不重启中心 VPS 或 ssh-agent，私钥就会保持解锁状态。

acme.sh 的 Cron Job 运行时，它会继承当前 Shell 环境中已解锁的 ssh-agent，从而在执行脚本中的 ssh 和 scp 命令时，不需要输入任何口令，实现全自动部署。

## 第二步：安装 acme.sh

确保 `acme.sh` 已安装并能正常工作。

```sh
# 以 Debian 为例
apt install cron curl && curl https://get.acme.sh | sh && source ~/.bashrc

# acme.sh --set-default-ca --server letsencrypt
# acme.sh --register-account
# acme.sh --upgrade --auto-upgrade

# export NTFY_URL="https://ntfy.domain.com"
# export NTFY_TOPIC="acme"
# export NTFY_TOKEN="tk_dzggsc7314v3n5len5qcwbh5kb7sn"
# acme.sh --set-notify --notify-hook ntfy
```



## 第三步：安装部署 Hook 脚本

1. **保存脚本：** 下载 **`custom.sh`** 文件。

2. **放置路径：** 将此文件复制到 `acme.sh` 的 Hook 目录，并确保其可执行：

   ```sh
   # 假设 acme.sh 安装在当前用户的 HOME 目录下
   cp custom.sh ~/.acme.sh/deploy/custom.sh
   chmod +x ~/.acme.sh/deploy/custom.sh
   ```

## 第四步：为您的每个域名创建配置文件 [DOMAIN].env

在 `acme.sh` 存放证书配置的目录内，为您的域名创建一个 `.env` 格式的配置文件，用于定义目标服务器。

1. **创建文件：** 进入您的证书目录（以 `example.com` 为例）：

   ```sh
   # 假设您使用的是 ECC 证书
   mkdir -p ~/.acme.sh/example.com_ecc
   nano ~/.acme.sh/example.com_ecc/example.com.env
   ```
   
2. **文件内容格式：** 每行定义一个目标服务器，格式为：`[IP 或 Hostname]:[目标路径]:[重启命令]`

   ```sh
   # ----------------------------------------------------
   # example.com.env 配置文件内容示例
   # ----------------------------------------------------
   # 目标服务器A：Nginx 服务器
   192.168.1.10:/etc/nginx/ssl:systemctl reload nginx
   
   # 目标服务器B：Apache 服务器 (需使用 httpd 命令)
   web02.corp.com:/etc/httpd/certs:systemctl reload httpd
   
   # 目标服务器C：只需复制文件，无需重启服务
   192.168.1.12:/var/ftp/certs:
   
   # 目标服务器D：使用非 systemd 的重启命令
   192.168.1.13:/usr/local/haproxy/ssl:/etc/init.d/haproxy reload
   ```

------

## 第五步：使用脚本（三种运行模式）

申请证书

```sh
acme.sh --issue --dns dns_cf --force -d example.com -d *.example.com
```

### 模式一：作为 Deploy Hook 注册 (推荐用于新部署)

这是最标准的使用方式。`acme.sh` 会在**首次安装或手动部署时**调用 Hook 函数，并以**参数形式**传递证书文件路径。

```sh
# 假设证书已存在
acme.sh --deploy -d example.com --deploy-hook custom
```

**行为：** 脚本会执行 `custom_deploy` 函数。在 `main` 函数中，由于 `custom_deploy` 被 `acme.sh` 直接调用，`main` 不会执行。

### 模式二：作为 Renew Hook 注册 (推荐用于自动化续期)

这是确保证书**自动续期成功后**执行部署的最佳方式。`acme.sh` 会以 **`eval` 方式**执行命令，将证书路径作为**环境变量**传递。

```sh
# 注册时设置此 Hook，它将在证书续期成功后自动运行
acme.sh --install-cert -d example.com \
--fullchain-file /etc/letsencrypt/example.com.fullchain.cer \
--key-file       /etc/letsencrypt/example.com.key \
--renew-hook    "/root/.acme.sh/deploy/custom.sh"
```

**行为：** 脚本被无参数调用 (`$# -eq 0`)，进入 `main` 的 **Renew Hook 模式**，从 `CERT_FULLCHAIN_PATH` 等环境变量中读取证书信息并部署。

### 模式三：手动测试和快速部署

您可以使用命令行参数手动触发部署，这对于测试非常方便。

**方法 A: 仅提供域名 (自动查找)**

```sh
/root/.acme.sh/deploy/custom.sh -d example.com
# 脚本会自动在 ~/.acme.sh/example.com/ 目录下查找证书文件
```

**方法 B: 提供所有文件路径 (覆盖查找)**

```sh
/root/.acme.sh/deploy/custom.sh \
  -d example.com \
  -k /root/.acme.sh/example.com_ecc/example.com.key \
  -f /root/.acme.sh/example.com_ecc/example.com.fullchain.cer
```

**行为：** 脚本进入 `main` 的 **手动模式**，解析具名参数，然后调用 `custom_deploy` 函数。

