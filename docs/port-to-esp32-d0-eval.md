# Airfrog ESP32-C3 → ESP32-D0 移植工作量评估报告

> 仅评估，不改代码。工作目录：`/home/tpv/rust/airfrog`

## 调查概览

`/home/tpv/rust/airfrog` 是一个 Rust workspace，包含 5 个 crate 和一个 examples 子项目（`airfrog-ws`）。当前硬绑定到 ESP32-C3（单核 RISC-V，160MHz）+ esp-hal 1.0.0-rc.0。项目用作 SWD 调试器，只用了 2 个 GPIO（SWDIO=IO0，SWCLK=IO1），并启用了完整的 WiFi + HTTP + REST + Binary API + OTA + RTT 等功能。代码量约为 ~6300 行（firmware 部分）+ ~4400 行（SWD 库）。

---

## A. 差异影响矩阵

| 差异项 | 影响范围 | 评估 | 说明 |
|---|---|---|---|
| **esp-hal feature: `esp32c3` → `esp32`** | 5 个 `Cargo.toml` | 小改 | 全部 `esp32c3` 字符串改成 `esp32`（共 16 处，跨 4 个 Cargo.toml） |
| **target: `riscv32imc` → `xtensa-esp32-elf`** | `.cargo/config.toml`、`rust-toolchain.toml`、CI 脚本 | 小改 | 见 B.3 |
| **`esp-println` feature `esp32c3` → `esp32`** | `Cargo.toml` × 3 | 小改 | 同上，feature flag 切换 |
| **`esp-storage` feature `esp32c3` → `esp32`** | `airfrog/Cargo.toml:46` | 小改 | |
| **`esp-hal-embassy` feature `esp32c3` → `esp32`** | 3 个 Cargo.toml | 小改 | |
| **`esp-wifi` feature `esp32c3` → `esp32`** | 3 个 Cargo.toml + ESP-IDF 兼容性 | 小改 | esp-wifi 0.15 已声明 esp32 支持 |
| **`riscv::asm::delay()` 内联延时** | `airfrog-swd/src/protocol.rs:271,273,279,287,394,396` 共 6 处 | **大改** | RISC-V intrinsic，Xtensa 不可用。`riscv` crate 必须从 `airfrog/Cargo.toml:78`、`airfrog-swd/Cargo.toml:45` 移除，改用 `xtensa_lx::asm::delay` 或自实现 nop 循环。这是**唯一一处真正影响功能正确性的硬阻塞点** |
| **`riscv` crate 依赖** | `airfrog/Cargo.toml:78`、`airfrog-swd/Cargo.toml:45` | 大改 | 同上 |
| **`espflash --chip esp32c3` → `esp32`** | `.cargo/config.toml:2`、`build.sh:42`、`flash.sh:28` | 小改 | 3 处硬编码 |
| **GPIO 映射（SWD 用 IO0/IO1）** | 全部 | 无需改 | ESP32-D0 的 GPIO0/GPIO1 是普通双向 IO，没有 input-only 限制，SWD bit-bang 兼容 |
| **BOOT 按钮 = GPIO9** | `BUILD.md:37`、`docs/FAQ.md:54` | 无需改 | GPIO9 在 ESP32-D0 是普通 GPIO；但启动时需下拉，**注意 strapping pin 行为**（ESP32-D0 的 GPIO9 在 reset 时不能直接为低——通常 BOOT mode 用 GPIO0）|
| **CPU 时钟 160MHz → 240MHz** | `airfrog-swd/src/protocol.rs` 的 SWD 速度表 | **需要重新校准** | `Turbo` 模式的延时循环是按 160MHz 算的（`clock_high/low_cycles=0`），换 240MHz 后 bit-bang 速度会变得太快，需调小 cycle 数；`Slow/Medium/Fast`（75/33/10 cycles）也需要重新算 |
| **`CpuClock::max()`** | 所有 main.rs 例子 | 无需改 | esp-hal 自动用该芯片的最大频率 |
| **`Cpu::current()` 和 `esp_hal::rtc_cntl::reset_reason`** | `airfrog/src/device.rs:86-87` | 无需改 | 两边都支持 |
| **`SystemTimer` (systimer)** | `airfrog/src/device.rs:16` | 无需改 | ESP32 也有 systimer（C3 是 SYSTIMER，ESP32-D0 也是 SYSTIMER 模块） |
| **`Efuse::read_base_mac_address()`** | `airfrog/src/device.rs:49` | 无需改 | 两边都有 eFuse |
| **`Rng::new(peripherals.RNG)`** | `airfrog-util/src/net.rs:313` | 无需改 | |
| **`esp_wifi::init(...)` & `WifiController`** | `airfrog-util/src/net.rs:318-319` | 无需改 | esp-wifi 已经原生支持 ESP32（用 HSPI 接 WiFi） |
| **`TIMG0`、`TIMG1`** | 多处 | 无需改 | ESP32-D0 也有 TIMG0/1 |
| **`esp_bootloader_esp_idf::esp_app_desc!()`** | `airfrog/src/main.rs:103`、所有 examples | 无需改 | esp-bootloader-esp-idf 同时支持两芯片 |
| **`esp_storage::FlashStorage`** | `airfrog/src/flash.rs:13` | 无需改 | 通用封装 |
| **`esp_backtrace`** | `airfrog/Cargo.toml:49` | 小改 | feature `esp32c3` → `esp32` |
| **`esp_println` 默认用 UART0** | `airfrog/src/main.rs:165` 等 | 无需改 | ESP32-D0 UART0 是 GPIO1/GPIO3（注意 SWD 用了 IO0/IO1，**没冲突**） |
| **无 USB-Serial/JTAG** | 烧录流程 | 中改 | ESP32-C3-MINI-1 内置 USB-Serial/JTAG；ESP32-D0 没有。**板子必须有外部 USB-UART 桥（CP2102/CH340）或保留 UART 编程口**——现有 PCB rev-b 留有 UART 编程口（FAQ.md:49-54），所以**功能上不丢，但流程要改文档** |
| **双核 vs 单核 SMP** | 共享状态、`CriticalSectionRawMutex` | 无需改 | 项目用 `embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex`（软件实现的临界区），以及 `embassy_executor` 单线程 executor。**双核不会破坏正确性**——只是第二核默认闲置。如果想利用 SMP 反而是额外工作 |
| **partition table 4MB** | `airfrog/partitions.csv` | 无需改 | ESP32-WROOM-32 默认就是 4MB |
| **linker scripts `linkall.x`** | build.rs 中 `-Tlinkall.x` | 无需改 | esp-hal 内部根据 feature 自动选用 `ld/esp32c3/...` 或 `ld/esp32/...`；项目里写的只是 `-Tlinkall.x` 这个总入口 |
| **`memory.x`** | 无 | 无需改 | 完全由 esp-hal 提供 |
| **`ledc`、`spi`、`adc`、`i2c`、`usb_serial_jtag`、`twai` 等** | 无 | 无需改 | 项目**完全没用**这些外设 |
| **PSRAM** | 无 | 无需改 | 现有代码没有使用 PSRAM（`esp-alloc` 只声明 `HEAP_SIZE=128K`，远小于内部 SRAM 328K），不需要 PSRAM 路径。但 ESP32-D0WD-PSR/ESP32-D0WD-V3 带 PSRAM 时 `esp-alloc` 也可以把 heap 放到 PSRAM——可选优化 |
| **flash 加密 / eFuse / secure boot V2** | 无 | 无需改 | 项目未使用 |
| **OTA / 双 OTA 分区** | `airfrog/partitions.csv` | 无需改 | 通用 |
| **docs 中的"160MHz"、"4MHz SWD"、"bit-banging"、"RISC-V variants"等描述** | `docs/TECHNICAL.md:41,45,50,64`、`docs/FAQ.md:117,127,129-137,152-156` | 中改 | 这些都是宣传性文字，需改写成 ESP32-D0 背景。`docs/TECHNICAL.md` 整段"ESP32-C3"小节要重写。`README.md:9,14,78` 也要改 |
| **CI 脚本** | `.github/workflows/rust_ci.yml:34`、`ci/check.sh` | 中改 | `.github` 改 target 为 `xtensa-esp32-elf-espidf` 之类（注意 esp-hal 用 Xtensa 目标命名 `xtensa-esp32-elf` 而非 `xtensa-esp32-none-elf`，还需安装 `esp-idf` 工具链或用 espup） |
| **espflash save-image `--merge`** | `build.sh:42-43` | 小改 | `--chip esp32` 即可 |

