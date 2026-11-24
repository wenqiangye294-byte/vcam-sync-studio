# 虚拟相机同步工作台（VCam Sync Studio）

面向 **电脑端排期同步 + iPhone iOS 16.2 相机输出替换** 的完整端到端方案：
- **电脑端独立桌面工具**：按「商品任务包」管理下载图片、批量本地导入、拖拽排序、长按录制视频队列，并通过局域网 Wi-Fi（扫码配对 + UDP 自动发现 + WebSocket 实时同步）推送到手机。
- **手机端（iOS 16.2 双模式支持）**：
  - **纯巨魔免越狱（TrollStore + TrollFools）**：安装 `VCamSync.tipa` 同步控制端 + 用 TrollFools 给目标 App 注入 `VCamHook.dylib`。
  - **方案 B 越狱环境（Dopamine rootless iOS 16.2）**：安装 `VCamTweak-rootless.deb` + `VCamSync.tipa`，系统内相机插件直接生效。
- **核心拍摄体验**：
  - **点击拍摄**：按电脑端图片队列顺序输出图片，拍完一张自动切至下一张并同步进度给电脑。
  - **长按录制**：开始长按录制时实时切换到视频源，松手停止后自动将录制文件替换为预设视频（支持完整替换 / 按长按时长截取 / 实时逐帧注入）。

---

## 目录结构

```text
vcam-sync-studio/
├── desktop/                          # Windows/macOS 电脑端桌面工作台
│   ├── app_launcher.pyw              # Windows 无黑框独立窗口启动器
│   ├── start_windows.bat             # Windows 一键启动脚本
│   ├── create_desktop_shortcut.bat   # 创建桌面图标「虚拟相机同步工作台」
│   ├── allow_firewall_windows.bat    # 一键放行局域网防火墙端口 18760 / 18766
│   ├── main.py                       # FastAPI + WebSocket 同步服务
│   ├── storage.py                    # SQLite 商品队列、排序与游标状态持久化
│   ├── media_utils.py                # 图片 EXIF 转正与纯 Python MP4 元数据解析
│   ├── qr_generator.py               # 零依赖本地 SVG 二维码生成器
│   ├── discovery.py                  # 局域网 IP 识别与 UDP 自动发现服务
│   ├── static/                       # 中文桌面操作界面
│   └── tests/                        # 自动化单元测试
├── ios/
│   ├── shared/VCamProtocol.h         # 电脑/手机/插件共享协议常量
│   ├── VCamHook/                     # 零 Substrate 依赖的 AVFoundation 虚拟相机插件源码
│   └── VCamSyncApp/                  # 巨魔商店高权限伴侣 App 源码与 macOS 构建脚本
└── .github/workflows/build-ios.yml   # GitHub Actions 零成本云编译 iOS 安装包
```

---

## 一、电脑端一键启动（Windows）

1. 双击运行 `desktop/start_windows.bat`：自动检查环境并以独立桌面软件窗口打开工作台（默认监听 `0.0.0.0:18760` 与 UDP `18766`）。
2. 双击运行 `desktop/create_desktop_shortcut.bat`：在桌面创建 **「虚拟相机同步工作台」** 图标，以后直接双击桌面图标即可静默启动。
3. **局域网放行（首次推荐）**：右键以管理员身份运行一次 `desktop/allow_firewall_windows.bat`（或在 Windows 防火墙提示时勾选「专用网络」允许），确保手机能连上电脑。

---

## 二、通过 GitHub Actions 云编译 iOS 16.2 安装包（无需本地 Mac）

1. 将整个 `vcam-sync-studio` 文件夹作为一个 Git 仓库推送到你的 GitHub（确保仓库根目录包含 `.github/workflows/build-ios.yml`）。
2. 打开 GitHub 仓库页面 -> 点击顶部 **Actions** -> 选择 **Build iOS 16.2 Artifacts** -> 点击 **Run workflow**（或每次 `git push` 自动触发）。
3. 等待约 1~2 分钟构建完成，在页面底部 **Artifacts** 下载 `vcam-ios-16.2-artifacts.zip`，解压后包含：
   - `VCamSync.tipa`（以及等价的 `VCamSync.ipa`）
   - `VCamHook.dylib`
   - `VCamTweak-rootless.deb`

---

## 三、手机端安装步骤（iOS 16.2）

### 路线 A：纯巨魔 + TrollFools（当前 iPhone 16.2 免越狱）

1. **安装控制端**：将 `VCamSync.tipa` 传到手机，使用 **TrollStore（巨魔商店）** 安装。
2. **注入虚拟相机插件**：打开 **TrollFools**，选择你要替换相机画面的目标 App，选择注入 `VCamHook.dylib`。
3. **配对与镜像目录（关键）**：
   - 确保 iPhone 与电脑连着同一个 Wi-Fi，打开手机上的 **VCamSync**。
   - 点击 **「扫码配对电脑」** 扫描电脑端右侧的二维码（或点击 **「自动搜索局域网电脑」**）。
   - 点击 **「选择要替换相机的目标 App」**，勾选刚才注入 `VCamHook.dylib` 的 App 并点击 **「保存并同步」**。
   - 这样 `VCamSync` 会自动把电脑传来的图片、视频与队列直接镜像写入目标 App 自己的缓存目录，沙盒内 App 无需任何越狱权限即可毫秒级读取替换！

### 路线 B：越狱环境（Dopamine Rootless iOS 16.2）

1. 将 `VCamTweak-rootless.deb` 传到手机，使用 **Sileo / Zebra / Filza** 安装后注销（Respring）。
2. 用 TrollStore 安装 `VCamSync.tipa`，打开扫码配对电脑即可直接生效（`VCamHook.dylib` 会自动屏蔽 `VCamSync` 自身，不影响扫码相机）。

---

## 四、使用流程与小贴士

1. **新建/选择商品包**：在电脑端左侧创建商品包，把下载好的商品图拖拽上传，或直接粘贴本地文件夹路径（例如主图工作台导出目录）一键按文件名顺序批量导入。
2. **调整拍摄顺序**：直接拖拽图片卡片即可重排顺序；点击任意卡片上的 **「设为当前」** 可以随时把手机端下一张待拍图片跳到指定位置。
3. **设置长按录制视频**：在「2. 长按录制 · 视频替换队列」上传 `.mp4` / `.mov` 视频，默认采用 **「完整替换原视频」** 模式（也可切换为「按长按时长截取」或「实时逐帧注入」）。
4. **画面方向/比例微调**：如果部分 App 内预览旋转了 90° 或镜像了，直接在电脑端下方「相机画面输出微调」切换角度、铺满/适应模式或镜像开关，手机端实时生效。
5. **多网卡切换**：如果电脑开着代理或虚拟机导致扫码后连接超时，请在电脑端右侧「本机广播网卡 IP」下拉框切换成路由器真实局域网 IP（如 `192.168.x.x`）后重新扫码。

---

## 五、运行电脑端单元测试

```bash
python -m unittest discover -s desktop/tests -v
```
