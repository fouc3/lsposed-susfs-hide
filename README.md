# LSPosed × SUSFS 隐藏方案

> **English**: Hide LSPosed's `dex2oat` bind mount and `zygisk/*.so` mappings from
> non-root processes on KernelSU + SUSFS kernels. LSPosed itself is left
> untouched — 2.0.3 crashes if its module id or `daemon.apk` is modified, so the
> mounts are hidden at the kernel level instead. See [Why not patch
> LSPosed](#为什么不能改-lsposed).

在 SUSFS 内核上隐藏 LSPosed 的两处进程级痕迹：

- `/proc/self/mountinfo` 里 `bin/dex2oat` 的 bind mount（挂载源路径含 `zygisk_lsposed`）
- `/proc/self/maps` 里 `zygisk/*.so` 的映射路径

**不修改 LSPosed 本体**，全部在内核层完成。对任何读取这些文件的进程都生效，与具体检测器无关。

## 背景

LSPosed 2.0.3 的守护进程会把模块目录下的 `bin/dex2oat` bind-mount 到
`/apex/com.android.art/bin/dex2oat32` 和 `dex2oat64`，目的是让 ART 编译 App 时加上
`--inline-max-code-units=0`，防止被 hook 的方法被内联。

这个挂载是在 **PID 1 的 mount namespace** 里建立的，所以**每个 App 读自己的
`/proc/self/mountinfo` 都能看到**，无需 root。挂载源路径里直接带着模块目录：

```
/data/adb/modules/zygisk_lsposed/bin/dex2oat  ->  /apex/com.android.art/bin/dex2oat64
```

同理，Zygisk 把 `zygisk/arm64-v8a.so` 映射进每个被注入的进程，路径也出现在
`/proc/self/maps`。

## 为什么不能改 LSPosed

实测（2.0.3 / 7716），以下改动都会让守护进程在启动约 1 秒后 `SIGSEGV`（fault addr `0x314`，线程 `Thread-2`）：

| 改动 | 结果 |
| --- | --- |
| 改 `module.prop` 的 id（`zygisk_lsposed` → 其他） | 崩 |
| 删除 `bin/dex2oat` | 崩 |
| 改 `daemon.apk` 的 dex，跳过 dex2oat 初始化 | 崩（`daemon.apk` 内置 `com.android.apksig` 自校验） |
| 用 `dalvik.vm.dex2oat-flags` 属性替代挂载 | 被守护进程自身删除，且被检测为 `Property Modified` |

结论：2.0.3 的守护进程绑死了自身身份与 APK 完整性，二进制层面无法安全修改，只能从内核层绕过。

## 原理

SUSFS 提供三个能力：

| 命令 | 作用 | 生效对象 |
| --- | --- | --- |
| `hide_sus_mnts_for_non_su_procs 1` | 打开"sus 挂载"过滤的**总开关**（默认关闭） | 非 root 进程 |
| `add_sus_mount <挂载点>` | 该挂载点从 `/proc/self/{mounts,mountinfo,mountstats}` 隐藏 | 非 root 进程 |
| `add_sus_map <库路径>` | 该文件从 `/proc/self/{maps,smaps,map_files,...}` 隐藏 | uid ≥ 10000 |

要点：

1. `add_sus_mount` 必须**在挂载建立之后**调用，否则无效；
2. 只打标签不开总开关，等于没做——`hide_sus_mnts_for_non_su_procs` 默认是 0；
3. 有些模块会在 `boot-completed` 阶段把总开关重置回 0，所以本模块会在 60 秒后再补一次。

## 项目结构

```
.
├── build.sh                    # 打包成 SystemHelper.zip
├── module/
│   ├── module.prop
│   ├── common.sh               # 共享逻辑：定位框架目录、解析挂载点、打标签
│   ├── service.sh              # late_start：等待挂载 → 打标签
│   └── boot-completed.sh       # boot_completed：兜底再来一次
└── .github/workflows/build.yml # shellcheck + 打包 + tag 自动发 Release
```

`common.sh` 不硬编码模块 id：它遍历 `/data/adb/modules/*` 找唯一带
`bin/dex2oat` 的目录，再从 `/proc/self/mountinfo` 解析出实际挂载点。

## 依赖

1. **SUSFS 内核**，且实现以下命令：
   - `CMD_SUSFS_ADD_SUS_MOUNT`（0x55560）
   - `CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS`
   - `CMD_SUSFS_ADD_SUS_MAP`

   本项目验证所用内核：<https://github.com/fouc3-mirror/Resukisu>

   自检（返回 `SUSFS operation not supported` 说明内核未实现）：

   ```sh
   su -c "/data/adb/ksu/bin/ksu_susfs add_sus_mount /apex/com.android.art/bin/dex2oat64"
   ```

2. **susfs4ksu 模块**（提供 `/data/adb/ksu/bin/ksu_susfs`）
3. **LSPosed 2.0.3 原版**（任何二改版都会崩，见上）

## 安装

```sh
su -c "/data/adb/ksud module install /data/local/tmp/SystemHelper.zip"
```

或用模块管理器直接刷入，重启生效。

自行构建：

```sh
./build.sh          # 生成 SystemHelper.zip
```

## 验证

```sh
# 1. 本模块的运行日志
su -c cat /data/adb/system_helper.log
# 期望：add_sus_mount /apex/com.android.art/bin/dex2oat64 等条目

# 2. 内核侧确认
su -c dmesg | grep -E 'susfs_add_sus_mount|hide_sus_mnts'
# 期望：CMD_SUSFS_ADD_SUS_MOUNT -> ret: 0
#       susfs_is_hide_sus_mnts_for_non_su_procs_enabled: 1

# 3. App 视角（uid ≥ 10000 的进程）
#    读取 /proc/self/mountinfo 时应看不到 dex2oat 条目
```

## 工作流程

```
LSPosed daemon 启动
   └─ 在 PID 1 namespace bind-mount bin/dex2oat -> /apex/.../dex2oat{32,64}
        └─ system_helper 检测到挂载出现
             ├─ ksu_susfs hide_sus_mnts_for_non_su_procs 1
             ├─ ksu_susfs add_sus_mount <每个 dex2oat 挂载点>
             ├─ ksu_susfs add_sus_map <moddir>/zygisk/*.so
             └─ 60s 后重复一次（防止被其他模块重置）
```

## 限制

- 守护进程若在运行中 `umount` 后又重新挂载，新挂载不带标签，会重新暴露直到下次重启。
- `add_sus_map` 只对 uid ≥ 10000 的进程生效，system_server 等不受影响。
- 管理器包名仍是 `org.lsposed.manager`，若检测方查询"已安装应用列表"，本方案覆盖不到。
- 换回不支持上述命令的内核后，本模块会静默失效（错误写入日志），不影响开机。

## 致谢

- [LSPosed](https://github.com/LSPosed/LSPosed)
- [SUSFS / susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu)
- [KernelSU](https://github.com/tiann/KernelSU)
- [Resukisu](https://github.com/fouc3-mirror/Resukisu)（本项目验证所用内核）

## 免责声明

本项目仅用于个人设备的隐私与兼容性研究。使用者需自行承担一切后果，并遵守所在地法律法规。
