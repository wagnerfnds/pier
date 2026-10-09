## Reading a Tide Chart

A tide chart looks intimidating at first, but it boils down to a handful of numbers and a simple pattern. Once you know what each column means, you can plan a shoreline visit in under a minute. Most coastlines see two high tides and two low tides each day, roughly six hours apart, though some regions have only one of each.

### Decoding the Numbers

Every chart lists times and heights. Heights are measured in feet or meters relative to a baseline called "mean lower low water," which is the average of the lowest daily tides. A height of `0.0` means the water sits at that average low mark. Negative values, known as minus tides, mean the water has dropped even lower, exposing parts of the shore that are usually submerged. These are the best days for tide pooling.

You will typically see these entries:

- **High tide:** The peak water level, labeled `H` on many charts, when the shore is most covered.
- **Low tide:** The lowest level, labeled `L`, when pools and flats are most exposed.
- **Height:** The water level at that moment, compared against the baseline.
- **Range:** The difference between consecutive highs and lows, which tells you how dramatic the swing will be.

Tides also follow the moon. Around new and full moons you get "spring tides" with larger ranges, while quarter moons bring gentler "neap tides." Official predictions from [NOAA](https://example.com/tides) account for these cycles and are published for specific stations, so always choose the station nearest your beach.

> "Time and tide wait for no one."

That old proverb is practical advice. The water moves faster than it appears, especially across flat sand, so build in a safety margin.

### Working Out Your Window

Tides change gradually, not in a straight line. The water moves slowly just after a high or low, then speeds up through the middle of the cycle. A handy shortcut is the "rule of twelfths," which says the tide moves roughly one twelfth of its range in the first hour, two in the second, three in the third, three in the fourth, two in the fifth, and one in the last.

You can also estimate the time between two tide events with a few lines of code:

```javascript
const low = new Date("2026-10-06T07:42:00");
const high = new Date("2026-10-06T13:55:00");
const hours = (high - low) / (1000 * 60 * 60);
console.log(`Rising for ${hours.toFixed(1)} hours`);
console.log(`Roughly ${(hours / 6).toFixed(2)} hours per twelfth`);
```

Whatever method you use, plan to arrive an hour before low tide and head back as the water begins to rise. Local conditions such as wind and air pressure can push actual levels above or below the prediction, so treat the chart as a strong guide rather than a guarantee.
