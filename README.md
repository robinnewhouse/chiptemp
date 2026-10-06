# Chip Temps

A tiny macOS menu bar app that shows your Apple Silicon chip temperature.

- Menu bar shows the hottest spot on the chip, e.g. `49°`.
- Click it for current chip, SSD and battery temps plus a chart (5 minutes to 7 days).
- Reads every 5 seconds, keeps 7 days of history, starts at login (switch in the panel).
- No sudo: reads Apple's built-in sensors directly.

## Build and install

```sh
./build.sh
```

Needs Xcode Command Line Tools and macOS 14+. Builds `Chip Temps.app`, copies it to `/Applications`, and opens it.

History lives in `~/Library/Application Support/Chip Temps/history.csv`.

## Sensor notes

- `PMU tdie1`–`14`: 14 spots on the main chip. The app shows the hottest; the panel also shows the average.
- `NAND CH0 temp`: SSD. `gas gauge battery`: battery.
- Ignored: `PMU tdev1`–`8` (read about −9200°C) and `PMU tcal` (always 51.8; a fixed value, not a live reading).
