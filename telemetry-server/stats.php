<?php
// stats.php — the RetroForge telemetry dashboard. Password from config.php (or public, see
// stats_public). Plain HTML and inline SVG: no JavaScript, no external requests.
declare(strict_types=1);
require __DIR__ . '/lib/common.php';

$cfg = telemetry_config();
$password = (string)($cfg['stats_password'] ?? '');
$public = (bool)($cfg['stats_public'] ?? false);

header('Cache-Control: no-store');
header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'self'");
header('X-Frame-Options: DENY');
header('Referrer-Policy: no-referrer');

function h(?string $s): string
{
    return htmlspecialchars($s ?? '', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

// --- access ----------------------------------------------------------------------------------------
session_name('rf_stats');
session_set_cookie_params(['httponly' => true, 'samesite' => 'Strict', 'secure' => !empty($_SERVER['HTTPS'])]);
session_start();

$loginError = '';
if (isset($_POST['logout'])) {
    $_SESSION = [];
    session_destroy();
    header('Location: ' . strtok($_SERVER['REQUEST_URI'] ?? 'stats.php', '?'));
    exit;
}
if ($password !== '' && isset($_POST['password'])) {
    usleep(300000); // a slow wrong guess
    if (hash_equals($password, (string)$_POST['password'])) {
        session_regenerate_id(true);
        $_SESSION['ok'] = true;
        header('Location: ' . ($_SERVER['REQUEST_URI'] ?? 'stats.php'));
        exit;
    }
    $loginError = 'Wrong password.';
}
$signedIn = !empty($_SESSION['ok']);
$allowed = $signedIn || $public;

// --- period ----------------------------------------------------------------------------------------
$periods = [7 => '7 days', 30 => '30 days', 90 => '90 days', 365 => '1 year', 0 => 'All time'];
$days = isset($_GET['days']) && array_key_exists((int)$_GET['days'], $periods) ? (int)$_GET['days'] : 30;
$since = $days > 0 ? gmdate('Y-m-d\TH:i:s\Z', time() - $days * 86400) : '0000';

// --- data ------------------------------------------------------------------------------------------
$data = null;
$error = '';
if ($allowed) {
    try {
        $db = telemetry_db();
        $one = function (string $sql, array $args = []) use ($db) {
            $q = $db->prepare($sql);
            $q->execute($args);
            return $q->fetchColumn();
        };
        $by = function (string $col) use ($db, $since): array {
            $q = $db->prepare("SELECT COALESCE(NULLIF($col, ''), 'unknown') AS k, COUNT(*) AS n
                               FROM devices WHERE last_seen >= ? GROUP BY 1 ORDER BY n DESC, k LIMIT 25");
            $q->execute([$since]);
            return $q->fetchAll(PDO::FETCH_KEY_PAIR);
        };
        $ago = fn(int $d) => gmdate('Y-m-d\TH:i:s\Z', time() - $d * 86400);
        $data = [
            'total' => (int)$one('SELECT COUNT(*) FROM devices'),
            'active' => (int)$one('SELECT COUNT(*) FROM devices WHERE last_seen >= ?', [$since]),
            'active_1d' => (int)$one('SELECT COUNT(*) FROM devices WHERE last_seen >= ?', [$ago(1)]),
            'new' => (int)$one('SELECT COUNT(*) FROM devices WHERE first_seen >= ?', [$since]),
            'reports' => (int)$one('SELECT COALESCE(SUM(report_count), 0) FROM devices'),
            'models' => $by('device_model'),
            'socs' => $by('soc'),
            'versions' => $by('os_version_id'),
            'countries' => $by('country'),
            'channels' => $by('ota_channel'),
            'targets' => $by('install_target'),
            'ram' => $by("CASE WHEN ram_mb IS NULL THEN NULL ELSE CAST(ROUND(ram_mb / 1024.0) AS INTEGER) || ' GB' END"),
            'storage' => $by("CASE WHEN storage_gb IS NULL THEN NULL ELSE storage_gb || ' GB' END"),
            'modes' => $by('build_mode'),
        ];
        // Daily series for the charts: the last N days (90 at most, so the bars stay readable).
        $span = $days > 0 ? min($days, 90) : 90;
        $first = gmdate('Y-m-d', time() - ($span - 1) * 86400);
        $series = [];
        for ($i = $span - 1; $i >= 0; $i--) {
            $series[gmdate('Y-m-d', time() - $i * 86400)] = ['active' => 0, 'new' => 0];
        }
        $q = $db->prepare('SELECT day, COUNT(*) FROM device_days WHERE day >= ? GROUP BY day');
        $q->execute([$first]);
        foreach ($q->fetchAll(PDO::FETCH_KEY_PAIR) as $d => $n) {
            if (isset($series[$d])) $series[$d]['active'] = (int)$n;
        }
        $q = $db->prepare('SELECT substr(first_seen, 1, 10), COUNT(*) FROM devices WHERE first_seen >= ? GROUP BY 1');
        $q->execute([$first]);
        foreach ($q->fetchAll(PDO::FETCH_KEY_PAIR) as $d => $n) {
            if (isset($series[$d])) $series[$d]['new'] = (int)$n;
        }
        $data['series'] = $series;
        if ($signedIn) {
            $data['recent'] = $db->query('SELECT device_id, device_model, soc, os_version_id, ota_channel,
                    install_target, country, first_seen, last_seen, report_count
                FROM devices ORDER BY last_seen DESC LIMIT 50')->fetchAll();
        }
    } catch (Throwable $e) {
        error_log('telemetry stats: ' . $e->getMessage());
        $error = 'The database could not be read. Check the path in config.php and that PHP can write to its folder.';
    }
}

// --- rendering helpers -----------------------------------------------------------------------------
function flag(string $cc): string
{
    if (!preg_match('/^[A-Z]{2}$/', $cc)) return '';
    return mb_chr(0x1F1E6 + ord($cc[0]) - 65) . mb_chr(0x1F1E6 + ord($cc[1]) - 65) . ' ';
}

function breakdown(string $title, array $rows, bool $flags = false): string
{
    $total = array_sum($rows);
    $out = '<section class="card"><h2>' . h($title) . '</h2>';
    if (!$rows) {
        return $out . '<p class="muted">No devices in this period.</p></section>';
    }
    $max = max($rows);
    $out .= '<table class="bars"><tbody>';
    foreach ($rows as $k => $n) {
        $k = (string)$k;
        $pct = $total ? round($n * 100 / $total) : 0;
        $w = $max ? round($n * 100 / $max, 1) : 0;
        $label = ($flags ? flag($k) : '') . h($k);
        $out .= "<tr><th scope=\"row\" title=\"" . h($k) . "\">$label</th>"
              . "<td class=\"bar\"><span style=\"width:{$w}%\"></span></td>"
              . "<td class=\"num\">" . number_format($n) . "</td><td class=\"pct\">$pct%</td></tr>";
    }
    return $out . '</tbody></table></section>';
}

function chart(array $series, string $key, string $title): string
{
    $n = count($series);
    $vals = array_column($series, $key);
    $max = max(1, max($vals ?: [0]));
    $W = 720; $H = 160; $pad = 2;
    $bw = $W / max(1, $n);
    $bars = '';
    $i = 0;
    foreach ($series as $day => $v) {
        $bh = $v[$key] ? max(2, round($v[$key] / $max * ($H - 20), 1)) : 0;
        $x = round($i * $bw + $pad / 2, 1);
        $y = $H - $bh;
        $w = max(1, round($bw - $pad, 1));
        $bars .= "<rect x=\"$x\" y=\"$y\" width=\"$w\" height=\"$bh\" rx=\"1.5\"><title>" . h($day) . ': ' . $v[$key] . "</title></rect>";
        $i++;
    }
    $days = array_keys($series);
    $total = array_sum($vals);
    $peak = max($vals ?: [0]);
    return '<section class="card wide"><h2>' . h($title) . '</h2>'
        . '<p class="muted">Peak ' . number_format($peak) . ($key === 'new' ? ' · total ' . number_format($total) : '') . '</p>'
        . "<svg class=\"chart\" viewBox=\"0 0 $W $H\" preserveAspectRatio=\"none\" role=\"img\" aria-label=\"" . h($title) . "\">$bars</svg>"
        . '<div class="axis"><span>' . h($days[0] ?? '') . '</span><span>' . h(end($days) ?: '') . '</span></div></section>';
}

function ago(string $iso): string
{
    $s = time() - (strtotime($iso) ?: time());
    if ($s < 120) return 'just now';
    if ($s < 7200) return intdiv($s, 60) . ' min ago';
    if ($s < 172800) return intdiv($s, 3600) . ' h ago';
    return intdiv($s, 86400) . ' days ago';
}
?><!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>RetroForge Stats</title>
<style>
:root {
  --bg: #f6f5fa; --card: #ffffff; --text: #1d1b26; --muted: #6b6878; --line: #e4e1ee;
  --accent: #8b3fd9; --accent-soft: #eadcfb; --bad: #c0392b;
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #121119; --card: #1c1a26; --text: #ecebf3; --muted: #9c98ad; --line: #2c2938;
          --accent: #b57cf5; --accent-soft: #33264a; --bad: #ff7b6b; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text);
       font: 15px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
header { display: flex; flex-wrap: wrap; gap: 12px 24px; align-items: center; justify-content: space-between;
         padding: 20px 24px; border-bottom: 1px solid var(--line); background: var(--card); }
header h1 { margin: 0; font-size: 20px; letter-spacing: .2px; }
header h1 span { color: var(--accent); }
nav { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
nav a, button { color: var(--text); text-decoration: none; padding: 6px 12px; border-radius: 999px;
                border: 1px solid var(--line); background: transparent; font: inherit; cursor: pointer; }
nav a.on { background: var(--accent); border-color: var(--accent); color: #fff; }
main { max-width: 1200px; margin: 0 auto; padding: 24px; }
.kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 16px; margin-bottom: 16px; }
.kpi { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 16px 18px; }
.kpi b { display: block; font-size: 30px; font-variant-numeric: tabular-nums; line-height: 1.1; }
.kpi span { color: var(--muted); font-size: 13px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 16px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 16px 18px; min-width: 0; }
.card.wide { grid-column: 1 / -1; }
.card h2 { margin: 0 0 10px; font-size: 15px; }
.muted { color: var(--muted); margin: 0 0 8px; font-size: 13px; }
table { width: 100%; border-collapse: collapse; }
.bars th { text-align: left; font-weight: 500; padding: 4px 8px 4px 0; white-space: nowrap; overflow: hidden;
           text-overflow: ellipsis; max-width: 170px; }
.bars td { padding: 4px 0; }
.bars .bar { width: 100%; padding-right: 10px; }
.bars .bar span { display: block; height: 10px; border-radius: 5px; background: var(--accent); min-width: 2px; }
.num, .pct { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
.pct { color: var(--muted); padding-left: 8px !important; width: 3.5em; }
.chart { width: 100%; height: 160px; display: block; }
.chart rect { fill: var(--accent); }
.chart rect:hover { fill: var(--text); }
.axis { display: flex; justify-content: space-between; color: var(--muted); font-size: 12px; margin-top: 4px; }
.scroll { overflow-x: auto; }
.devices th, .devices td { text-align: left; padding: 6px 10px 6px 0; border-bottom: 1px solid var(--line); white-space: nowrap; font-size: 13px; }
.devices th { color: var(--muted); font-weight: 500; }
code { font-size: 12px; }
.login { max-width: 360px; margin: 12vh auto; }
.login input { width: 100%; padding: 10px 12px; border-radius: 10px; border: 1px solid var(--line);
               background: var(--bg); color: var(--text); font: inherit; margin: 8px 0 12px; }
.login button { background: var(--accent); border-color: var(--accent); color: #fff; width: 100%; padding: 10px; }
.error { color: var(--bad); }
footer { color: var(--muted); font-size: 12px; text-align: center; padding: 8px 24px 32px; }
@media (max-width: 600px) {
  header, main { padding: 16px; }
  .grid { grid-template-columns: 1fr; }
  .kpi b { font-size: 24px; }
}
</style>
</head>
<body>
<?php if ($password === '' && !$public): ?>
  <main><section class="card login"><h2>Stats are switched off</h2>
  <p class="muted">Set <code>stats_password</code> (or <code>stats_public</code>) in config.php.</p></section></main>
<?php elseif (!$allowed): ?>
  <main><form class="card login" method="post">
    <h2>RetroForge stats</h2>
    <label for="pw" class="muted">Password</label>
    <input id="pw" type="password" name="password" autocomplete="current-password" autofocus required>
    <?php if ($loginError): ?><p class="error"><?= h($loginError) ?></p><?php endif ?>
    <button type="submit">Sign in</button>
  </form></main>
<?php else: ?>
  <header>
    <h1><span>RetroForge</span> device stats</h1>
    <nav>
      <?php foreach ($periods as $d => $label): ?>
        <a href="?days=<?= $d ?>" class="<?= $d === $days ? 'on' : '' ?>"><?= h($label) ?></a>
      <?php endforeach ?>
      <?php if ($signedIn): ?>
        <form method="post" style="margin:0"><button name="logout" value="1">Sign out</button></form>
      <?php endif ?>
    </nav>
  </header>
  <main>
  <?php if ($error): ?>
    <section class="card"><p class="error"><?= h($error) ?></p></section>
  <?php else: $p = strtolower($periods[$days]); ?>
    <div class="kpis">
      <div class="kpi"><b><?= number_format($data['total']) ?></b><span>devices ever seen</span></div>
      <div class="kpi"><b><?= number_format($data['active']) ?></b><span>active, <?= h($days ? "last $p" : 'all time') ?></span></div>
      <div class="kpi"><b><?= number_format($data['active_1d']) ?></b><span>active, last 24 hours</span></div>
      <div class="kpi"><b><?= number_format($data['new']) ?></b><span>new, <?= h($days ? "last $p" : 'all time') ?></span></div>
      <div class="kpi"><b><?= number_format($data['reports']) ?></b><span>reports (≈ boots)</span></div>
    </div>
    <div class="grid">
      <?= chart($data['series'], 'active', 'Active devices per day') ?>
      <?= chart($data['series'], 'new', 'New devices per day') ?>
      <?= breakdown('Device model', $data['models']) ?>
      <?= breakdown('SoC', $data['socs']) ?>
      <?= breakdown('RetroForge version', $data['versions']) ?>
      <?= breakdown('Country', $data['countries'], true) ?>
      <?= breakdown('Update channel', $data['channels']) ?>
      <?= breakdown('Installed on', $data['targets']) ?>
      <?= breakdown('Memory', $data['ram']) ?>
      <?= breakdown('Boot disk size', $data['storage']) ?>
      <?= breakdown('Build', $data['modes']) ?>
      <?php if (!empty($data['recent'])): ?>
      <section class="card wide"><h2>Recently seen devices</h2>
        <div class="scroll"><table class="devices">
          <thead><tr><th>Device ID</th><th>Model</th><th>SoC</th><th>Version</th><th>Channel</th><th>On</th><th>Country</th><th>First seen</th><th>Last seen</th><th>Reports</th></tr></thead>
          <tbody>
          <?php foreach ($data['recent'] as $r): ?>
            <tr><td><code><?= h($r['device_id']) ?></code></td><td><?= h($r['device_model']) ?></td><td><?= h($r['soc']) ?></td>
                <td><?= h($r['os_version_id']) ?></td><td><?= h($r['ota_channel']) ?></td><td><?= h($r['install_target']) ?></td>
                <td><?= flag((string)$r['country']) . h($r['country']) ?></td><td><?= h(substr((string)$r['first_seen'], 0, 10)) ?></td>
                <td title="<?= h($r['last_seen']) ?>"><?= h(ago((string)$r['last_seen'])) ?></td><td class="num"><?= number_format((int)$r['report_count']) ?></td></tr>
          <?php endforeach ?>
          </tbody></table></div>
      </section>
      <?php endif ?>
    </div>
    <p class="muted" style="margin-top:16px">Breakdowns count devices seen in the selected period. Times are UTC.</p>
  <?php endif ?>
  </main>
  <footer>Country data: IP geolocation by <a href="https://db-ip.com" style="color:inherit">DB-IP</a></footer>
<?php endif ?>
</body>
</html>
