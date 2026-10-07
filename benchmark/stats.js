function mean(a) { return a.reduce((s, x) => s + x, 0) / a.length; }
function median(a) {
  const s = [...a].sort((x, y) => x - y);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}
function stdev(a) {
  if (a.length < 2) return 0;
  const m = mean(a);
  return Math.sqrt(a.reduce((s, x) => s + (x - m) ** 2, 0) / (a.length - 1));
}
function pct(a, p) {
  const s = [...a].sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.floor(p * s.length))];
}

function report(label, samples) {
  return {
    label,
    n: samples.length,
    mean:   +mean(samples).toFixed(3),
    median: +median(samples).toFixed(3),
    stdev:  +stdev(samples).toFixed(3),
    p50:    +pct(samples, 0.50).toFixed(3),
    p95:    +pct(samples, 0.95).toFixed(3),
    p99:    +pct(samples, 0.99).toFixed(3),
    min:    +Math.min(...samples).toFixed(3),
    max:    +Math.max(...samples).toFixed(3),
  };
}

module.exports = { mean, median, stdev, pct, report };