---

## B. 必改项清单

### B.1 Cargo features（5 个文件，~16 处）

| 文件:行 | 改动 |
|---|---|
| `Cargo.toml:39` | `esp32c3` → `esp32` |
| `Cargo.toml:44` | `esp32c3` → `esp32` |
| `Cargo.toml:49` | `esp-println` 的 `esp32c3` → `esp32` |
| `Cargo.toml:55` | `esp-hal-embassy` 的 `esp32c3` → `esp32` |
| `Cargo.toml:59` | `esp-wifi` 的 `esp32c3` → `esp32` |
| `Cargo.toml:78` | **删掉** `riscv = "0.14.0"`（或 `cfg`-gate） |
| `airfrog/Cargo.toml:43,46,50,55,61,65` | `esp32c3` → `esp32`（6 处） |
| `airfrog-util/Cargo.toml:27,32,48` | `esp32c3` → `esp32`（3 处） |
| `airfrog-swd/Cargo.toml:28` | `esp32c3` → `esp32` |
| `airfrog-swd/Cargo.toml:45` | **删掉** `riscv = "0.14.0"` |

### B.2 RISC-V 延时替换（**核心改动**）

`airfrog-swd/src/protocol.rs:271,273,279,287,394,396`：

```rust
riscv::asm::delay(self.clock_low_cycles);   // 改：core::hint::spin_loop() 循环 N 次
                                            // 或 xtensa-lx asm::delay（如果 esp-hal 1.0 对 ESP32 提供）
                                            // 建议自实现一个 #[inline] nop 循环以保证计时准确
```

