# FlClash po0

在官方 [FlClash](https://github.com/chen08209/FlClash) 上加了 po0 防火墙自动加白，只做安卓版。
加白逻辑参考 [po0fw](https://github.com/w0ven/po0fw) 和 po0-clash 6.x。

## 用法

工具 → 设置 → **po0 加白**：

1. 点「添加 token」，粘贴 `pgnfw_` 开头的 token（或包含它的链接），备注可留空。
2. 保持「自动加白」开启。「检查间隔」可以改成 1～3600 秒，默认 5 秒。
3. 「立即加白」手动检查一次。

每轮先只读查询白名单（不占名额），当前出口的 /24 不在名单里才调用 `…/add` 写入。
连续失败时按间隔的 2/4/8/16 倍退避，最长 30 秒；网络切换、亮屏、回到前台时立即检查；熄屏时暂停。
检查跑在界面进程里，从最近任务里划掉应用后停止。

## 加白请求怎么绕开代理

po0 按请求的来源 IP 加白，所以请求必须从手机的真实网络发出：

- 代理没开：直接请求。
- 代理开着：po0 往配置里加一个只给自己用的入站 `po0-direct`（`127.0.0.1` 随机端口、随机账号，`proxy: DIRECT`），
  请求走这个入站出去。入站指定了出站，所以规则、全局模式、VPN 都改不了它。
- 代理开着但这个入站还没生效：不发请求（否则会把节点 IP 加白），连续两次后自动重新应用一次配置。

## 和上游的关系

| 分支 / 文件 | 说明 |
|---|---|
| `po0` | 上游正式版 + po0 改动，所有构建都出自这里 |
| `lib/po0/`、`Po0ScreenPlugin.kt` | po0 的全部代码 |
| 上游原有文件 | 只加了几行接入：`main.dart`、`providers/action.dart`、`providers/actions/setup.dart`、`views/tools.dart`、`MainActivity.kt` |

包名 `com.follow.clash.po0`、应用名「FlClash po0」和应用内更新源在 CI 打包时替换，不改仓库里的文件，
所以合并上游时这几处不会冲突，可以和官方 FlClash 同时安装。

### 自动同步

`po0 sync upstream` 每 6 小时运行一次：

1. 取上游最新的正式版标签 `vX.Y.Z`。
2. 已经合并过并且发布过 → 什么都不做。
3. 否则合并进 `po0`，推送，然后调用 `po0 android` 打出三种 ABI 的 APK，发布到本仓库的 `vX.Y.Z` Release。
4. 合并有冲突 → 开一个 issue 列出冲突文件，`po0` 不动。解决冲突、推送后手动运行一次这个流程。

应用里的「检查更新」看的是本仓库的 Release，所以上游出新版、这边同步发布后，手机上会提示更新。
只改了 po0 代码、上游没变时，在 Actions 里手动运行 `po0 sync upstream` 并勾选 rebuild，会用同一版本号重新发布；
这种情况应用不会提示更新，需要手动下载安装（versionCode 会变大，可以直接覆盖安装）。

### 签名

Release 必须用固定的签名，否则无法覆盖安装。仓库需要这 4 个 Actions secrets：

| Secret | 内容 |
|---|---|
| `KEYSTORE` | keystore 文件的 base64 |
| `KEY_ALIAS` | 密钥别名 |
| `STORE_PASSWORD` | keystore 密码 |
| `KEY_PASSWORD` | 密钥密码（PKCS12 与 `STORE_PASSWORD` 相同） |

keystore 和密码不要提交进仓库，并另外备份好：丢了之后新版本就没法覆盖安装旧版本了。
推送到 `po0` 的测试构建没有这些 secret 也能跑，只是用临时的调试签名，包名带 `.dev`。

## 上游的工作流

本仓库停用了上游的 `build`、`issue-gate`、`pages`：它们只对官方仓库有意义，`issue-gate` 还会关掉同步流程开的冲突 issue。
