# keycloaktool
一款实现Keycloak HA之间DB数据自动同步的工具
# 1 基础知识
## 1.1 系统架构
~~~
https://websso.cmdschool.org(nginx anyCast Cluster)
           |
           |--> https://dgrhbk01.cmdschool.org:8443 -->  |                    |
           |    (10.168.200.54,keycloak,active)          |------------------->|tcp://dgrhbkdb01.cmdschool.org:3306          
           |--> https://dgrhbk02.cmdschool.org:8443 -->  |                    |    (10.168.200.54,mariaDB)
           |    (10.168.200.55,keycloak,active)          | 
           |                                             
           |--> https://hkrhbk01.cmdschool.org:8443 ---> |                    | 
           |    (10.168.2.246,keycloak,backup)           |------------------->|tcp://hkrhbkdb01.cmdschool.org:3306
           |--> https://hkrhbk02.cmdschool.org:8443 ---> |                    |    (10.168.208.183,mariaDB)
           |    (10.168.208.218,keycloak,backup)         |
~~~
如上图所示：
- Nginx代理发布服务websso.cmdschool.org，其中dgrhbk01和dgrhbk02为活动节点，hkrhbk01和hkrhbk02为备份节点
- 当dgrhbk01和dgrhbk02都离线，hkrhbk01和hkrhbk02自动上线
- dgrhbk01和dgrhbk02使用的数据库为dgrhbkdb01，hkrhbk01和hkrhbk02使用的数据库为hkrhbkdb01
- 数据库dgrhbkdb01与hkrhbkdb01相互独立，使用本章的脚本实现同步

## 1.2 同步逻辑
- 关闭所有目标Keycloak节点应用程序服务（keycloak.service）
- 将源Keycloak节点的数据库通过mysqldump下载到临时目录
- 将mysqldump下载到临时目录的数据导入到目标Keylcoak节点的数据库
- 启动所有目标Keycloak节点应用程序服务

## 1.3 数据来源
- 脚本读取源节点的/etc/keycloak/keycloak.conf获取源节点的数据库参数
- 脚本读取目标节点的/etc/keycloak/keycloak.conf获取目标节点的数据库参数
- 源和目标Keycloak节点应用程序服务（keycloak.service）节点名称、登陆的账号来源于变量

# 2 部署工具
## 2.1 部署脚本
On dgrhbk01
~~~
# mkdir -p ~/scripts/
# wget --no-check-certificate https://raw.githubusercontent.com/tanzhenchao/keycloaktool/7cddd6c3a52aaaef6453801b16fb69ec12782
265/keycloaktool.sh
# cp ~/scripts/keycloaktool.sh /usr/local/bin/keycloaktool
# chmod +x /usr/local/bin/keycloaktool
~~~

## 2.2 修改配置
On dgrhbk01
~~~
# vim /usr/local/bin/keycloaktool
~~~
配置修改如下，
~~~
sourceKeycloakHost="dgrhbk01"
sourcekeycloakConf="/etc/keycloak/keycloak.conf"
targeKeycloakHost="hkrhbk01"
targekeycloakConf="/etc/keycloak/keycloak.conf"

logFile="/var/log/$(basename $0).log"
syncDir="/backup"
backupKeeptime='+7'
keycloakHosts="hkrhbk01 hkrhbk02"
sshUser="root"
serviceName="keycloak"
~~~
根据配置要求，你可能需要手动创建备份目录，
On dgrhbk01
~~~
# mkdir -p /backup
~~~

## 2.3 配置公钥认证
On dgrhbk01
~~~
# ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa

# ssh-copy-id -i ~/.ssh/id_rsa.pub root@dgrhbk01
# ssh-copy-id -i ~/.ssh/id_rsa.pub root@hkrhbk01
# ssh-copy-id -i ~/.ssh/id_rsa.pub root@hkrhbk02

# ssh dgrhbk01
# ssh hkrhbk01
# ssh hkrhbk02
~~~

## 2.4 设置数据库权限
On hkrhbkdb01
~~~
# mysql -uroot -p
> grant all privileges on keycloak.* to 'keycloak'@'10.168.200.54' identified by 'keycloakpwd';
~~~

# 3 测试脚本
## 3.1 获取脚本帮助
On dgrhbk01
# keycloaktool 
Usage: /usr/local/bin/keycloaktool {keycloak|db}

## 3.2 手动执行同步
### 3.2.1 停止所有目标Keycloak节点的服务
On dgrhbk01
~~~
# keycloaktool keycloak stop
~~~

### 3.2.2 备份所有目标Keycloak节点的数据库
On dgrhbk01
~~~
# keycloaktool db backup
~~~

### 3.2.3 将数据同步到目标Keycloak节点的数据库
On dgrhbk01
~~~
# keycloaktool db sync
~~~

### 3.2.4 启动所有目标Keycloak节点的服务
On dgrhbk01
~~~
# keycloaktool keycloak start
~~~

# 3.3 自动执行同步
### 3.3.1 执行自动同步参数(自动执行以上所有步骤)
On dgrhbk01
~~~
# keycloaktool db autosync
~~~
### 3.3.2 设置脚本定时执行
On dgrhbk01
~~~
# crontab -e
~~~
加入如下配置，
~~~
0 5 * * * /usr/local/bin/keycloaktool db autosync
~~~
# 3.4 检查日志
On dgrhbk01
~~~
# cat /var/log/keycloaktool.log
~~~