需要在 `airfrog-swd/src/protocol.rs` 顶部新增一个 trait 或内联 nop 函数，约 10-20 行新代码。

### B.3 工具链 & 构建脚本

| 文件:行 | 改动 |
|---|---|
| `rust-toolchain.toml:4` | `riscv32imc-unknown-none-elf` → `xtensa-esp32-elf`（esp-hal 推荐名字） |
| `.cargo/config.toml:1` | `[target.riscv32imc-unknown-none-elf]` → `[target.xtensa-esp32-elf]` |
| `.cargo/config.toml:2` | `--chip esp32c3` → `--chip esp32` |
| `.cargo/config.toml:14` | `target = "riscv32imc-..."` → `target = "xtensa-esp32-elf"` |
| `.cargo/config.toml:17` | 保留 `build-std` |
| `build.sh:15,42-43` | target 路径 + `--chip esp32` |
| `flash.sh:28-29` | `--chip esp32` + target 路径 |
| `.vscode/settings.json:6` | `riscv32imc-...` → `xtensa-esp32-elf` |
| `.github/workflows/rust_ci.yml:34` | target 改 Xtensa |

### B.4 SWD 速度重新校准（Turbo 4MHz 不再可行）

`airfrog-swd/src/protocol.rs:106-122` 中的 `Speed::clock_high/low_cycles`：

| 速度 | C3 @ 160MHz | D0 @ 240MHz 粗估 |
|---|---|---|
| Slow | 75 cycles ≈ 0.5MHz | ~112 cycles |
| Medium | 33 cycles ≈ 1MHz | ~50 cycles |
| Fast | 10 cycles ≈ 2MHz | ~15 cycles |
| Turbo | 0 cycles ≈ 4MHz | 0 cycles ≈ 6-8MHz（可能太快） |

实际上 bit-bang 速率上限被 GPIO 翻转速度决定，ESP32-D0 GPIO 翻转速度与 C3 接近，所以可考虑把 Turbo 仍标为 4MHz 但接受计时精度变化；或重新测速后调整。

### B.5 文档重写

| 文件 | 改动 |
|---|---|
| `README.md:9` | "$3 ESP32-C3 module" → "ESP32-WROOM-32" |
| `README.md:78` | "ESP32-C3-MINI-1" → 改成 ESP32-D0W 模组 |
| `docs/TECHNICAL.md:41-65` 整段 | 重写"SWD 实现"和"ESP32-C3"小节 |
| `docs/FAQ.md:36,117,127,129-137,152-156` | 多处提及 ESP32-C3 需调整 |
| `docs/FAQ.md:54` | IO9/BOOT 描述：ESP32-D0 编程用 **GPIO0** 拉低（不是 IO9）—— 这是 ESP32-C3 特有的约定 |
| `docs/FAQ.md:154-156` | 重写 4MHz SWD 来源 |
| `BUILD.md:37` | "Hold BOOT (GP9) low" → "Hold GPIO0 low"（ESP32-D0 烧录约定）|

