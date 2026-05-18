# ACK_TIMER 在 DATA_TIMER=2200 / BACKLOG=3 下的重新优化报告

生成时间：2026-05-16 21:16:01

## 目标

- 固定 `DATA_TIMER = 2200 ms`。
- 固定 `MAX_PHL_BACKLOG = 3 * FRAME_WIRE_BYTES(DATA_FRAME_LEN)`。
- 在默认误码率双向洪水场景下，以折中评分重新选择 `ACK_TIMER`。

## 评分公式

- `Score = AvgUtil - 0.03 * DataTimeoutPerMin - 0.002 * SendAckPerMin`
- 仅当 `BothQuit=True`、`Fatal=False`、`BadPacket=False`、`PhlOverflow=False`、`ForcedStop=False` 时记为有效。

## 长测候选平均排名

| ACK_TIMER | Runs | AvgScore | AvgUtil | Avg timeout/min | Avg ack/min | AllValid |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `120` | `2` | `88.748` | `89.04` | `4` | `86` | `True` |
| `120180` | `1` | `81.47` | `81.83` | `12` | `0` | `True` |

## 最终结论

- 最终采用 `ACK_TIMER = 120 ms`。
- 采用原因：`AvgScore = 88.748`，`AvgUtil = 89.04%`，`Avg timeout/min = 4`，`Avg ack/min = 86`。

## 产物

- 粗筛结果：`01-粗筛-2min\results.csv`
- 长测结果：`02-长测-20min\results.csv`
- 复测结果：`03-冠军复测-20min\results.csv`
- 无误码校验：`04-无误码校验-2min\results.csv`
