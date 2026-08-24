# WCVoiceClone — GitHub Actions 自动编译

把本仓库整个上传到 GitHub（Public 仓库），Actions 会自动编译出 deb。

## 使用步骤
1. 登录 github.com → 右上角 + → New repository → 起名 → Public → Create
2. 在新仓库页面点 "uploading an existing file"，把本文件夹里的**所有内容**拖进去
3. 点 Commit changes，等 1~2 分钟
4. 仓库 Actions 标签页 → 最新一次运行 → Artifacts 下载 `WCVoiceClone-deb`
5. 解压得到 .deb，装到越狱手机
