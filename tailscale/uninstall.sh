#!/bin/sh

alias echo_date='echo 【$(TZ=UTC-8 date -R +%Y年%m月%d日\ %X)】:'

echo_date 删除tailscale插件相关文件！

# 停服务（可选）
if [ "$tailscale_enable" == "1" ];then
	echo_date 关闭 tailscale插件 !
	sh /koolshare/scripts/tailscale_config stop
fi

# 删除文件
rm -f  /koolshare/bin/tailscale
rm -f  /koolshare/bin/tailscaled
rm -f  /koolshare/webs/Module_tailscale.asp
rm -f  /koolshare/res/*tailscale* 2>/dev/null
rm -f  /koolshare/init.d/*tailscale*.sh 2>/dev/null
rm -f  /tmp/*tailscale*

# 脚本按你的包名删除（保留其它应用的脚本）
rm -f  /koolshare/scripts/tailscale_*


dbus remove softcenter_module_tailscale_version
dbus remove softcenter_module_tailscale_install     
dbus remove softcenter_module_tailscale_name
dbus remove softcenter_module_tailscale_title
dbus remove softcenter_module_tailscale_description
dbus remove softcenter_module_tailscale_home_url
dbus remove softcenter_module_tailscale_description
dbus remove tailscale_enable
dbus remove tailscale_version
dbus remove tailscale_ipv4_enable
dbus remove tailscale_ipv6_enable
dbus remove tailscale_role
dbus remove tailscale_SNAT_enable
dbus remove tailscale_advertise_exit
dbus remove tailscale_advertise_routes
dbus remove tailscale_authkey
    

echo_date "tailscale插件卸载成功！"
echo_date "-------------------------------------------"
echo_date "卸载保留了tailscale配置文件夹: /koolshare/configs/tailscale"
echo_date "如果你希望重装tailscale插件后，完全重新配置tailscale"
echo_date "请重装插件前手动删除文件夹/koolshare/configs/tailscale"
echo_date "-------------------------------------------"

exit 0
