<?php
// Shared by report.php and stats.php: configuration and the database.
declare(strict_types=1);

function telemetry_config(): array
{
    static $cfg = null;
    if ($cfg === null) {
        $file = dirname(__DIR__) . '/config.php';
        if (!is_file($file)) {
            http_response_code(500);
            header('Content-Type: text/plain');
            exit("config.php missing: copy config.sample.php to config.php\n");
        }
        $cfg = require $file;
    }
    return $cfg;
}

function telemetry_db(): PDO
{
    static $pdo = null;
    if ($pdo === null) {
        $path = telemetry_config()['db'];
        $pdo = new PDO('sqlite:' . $path, null, null, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
        $pdo->exec('PRAGMA busy_timeout = 10000');
        $pdo->exec('PRAGMA foreign_keys = ON');
        // schema.sql is idempotent (CREATE ... IF NOT EXISTS) and costs well under a millisecond.
        $pdo->exec(file_get_contents(dirname(__DIR__) . '/schema.sql'));
    }
    return $pdo;
}

function utc_now(): string
{
    return gmdate('Y-m-d\TH:i:s\Z');
}
