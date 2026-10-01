# Visual reference for the widgets

The approved mockups, described so they can be rebuilt in SwiftUI. All figures
shown in the mockups are samples.

## Palette and type

| Role | Colour |
|---|---|
| Widget background | `#0E1318` |
| Primary text | `#EEF2F6` |
| Secondary text | `#9AA7B4` |
| Allocated / running (blue) | `#3F8FE0` |
| Pending / needs attention (amber) | `#FFC073` |
| Idle node cell fill / track | `#26323E`, outline `#5B6B7B` |
| Idle segment in ring and bars | `#45586B` |
| Drained (grey) | `#8A96A3` |
| Down (light red) | `#FF8A80`, white outline in the node grid |
| Busy GPU card fill | `#14324F`, outline blue |
| Idle-allocated GPU card fill | `#3A2A12`, outline and text amber |
| Stale figures | `#6F7C89` |

Widgets are always dark, regardless of system appearance. Figures use the
system monospaced design (`.monospaced`), labels the default design. Every
widget has a header row: title on the left in small capitals style (11 pt,
semibold, secondary colour, upper case, slight tracking), the snapshot time
`HH:mm` on the right in monospaced 11 pt. Medium and larger widgets carry a
refresh button (an `AppIntent` button) beside the time.

## Queue

- **Small:** two large figures side by side: running (blue) and pending
  (amber), each with a small label below. Footer, separated by a hairline:
  "mine" left, `12 R · 3 PD` right.
- **Medium:** title "Queue · all partitions" (or the partition name). Left:
  running and pending figures stacked. Right: "Pending, by reason", then one
  horizontal bar per reason (label, amber bar on a track, count), up to four.
- **Large:** title "My jobs · 12 R · 3 PD". Up to seven rows, hairline
  between: a state chip (`R` blue outline, `PD` amber outline), job name
  (monospaced) with partition and resources below in secondary, and on the
  right either `5:12 / 12:00` with "elapsed", `~ 15:40` with "est. start", or
  the pending reason with "reason". Footer "and N more" when there are more.

## Nodes

- **Small:** a ring with four segments (allocated, idle, drained, down), the
  allocated percentage in the centre with "allocated" below it. Under the
  ring a two-by-two legend with counts.
- **Medium:** title "Nodes · by partition". One row per partition (up to
  four): name, a stacked bar of the four states, `148/170`, and "2 down"
  (light red when more than one is down). Legend with totals as footer.
- **Extra large (iPad):** title "Nodes · 240". One block per partition: name
  and `148/170` on the left, then a wrapping grid with one 12 pt rounded cell
  per node, coloured by state. Legend with totals as footer.

## QOS

- **Medium:** title "QOS · CPUs in use". One bar per QOS (up to three or
  four): name, bar, `14.2k / 18k`. The bar turns amber above 95 % of the
  limit. Footer: "fairshare · my account" left, the value right.

## GPU

- **Small:** large `14` in blue with `/ 24` in secondary beside it. Below, in
  amber: "3 allocated but idle" (omitted when metrics are unavailable or the
  count is zero). Footer: `A100 11/16` left, `A40 3/8` right.
- **Medium:** title "GPU · by card type". Left: one bar per type with
  `11/16`; below three small figures: pending jobs (amber), longest wait
  (`3h 12m`), idle cards (amber). Right: a six-hour utilisation sparkline
  with "utilisation, 6 h" and the current percentage below. Without metrics
  the sparkline shows the allocated fraction and is labelled "allocated, 6 h".
- **Large:** title "GPU nodes · 14/24". Nodes grouped by type, each group
  with a heading (`A100 · 4 per node`, `11/16` right). One row per node:
  name (monospaced), then one cell per card, 58 × 30 pt, rounded. Busy: dark
  blue fill, blue outline, utilisation `97%`. Idle-allocated: dark amber
  fill, amber outline and text. Allocated without metrics: as busy, text
  "alloc". Free: outline only, "free" in secondary. Drained: grey outline,
  "drain". Down: light red outline, "down". A 3 pt bar along the bottom of
  the cell shows memory use. Footer legend. At most eight node rows; beyond
  that, "and N more nodes".
- **Extra large (iPad):** the same grid with wider cells (112 pt) showing
  utilisation, memory (`36G`), temperature (`74°`) and power (`286W`). On the
  right, behind a hairline: "Top users · cards" with up to five rows, and at
  the bottom the legend and `6 jobs pending · 3h 12m`.

## Runners

- **CI, small:** title "CI runners". Two figures: alive (blue), waiting
  (amber). Footer: "oldest wait" left, `18 min` right.
- **Dask, medium:** title "Dask clusters · 3". Column headings: cluster,
  workers, time left. One row per cluster (up to three): a dot (blue when
  the scheduler is alive, light red otherwise), `owner · id`, `14/16`,
  `0:42` (amber below 15 minutes, "—" when unknown). Footer "dot: scheduler
  alive".
- **JupyterHub, small:** title "JupyterHub". One figure: sessions (blue).
  Footer, two lines: "with a GPU" and its count; "near walltime" and its
  count in amber.

## States

- **VPN needed:** the family title and the time of the last snapshot in the
  header; a shield-with-cross symbol in amber and "VPN needed" in semibold;
  footer "last seen" with the key figures of the last snapshot in secondary.
- **Sign in needed:** header with "—" as time; a key symbol in amber and
  "Sign in needed"; footer "Tap to open the app". No data shown.
- **Stale:** the normal layout, with all figures and bars in the stale grey
  and the header time replaced by "as of 13:05" in amber.

## Lock screen

- **Circular:** gauge of the allocated node fraction with the percentage as
  a number in the centre.
- **Rectangular:** "Next job start", the time `~ 15:40`, and the job name.
  Shows "VPN needed" or "Sign in needed" in those states; when the user has
  no pending job, shows `12 R · 3 PD`.
- **Inline:** `12 R · 3 PD`.
