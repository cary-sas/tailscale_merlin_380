#! /bin/sh
# 引用环境变量等

eval `dbus export tailscale`

alias echo_date='echo 【$(TZ=UTC-8 date -R +%Y年%m月%d日\ %X)】:'


# 判断路由架构和平台
case $(uname -m) in
	armv7l)
		echo_date 固件平台【koolshare merlin armv7l】符合安装要求，开始安装插件！
	;;
	*)
		echo_date 本插件适用于koolshare merlin armv7l固件平台，你的平台"$(uname -m)"不能安装！！！
		echo_date 退出安装！
		exit 1
	;;
esac

if [ "$tailscale_enable" == "1" ];then
	echo_date 关闭 tailscale插件 !
	sh /koolshare/scripts/tailscale_config stop
fi

# remove before install
rm -f "/var/run/tailscale/tailscaled.sock" >/dev/null 2>&1
rm -f "/var/run/tailscale/tailscaled.pid" >/dev/null 2>&1
rm -f /koolshare/bin/tailscale* >/dev/null 2>&1
rm -f /koolshare/res/icon-tailscale.png >/dev/null 2>&1
rm -f /koolshare/scripts/tailscale_* >/dev/null 2>&1
rm -f /koolshare/webs/Module_tailscale.asp >/dev/null 2>&1
find /koolshare/init.d -name "*tailscale*" | xargs rm -f
rm -f /tmp/tailscale_*.log >/dev/null 2>&1

# 解压安装包
echo_date "解压安装包..."
tar -zxf /tmp/tailscale.tar.gz -C /tmp/
if [ "$?" != "0" ]; then
  echo_date "解压安装包失败！退出安装！"
  rm -rf /tmp/tailscale* >/dev/null 2>&1
  exit 1
fi			


# 1) 拷贝到 koolshare 标准位置
cp -rf /tmp/tailscale/bin/*        /koolshare/bin/
cp -rf /tmp/tailscale/scripts/*    /koolshare/scripts/
cp -rf /tmp/tailscale/init.d/*     /koolshare/init.d/
cp -rf /tmp/tailscale/webs/*       /koolshare/webs/
cp -rf /tmp/tailscale/res/*        /koolshare/res/


# 2) 清理临时
rm -rf /tmp/tailscale* >/dev/null 2>&1

# 3) 权限
chmod 755 /koolshare/bin/tailscale.combined  2>/dev/null
chmod 755 /koolshare/bin/jq               2>/dev/null
chmod 755 /koolshare/scripts/tailscale_*  2>/dev/null
chmod 755 /koolshare/init.d/*tailscale*.sh 2>/dev/null

ln -sf /koolshare/bin/tailscale.combined /koolshare/bin/tailscale  2>/dev/null
ln -sf /koolshare/bin/tailscale.combined /koolshare/bin/tailscaled 2>/dev/null

# 离线安装时设置软件中心内储存的版本号和连接

dbus set tailscale_version="1.0.4"
dbus set softcenter_module_tailscale_version="1.0.4"
dbus set softcenter_module_tailscale_install="4"
dbus set softcenter_module_tailscale_name="tailscale"
dbus set softcenter_module_tailscale_title="Tailscale"
dbus set softcenter_module_tailscale_description="Tailscale - 零配置 VPN"
dbus set softcenter_module_tailscale_home_url="Module_tailscale.asp"

if [ "$tailscale_enable" == "1" ];then
	echo_date 重启 tailscale插件 !
	sh /koolshare/scripts/tailscale_config start
fi

echo_date 更新完毕，请等待网页自动刷新！

exit 0