### B.6 PCB 兼容

| 文件 | 改动 |
|---|---|
| `pcb/airfrog-rev-b/fab/airfrog-rev-b-bom.csv:6` | ESP32-C3-MINI-1 → ESP32-WROOM-32（或 ESP32-D0WD-V3）|
| `pcb/airfrog-rev-a2/fab/airfrog-rev-a2-bom.csv:10` | 同上 |
| 原理图 | 需要重新设计——ESP32-WROOM-32 模组引脚定义与 ESP32-C3-MINI-1 不同（PIN 1 是 GND，PIN 8 是 EN 等），且需要外部 USB-UART 桥 |
| 板型 | ESP32-WROOM-32 是 18×25.5mm（比 MINI-1 的 16×28mm 大一点点但形状不同），可能影响 16×28mm PCB 布局 |

### B.7 可选

- `airfrog/src/main.rs:184` 的 TIMG1 init 和 `airfrog-util/src/net.rs:227` 的 TIMG0 init：**无需改**——esp-hal 在 ESP32 也提供同名外设

---

## C. 风险点

### C.1 ESP32-C3 → ESP32-D0 非代码风险

| 风险 | 严重度 | 说明 |
|---|---|---|
| **PCB 必须重新设计** | 高 | ESP32-C3-MINI-1 与 ESP32-WROOM-32 模组封装完全不同，前者 16×28mm 8-pin/2-side castellation，后者 18×25.5mm SMD-38-pin，且 IO 顺序差异大。**不能直接换芯片** |
| **ESP32-D0 没有原生 USB-Serial/JTAG** | 中 | 现有烧录流程假设内置 USB。C3-MINI-1 通过 USB 直接烧，ESP32-WROOM-32 必须经外部 USB-UART。**需在 PCB 加 CH340/CP2102 或保留 UART 编程口**（FAQ.md 已经预留了编程口，硬件上不用改 PCB 太多） |
| **GPIO9 不是 ESP32-D0 的 BOOT 按钮** | 中 | ESP32-C3 的烧录模式是 GPIO9=LOW；ESP32-D0 是 **GPIO0=LOW**。需要改 BUILD.md 烧录说明（30 秒工作量） |
| **GPIO strapping pin 时序差异** | 中 | ESP32-D0 GPIO2/12/15/0 在 boot 时有特殊电平要求，ESP32-C3 是 GPIO2/8/9。若 PCB 用了 GPIOs 2/12/15 做其他用途，需确认 |
| **flash 容量** | 低 | ESP32-C3-MINI-1 = 4MB；ESP32-WROOM-32 = 4MB（多数版本）；partitions.csv 不用改 |
| **WiFi 性能** | 低 | ESP32-D0 WiFi 与 C3 性能相近；但 ESP32-D0 没有 BLE |
| **PSRAM** | 低 | 可选优化：HEAP_SIZE 现在只有 128K，不需要 PSRAM |
| **芯片涨价** | 中 | ESP32-C3 模块目前 ~$3；ESP32-WROOM-32 ~$3-4，但 BOM 上"$3"卖点会受影响 |
| **community/可获得性** | 中 | ESP32-C3 是近 5 年新设计，社区资源更多；ESP32-D0 是 2016 年产品，长期供货更稳定（但 Espressif 已把它列入"经典"档） |

### C.2 esp-hal 对 ESP32 双核的成熟度

- **esp-hal 1.0.0-rc.0 支持 ESP32（Xtensa LX6）**——`Cargo.lock` 已经把 `esp32 v0.38.0`、`xtensa-lx`、`xtensa-lx-rt` 都拉进来了，说明依赖图支持
- **双核 SMP 在 esp-hal 1.0 中的支持**：
  - esp-hal 1.0 不默认启用 SMP（不切第二个核），esp-hal-embassy 仍然是单 executor
  - 现有代码用 `embassy_executor::main` 单线程，第二核闲置——**功能不会出错**
  - 如果想让双核工作，需要 `embassy-executor` 的 `integrated-timers` + `executor-thread` 模式分别跑在两个核上，或者用 esp-idf-style task pinning。**当前 embassy-executor 0.7 没有自动 SMP 调度**，所以不用动
