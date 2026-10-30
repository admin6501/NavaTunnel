# NavaTunnel common questions

[فارسی](FAQ.fa.md) · [Home](../README.md) · [Setup](USAGE.md) · [Operations](OPERATIONS.md) · [Commands](CLI.md)

## What runs on each server?

Iran accepts users on the forwarded service ports and runs FRPS. Foreign runs FRPC and your actual application, such as Xray. GRE/FOU provides the IP path between FRPC and FRPS. NavaTunnel creates the tunnel, not application inbounds, users or subscriptions.

## Can several Iran servers share one foreign?

Yes. Each Iran has an independent GRE/FRPC connection on foreign, and both can expose the same service ports to the same foreign application. Control ports may also match across different Iran servers. Their internal GRE networks must be different. Follow the [shared-foreign guide](USAGE.md#connect-several-iran-servers-to-one-foreign-server); do not change the existing first connection just to add a second one.

On a single Iran, ports for its different foreign tunnels must not overlap. These connections do not automatically distribute users or switch them to a healthier Iran.

## Does changing FRP protocol change my application's protocol?

No. TCP/KCP/QUIC/WebSocket/WSS here are the FRP transport. VLESS/VMess/Trojan and their inbounds are configured in your application. To add an inbound, create it on foreign and add its port to the complete forwarded-port list on each relevant Iran, then update its selected foreign connection. See [the steps](USAGE.md#add-an-application-protocol-or-inbound).

## Is the tunnel encrypted?

GRE/FOU itself is not encrypted. FRP 0.71 defaults to TLS, so an absent explicit `transport.tls.enable` setting is not proof of plaintext. Check the effective version and configuration rather than one grep result. Encryption does not automatically validate the peer's certificate identity. Application TLS is a separate layer; NavaTunnel does not install application certificates for you. WSS configures an FRP TLS front, not a website or Cloudflare proxy.

## Does loss recovery remove packet loss?

No. Choosing recovery selects KCP/FEC and can recover some missing transport data at the cost of extra traffic. It cannot fix the physical route or guarantee zero loss. Saved selection on Iran does not verify foreign's live transport; apply the new code to the matching selected connection. Disabling recovery returns KCP to TCP. Neither cover traffic nor the SYN limiter is packet-loss repair.

## How much traffic does 1 GB downloaded by a user consume?

There is no fixed multiplier. The provider's incoming/outgoing billing rules, packet sizes, GRE/FOU and FRP/TLS headers, retransmissions and FEC all matter. Cover traffic adds its own usage. GRE counters measure inner IPv4, so use the provider's own meter for billable consumption. An idle ping test is small but not traffic-free; a throughput test can consume much more.

## Why does usage say zero or stop increasing?

The display is a saved sample, usually updated every 10 seconds; three decimals round small values to `0.000 GB`. Verify the application is using that tunnel, then inspect its counter and the traffic service journal. `NavaTunnel traffic repair` repairs monitoring while keeping saved totals, limits and modes. Do not reset or delete the counter merely to refresh it. [Traffic guide](OPERATIONS.md#traffic-and-quotas)

## Which IP goes in the migration public-IP field?

`Destination tunnel public IPv4` is the **new destination's own public IPv4**. When moving foreign, enter the new foreign IP; when moving Iran, enter the new Iran IP. Enter accepts the SSH destination IP. It is not the opposite server's IP. After migration, update the other endpoint(s), and move the foreign application separately. [Full migration checklist](OPERATIONS.md#migrate-over-ssh)

## Do two same-name Cloudflare A records provide automatic failover?

With DNS-only records, they offer DNS round-robin-style distribution, not health checks, packet-loss-aware routing or guaranteed equal load. DNS caching and client address selection affect which Iran receives an attempt. DNS-only records expose the Iran IPs directly. Cloudflare's ordinary orange-cloud web proxy does not proxy arbitrary TCP/UDP application protocols just because their ports appear in NavaTunnel.

NavaTunnel does not currently update Cloudflare DNS or run an external quality-aware load balancer. A DNS answer containing two IPs does not prove which one the application used. A `dialing TCP to domain:port` log line also does not identify the selected IP.

## How do I find which Iran a user actually used?

If the client's connection log includes the resolved remote IP for the successful connection, compare it to your Iran IPs. If only the hostname is logged, inspect actual connections on each Iran. For the first FRPS service:

```bash
journalctl -u frps -f -o cat | grep --line-buffered 'get a user connection'
```

Reconnect the user and generate traffic, then match their Internet source IP before VPN connection. Use the actual `frps-N` unit for other Iran tunnels. This requires informational connection logging; absence of a log line alone is not proof of no traffic. Existing TCP connections can also be inspected with `ss -tnp` using their service port. With many users behind the same NAT, correlate time and source ports too. If both Iran paths end at the same foreign server, an IP-check website shows the same foreign exit IP for both and cannot distinguish them.

## Do start, stop, update and migration control the opposite server?

Selected start/stop actions affect only the local connection. Updating scripts does not remotely update another server. SSH migration installs/restores the destination but leaves the source running; opposite endpoints still require the new address. A successful service start does not prove application authentication or end-to-end forwarding. Test the actual client before retiring a source.

## Are Cluster, NavaLink, a web panel or Backhaul required?

No. Current setup is GRE/FOU with FRP and the terminal menu. Old Cluster/NavaLink connections are retired as described in the [upgrade guide](OPERATIONS.md#upgrading-from-older-versions). The small optional WSS TLS helper and compatibility paths do not re-enable those features.
