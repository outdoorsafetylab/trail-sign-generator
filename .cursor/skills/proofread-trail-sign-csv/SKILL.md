---
name: proofread-trail-sign-csv
description: >-
  Proofreads trail-sign CSV data against SVG templates and waypoint-arrow
  conventions (solid ➡ vs hollow ⇨), including 反向路標. Use when the user
  asks to 校對, audit, or check a route CSV (SM300, YM150/YM160/YM170,
  SM400, etc.), 分段第一行/第二行 arrows, reverse/inbound signs, printed
  fields, TWD97/WGS84, or landmark names before generating PDFs.
---

# Proofread trail-sign CSV

Proof **content that will be printed**, not every CSV column. Do not regenerate PDFs unless asked.

## 1. Which columns are printed

1. Open the milestone YAML (`input.template`, `input.data`).
2. A CSV header is printed iff that **exact header string** appears in the template SVG (the generator does `gsub(header, value)`).
3. Ignore headers that never appear in the SVG (typical leftovers: `Waypoint`, `里程(公里)`, `路線分段`, `GPX航點`).
4. Combined template text such as `WGS84 N緯度 E經度` still prints `緯度` / `經度` via substring replace. Same for `TWD97 X東距 Y北距`.

`hide_when_empty` in YAML only hides drawings when a column is blank; blank `里程` on a peak plate is valid.

## 2. Mechanical checks (all printed columns)

Run these against every data row. Report counts and a few examples, not a dump of every row.

| Check | Expectation |
| --- | --- |
| `路線名稱` / `路線編號` | Constant for the route |
| `總里程` | Constant integer (route length). Unchanged on the return half |
| `里程` | **Outbound:** contiguous `0 … N`. **Inbound:** same integers descending `N-1 … 0`. Repeats are required, not errors. A blank-`里程` row is a spur/peak plate, not a gap |
| Consecutive WGS84 | Haversine ≈ 100 m per 0.1 km **within one direction**. At the outbound→inbound hinge, coordinates retrace; do not flag that as a jump. Spurs may jump. Short stretches (30–50 m) can be GPX bunching — note, do not fail |
| WGS84 vs TWD97 | If sibling repo `gpxtoolkit` exists, `twd97.FromWGS84(lng, lat, pkm=false)` should match `東距`/`北距` within **1 m** (values are integer metres). Do not reimplement TWD97 in Python |

## 3. Segment arrows (分段第一行 + 分段第二行)

Arrows are meaningful. Canonical outbound+inbound: `玉山後四峰/YM160.csv` (also YM150, YM170). Arrow placement on a one-way stretch: `白姑大山/SM400.csv`.

Concatenate both lines into one ordered waypoint chain. Parse tokens:

`名稱(公里數字)` + optional `➡` or `⇨`

- **➡** (solid): exactly one per sign. Marks **you-are-here** on the listed chain — the last listed waypoint already reached.
- **⇨** (hollow): every other listed waypoint (already passed **or** still ahead).
- The last waypoint often has **no** trailing arrow.
- `地標名稱` need **not** appear in the chain (minor water, gates, cairns). If a landmark km **equals** a listed km, names should match or one should contain the other (e.g. `火石山下營地/水源` vs `火石山下營地`).

**Which token gets ➡** (outbound, listed km non-decreasing):

the last item with `km <= current 里程`.

**Inbound** (listed km non-increasing):

the last item in list order with `km >= current 里程`.

The whole chain may be **replaced** at a major camp/trailhead (new first km ≈ current `里程`). That is valid. Do not require one chain for the entire CSV.

**Empty 分段** is allowed when:

- the **far-end / peak plate** (YM160: `南玉山` at 55) — then inbound rows. Do not treat this as “done” if 反向 is still planned
- spur/peak plate with blank mileage (may exist only on outbound)

Flag as a note, not an automatic error.

### Typical bug after renaming waypoints

Arrow **switch mileage** left over from a removed listed point (e.g. still advancing ➡ at old km 115 after deleting `雙溪前營地(115)`). Fix: ➡ must follow the **current** listed km values, not historical ones.

## 3b. Reverse half (反向路標)

Canonical: **玉山後四峰** (`YM160.csv`, `YM150.csv`, `YM170.csv`). Same CSV, same YAML/SVG; the generator does not flip arrows. `玉山後四峰/sample.csv` shows two faces at one post (same km/coords, outbound chain vs inbound chain).

Pattern (use the 0.1K series; some YM files also append extra sparse landmark rows — do not copy that):

1. Outbound `里程` `0 … N-1` at 0.1 km, then far-end row `N` with **empty 分段** (peak name only).
2. Immediately: inbound `N-1 … 0`, same coords as the matching outbound `里程`.
3. Reverse the listed chain (far peak first, start last). Same names and km digits. Apply the inbound ➡ rule.
   - Outbound: `圓峰山屋(00)➡三叉路口(08)⇨` … `⇨南玉山(55)`
   - Inbound: `南玉山(55)➡小南山登山口(35)⇨` … `⇨圓峰山屋(00)`
4. `地標名稱` at the same km matches both directions.
5. Skip spurs that are not walked on the return (e.g. SM300 `大雪山`).
6. If the outbound chain is **replaced in blocks** (SM300 camps), reverse **each block** the same way; do not collapse into one chain unless the outbound was one chain.

When building SM300 reverse: after `翠池山屋` empty 分段, append 519→0 with reversed blocks; copy lat/lng/東距/北距 from the outbound row of that `里程`.

## 4. Landmarks vs overflow

- List nonempty `地標名稱` with `里程` for human spot-check against maps.
- Note unusually long printed strings (`地標名稱` ≥ 8 CJK, 分段 lines ≥ 28 chars). Overflow is a layout risk; confirm in SVG/PDF, do not auto-resize fonts unless asked.

## 5. Report format

Lead with pass/fail on arrows and coords. Then:

1. Printed vs ignored columns
2. Arrow: violations only (row/`里程`/got/expected). If clean, say so and list chain-switch blocks briefly
3. Mileage/total/gaps (check outbound and inbound halves separately)
4. Coordinate residuals (max \|ΔE\|, \|ΔN\|) or “gpxtoolkit not available”
5. Empty-分段 notes, long strings, landmark list if relevant

Do not treat reference-only columns (`Waypoint` like `1.5k`) as print errors.
