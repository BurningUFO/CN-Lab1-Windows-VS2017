# Performance Table Supplement Results

Run directory: `C:/code/CN-Lab1-Windows-VS2017/docs/测试记录/性能测试记录表/perf-table-20260516-235231`

Runtime: 620 s. Current implementation: Selective Repeat. GoBackN columns were not measured in this project run.

| Id | Command | Description | Runtime(s) | Selective A | Selective B | Issue |
|---:|---|---|---:|---:|---:|---|
| 1 | `--utopia` | 无误码信道数据传输 | 620 | 53.05% | 96.95% | none |
| 2 | `无` | 站点A平缓方式发出数据，站点B周期性交替发送/停发 | 620 | 49.06% | 90.46% | none |
| 3 | `--flood --utopia` | 无误码信道，A/B 洪水式产生分组 | 620 | 96.86% | 96.87% | none |
| 4 | `--flood` | 默认误码率，A/B 洪水式产生分组 | 620 | 87.41% | 85.20% | none |
| 5 | `--flood --ber=1e-4` | 误码率 1e-4，A/B 洪水式产生分组 | 620 | 48.34% | 47.31% | none |