- **xtensa-lx asm::delay 是否可用**：经查 esp-hal 的 `xtensa-lx` 提供 `asm::delay`（与 `riscv::asm::delay` 签名类似）。可直接替换——**但要实测**
- **Xtensa 工具链**：
  - 需要 `espup` 或 rust-xtensa 工具链（esp-hal 文档推荐 `espup install`）
  - `rust-toolchain.toml` 中 `channel = "nightly"` 和 `components = ["rust-src"]` 之外，还需要 `rustup target add xtensa-esp32-elf`（或 espup 安装对应 target）
  - 当前 `targets = ["riscv32imc-..."]` 是错的；应改成 `["xtensa-esp32-elf"]`
  - 注意：esp-hal 1.0 默认使用 **`xtensa-esp32-espidf`** target（带 esp-idf libc），不是裸机 `xtensa-esp32-none-elf`
- **esp-hal 1.0 RC 版稳定性**：
  - 1.0.0-rc.0 是 RC（pre-release），不是 stable。生产项目通常会等 1.0 stable
  - esp32 支持在 esp-hal 中是相对成熟的（不像 c6/h2 是新的）
  - 已知问题：esp-wifi 在 ESP32 上尚有一些限制（WiFi+CPU 高负载下栈冲突历史较多）

### C.3 SWD 性能变化

ESP32-D0 时钟 240MHz → bit-bang 自然速度上限提高，但 GPIO 翻转速度与 ESP32-C3 相近（~50MHz 边沿速率）。实际可达 Turbo ~4-6MHz。**但软件计算的 cycle 数需要重新校准**，否则时序错误会引发 parity error。

---

## D. 工作量估算

### D.1 总工时

| 类别 | 估计工时 |
|---|---|
| **必改代码（feature flag 替换 + 工具链 + 文档）** | 4-6 小时 |
| **核心：riscv::asm::delay 替换 + 重新校准** | 6-12 小时 |
| **SWD 时序在新芯片上的重新调试** | 8-16 小时 |
| **CI / build script 更新** | 2-4 小时 |
| **文档重写（README、TECHNICAL、FAQ、BUILD）** | 3-4 小时 |
| **双核潜在问题调试预留** | 4-8 小时 |
| **PCB 重设计**（如需要） | 30-50 小时（独立大任务） |
| **测试 & 验证（烧录、SWD 实测、网络测试）** | 8-16 小时 |

**软件部分总计**：约 **35-65 人·小时（4-8 人·天）**
**含 PCB 重设计**：约 **65-115 人·小时（8-14 人·天）**

### D.2 阶段拆分

| 阶段 | 内容 | 预期时长 |
|---|---|---|
| **POC（最低可行验证）** | D.3 | 1-2 天 |
| **阶段 1：代码替换** | feature flag、riscv→xtensa、SWD 时序表、文档、脚本 | 2-3 天 |
| **阶段 2：验证** | 在 ESP32-D0 板上烧录、跑通 swd-basic、mqtt、OTA | 2-3 天 |
| **阶段 3：PCB 适配**（如需要） | 新 PCB 设计 → 打样 → 验证 | 5-10 天（外包 fab 至少 +1 周） |

### D.3 POC 建议

**最小可行性测试**：把 `airfrog/Cargo.toml` 全部 `esp32c3` 改成 `esp32`，`riscv` 删掉，`rust-toolchain.toml` 改成 `xtensa-esp32-espidf`，替换 `airfrog-swd/src/protocol.rs` 里的 `riscv::asm::delay`，然后用 `examples/swd-basic.rs` 在 ESP32-D0 DevKit 上：

```bash
# 伪命令（不执行，仅示意）
rustup target add xtensa-esp32-espidf
cargo build --example swd-basic
espflash flash --chip esp32 target/.../swd-basic
```

**POC 通过标准**：能读到目标 STM32 的 IDCODE（证明 GPIO bit-bang 工作），并且 `slow/medium/fast/turbo` 四档速度都能用。

**POC 不需要做的事**：
- 不需要重 PCB（用现成 ESP32-DevKitC 或 NodeMCU-32S）
- 不需要做 WiFi（先验证 SWD bit-bang）
- 不需要做完整 HTML 界面
- 不需要处理 flash 加密 / secure boot

