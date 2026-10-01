# Synology Assistant discovery protocol

Synology does not publish this protocol. Everything below was recovered by reading the
x86_64 `DSAssistant` binary (symbols are intact: `CFindHostUDP`, `FHOSTPacketWrite`,
`grgfieldAttribs`, ...) and then **verified against a live DS918+ (DSM 7.4.1-90080)** on
2026-10-01. Items marked *unverified* come from the binary only.

The web finder (finds.synology.com) is a different mechanism: it asks a DSM host to run
`/webman/search.cgi`, so it cannot see a NAS that has not been set up.

## Transport

- UDP, **port 9999**, IPv4 only.
- The query is broadcast to `255.255.255.255:9999` (the OEM app also walks every interface
  and repeats the query once a second).
- **The client must listen on UDP 9999.** The NAS replies from its port 1234 to
  `255.255.255.255:9999` (broadcast) and to the querying host's port 9999, regardless of the
  query's source port (confirmed in a capture of the OEM app, which queries from random
  ports). A client bound to an ephemeral port never hears the reply. Bind 9999 with
  `SO_REUSEADDR | SO_REUSEPORT | SO_BROADCAST` so it can coexist with the OEM app.
- Broadcasts loop back to the sender, so ignore datagrams whose packet type is 1 (query).

## Packet layout

```
12 34 56 78 'S' 'Y' 'N' 'O'        8-byte header (plain)
12 34 55 66 'S' 'Y' 'N' 'O'        8-byte header (encrypted variant, libsodium; not needed)
then a sequence of fields:  [id: u8] [length: u8] [value: length bytes]
```

- Integers are 4 or 8 bytes, **little-endian**, except the address fields `0x12`–`0x15`,
  `0x1e` which keep network byte order (`0a 14 1f 09` = 10.20.31.9).
- Strings are raw bytes, not NUL terminated, max 255.
- Zero-length fields occur (`0x50`, `0x52`, ...). Field order is not significant.

## Query (client to NAS)

Minimum that the NAS answers (verified):

| Field | Meaning | Value |
|---|---|---|
| `0xa4` | FindHost protocol version | u32 `0x01020000` |
| `0x01` | packet type | u32 `1` (query) |

The OEM app (157-byte query, captured) also sends `0xa6` = `0x78`, service bitmaps
`0xb0` and `0xb8` = `0x1c0` (bits 6, 7, 8), `0xb1`/`0xb9` = 0, `0x7c` = `00:00:00:00:00:00`,
`0xc4` (its libsodium public key, 64 hex chars) and `0xc5` (process ID).

- **`0x7c` is a target-MAC filter.** All zeros means "any device". A non-zero MAC that does
  not match the NAS makes it ignore the query (verified). Omit the field on a broadcast.
- **`0xc4`/`0xc5` switch the reply to the encrypted format** (header `12 34 55 66 'SYNO'`,
  455 bytes, opaque blobs in fields `0xd7 0xb4 0x69 0x6d 0x74 0x4e`). Omit them and the NAS
  sends the plain 308-byte reply, which is what this implementation uses.

## Response (NAS to client), packet type `0x01` = 2

Verified against the OEM app's window for the same device:

| Field | Meaning | Example |
|---|---|---|
| `0x01` | packet type | u32 `2` |
| `0x11` | server name | `Automatica` |
| `0x19` | MAC address (string) | `00:11:32:aa:bb:01` |
| `0x12` | IP address (network order) | 10.20.31.9 |
| `0x13` | netmask | 255.255.255.0 |
| `0x14` | gateway | 10.20.31.1 |
| `0x15` | DNS | 1.1.1.2 |
| `0x18` | IP assignment: 1 = Manual, 0 = DHCP (DHCP side *unverified*) | `1` |
| `0x1e` | the querying host's IP as seen by the NAS | 10.20.31.192 |
| `0x77` | DSM version | `7.4.1` |
| `0x49` | DSM build number | `90080` |
| `0x78` | model | `DS918+` |
| `0xc0` | serial number | `TESTSERIAL123` |
| `0x70` | platform / unique id | `synology_apollolake_918+` |
| `0xc1` | product | `DSM` |
| `0x48` | state code: 1 = Ready (other values *unverified*) | `1` |
| `0x75` / `0x76` | DSM HTTP / HTTPS port (verified: both answer 200; TCP 5000 is refused on this unit) | 2000 / 2001 |
| `0xb0` `0xb1` `0xb8` `0xb9` | service bitmaps | |
| `0x73` | short serial fragment, purpose *unverified* | |

The full field table (85 entries: id, int/string/array type, flags) lives at
`_grgfieldAttribs` in the binary; fields not listed here are unidentified.

## Other OEM features (not reverse engineered)

- Wake-on-LAN: standard magic packet, hosts stored under `WOL/RegisteredHosts/`.
- Install / recovery / memory test / network setting: further packet types sent to NAS units
  that are not configured, plus a TCP channel (`CSynoTCP`).

## Discovery only works within the server's own subnet

A Synology answers discovery probes only from hosts on its own subnet. Tested with no firewall in
between:

- From a computer on one subnet, a unicast query to a server on the same subnet was answered, but a
  query to a server on another subnet (reachable by ping and by TCP on the DSM ports) got no reply.
- From a Mac connected by WireGuard to three remote subnets, queries (unicast, and a sweep of
  every address in each subnet) to the servers there got no replies either.

So a routed network, including a site-to-site VPN, cannot be scanned with this protocol. Run the
client on a computer on the same subnet as the servers.

Servers with several network ports answer once per port (different MAC and IP, same serial
number), so the serial number is the key for treating them as one server.

Timing, measured with one broadcast query every 5 s for two minutes (25 queries, with and
without a VPN up): every query was answered, 1.1 to 3.3 s later (mean 2.1 s), as a pair of
identical datagrams. Sending queries every second instead gets only the first one answered, so
send one query and retry only if nothing has replied after about 3.5 s.

## macOS Local Network privacy

Broadcast UDP needs the Local Network permission. Until the user allows it, macOS fails sends to
local addresses with EHOSTUNREACH (errno 65) and shows its prompt on the first attempt. The OEM
app starts scanning before the prompt is answered, so its first scan is always empty.

There is no API to read the permission state, and a Bonjour self-discovery probe wrongly reports
success while the prompt is still open. The Swift app instead makes a real send (an empty
datagram to the broadcast discard port) once a second and starts scanning when it succeeds.
