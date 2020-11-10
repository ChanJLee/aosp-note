# Android 系统启动流程

## 概述

- 长按开机键，引导芯片从ROM特殊位置读取BootLoader

- BootLoader把Linux内核镜像加载到内存，并且初始化Linux内核

- Linux内核构造出init进程

- init 构造出zygote进程 

- zygote启动system server进程

- system server 启动各种java核心服务，比如AMS, 完成后发送 ACTION_BOOT_COMPLETED 启动launcher


## BootLoader初始化

