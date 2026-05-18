# ACK_TIMER 在 DATA_TIMER=2200 / BACKLOG=3 下的重新优化报告

生成时间：2026-05-16 23:11:00

## 目标

- 固定 `DATA_TIMER = 2200 ms`。
- 固定 `MAX_PHL_BACKLOG = 3 * FRAME_WIRE_BYTES(DATA_FRAME_LEN)`。
- 在默认误码率双向洪水场景下，以折中评分重新选择 `ACK_TIMER`。

## 修正说明

- 旧脚本使用 `Wait-Process -Id ...` 时会把已经正常 `Quit.` 的进程误记为 `ForcedStop=True`；本报告按日志中的 `Quit.` 重新修正该标志。
- 修正后的汇总表见 `all-results-corrected.csv`，原始分阶段 CSV 保留不覆盖。

## 评分公式

- `Score = AvgUtil - 0.03 * DataTimeoutPerMin - 0.002 * SendAckPerMin`
- 有效性条件：`BothQuit=True`、`Fatal=False`、`BadPacket=False`、`PhlOverflow=False`、`ForcedStop=False`。

## 默认误码长测排名

| ACK_TIMER | Runs | AvgScore | AvgUtil | Avg timeout/min | Avg ack/min | AllValid |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `120` | `2` | `86.146` | `86.68` | `11.675` | `91.725` | `True` |
| `100` | `1` | `86.12` | `86.63` | `10.6` | `96.1` | `True` |
| `80` | `2` | `85.994` | `86.515` | `11.075` | `94.15` | `True` |
| `140` | `1` | `85.756` | `86.3` | `11.95` | `92.55` | `True` |
| `180` | `2` | `85.72` | `86.292` | `13.3` | `86.675` | `True` |
| `160` | `1` | `85.658` | `86.21` | `12.4` | `90.15` | `True` |
| `200` | `1` | `85.166` | `85.73` | `13.1` | `85.65` | `True` |

## 无误码准入校验

| ACK_TIMER | AvgUtil | Send ACK/min | Score | Pass |
| ---: | ---: | ---: | ---: | --- |
| `80` | `96.685%` | `43` | `96.599` | `True` |
| `100` | `96.72%` | `43` | `96.634` | `True` |
| `120` | `96.93%` | `5` | `96.92` | `True` |
| `140` | `96.775%` | `33` | `96.709` | `True` |
| `160` | `96.72%` | `40` | `96.64` | `True` |
| `180` | `96.625%` | `59` | `96.507` | `True` |
| `200` | `96.935%` | `4` | `96.927` | `True` |

## 最终结论

- 最终采用 `ACK_TIMER = 120 ms`。
- 采用原因：`120 ms` 在默认误码长测中的平均分最高：`AvgScore = 86.146`，`AvgUtil = 86.68%`，`Avg timeout/min = 11.675`，`Avg ack/min = 91.725`。
- `100 ms` 是近邻候选，单次 20 分钟补充长测 `Score = 86.120`，低于 `120 ms` 的双样本平均 `86.146`；在不继续增加测试轮次的前提下保留 `120 ms` 更稳妥。

## 产物

- 修正汇总：`all-results-corrected.csv`
- 补充长测：`02b-补充长测-20min\results.csv`
- 补充无误码校验：`04b-补充无误码校验-2min\results.csv`