---

## E. 是否建议做

### 结论：**不建议为了"换芯片"而换芯片**，除非有强约束。

### 详细理由

**ESP32-C3 优势（airfrog 现状）**：
1. **价格更低**：C3-MINI-1 在 2025 年长期 ~$1.5-2.5（量产价）；ESP32-WROOM-32 仍 ~$2.5-3.5，**项目"$3 模组"卖点受影响**
2. **更小封装**：MINI-1 是 16×28mm 8-pin 极简模组；ESP32-WROOM-32 是 18×25.5mm 但**38-pin SMD castellation，需要回流焊**，hand-soldering 极难（项目 README 强调 hand-solderable）
3. **内置 USB-Serial/JTAG**：无需 USB-UART 桥，BOM 更简
4. **RISC-V 单核** 资源占用比 ESP32 略低，启动略快
5. **更现代**：C3 推出时间晚（2020），bug 更少，文档更新

**ESP32-D0 优势（值得换的理由）**：
1. **双核**：如果将来想做实时 SWD + WiFi + RTT 并行处理更重的负载（但目前不需要）
2. **PSRAM**：未来可以跑更大固件
3. **更多 GPIO**（40 vs 22）：但项目只用了 2 个 GPIO
4. **更成熟的 esp-idf 生态**：但项目用 esp-hal，生态影响小
5. **Xtensa 性能更强**（240MHz vs 160MHz）：但 SWD bit-bang 受限于 GPIO 而非 CPU

### 唯一可能要做的情况

1. **ESP32-C3 长期供货紧张/停产**（目前还看不到这个迹象）
2. **需要 PSRAM 跑大固件**（项目当前 < 1MB，不需要）
3. **已有 ESP32-D0 库存要消化**
4. **需要 BLE**（airfrog 完全没有 BLE 功能需求）

### 如果一定要做，建议路径

1. **先做 POC**（1-2 天）：用 ESP32-DevKitC + swd-basic 验证 esp-hal 在 ESP32 上的稳定性
2. **仅做软件改造**（暂不改 PCB）：保留现有 ESP32-C3-MINI-1 PCB 不变，仅将 firmware 移植完成并验证它在 ESP32-D0 平台上能跑
3. **PCB 仅在用户明确需要时再做**：可在 `pcb/` 下新增 `airfrog-esp32/` 子目录
4. **保留双 build matrix**：让一个 codebase 同时支持两个芯片，用 `[target.'cfg(...)']` 或 feature flag 切换（更长期价值）

---

## TL;DR

1. **移植软件部分工作量约 4-8 人·天**（不算 PCB 重设计），主要阻塞点是 `airfrog-swd/src/protocol.rs` 里 6 处 `riscv::asm::delay()` 必须替换为 Xtensa 等价物，并且 SWD 时序表需要按 240MHz 重新校准；其余 16 处 feature flag 和 3 处构建脚本替换是机械工作。
2. **esp-hal 1.0 RC 已支持 ESP32**，`Cargo.lock` 已包含 `xtensa-lx/xtensa-lx-rt/esp32` 依赖，但需要切换 toolchain 到 `xtensa-esp32-espidf` target（注意是 espidf 不是裸机），并使用 `espup` 安装 Xtensa nightly 工具链；双核 SMP 在当前 embassy 单 executor 模型下不会破坏正确性。
3. **PCB 不可直接替换**：ESP32-C3-MINI-1（16×28mm 8-pin castellation）与 ESP32-WROOM-32（18×25.5mm 38-pin SMD）封装、引脚定义、烧录方式（USB-Serial/JTAG vs UART）完全不同，**必须重设计 PCB**，约 5-10 人·天。
4. **不建议迁移**：ESP32-C3 在尺寸、价格、内置 USB、单核简洁性上都更适合 airfrog "$3、可手焊、零 BOM" 的产品定位；ESP32-D0 没有显著优势抵消 PCB 改造和 SWD 时序重新校准的成本，除非有供货/库存/PSRAM 等外部强约束。
5. **建议先做 1-2 天 POC**：用 ESP32-DevKitC + `examples/swd-basic.rs` 验证 esp-hal 在 ESP32 上的 bit-bang 兼容性，确认后再决定是否投入 PCB 改造。