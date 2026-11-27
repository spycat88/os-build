<?php
// Minimal MaxMind DB (.mmdb) reader: enough to look up an IP's country in DB-IP's "IP to Country
// Lite" or MaxMind's GeoLite2-Country, with no Composer package and no PHP extension.
// Format: https://maxmind.github.io/MaxMind-DB/
declare(strict_types=1);

final class Mmdb
{
    private const MARKER = "\xAB\xCD\xEFMaxMind.com";

    private string $buf;
    private int $nodeCount;
    private int $recordSize;
    private int $ipVersion;
    private int $treeSize;
    private int $ipv4Start = 0;

    public function __construct(string $path)
    {
        $buf = @file_get_contents($path);
        if ($buf === false) {
            throw new RuntimeException("cannot read $path");
        }
        $this->buf = $buf;
        $pos = strrpos($buf, self::MARKER);
        if ($pos === false) {
            throw new RuntimeException("$path is not a MaxMind DB");
        }
        $metaStart = $pos + strlen(self::MARKER);
        [$meta] = $this->decode($metaStart, $metaStart);
        $this->nodeCount = (int)$meta['node_count'];
        $this->recordSize = (int)$meta['record_size'];
        $this->ipVersion = (int)$meta['ip_version'];
        if (!in_array($this->recordSize, [24, 28, 32], true)) {
            throw new RuntimeException("unsupported record size {$this->recordSize}");
        }
        $this->treeSize = intdiv($this->recordSize * 2, 8) * $this->nodeCount;
        if ($this->ipVersion === 6) {
            $node = 0;
            for ($i = 0; $i < 96 && $node < $this->nodeCount; $i++) {
                $node = $this->record($node, 0);
            }
            $this->ipv4Start = $node;
        }
    }

    /** The record for $ip, or null when the database has none. */
    public function get(string $ip): ?array
    {
        $packed = @inet_pton($ip);
        if ($packed === false) {
            return null;
        }
        $bits = strlen($packed) * 8;
        if ($bits === 128 && $this->ipVersion === 4) {
            return null;
        }
        $node = ($bits === 32 && $this->ipVersion === 6) ? $this->ipv4Start : 0;
        for ($i = 0; $i < $bits && $node < $this->nodeCount; $i++) {
            $bit = (ord($packed[$i >> 3]) >> (7 - ($i & 7))) & 1;
            $node = $this->record($node, $bit);
        }
        if ($node <= $this->nodeCount) {
            return null; // == node_count: no data; < : ran out of bits
        }
        $dataStart = $this->treeSize + 16;
        [$value] = $this->decode($this->treeSize + ($node - $this->nodeCount), $dataStart);
        return is_array($value) ? $value : null;
    }

    private function record(int $node, int $bit): int
    {
        $b = $this->buf;
        switch ($this->recordSize) {
            case 24:
                $o = $node * 6 + $bit * 3;
                return (ord($b[$o]) << 16) | (ord($b[$o + 1]) << 8) | ord($b[$o + 2]);
            case 28:
                $o = $node * 7;
                if ($bit === 0) {
                    return ((ord($b[$o + 3]) & 0xF0) << 20) | (ord($b[$o]) << 16) | (ord($b[$o + 1]) << 8) | ord($b[$o + 2]);
                }
                return ((ord($b[$o + 3]) & 0x0F) << 24) | (ord($b[$o + 4]) << 16) | (ord($b[$o + 5]) << 8) | ord($b[$o + 6]);
            default:
                $o = $node * 8 + $bit * 4;
                return unpack('N', substr($b, $o, 4))[1];
        }
    }

    private function uint(int $off, int $len): int
    {
        $v = 0;
        for ($i = 0; $i < $len; $i++) {
            $v = ($v << 8) | ord($this->buf[$off + $i]);
        }
        return $v;
    }

    /** Decode the field at absolute offset $off. Pointers are relative to $base. Returns [value, next offset]. */
    private function decode(int $off, int $base): array
    {
        $ctrl = ord($this->buf[$off++]);
        $type = $ctrl >> 5;
        if ($type === 1) { // pointer
            $ss = ($ctrl >> 3) & 3;
            $vvv = $ctrl & 7;
            switch ($ss) {
                case 0: $p = ($vvv << 8) | $this->uint($off, 1); $off += 1; break;
                case 1: $p = (($vvv << 16) | $this->uint($off, 2)) + 2048; $off += 2; break;
                case 2: $p = (($vvv << 24) | $this->uint($off, 3)) + 526336; $off += 3; break;
                default: $p = $this->uint($off, 4); $off += 4;
            }
            [$value] = $this->decode($base + $p, $base);
            return [$value, $off];
        }
        if ($type === 0) {
            $type = 7 + ord($this->buf[$off++]);
        }
        $size = $ctrl & 0x1F;
        if ($size === 29) {
            $size = 29 + $this->uint($off, 1); $off += 1;
        } elseif ($size === 30) {
            $size = 285 + $this->uint($off, 2); $off += 2;
        } elseif ($size === 31) {
            $size = 65821 + $this->uint($off, 3); $off += 3;
        }
        switch ($type) {
            case 2: // utf8 string
            case 4: // bytes
                return [substr($this->buf, $off, $size), $off + $size];
            case 3: // double
                return [unpack('E', substr($this->buf, $off, 8))[1], $off + 8];
            case 15: // float
                return [unpack('G', substr($this->buf, $off, 4))[1], $off + 4];
            case 5: case 6: case 9: case 10: // unsigned ints (64/128-bit may overflow; never needed here)
                return [$size > 8 ? 0 : $this->uint($off, $size), $off + $size];
            case 8: // int32
                $v = $this->uint($off, $size);
                if ($size === 4 && $v >= 0x80000000) {
                    $v -= 0x100000000;
                }
                return [$v, $off + $size];
            case 7: // map
                $map = [];
                for ($i = 0; $i < $size; $i++) {
                    [$k, $off] = $this->decode($off, $base);
                    [$v, $off] = $this->decode($off, $base);
                    $map[$k] = $v;
                }
                return [$map, $off];
            case 11: // array
                $arr = [];
                for ($i = 0; $i < $size; $i++) {
                    [$arr[], $off] = $this->decode($off, $base);
                }
                return [$arr, $off];
            case 14: // boolean
                return [$size !== 0, $off];
            default: // container / end marker: not used in data records
                return [null, $off];
        }
    }
}
