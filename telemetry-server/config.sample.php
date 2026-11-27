<?php
// Copy to config.php and edit. config.php is not served (see .htaccess) and holds the stats password.
return [
    // SQLite database. Keep it outside the web root if your host lets you; otherwise data/ is
    // blocked by its .htaccess (Apache) — on nginx add the `location` rule from README.md.
    'db' => __DIR__ . '/data/telemetry.db',

    // Country database (.mmdb): DB-IP "IP to Country Lite" or MaxMind GeoLite2-Country.
    // geoip-update.sh fetches DB-IP's. Missing file = country left empty.
    'geoip_db' => __DIR__ . '/data/country.mmdb',

    // Behind Cloudflare or another proxy you control: true takes the client IP from
    // CF-Connecting-IP / X-Forwarded-For and the country from CF-IPCountry. Leave false when clients
    // reach PHP directly, or anyone can claim any address.
    'trust_proxy' => false,

    // Password for stats.php. Make it long. Empty = stats page disabled.
    'stats_password' => '',

    // true = stats.php needs no password (aggregate numbers only; device IDs are never shown publicly).
    'stats_public' => false,
];
