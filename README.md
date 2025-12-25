# 📡 Nano Probe v1.1

极简、轻量级的服务器监控探针。支持 CPU、内存、硬盘、实时流量、累积流量、运行时间及 TCP/UDP 连接数监控。

## 🚀 一键安装

使用 root 用户执行以下命令：

```bash
wget -O install.sh https://raw.githubusercontent.com/887BF690/nano-probe/refs/heads/main/install.sh && bash install.sh
```

## ✨ 功能特性
轻量级: 基于 FastAPI (Python) 和原生前端，无重度依赖。

实时性: 使用 WebSocket 实时更新数据。

增强监控: 包含系统 Uptime 和网络连接数监控。

历史记录: 支持 24 小时 CPU 与延迟热力图。

## 🛠️ 安装要求

Python 3.7+

Root 权限

支持 Debian/Ubuntu/CentOS


## 自定义延时检测 (名称,IP|名称2,IP2): 可选默认 Google

北京移动,211.138.30.66|北京联通,123.123.123.123|江苏电信,218.2.2.2
