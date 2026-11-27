<?php
// POST report.php — the once-per-boot report from retroforge-telemetry (rootfs/overlay/usr/bin).
//
//   201 {"status":"created"}  first report from this device_id
//   200 {"status":"updated"}  returning device
//   400 malformed / 405 not POST / 413 too large / 503 database error (the client retries)
//
// New devices are inserted; returning ones get last_seen and their current facts, first_seen never
// changes. The request IP is used for the GeoIP lookup only and is never stored.
declare(strict_types=1);
require __DIR__ . '/lib/common.php';

const MAX_BODY = 8192;
const SCHEMAS = [1];
const STR_FIELDS = ['os_name', 'os_version_id', 'os_version', 'os_build_id', 'os_variant', 'os_git',
    'build_mode', 'soc', 'device_model', 'device_profile', 'kernel', 'arch', 'install_target',
    'ota_channel', 'boot_slot'];
const INT_FIELDS = ['cpu_count', 'ram_mb', 'storage_gb', 'uptime_s'];

function reply(int $code, array $body): never
{
    http_response_code($code);
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    echo json_encode($body);
    exit;
}

function client_ip(array $cfg): string
{
    if ($cfg['trust_proxy']) {
        if (!empty($_SERVER['HTTP_CF_CONNECTING_IP'])) {
            return trim($_SERVER['HTTP_CF_CONNECTING_IP']);
        }
        if (!empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
            return trim(explode(',', $_SERVER['HTTP_X_FORWARDED_FOR'])[0]);
        }
    }
    return $_SERVER['REMOTE_ADDR'] ?? '';
}

function country(array $cfg, string $ip): ?string
{
    if ($cfg['trust_proxy']) {
        $cf = $_SERVER['HTTP_CF_IPCOUNTRY'] ?? '';
        if (preg_match('/^[A-Z]{2}$/', $cf) && $cf !== 'XX' && $cf !== 'T1') {
            return $cf;
        }
    }
    if (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)) {
        return null;
    }
    $db = $cfg['geoip_db'] ?? '';
    if ($db === '' || !is_file($db)) {
        return null;
    }
    try {
        require_once __DIR__ . '/lib/mmdb.php';
        $rec = (new Mmdb($db))->get($ip);
    } catch (Throwable $e) {
        error_log('telemetry: GeoIP: ' . $e->getMessage());
        return null;
    }
    $code = $rec['country']['iso_code'] ?? $rec['registered_country']['iso_code'] ?? null;
    return is_string($code) && preg_match('/^[A-Z]{2}$/', $code) ? $code : null;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    header('Allow: POST');
    reply(405, ['error' => 'POST only']);
}
$raw = file_get_contents('php://input', false, null, 0, MAX_BODY + 1);
if ($raw === false || $raw === '') {
    reply(400, ['error' => 'empty body']);
}
if (strlen($raw) > MAX_BODY) {
    reply(413, ['error' => 'too large']);
}
$data = json_decode($raw, true);
if (!is_array($data)) {
    reply(400, ['error' => 'body is not a JSON object']);
}
if (!in_array($data['schema'] ?? null, SCHEMAS, true)) {
    reply(400, ['error' => 'unknown schema']);
}
$id = $data['device_id'] ?? null;
if (!is_string($id) || !preg_match('/^[0-9a-f]{20}$/', $id)) {
    reply(400, ['error' => 'device_id must be 20 lowercase hex digits']);
}

$rec = [':device_id' => $id, ':schema' => $data['schema']];
foreach (STR_FIELDS as $f) {
    $v = $data[$f] ?? null;
    $rec[":$f"] = is_string($v) && $v !== '' ? mb_substr($v, 0, 128) : null;
}
foreach (INT_FIELDS as $f) {
    $v = $data[$f] ?? null;
    $rec[":$f"] = is_int($v) && $v >= 0 && $v < 2 ** 40 ? $v : null;
}
$cfg = telemetry_config();
$rec[':country'] = country($cfg, client_ip($cfg));
$rec[':now'] = utc_now();

$fields = array_merge(STR_FIELDS, INT_FIELDS);
$cols = implode(', ', $fields);
$vals = implode(', ', array_map(fn($f) => ":$f", $fields));
$sets = implode(",\n    ", array_map(fn($f) => "$f = excluded.$f", $fields));
$upsert = "
INSERT INTO devices (device_id, first_seen, last_seen, report_count, first_version_id, country, schema, $cols)
VALUES (:device_id, :now, :now, 1, :os_version_id, :country, :schema, $vals)
ON CONFLICT(device_id) DO UPDATE SET
    last_seen    = excluded.last_seen,
    report_count = devices.report_count + 1,
    country      = COALESCE(excluded.country, devices.country),
    schema       = excluded.schema,
    $sets";

try {
    $db = telemetry_db();
    $db->exec('BEGIN IMMEDIATE');
    $q = $db->prepare('SELECT 1 FROM devices WHERE device_id = ?');
    $q->execute([$id]);
    $new = $q->fetchColumn() === false;
    $db->prepare($upsert)->execute($rec);
    $db->prepare('INSERT OR IGNORE INTO device_days (day, device_id) VALUES (?, ?)')
       ->execute([substr($rec[':now'], 0, 10), $id]);
    if ($rec[':os_build_id'] !== null) {
        $db->prepare('INSERT OR IGNORE INTO device_builds (device_id, os_build_id, os_version_id, first_seen)
                      VALUES (?, ?, ?, ?)')
           ->execute([$id, $rec[':os_build_id'], $rec[':os_version_id'], $rec[':now']]);
    }
    $db->exec('COMMIT');
} catch (Throwable $e) {
    if (isset($db)) {
        try { $db->exec('ROLLBACK'); } catch (Throwable) {}
    }
    error_log('telemetry: ' . $e->getMessage());
    reply(503, ['error' => 'storage unavailable']);
}
reply($new ? 201 : 200, ['status' => $new ? 'created' : 'updated']);
