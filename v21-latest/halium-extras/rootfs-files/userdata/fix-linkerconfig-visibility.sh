#!/system/bin/sh
/apex/com.android.runtime/bin/linkerconfig --target /linkerconfig
sed -i "s/^namespace\.com_android_art\.isolated = true\$/namespace.com_android_art.isolated = true\nnamespace.com_android_art.visible = true/" /linkerconfig/ld.config.txt
# НАЙДЕНО 2026-07-24: верхнеуровневый /linkerconfig/ld.config.txt чинится
# строкой выше, но у APEX-собственного /linkerconfig/com.android.art/ld.config.txt
# СВОЙ namespace (там он называется "default", а не "com_android_art") --
# и у него никогда не было visible=true. Требуется отдельный sed.
sed -i "s/^namespace\.default\.isolated = true\$/namespace.default.isolated = true\nnamespace.default.visible = true/" /linkerconfig/com.android.art/ld.config.txt
