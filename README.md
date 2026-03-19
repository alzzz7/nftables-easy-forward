# nftables 简单转发

纯bash的nftables转发脚本，支持 IPv4/IPv6 及批量端口 / 端口范围，理论上支持所有linux发行版。~~ai含量99.99%~~

## 快速使用

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/alzzz7/nftables-easy-forward/main/nfteasy.sh)"
```

大陆加速源
```bash
bash -c "$(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/alzzz7/nftables-easy-forward/main/nfteasy.sh)"
```

## 卸载

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/alzzz7/nftables-easy-forward/main/nfteasy_uninstall.sh)"
```

大陆加速源
```bash
bash -c "$(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/alzzz7/nftables-easy-forward/main/nfteasy_uninstall.sh)"
```

## 何意味

自用脚本，用 gemini3.1pro 快速完成，已经充分测试了，可放心使用，有问题欢迎提 issues，或 pull requests  

## License

[MIT License](https://github.com/alzzz7/nftables-easy-forward/blob/main/LICENSE)

---

## 如果你不想使用脚本，可以根据以下教程手动转发，效果一致

### 准备环境

###  安装 nftables

- **Ubuntu/Debian**: `sudo apt install nftables`

- **CentOS/RHEL/Alma**: `sudo yum install nftables`

- **Arch**: `sudo pacman -S nftables`


安装后确保服务正在运行，并设置为开机自启：

```bash
sudo systemctl enable --now nftables
```

## 开启内核网络转发

开启 IPv4 转发

```bash
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-nft-forward.conf
```

开启 IPv6 转发 ( 如果你的机器支持且需要的话 )

```bash
echo "net.ipv6.conf.all.forwarding = 1" | sudo tee -a /etc/sysctl.d/99-nft-forward.conf
```

重新载入内核参数使其立即生效

```bash
sudo sysctl -p /etc/sysctl.d/99-nft-forward.conf
```


## 创建 Nftables 基础表

`nftables` 是一个树状结构系统：`表 (Table) -> 链 (Chain) -> 规则 (Rule)`

为了不干扰系统防火墙，我们建立一个名为 `nft_forwarding` 的独立转发表，使用支持双栈的 `inet`

新建名为 [ nft_forwarding ] 的双栈转发表

```bash
sudo nft add table inet nft_forwarding
```

 添加 PREROUTING 链，用于目的地址转换 DNAT
 
```bash
sudo nft add chain inet nft_forwarding prerouting '{ type nat hook prerouting priority dstnat ; policy accept ; }'
```

添加 POSTROUTING 链，用于源IP伪装 SNAT/MASQUERADE

```bash
sudo nft add chain inet nft_forwarding postrouting '{ type nat hook postrouting priority srcnat ; policy accept ; }'
```


## 下发具体的转发规则


TCP/UDP的DNAT和MASQUERADE均支持端口范围及不连续端口，目标ip支持 IPv4/IPv6，以下不再赘述

### TCP

 DNAT

```bash
sudo nft add rule inet nft_forwarding prerouting meta nfproto ipv4 tcp dport { 监听端口范围起始-监听端口范围结束 } dnat ip to [目标ip]
```

 MASQUERADE

```bash
sudo nft add rule inet nft_forwarding postrouting meta nfproto ipv4 ip daddr [目标ip] tcp dport { 监听端口范围起始-监听端口范围结束 } masquerade
```

### UDP

 DNAT

```bash
sudo nft add rule inet e2e_forwarding prerouting meta nfproto ipv4 udp dport { 监听端口范围起始-监听端口范围结束 } dnat ip to [目标ip]
```

 MASQUERADE

```bash
sudo nft add rule inet e2e_forwarding postrouting meta nfproto ipv4 ip daddr [目标ip] udp dport { 监听端口范围起始-监听端口范围结束 } masquerade
```


## 防火墙端口放行

**UFW (ubuntu) ：**

放行刚刚设置转发的 tcp 和 udp

```bash
sudo ufw allow 端口范围起始:端口范围结束/tcp
```

```bash
sudo ufw allow 端口/tcp
```

```bash
sudo ufw allow 端口范围起始:端口范围结束/udp
```

```bash
sudo ufw allow 端口/udp
```

**firewalld (redhat/centos) ：**

```bash
sudo firewall-cmd --add-port=端口范围起始-端口范围结束/tcp --permanent
```

```bash
sudo firewall-cmd --add-port=端口/tcp --permanent
```

```bash
sudo firewall-cmd --add-port=端口范围起始-端口范围结束/udp --permanent
```

```bash
sudo firewall-cmd --add-port=端口/udp --permanent
```

```bash
sudo firewall-cmd --add-masquerade --permanent
```

```bash
sudo firewall-cmd --reload
```


## 5. 保存与持久化
  
刚才的 `nft add ...` 操作都是**写入内存**的，重启失效，记得将其导出覆盖到系统的默认加载文件中，大部分系统为 `/etc/nftables.conf`，少数 CentOS 可能存放在`/etc/sysconfig/nftables.conf`


查看内存中现在的状态与规则

```bash
sudo nft list ruleset
```

保存当前内存至系统自启文件

```bash
sudo nft list ruleset > /etc/nftables.conf
```

如果中途出错想清零重来

```bash
sudo nft flush table inet nft_forwarding
```
